# frozen_string_literal: true

require "fiddle"

module AgentSessionRegistry
  # A private group plus Linux subreaper adoption lets the caller reap ordinary
  # orphaned descendants. Collection never waits for unrelated child groups.
  class OwnedAdapterProcess
    def self.enable_adoption
      prctl = Fiddle::Function.new(Fiddle::Handle::DEFAULT["prctl"],
        [Fiddle::TYPE_INT, *Array.new(4, Fiddle::TYPE_LONG)], Fiddle::TYPE_INT)
      raise Adapter::Error, "could not enable adapter child adoption" unless prctl.call(36, 1, 0, 0, 0).zero?
    end

    def initialize(pid)
      @pid = pid
      @mutex = Mutex.new
      @status = nil
    end

    def wait
      loop do
        result = collect
        return result unless result.nil?
        sleep 0.01
      end
    end

    def stop(grace:)
      @mutex.synchronize do
        return @status unless @status.nil?
        signal("TERM", @pid)
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
      loop do
        result = collect
        return result unless result.nil?
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
      collect(force: true)
    end

    private

    def collect(force: false)
      @mutex.synchronize do
        # Timeout.timeout can asynchronously interrupt the caller's waiter.
        # Do not lose a reaped PID before owned-group cleanup and status storage
        # finish. The outer polling wait remains interruptible while active.
        Thread.handle_interrupt(Exception => :never) do
          return @status unless @status.nil?
          if force
            signal("KILL", -@pid)
            signal("KILL", @pid)
          end
          result = Process.wait2(@pid, force ? 0 : Process::WNOHANG)
          return nil unless result

          # Kill leftover members before returning even after normal completion.
          # Once their parents die, Linux adopts them here. Waiting on -pgid
          # drains only this invocation, including deeper adopted descendants.
          signal("KILL", -@pid)
          loop do
            Process.waitpid(-@pid)
          rescue Errno::ECHILD
            break
          end
          @status = result.last.exitstatus || 1
        end
      end
    end

    def signal(name, target)
      Process.kill(name, target)
    rescue Errno::ESRCH
      nil
    end
  end
end
