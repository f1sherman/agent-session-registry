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
        { in: $stdin, out: $stdout, err: $stderr }
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
          event_write.fileno => event_write
        }
      ],
      spawned_arguments
    )
  ensure
    event_read&.close
    event_write&.close
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
