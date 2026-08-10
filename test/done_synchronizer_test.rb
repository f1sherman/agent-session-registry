# frozen_string_literal: true

require_relative "test_helper"
require "agent_session_registry/done_synchronizer"

class DoneSynchronizerTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "sync.sock")
    @identity = AgentSessionRegistry::Identity.new(
      source: "pi", hostname: "dev", session_id: "session-1"
    )
  end

  def teardown
    @server&.close
    @thread&.join(0.2)
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
  end

  def test_sends_exact_request_and_accepts_acknowledgment
    received = start_server("ok" => true, "status" => "done")

    assert AgentSessionRegistry::DoneSynchronizer.call(
      socket_path: @path, identity: @identity, timeout: 1
    )
    assert_equal(
      {
        "action" => "done",
        "source" => "pi",
        "hostname" => "dev",
        "session_id" => "session-1"
      },
      received.pop
    )
  end

  def test_rejects_negative_malformed_oversized_eof_missing_and_timeout
    failures = [
      -> { start_server("ok" => false, "error" => "not allowed") },
      -> { start_raw_server("not-json\n") },
      -> { start_raw_server(("x" * (AgentSessionRegistry::DoneSynchronizer::MAX_BYTES + 1)) + "\n") },
      -> { start_raw_server("") }
    ]

    failures.each do |setup|
      cleanup_server
      setup.call
      assert_raises(AgentSessionRegistry::DoneSynchronizer::Error) do
        synchronize(timeout: 0.2)
      end
    end

    cleanup_server
    assert_raises(AgentSessionRegistry::DoneSynchronizer::Error) do
      synchronize(timeout: 0.1)
    end

    start_raw_server(nil, delay: 0.3)
    assert_raises(AgentSessionRegistry::DoneSynchronizer::Error) do
      synchronize(timeout: 0.05)
    end
  end

  private

  def synchronize(timeout:)
    AgentSessionRegistry::DoneSynchronizer.call(
      socket_path: @path, identity: @identity, timeout: timeout
    )
  end

  def start_server(response)
    received = Queue.new
    start_raw_server(JSON.generate(response) + "\n", received: received)
    received
  end

  def start_raw_server(response, received: nil, delay: 0)
    @server = UNIXServer.new(@path)
    @thread = Thread.new do
      socket = @server.accept
      line = socket.gets
      received << JSON.parse(line) if received
      sleep delay if delay.positive?
      socket.write(response) if response
      socket.close
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def cleanup_server
    @server&.close
    @thread&.join(0.2)
    @server = nil
    @thread = nil
    FileUtils.rm_f(@path)
  end
end
