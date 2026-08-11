# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"

require_relative "identity"

module AgentSessionRegistry
  class CompletionServer
    MAX_BYTES = 16 * 1024
    READ_TIMEOUT = 5.0
    REQUEST_KEYS = %w[action source hostname session_id].freeze

    def initialize(path:, database:, identity_provider:)
      @path = path.to_s
      @database = database
      @identity_provider = identity_provider
      @mutex = Mutex.new
    end

    def start
      @mutex.synchronize do
        return self if @thread&.alive?

        directory = File.dirname(@path)
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
        FileUtils.rm_f(@path)
        @server = UNIXServer.new(@path)
        File.chmod(0o600, @path)
        @stop_reader, @stop_writer = IO.pipe
        @thread = Thread.new { serve }
        @thread.report_on_exception = false
      end
      self
    rescue SystemCallError => error
      cleanup
      raise error
    end

    def stop
      thread = @mutex.synchronize do
        begin
          @stop_writer&.write_nonblock("x", exception: false)
        rescue IOError, SystemCallError
          nil
        end
        @thread
      end
      thread&.join
      cleanup
      nil
    end

    private

    def serve
      loop do
        ready = IO.select([@server, @stop_reader])
        break if ready.first.include?(@stop_reader)

        socket = @server.accept_nonblock(exception: false)
        next if socket == :wait_readable

        handle(socket)
      end
    rescue IOError, SystemCallError
      nil
    ensure
      @server&.close unless @server&.closed?
    end

    def handle(socket)
      response = begin
        request = JSON.parse(read_line(socket))
        identity = validate_request(request)
        record = @database.reconcile(identity, status: "done")
        raise ArgumentError, "completion record not found" unless record

        { "ok" => true, "status" => "done" }
      rescue StandardError => error
        { "ok" => false, "error" => bounded_error(error) }
      end
      socket.write(JSON.generate(response) + "\n")
    rescue IOError, SystemCallError
      nil
    ensure
      socket.close unless socket.closed?
    end

    def read_line(socket)
      deadline = monotonic_time + READ_TIMEOUT
      buffer = +""
      loop do
        remaining = deadline - monotonic_time
        raise ArgumentError, "completion request timed out" unless remaining.positive?
        ready = IO.select([socket, @stop_reader], nil, nil, remaining)
        raise ArgumentError, "completion request timed out" unless ready
        raise ArgumentError, "completion server stopped" if ready.first.include?(@stop_reader)

        byte = socket.read_nonblock(1, exception: false)
        next if byte == :wait_readable
        raise ArgumentError, "completion request ended before newline" if byte.nil?
        break if byte == "\n"

        buffer << byte
        raise ArgumentError, "completion request exceeds #{MAX_BYTES} bytes" if buffer.bytesize > MAX_BYTES
      end
      buffer
    end

    def validate_request(request)
      unless request.is_a?(Hash) &&
          request.keys.all? { |key| key.is_a?(String) } &&
          request.keys.sort == REQUEST_KEYS.sort
        raise ArgumentError, "completion request schema is invalid"
      end
      raise ArgumentError, "completion action must be done" unless request.fetch("action") == "done"
      %w[source hostname session_id].each do |field|
        raise ArgumentError, "completion #{field} must be a string" unless request.fetch(field).is_a?(String)
      end

      actual = Identity.new(
        source: request.fetch("source"),
        hostname: request.fetch("hostname"),
        session_id: request.fetch("session_id")
      )
      expected = @identity_provider.call
      raise ArgumentError, "completion identity is not available" unless expected
      expected = Identity.parse(expected) unless expected.is_a?(Identity)
      raise ArgumentError, "completion identity does not match" unless actual == expected

      actual
    end

    def bounded_error(error)
      message = error.message.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      message = error.class.name if message.empty?
      bounded = +""
      message.each_char do |character|
        break if bounded.bytesize + character.bytesize > 512

        bounded << character
      end
      bounded
    end

    def cleanup
      @mutex.synchronize do
        [@server, @stop_reader, @stop_writer].each do |io|
          io&.close unless io&.closed?
        rescue IOError
          nil
        end
        @server = @stop_reader = @stop_writer = @thread = nil
        FileUtils.rm_f(@path)
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
