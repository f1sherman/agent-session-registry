# frozen_string_literal: true

require "json"
require "socket"

require_relative "identity"

module AgentSessionRegistry
  module DoneSynchronizer
    class Error < StandardError; end

    MAX_BYTES = 16 * 1024
    REQUEST_KEYS = %w[action source hostname session_id].freeze
    SUCCESS_KEYS = %w[ok status].freeze
    FAILURE_KEYS = %w[error ok].freeze

    module_function

    def call(socket_path:, identity:, timeout:)
      identity = identity.is_a?(Identity) ? identity : Identity.parse(identity)
      timeout = Float(timeout)
      raise ArgumentError, "timeout must be positive" unless timeout.positive?

      deadline = monotonic_time + timeout
      socket = connect(socket_path.to_s, deadline)
      request = {
        "action" => "done",
        "source" => identity.source,
        "hostname" => identity.hostname,
        "session_id" => identity.session_id
      }
      write_all(socket, JSON.generate(request) + "\n", deadline)
      response = JSON.parse(read_line(socket, deadline))
      validate_response(response)
    rescue Error
      raise
    rescue JSON::ParserError, EncodingError => error
      raise Error, "invalid completion acknowledgment: #{error.message}"
    rescue SystemCallError, IOError => error
      raise Error, "completion synchronization failed: #{error.message}"
    ensure
      socket&.close
    end

    def connect(socket_path, deadline)
      socket = Socket.new(Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
      result = socket.connect_nonblock(Socket.sockaddr_un(socket_path), exception: false)
      if result == :wait_writable
        wait(socket, deadline, write: true)
        error_number = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
        raise SystemCallError.new("connect(2) for #{socket_path}", error_number) unless error_number.zero?
      end
      socket
    rescue StandardError
      socket&.close
      raise
    end
    private_class_method :connect

    def write_all(io, data, deadline)
      offset = 0
      while offset < data.bytesize
        wait(io, deadline, write: true)
        written = io.write_nonblock(data.byteslice(offset..), exception: false)
        next if written == :wait_writable

        offset += written
      end
    end
    private_class_method :write_all

    def read_line(io, deadline)
      buffer = +""
      loop do
        wait(io, deadline, write: false)
        byte = io.read_nonblock(1, exception: false)
        next if byte == :wait_readable
        raise Error, "completion acknowledgment ended before newline" if byte.nil?
        break if byte == "\n"

        buffer << byte
        raise Error, "completion acknowledgment exceeds #{MAX_BYTES} bytes" if buffer.bytesize > MAX_BYTES
      end
      buffer
    end
    private_class_method :read_line

    def wait(io, deadline, write:)
      remaining = deadline - monotonic_time
      raise Error, "completion synchronization timed out" unless remaining.positive?

      ready = if write
        IO.select(nil, [io], nil, remaining)
      else
        IO.select([io], nil, nil, remaining)
      end
      raise Error, "completion synchronization timed out" unless ready
    end
    private_class_method :wait

    def validate_response(response)
      raise Error, "completion acknowledgment must be a JSON object" unless response.is_a?(Hash)
      keys = response.keys
      unless keys.all? { |key| key.is_a?(String) }
        raise Error, "completion acknowledgment keys are invalid"
      end

      if keys.sort == SUCCESS_KEYS && response["ok"] == true && response["status"] == "done"
        true
      elsif keys.sort == FAILURE_KEYS && response["ok"] == false && response["error"].is_a?(String)
        raise Error, "completion synchronization rejected: #{response.fetch("error")[0, 512]}"
      else
        raise Error, "completion acknowledgment schema is invalid"
      end
    end
    private_class_method :validate_response

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic_time
  end
end
