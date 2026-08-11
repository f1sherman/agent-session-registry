# frozen_string_literal: true

require_relative "test_helper"
require "agent_session_registry/completion_server"

class CompletionServerTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    File.chmod(0o700, @directory)
    @path = File.join(@directory, "done.sock")
    @database = AgentSessionRegistry::Database.new(
      path: File.join(@directory, "registry.sqlite3")
    )
    @identity = AgentSessionRegistry::Identity.new(
      source: "pi", hostname: "dev", session_id: "session-1"
    )
    register(@identity)
    @current_identity = @identity
    @server = AgentSessionRegistry::CompletionServer.new(
      path: @path,
      database: @database,
      identity_provider: -> { @current_identity }
    )
  end

  def teardown
    @server&.stop
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
  end

  def test_lifecycle_permissions_exact_identity_and_idempotence
    refute File.exist?(@path)
    assert_same @server, @server.start
    assert File.socket?(@path)
    assert_equal 0o700, File.stat(@directory).mode & 0o777
    assert_equal 0o600, File.stat(@path).mode & 0o777

    assert_equal({ "ok" => true, "status" => "done" }, request(valid_request))
    assert_equal "done", @database.fetch(@identity).fetch(:status)
    assert_equal({ "ok" => true, "status" => "done" }, request(valid_request))

    @server.stop
    refute File.exist?(@path)
    assert_raises(Errno::ENOENT) { UNIXSocket.new(@path) }
  end

  def test_rejects_wrong_missing_extra_invalid_and_unavailable_identities
    @server.start
    other = AgentSessionRegistry::Identity.new(
      source: "pi", hostname: "dev", session_id: "session-2"
    )
    register(other)

    invalid = [
      valid_request.merge("session_id" => "session-2"),
      valid_request.reject { |key, _| key == "action" },
      valid_request.merge("extra" => true),
      valid_request.merge("session_id" => 1),
      valid_request.merge("action" => "update")
    ]
    invalid.each do |payload|
      response = request(payload)
      assert_equal false, response.fetch("ok")
      assert_kind_of String, response.fetch("error")
    end
    assert_equal "active", @database.fetch(@identity).fetch(:status)
    assert_equal "active", @database.fetch(other).fetch(:status)

    @current_identity = nil
    response = request(valid_request)
    assert_equal false, response.fetch("ok")
    assert_equal "active", @database.fetch(@identity).fetch(:status)
  end

  def test_stop_interrupts_a_stalled_request
    @server.start
    socket = UNIXSocket.new(@path)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @server.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.5
    refute File.exist?(@path)
  ensure
    socket&.close
  end

  def test_stop_waits_for_an_in_progress_reconciliation
    started = Queue.new
    release = Queue.new
    delayed_database = Object.new
    database = @database
    delayed_database.define_singleton_method(:reconcile) do |identity, changes|
      started << true
      release.pop
      database.reconcile(identity, changes)
    end

    @server.stop
    @server = AgentSessionRegistry::CompletionServer.new(
      path: @path,
      database: delayed_database,
      identity_provider: -> { @current_identity }
    ).start
    requester = Thread.new { request(valid_request) }
    started.pop
    stopper = Thread.new { @server.stop }

    refute stopper.join(0.05), "stop returned before reconciliation finished"
    release << true
    assert stopper.join(1), "stop did not finish after reconciliation"
    assert requester.join(1), "request did not finish"
    assert_equal "done", @database.fetch(@identity).fetch(:status)
    refute File.exist?(@path)
  ensure
    release << true if release && release.empty?
    requester&.join(0.2)
    stopper&.join(0.2)
  end

  def test_rejects_malformed_oversized_multibyte_and_stale_requests
    @server.start
    assert_equal false, raw_request("not-json\n").fetch("ok")
    oversized = "{" + ("x" * (AgentSessionRegistry::CompletionServer::MAX_BYTES + 1)) + "}\n"
    assert_equal false, raw_request(oversized).fetch("ok")

    multibyte = valid_request.merge("source" => "é" * 300)
    response = request(multibyte)
    assert_equal false, response.fetch("ok")
    assert response.fetch("error").valid_encoding?
    assert_operator response.fetch("error").bytesize, :<=, 512
    assert_equal "active", @database.fetch(@identity).fetch(:status)

    @server.stop
    refute File.exist?(@path)
    assert_equal "active", @database.fetch(@identity).fetch(:status)
  end

  private

  def register(identity)
    @database.register(
      source: identity.source,
      hostname: identity.hostname,
      session_id: identity.session_id,
      remote: true,
      status: "active",
      name: "",
      cwd: "/work",
      adapter: "pi-dev",
      adapter_config: { "session_file" => "/sessions/one.jsonl" }
    )
  end

  def valid_request
    {
      "action" => "done",
      "source" => @identity.source,
      "hostname" => @identity.hostname,
      "session_id" => @identity.session_id
    }
  end

  def request(payload)
    raw_request(JSON.generate(payload) + "\n")
  end

  def raw_request(payload)
    socket = UNIXSocket.new(@path)
    socket.write(payload)
    JSON.parse(socket.gets)
  ensure
    socket&.close
  end
end
