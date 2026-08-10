# frozen_string_literal: true

require_relative "test_helper"
require "agent_session_registry/adapter"

class AdapterTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @adapter_path = File.join(@directory, "pi-local")
    File.write(@adapter_path, "#!/usr/bin/env ruby\nexit 0\n")
    File.chmod(0o755, @adapter_path)
    @adapter = AgentSessionRegistry::Adapter.new(directory: @directory)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_spawns_adapter_without_a_shell_and_waits_for_its_status
    key = "pi:workstation:session-1"
    config = { "session_file" => "/sessions/one.jsonl" }
    spawned_arguments = nil

    Process.stub(:spawn, ->(*arguments) { spawned_arguments = arguments; 12_345 }) do
      pid = @adapter.spawn(name: "pi-local", action: "resume", key: key, config: config)
      assert_equal 12_345, pid
    end

    assert_equal(
      [
        @adapter_path,
        "resume",
        key,
        JSON.generate(config),
        { in: $stdin, out: $stdout, err: $stderr, close_others: true }
      ],
      spawned_arguments
    )

    status = Object.new
    status.define_singleton_method(:exitstatus) { 17 }
    Process.stub(:wait2, [12_345, status]) do
      assert_equal 17, @adapter.wait(12_345)
    end
  end

  def test_passes_only_the_private_event_descriptor_and_sync_socket
    key = "pi:workstation:session-1"
    config = { "session_file" => "/sessions/one.jsonl" }
    event_read, event_write = IO.pipe
    spawned_arguments = nil

    Process.stub(:spawn, ->(*arguments) { spawned_arguments = arguments; 12_345 }) do
      pid = @adapter.spawn(
        name: "pi-local",
        action: "resume",
        key: key,
        config: config,
        event_io: event_write,
        sync_socket: "/tmp/asr-sync.sock"
      )
      assert_equal 12_345, pid
    end

    assert_equal(
      [
        {
          "ASR_ADAPTER_EVENT_FD" => event_write.fileno.to_s,
          "ASR_ADAPTER_SYNC_SOCKET" => "/tmp/asr-sync.sock"
        },
        @adapter_path,
        "resume",
        key,
        JSON.generate(config),
        {
          in: $stdin,
          out: $stdout,
          err: $stderr,
          close_others: true,
          event_write.fileno => event_write
        }
      ],
      spawned_arguments
    )
  ensure
    event_read&.close
    event_write&.close
  end

  def test_actual_child_inherits_event_descriptor_but_not_unrelated_descriptor
    File.write(@adapter_path, <<~RUBY)
      #!/usr/bin/env ruby
      event = IO.for_fd(Integer(ENV.fetch("ASR_ADAPTER_EVENT_FD")))
      event.write("event")
      begin
        leak = IO.for_fd(Integer(ENV.fetch("LEAK_FD")))
        leak.write("leaked")
      rescue Errno::EBADF
        nil
      end
    RUBY
    File.chmod(0o755, @adapter_path)
    event_read, event_write = IO.pipe
    leak_read, leak_write = IO.pipe
    leak_write.close_on_exec = false
    original_leak_fd = ENV["LEAK_FD"]
    ENV["LEAK_FD"] = leak_write.fileno.to_s

    pid = @adapter.spawn(
      name: "pi-local",
      action: "resume",
      key: "pi:workstation:session-1",
      config: {},
      event_io: event_write
    )
    event_write.close
    leak_write.close

    assert_equal 0, @adapter.wait(pid)
    assert_equal "event", event_read.read
    assert_equal "", leak_read.read
  ensure
    ENV["LEAK_FD"] = original_leak_fd
    event_read&.close
    event_write&.close unless event_write&.closed?
    leak_read&.close
    leak_write&.close unless leak_write&.closed?
  end

  def test_passes_sync_socket_without_an_event_descriptor
    spawned_arguments = nil

    Process.stub(:spawn, ->(*arguments) { spawned_arguments = arguments; 12_345 }) do
      @adapter.spawn(
        name: "pi-local",
        action: "resume",
        key: "pi:workstation:session-1",
        config: {},
        sync_socket: "/tmp/asr-sync.sock"
      )
    end

    assert_equal(
      { "ASR_ADAPTER_SYNC_SOCKET" => "/tmp/asr-sync.sock" },
      spawned_arguments.first
    )
    refute spawned_arguments.last.keys.any? { |key| key.is_a?(Integer) }
  end

  def test_rejects_invalid_adapter_names
    ["nested/adapter", "..", "pi..local", "Pi-local", "pi;echo", "pi local"].each do |name|
      assert_raises(ArgumentError, name) do
        @adapter.spawn(name: name, action: "resume", key: "pi:host:id", config: {})
      end
    end
  end

  def test_rejects_missing_and_non_executable_adapters
    error = assert_raises(AgentSessionRegistry::Adapter::Error) do
      @adapter.spawn(name: "missing", action: "resume", key: "pi:host:id", config: {})
    end
    assert_match(/adapter.*missing/i, error.message)

    File.chmod(0o644, @adapter_path)
    error = assert_raises(AgentSessionRegistry::Adapter::Error) do
      @adapter.spawn(name: "pi-local", action: "resume", key: "pi:host:id", config: {})
    end
    assert_match(/executable/i, error.message)
  end

  def test_rejects_a_symlink_that_resolves_outside_the_adapter_directory
    outside_directory = Dir.mktmpdir
    outside_adapter = File.join(outside_directory, "outside")
    File.write(outside_adapter, "#!/usr/bin/env ruby\nexit 0\n")
    File.chmod(0o755, outside_adapter)
    File.symlink(outside_adapter, File.join(@directory, "outside"))

    error = assert_raises(AgentSessionRegistry::Adapter::Error) do
      @adapter.spawn(name: "outside", action: "resume", key: "pi:host:id", config: {})
    end
    assert_match(/outside/i, error.message)
  ensure
    FileUtils.remove_entry(outside_directory) if outside_directory
  end
end
