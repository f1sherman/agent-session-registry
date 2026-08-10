# frozen_string_literal: true

require "json"

require_relative "identity"

module AgentSessionRegistry
  module AdapterEvent
    class Error < StandardError; end

    MAX_BYTES = 16 * 1024
    REGISTERED_KEYS = %w[
      type source hostname session_id status name cwd session_file
    ].freeze
    INSPECTED_KEYS = REGISTERED_KEYS
    STATUS_KEYS = %w[
      type source hostname session_id status
    ].freeze

    module_function

    def read(io, timeout:, max_bytes: MAX_BYTES)
      timeout = Float(timeout)
      max_bytes = Integer(max_bytes)
      raise ArgumentError, "timeout must be positive" unless timeout.positive?
      raise ArgumentError, "max_bytes must be positive" unless max_bytes.positive?

      deadline = monotonic_time + timeout
      buffer = +""
      loop do
        remaining = deadline - monotonic_time
        raise Error, "adapter event timed out" unless remaining.positive?
        raise Error, "adapter event timed out" unless IO.select([io], nil, nil, remaining)

        byte = io.read_nonblock(1, exception: false)
        next if byte == :wait_readable
        raise Error, "adapter event ended before newline" if byte.nil?

        break if byte == "\n"

        buffer << byte
        raise Error, "adapter event exceeds #{max_bytes} bytes" if buffer.bytesize > max_bytes
      end

      parsed = JSON.parse(buffer)
      raise Error, "adapter event must be a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError, EncodingError => error
      raise Error, "invalid adapter event JSON: #{error.message}"
    end

    def validate_registered(event, session_id:)
      normalized = validate_metadata(event, type: "registered", keys: REGISTERED_KEYS)
      unless normalized.fetch("session_id") == session_id.to_s
        raise Error, "registered event session identity does not match"
      end
      raise Error, "registered event status must be active" unless normalized.fetch("status") == "active"

      normalized
    end

    def validate_inspected(event, identity:)
      normalized = validate_metadata(event, type: "inspected", keys: INSPECTED_KEYS)
      validate_matching_identity(normalized, identity)
      normalized
    end

    def validate_status(event, identity:)
      normalized = validate_base(event, type: "status", keys: STATUS_KEYS)
      validate_matching_identity(normalized, identity)
      raise Error, "status event status must be done" unless normalized.fetch("status") == "done"

      normalized
    end

    def validate_metadata(event, type:, keys:)
      normalized = validate_base(event, type: type, keys: keys)
      status = normalized.fetch("status")
      raise Error, "invalid adapter event status" unless %w[active done].include?(status)

      name = normalized.fetch("name")
      raise Error, "adapter event name must be a string or null" unless name.nil? || name.is_a?(String)
      %w[cwd session_file].each do |field|
        unless normalized.fetch(field).is_a?(String)
          raise Error, "adapter event #{field} must be a string"
        end
      end
      normalized
    end
    private_class_method :validate_metadata

    def validate_base(event, type:, keys:)
      raise Error, "adapter event must be a JSON object" unless event.is_a?(Hash)
      unless event.keys.all? { |key| key.is_a?(String) } && event.keys.sort == keys.sort
        raise Error, "adapter event keys do not match #{type} schema"
      end
      raise Error, "adapter event type must be #{type}" unless event.fetch("type") == type

      %w[source hostname session_id status].each do |field|
        raise Error, "adapter event #{field} must be a string" unless event.fetch(field).is_a?(String)
      end

      identity = Identity.new(
        source: event.fetch("source"),
        hostname: event.fetch("hostname"),
        session_id: event.fetch("session_id")
      )
      event.merge(
        "source" => identity.source,
        "hostname" => identity.hostname,
        "session_id" => identity.session_id
      )
    rescue ArgumentError => error
      raise Error, "invalid adapter event identity: #{error.message}"
    end
    private_class_method :validate_base

    def validate_matching_identity(event, identity)
      expected = identity.is_a?(Identity) ? identity : Identity.parse(identity)
      actual = Identity.new(
        source: event.fetch("source"),
        hostname: event.fetch("hostname"),
        session_id: event.fetch("session_id")
      )
      raise Error, "adapter event identity does not match" unless actual == expected
    rescue ArgumentError => error
      raise Error, "invalid adapter event identity: #{error.message}"
    end
    private_class_method :validate_matching_identity

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic_time
  end
end
