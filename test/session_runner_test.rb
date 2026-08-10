# frozen_string_literal: true

require_relative "test_helper"
require "timeout"
require "agent_session_registry/adapter"
require "agent_session_registry/session_runner"

class SessionRunnerTest < Minitest::Test
  class BlockingRegisterDatabase
    attr_reader :entered, :release

    def initialize(database)
      @database = database
      @entered = Queue.new
      @release = Queue.new
    end

    def register(attributes)
      @entered << true
      @release.pop
      @database.register(attributes)
    end

    def method_missing(name, *arguments, **keywords, &block)
      @database.public_send(name, *arguments, **keywords, &block)
    end

    def respond_to_missing?(name, include_private = false)
      @database.respond_to?(name, include_private) || super
    end
  end

  class FakeAdapter
    attr_reader :spawns, :stops

    def initialize
      @behaviors = []
      @processes = {}
      @spawns = []
      @stops = []
      @next_pid = 10_000
    end

    def enqueue(
      action:, events: [], status: 0, gate: nil, writer_gate: nil,
      on_spawn: nil, spawn_error: nil
    )
      @behaviors << {
        action: action,
        events: events,
        status: status,
        gate: gate,
        writer_gate: writer_gate,
        on_spawn: on_spawn,
        spawn_error: spawn_error
      }
    end

    def spawn(**arguments)
      behavior = @behaviors.shift or raise "unexpected adapter spawn"
      raise "expected #{behavior[:action]}, got #{arguments[:action]}" unless
        behavior.fetch(:action) == arguments.fetch(:action)
      raise behavior.fetch(:spawn_error) if behavior.fetch(:spawn_error)

      @next_pid += 1
      pid = @next_pid
      writer = arguments[:event_io]&.dup
      behavior[:writer] = Thread.new do
        behavior.fetch(:events).each { |event| writer.puts(JSON.generate(event)) }
        behavior.fetch(:writer_gate)&.pop
      ensure
        writer&.close
      end
      behavior.fetch(:on_spawn)&.call(arguments)
      @spawns << arguments.reject { |key, _| key == :event_io }
      @processes[pid] = behavior
      pid
    end

    def wait(pid)
      behavior = @processes.fetch(pid)
      behavior.fetch(:writer)&.join
      behavior.fetch(:gate)&.pop
      behavior.fetch(:status)
    end

    def stop(pid)
      @stops << pid
      behavior = @processes.fetch(pid)
      behavior.fetch(:gate)&.push(true)
      behavior.fetch(:writer_gate)&.push(true)
      behavior.fetch(:writer)&.join(0.2)
      behavior.fetch(:writer)&.kill
      143
    end
  end

  def setup
    @directory = Dir.mktmpdir
    @database = AgentSessionRegistry::Database.new(
      path: File.join(@directory, "registry.sqlite3")
    )
    @adapter = FakeAdapter.new
    @generated_ids = 0
    @runner = AgentSessionRegistry::SessionRunner.new(
      database: @database,
      adapter: @adapter,
      runtime_root: File.join(@directory, "runtime"),
      session_id_generator: lambda do
        @generated_ids += 1
        "session-1"
      end,
      event_timeout: 0.05
    )
    @identity = AgentSessionRegistry::Identity.parse("pi:dev:session-1")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_start_registers_while_adapter_runs_then_imports_final_name
    gate = Queue.new
    observed_socket = nil
    @adapter.enqueue(
      action: "start",
      events: [metadata("registered", name: nil)],
      status: 17,
      gate: gate,
      on_spawn: lambda do |arguments|
        observed_socket = arguments.fetch(:sync_socket)
        assert File.socket?(observed_socket), "completion listener did not start first"
      end
    )
    @adapter.enqueue(
      action: "inspect",
      events: [metadata("inspected", name: "Remote name")]
    )

    result = Queue.new
    thread = Thread.new do
      result << @runner.start(
        adapter_name: "pi-dev",
        cwd: "/home/brian/projects/repo"
      )
    end

    record = wait_for_record
    assert_equal true, thread.alive?
    assert_equal true, record.fetch(:remote)
    assert_equal "pi-dev", record.fetch(:adapter)
    assert_equal "", record.fetch(:name)
    assert_equal({ "session_file" => session_file }, record.fetch(:adapter_config))
    assert_operator observed_socket.bytesize, :<, 104
    assert_equal 0o700, File.stat(File.dirname(observed_socket)).mode & 0o777

    start_spawn = @adapter.spawns.fetch(0)
    assert_equal "start", start_spawn.fetch(:action)
    assert_equal "", start_spawn.fetch(:key)
    assert_equal(
      { "session_id" => "session-1", "cwd" => "/home/brian/projects/repo" },
      start_spawn.fetch(:config)
    )
    assert_equal 1, @generated_ids

    gate << true
    assert thread.join(1), "start did not finish"
    assert_equal 17, result.pop
    refute File.exist?(observed_socket)
    assert_equal "Remote name", @database.fetch(@identity).fetch(:name)
  end

  def test_start_publishes_completion_identity_only_after_registration
    blocking_database = BlockingRegisterDatabase.new(@database)
    runner = AgentSessionRegistry::SessionRunner.new(
      database: blocking_database,
      adapter: @adapter,
      runtime_root: File.join(@directory, "runtime"),
      session_id_generator: -> { "session-1" },
      event_timeout: 0.1
    )
    gate = Queue.new
    socket = Queue.new
    @adapter.enqueue(
      action: "start",
      events: [metadata("registered")],
      gate: gate,
      on_spawn: ->(arguments) { socket << arguments.fetch(:sync_socket) }
    )
    @adapter.enqueue(
      action: "inspect",
      events: [metadata("inspected", status: "done")]
    )

    result = Queue.new
    thread = Thread.new do
      result << runner.start(
        adapter_name: "pi-dev",
        cwd: "/home/brian/projects/repo"
      )
    end
    socket_path = socket.pop
    blocking_database.entered.pop

    early_response = synchronize_done(socket_path)
    assert_equal false, early_response.fetch("ok")
    assert_match(/identity is not available/, early_response.fetch("error"))
    assert_nil @database.fetch(@identity)

    blocking_database.release << true
    wait_for_record
    assert_equal(
      { "ok" => true, "status" => "done" },
      synchronize_done(socket_path)
    )
    assert_equal "done", @database.fetch(@identity).fetch(:status)

    gate << true
    assert thread.join(1), "start did not finish"
    assert_equal 0, result.pop
  end

  def test_remote_resume_inspects_then_applies_done_status_events
    register_remote
    @adapter.enqueue(
      action: "inspect",
      events: [metadata("inspected", name: "Current name")]
    )
    @adapter.enqueue(
      action: "resume",
      events: [status_event, status_event],
      status: 23
    )

    result = @runner.resume(identity: @identity, record: @database.fetch(@identity))

    assert_equal 23, result
    record = @database.fetch(@identity)
    assert_equal "done", record.fetch(:status)
    assert_equal "Current name", record.fetch(:name)
    assert_equal %w[inspect resume], @adapter.spawns.map { |spawn| spawn.fetch(:action) }
    assert @adapter.spawns.fetch(1).fetch(:sync_socket)
  end

  def test_remote_resume_refuses_source_done_and_preserves_local_done
    register_remote
    @database.done(@identity)
    @adapter.enqueue(
      action: "inspect",
      events: [metadata("inspected", status: "active")]
    )

    error = assert_raises(AgentSessionRegistry::SessionRunner::Error) do
      @runner.resume(identity: @identity, record: @database.fetch(@identity))
    end

    assert_match(/source session is done/, error.message)
    assert_equal "done", @database.fetch(@identity).fetch(:status)
    assert_equal ["inspect"], @adapter.spawns.map { |spawn| spawn.fetch(:action) }
  end

  def test_local_resume_keeps_existing_behavior_without_inspection
    local = AgentSessionRegistry::Identity.local(source: "pi", session_id: "local-1")
    @database.register(
      source: local.source,
      hostname: local.hostname,
      session_id: local.session_id,
      remote: false,
      status: "done",
      name: "",
      cwd: "/work",
      adapter: "pi-local",
      adapter_config: { "session_file" => "/sessions/local.jsonl" }
    )
    @adapter.enqueue(action: "resume", status: 9)

    assert_equal 9, @runner.resume(identity: local, record: @database.fetch(local))
    assert_equal "active", @database.fetch(local).fetch(:status)
    assert_equal ["resume"], @adapter.spawns.map { |spawn| spawn.fetch(:action) }
    refute @adapter.spawns.fetch(0).key?(:sync_socket)
  end

  def test_start_rejects_registration_authority_mismatches
    cases = {
      "source" => metadata("registered").merge("source" => "codex"),
      "hostname" => metadata("registered").merge("hostname" => "attacker"),
      "cwd" => metadata("registered").merge("cwd" => "/home/brian/projects/other"),
      "empty session file" => metadata("registered").merge("session_file" => ""),
      "relative session file" => metadata("registered").merge("session_file" => "relative.jsonl")
    }

    cases.each do |label, event|
      adapter = FakeAdapter.new
      adapter.enqueue(action: "start", events: [event])
      runner = AgentSessionRegistry::SessionRunner.new(
        database: @database,
        adapter: adapter,
        runtime_root: File.join(@directory, "runtime"),
        session_id_generator: -> { "session-1" },
        event_timeout: 0.05
      )

      assert_raises(AgentSessionRegistry::SessionRunner::Error, label) do
        runner.start(adapter_name: "pi-dev", cwd: "/home/brian/projects/repo")
      end
      assert_nil @database.fetch(@identity), label
      assert_equal 1, adapter.stops.length, label
    end
  end

  def test_start_rejects_malformed_or_missing_registration_and_stops_adapter
    @adapter.enqueue(action: "start", events: [{ "type" => "bad" }])

    assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
      @runner.start(adapter_name: "pi-dev", cwd: "/home/brian/projects/repo")
    end
    assert_nil @database.fetch(@identity)
    assert_equal 1, @adapter.stops.length

    @adapter = FakeAdapter.new
    @runner = AgentSessionRegistry::SessionRunner.new(
      database: @database,
      adapter: @adapter,
      runtime_root: File.join(@directory, "runtime"),
      session_id_generator: -> { "session-1" },
      event_timeout: 0.01
    )
    gate = Queue.new
    writer_gate = Queue.new
    @adapter.enqueue(
      action: "start",
      events: [],
      gate: gate,
      writer_gate: writer_gate
    )
    timeout_error = assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
      @runner.start(adapter_name: "pi-dev", cwd: "/home/brian/projects/repo")
    end
    assert_match(/timed out/, timeout_error.message)
    assert_nil @database.fetch(@identity)
    assert_equal 1, @adapter.stops.length
  end

  def test_start_fails_when_adapter_exits_before_registration
    @adapter.enqueue(action: "start", events: [], status: 19)

    error = assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
      @runner.start(adapter_name: "pi-dev", cwd: "/home/brian/projects/repo")
    end

    assert_match(/ended before newline/, error.message)
    assert_nil @database.fetch(@identity)
    assert_equal 1, @adapter.stops.length
  end

  def test_post_start_inspection_failure_preserves_registered_record
    @adapter.enqueue(action: "start", events: [metadata("registered")])
    @adapter.enqueue(action: "inspect", events: [{ "type" => "bad" }])

    assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
      @runner.start(adapter_name: "pi-dev", cwd: "/home/brian/projects/repo")
    end

    assert_equal "active", @database.fetch(@identity).fetch(:status)
  end

  def test_inspect_closes_event_descriptors_when_spawn_fails
    register_remote
    pipes = []
    original_pipe = IO.method(:pipe)
    @adapter.enqueue(
      action: "inspect",
      spawn_error: AgentSessionRegistry::Adapter::Error.new("spawn failed")
    )

    IO.stub(:pipe, lambda {
      original_pipe.call.tap { |pair| pipes << pair }
    }) do
      assert_raises(AgentSessionRegistry::Adapter::Error) do
        @runner.inspect(identity: @identity, record: @database.fetch(@identity))
      end
    end

    assert_equal 1, pipes.length
    assert pipes.flatten.all?(&:closed?), "inspect leaked an event descriptor"
  end

  def test_inspect_timeout_stops_adapter
    register_remote
    gate = Queue.new
    @adapter.enqueue(
      action: "inspect",
      events: [metadata("inspected")],
      gate: gate
    )

    error = assert_raises(AgentSessionRegistry::SessionRunner::Error) do
      @runner.inspect(identity: @identity, record: @database.fetch(@identity))
    end

    assert_match(/inspection timed out/, error.message)
    assert_equal 1, @adapter.stops.length
  end

  def test_inspect_rejects_cwd_and_session_file_drift
    register_remote
    [
      metadata("inspected").merge("cwd" => "/home/brian/projects/other"),
      metadata("inspected").merge("session_file" => "/sessions/other.jsonl")
    ].each do |event|
      @adapter.enqueue(action: "inspect", events: [event])
      assert_raises(AgentSessionRegistry::SessionRunner::Error) do
        @runner.inspect(identity: @identity, record: @database.fetch(@identity))
      end
    end

    record = @database.fetch(@identity)
    assert_equal "/home/brian/projects/repo", record.fetch(:cwd)
    assert_equal session_file, record.fetch(:adapter_config).fetch("session_file")
  end

  def test_event_channel_eof_while_remote_adapter_is_active_is_an_error
    register_remote
    @adapter.enqueue(action: "inspect", events: [metadata("inspected")])
    gate = Queue.new
    @adapter.enqueue(action: "resume", events: [], gate: gate)

    error = assert_raises(AgentSessionRegistry::SessionRunner::Error) do
      @runner.resume(identity: @identity, record: @database.fetch(@identity))
    end

    assert_match(/event channel closed/, error.message)
    refute_empty @adapter.stops
  end

  def test_inspect_cannot_change_location_or_adapter
    register_remote
    @adapter.enqueue(
      action: "inspect",
      events: [metadata("inspected", name: "Updated", status: "done")]
    )

    record = @runner.inspect(identity: @identity, record: @database.fetch(@identity))

    assert_equal true, record.fetch(:remote)
    assert_equal "pi-dev", record.fetch(:adapter)
    assert_equal "done", record.fetch(:status)
    assert_equal "Updated", record.fetch(:name)
  end

  private

  def metadata(type, name: "", status: "active")
    {
      "type" => type,
      "source" => "pi",
      "hostname" => "dev",
      "session_id" => "session-1",
      "status" => status,
      "name" => name,
      "cwd" => "/home/brian/projects/repo",
      "session_file" => session_file
    }
  end

  def status_event
    {
      "type" => "status",
      "source" => "pi",
      "hostname" => "dev",
      "session_id" => "session-1",
      "status" => "done"
    }
  end

  def session_file
    "/home/brian/.pi/agent/sessions/--repo--/session-1.jsonl"
  end

  def register_remote
    @database.register(
      source: "pi",
      hostname: "dev",
      session_id: "session-1",
      remote: true,
      status: "active",
      name: "",
      cwd: "/home/brian/projects/repo",
      adapter: "pi-dev",
      adapter_config: { "session_file" => session_file }
    )
  end

  def synchronize_done(socket_path)
    socket = UNIXSocket.new(socket_path)
    socket.puts(JSON.generate(
      "action" => "done",
      "source" => "pi",
      "hostname" => "dev",
      "session_id" => "session-1"
    ))
    JSON.parse(socket.gets)
  ensure
    socket&.close
  end

  def wait_for_record
    Timeout.timeout(1) do
      loop do
        record = @database.fetch(@identity)
        return record if record
        sleep 0.01
      end
    end
  end
end
