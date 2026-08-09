# frozen_string_literal: true

require "socket"

module AgentSessionRegistry
  class Identity
    NAME_PATTERN = /\A[a-z0-9][a-z0-9._-]*\z/
    SESSION_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    attr_reader :source, :hostname, :session_id

    def self.parse(key)
      fields = key.to_s.split(":", -1)
      raise ArgumentError, "identity key must contain exactly three fields" unless fields.length == 3

      new(source: fields[0], hostname: fields[1], session_id: fields[2])
    end

    def self.local(source:, session_id:)
      new(source: source, hostname: Socket.gethostname, session_id: session_id)
    end

    def initialize(source:, hostname:, session_id:)
      @source = normalize_name(source, "source")
      @hostname = normalize_name(hostname, "hostname")
      @session_id = session_id.to_s
      unless SESSION_ID_PATTERN.match?(@session_id)
        raise ArgumentError, "invalid session_id: #{session_id.inspect}"
      end

      @source.freeze
      @hostname.freeze
      @session_id.freeze
      freeze
    end

    def key
      "#{source}:#{hostname}:#{session_id}"
    end

    def ==(other)
      other.instance_of?(self.class) &&
        source == other.source &&
        hostname == other.hostname &&
        session_id == other.session_id
    end
    alias eql? ==

    def hash
      [self.class, source, hostname, session_id].hash
    end

    private

    def normalize_name(value, field)
      normalized = value.to_s.downcase.sub(/\.\z/, "")
      raise ArgumentError, "invalid #{field}: #{value.inspect}" unless NAME_PATTERN.match?(normalized)

      normalized
    end
  end
end
