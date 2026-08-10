# frozen_string_literal: true

require "json"

require_relative "identity"

module AgentSessionRegistry
  class Adapter
    class Error < StandardError; end

    STOP_GRACE_SECONDS = 0.25

    def initialize(directory:)
      @directory = File.realpath(directory)
    rescue SystemCallError => error
      raise Error, "adapter directory is unavailable: #{error.message}"
    end

    def spawn(name:, action:, key:, config:, event_io: nil, sync_socket: nil)
      candidate = resolve(name)
      environment = {}
      options = { in: $stdin, out: $stdout, err: $stderr }
      if event_io
        event_fd = event_io.fileno
        environment["ASR_ADAPTER_EVENT_FD"] = event_fd.to_s
        options[event_fd] = event_io
      end
      if sync_socket
        environment["ASR_ADAPTER_SYNC_SOCKET"] = sync_socket.to_s
      end

      arguments = [candidate, action, key, JSON.generate(config), options]
      arguments.unshift(environment) unless environment.empty?
      Process.spawn(*arguments)
    rescue SystemCallError => error
      raise Error, "could not start adapter #{name.inspect}: #{error.message}"
    end

    def wait(pid)
      status = Process.wait2(pid).last
      status.exitstatus || 1
    rescue SystemCallError => error
      raise Error, "could not wait for adapter process: #{error.message}"
    end

    def stop(pid)
      Process.kill("TERM", pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STOP_GRACE_SECONDS
      loop do
        if (result = Process.wait2(pid, Process::WNOHANG))
          return result.last.exitstatus || 1
        end
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
      Process.kill("KILL", pid)
      wait(pid)
    rescue Errno::ESRCH
      wait(pid)
    rescue SystemCallError => error
      raise Error, "could not stop adapter process: #{error.message}"
    end

    private

    def resolve(name)
      name = name.to_s
      unless Identity::NAME_PATTERN.match?(name) &&
          name == name.downcase &&
          !name.include?("..")
        raise ArgumentError, "invalid adapter name: #{name.inspect}"
      end

      real_candidate = File.realpath(File.join(@directory, name))
      prefix = @directory.end_with?(File::SEPARATOR) ? @directory : "#{@directory}#{File::SEPARATOR}"
      unless real_candidate.start_with?(prefix)
        raise Error, "adapter resolves outside the adapter directory: #{name}"
      end
      raise Error, "adapter is not a file: #{name}" unless File.file?(real_candidate)
      raise Error, "adapter is not executable: #{name}" unless File.executable?(real_candidate)

      real_candidate
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise Error, "adapter is missing: #{name}"
    end
  end
end
