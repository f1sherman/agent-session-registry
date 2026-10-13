# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "fiddle"
require "pty"
require "timeout"
require "agent_session_registry/adapter"

class AdapterOwnershipTest < Minitest::Test
  def setup
    skip "Linux child adoption boundary" unless RUBY_PLATFORM.include?("linux")
    prctl = Fiddle::Function.new(Fiddle::Handle::DEFAULT["prctl"],
      [Fiddle::TYPE_INT, *Array.new(4, Fiddle::TYPE_LONG)], Fiddle::TYPE_INT)
    assert_equal 0, prctl.call(36, 1, 0, 0, 0)
    @directory = Dir.mktmpdir("asr-ownership-")
    @children = []
  end

  def teardown
    @children&.each do |pid|
      # Reaping owns the PID. ECHILD means the fixture must not signal it.
      next if Process.waitpid(pid, Process::WNOHANG)
      Process.kill("KILL", pid)
      Process.waitpid(pid)
    rescue Errno::ECHILD
      next
    end
    FileUtils.remove_entry(@directory) if @directory
  end

  def spawn_fixture(mode, descendant_cleanup: :auto)
    path = File.join(@directory, "owned")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      ready = IO.for_fd(Integer(ENV.fetch("ASR_ADAPTER_EVENT_FD")))
      ready.sync = true
      child = fork do
        trap("TERM", "IGNORE")
        if #{mode.inspect} == "stopped-nested"
          fork do
            ready.puts(Process.pid)
            ready.close
            sleep
          end
        end
        ready.puts(Process.pid)
        ready.close
        sleep
      end
      ready.close
      if #{mode.inspect}.start_with?("stopped")
        Process.kill("STOP", Process.pid)
        sleep
      else
        exit 17
      end
    RUBY
    File.chmod(0o700, path)
    reader, writer = IO.pipe
    adapter = AgentSessionRegistry::Adapter.new(directory: @directory, descendant_cleanup: descendant_cleanup)
    pid = adapter.spawn(name: "owned", action: "resume", key: "fixture", config: {}, event_io: writer)
    @children << pid
    writer.close
    assert IO.select([reader], nil, nil, 2), "child did not publish readiness"
    child = Integer(reader.gets)
    @children << child
    if mode == "stopped-nested"
      descendant = Integer(Timeout.timeout(2) { reader.gets })
      @children << descendant
    end
    [adapter, pid, child, descendant]
  ensure
    reader&.close
    writer&.close unless writer&.closed?
  end

  def assert_reaped(pid)
    refute File.exist?("/proc/#{pid}"), "owned child #{pid} survived completion"
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  def wait_for_stopped(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      return if File.read("/proc/#{pid}/status").match?(/^State:\s+T/)
      flunk "adapter did not stop itself" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.005
    end
  end

  def adopted_sentinel
    reader, writer = IO.pipe
    parent = fork do
      reader.close
      child = fork do
        writer.close
        sleep
      end
      writer.puts(child)
      writer.close
      exit! 0
    end
    @children << parent
    writer.close
    sentinel = Integer(Timeout.timeout(2) { reader.gets })
    @children << sentinel
    Process.waitpid(parent)
    sentinel
  ensure
    reader&.close
    writer&.close unless writer&.closed?
  end

  def test_forced_stop_reaps_owned_child_without_touching_unrelated_process
    sentinel = Process.spawn(RbConfig.ruby, "-e", "sleep", pgroup: true)
    @children << sentinel
    orphan = adopted_sentinel
    adapter, pid, child = spawn_fixture("stopped")
    wait_for_stopped(pid)
    assert_equal 1, adapter.stop(pid)
    assert_reaped(pid)
    assert_reaped(child)
    assert_nil Process.waitpid(sentinel, Process::WNOHANG)
    assert_equal 1, Process.kill(0, sentinel)
    assert_nil Process.waitpid(orphan, Process::WNOHANG)
    assert_equal 1, Process.kill(0, orphan)
  end

  def test_normal_wait_preserves_status_and_reaps_surviving_child
    adapter, pid, child = spawn_fixture("exit")
    assert_equal 17, adapter.wait(pid)
    assert_reaped(pid)
    assert_reaped(child)
  end

  def test_forced_stop_reaps_deeper_adopted_descendants
    adapter, pid, child, descendant = spawn_fixture("stopped-nested")
    wait_for_stopped(pid)
    assert_equal 1, adapter.stop(pid)
    assert_reaped(child)
    assert_reaped(descendant)
  end

  def test_explicit_legacy_mode_keeps_original_process_group
    adapter, pid, child = spawn_fixture("stopped", descendant_cleanup: false)
    wait_for_stopped(pid)
    assert_equal Process.getpgrp, Process.getpgid(pid)
    assert_equal 1, adapter.stop(pid)
    assert_equal 1, Process.kill(0, child)
  end

  def test_terminal_auto_mode_preserves_foreground_group_and_explicit_supervision_rejects_it
    master, slave = PTY.open
    original_stdin = $stdin
    $stdin = slave
    assert_raises(AgentSessionRegistry::Adapter::Error) do
      AgentSessionRegistry::Adapter.new(directory: @directory, descendant_cleanup: true)
    end
    adapter, pid, child = spawn_fixture("stopped")
    wait_for_stopped(pid)
    assert_equal Process.getpgrp, Process.getpgid(pid)
    assert_equal 1, adapter.stop(pid)
    assert_equal 1, Process.kill(0, child)
  ensure
    $stdin = original_stdin
    master&.close
    slave&.close
  end

  def test_wait_and_stop_share_completion_without_competing_reaps
    adapter, pid, child = spawn_fixture("stopped")
    wait_for_stopped(pid)
    waiter = Thread.new { adapter.wait(pid) }
    waiter.report_on_exception = false
    assert_equal 1, adapter.stop(pid)
    assert waiter.join(2), "concurrent waiter did not finish"
    assert_equal 1, waiter.value
    assert_reaped(child)
  ensure
    waiter&.kill if waiter&.alive?
    waiter&.join
  end
end
