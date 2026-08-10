# frozen_string_literal: true

require "json"
require "sqlite3"
require "time"

require_relative "identity"
require_relative "record"

module AgentSessionRegistry
  class Database
    SCHEMA_VERSION = 2
    STATUSES = %w[active done].freeze
    MUTABLE_FIELDS = %i[remote status name cwd adapter adapter_config].freeze
    SELECT_FIELDS = Record::FIELDS.join(", ")

    CREATE_SESSIONS = <<~SQL.freeze
      CREATE TABLE sessions (
        source TEXT NOT NULL,
        hostname TEXT NOT NULL,
        session_id TEXT NOT NULL,
        remote INTEGER NOT NULL CHECK (remote IN (0, 1)),
        status TEXT NOT NULL CHECK (status IN ('active', 'done')),
        name TEXT NOT NULL DEFAULT '',
        cwd TEXT NOT NULL DEFAULT '',
        adapter TEXT NOT NULL,
        adapter_config TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (source, hostname, session_id)
      );
    SQL

    def initialize(path:, clock: -> { Time.now.utc })
      @path = path.to_s
      @clock = clock
      database = open_database(check_version: true)
      migrate(database)
    ensure
      database&.close
    end

    def register(attributes)
      normalized = normalize_registration(attributes)
      identity = identity_from(normalized)

      mutate do |database|
        current = fetch_from(database, identity)
        changes = MUTABLE_FIELDS.to_h { |field| [field, normalized.fetch(field)] }
        if current && MUTABLE_FIELDS.all? { |field| current.fetch(field) == changes.fetch(field) }
          current
        else
          if current
            update_row(database, identity, changes, timestamp)
          else
            insert_row(database, normalized, timestamp)
          end
          fetch_from(database, identity)
        end
      end
    end

    def update(identity, changes)
      identity = coerce_identity(identity)
      normalized = normalize_changes(changes)

      mutate do |database|
        current = fetch_from(database, identity)
        if current.nil?
          nil
        elsif normalized.empty? || normalized.all? { |field, value| current.fetch(field) == value }
          current
        else
          update_row(database, identity, normalized, timestamp)
          fetch_from(database, identity)
        end
      end
    end

    def done(identity)
      update(identity, status: "done")
    end

    def fetch(identity)
      identity = coerce_identity(identity)
      with_database { |database| fetch_from(database, identity) }
    end

    def list(status: "active", remote: nil)
      status = validate_status(status)
      unless remote.nil? || remote == true || remote == false
        raise ArgumentError, "remote must be true, false, or nil"
      end

      sql = "SELECT #{SELECT_FIELDS} FROM sessions WHERE status = ?"
      parameters = [status]
      unless remote.nil?
        sql += " AND remote = ?"
        parameters << (remote ? 1 : 0)
      end
      sql += " ORDER BY updated_at DESC, created_at DESC, source, hostname, session_id"

      with_database do |database|
        database.execute(sql, parameters).map { |row| record_from(row) }
      end
    end

    private

    def open_database(check_version: false)
      database = SQLite3::Database.new(@path)
      database.busy_timeout = 5_000
      if check_version
        version = database.get_first_value("PRAGMA user_version").to_i
        if version > SCHEMA_VERSION
          raise ArgumentError, "database schema version #{version} is newer than supported version #{SCHEMA_VERSION}"
        end
      end
      database.execute("PRAGMA journal_mode = WAL")
      database.execute("PRAGMA foreign_keys = ON")
      database.results_as_hash = true
      database
    rescue StandardError
      database&.close
      raise
    end

    def migrate(database)
      version = database.get_first_value("PRAGMA user_version").to_i
      return if version == SCHEMA_VERSION

      with_immediate(database) do
        version = database.get_first_value("PRAGMA user_version").to_i
        if version > SCHEMA_VERSION
          raise ArgumentError, "database schema version #{version} is newer than supported version #{SCHEMA_VERSION}"
        elsif version < SCHEMA_VERSION
          case version
          when 0
            database.execute_batch(CREATE_SESSIONS)
          when 1
            database.execute_batch(<<~SQL)
              ALTER TABLE sessions RENAME TO sessions_v1;
              #{CREATE_SESSIONS}
              INSERT INTO sessions (
                source, hostname, session_id, remote, status, name, cwd, adapter,
                adapter_config, created_at, updated_at
              )
              SELECT
                source, hostname, session_id, remote, status, name, cwd, adapter,
                adapter_config, created_at, updated_at
              FROM sessions_v1;
              DROP TABLE sessions_v1;
            SQL
          end
          database.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
        end
      end
    end

    def with_database
      database = open_database(check_version: true)
      yield database
    ensure
      database&.close
    end

    def mutate(&block)
      with_database { |database| with_immediate(database, &block) }
    end

    def with_immediate(database)
      database.execute("BEGIN IMMEDIATE")
      result = yield database
      database.execute("COMMIT")
      result
    rescue StandardError
      database.execute("ROLLBACK") if database&.transaction_active?
      raise
    end

    def normalize_registration(attributes)
      attributes = symbolize_hash(attributes, "attributes")
      allowed = %i[source hostname session_id] + MUTABLE_FIELDS
      reject_unknown_fields(attributes, allowed)
      identity = Identity.new(
        source: attributes.fetch(:source),
        hostname: attributes.fetch(:hostname),
        session_id: attributes.fetch(:session_id)
      )

      {
        source: identity.source,
        hostname: identity.hostname,
        session_id: identity.session_id,
        remote: validate_remote(attributes.fetch(:remote)),
        status: validate_status(attributes.fetch(:status)),
        name: validate_text(:name, attributes.fetch(:name, "")),
        cwd: validate_text(:cwd, attributes.fetch(:cwd, "")),
        adapter: validate_adapter(attributes.fetch(:adapter)),
        adapter_config: validate_adapter_config(attributes.fetch(:adapter_config))
      }
    rescue KeyError => error
      raise ArgumentError, "missing #{error.key}"
    end

    def normalize_changes(changes)
      changes = symbolize_hash(changes, "changes")
      reject_unknown_fields(changes, MUTABLE_FIELDS)
      changes.to_h do |field, value|
        normalized = case field
        when :remote then validate_remote(value)
        when :status then validate_status(value)
        when :adapter then validate_adapter(value)
        when :adapter_config then validate_adapter_config(value)
        else validate_text(field, value)
        end
        [field, normalized]
      end
    end

    def symbolize_hash(value, field)
      raise ArgumentError, "#{field} must be an object" unless value.is_a?(Hash)

      value.to_h { |key, item| [key.to_sym, item] }
    rescue NoMethodError
      raise ArgumentError, "#{field} keys must be strings or symbols"
    end

    def reject_unknown_fields(attributes, allowed)
      unknown = attributes.keys - allowed
      raise ArgumentError, "unknown field: #{unknown.first}" unless unknown.empty?
    end

    def validate_remote(value)
      raise ArgumentError, "remote must be true or false" unless value == true || value == false

      value
    end

    def validate_status(value)
      value = value.to_s
      raise ArgumentError, "invalid status: #{value.inspect}" unless STATUSES.include?(value)

      value
    end

    def validate_adapter(value)
      normalized = value.to_s.downcase.sub(/\.\z/, "")
      unless Identity::NAME_PATTERN.match?(normalized)
        raise ArgumentError, "invalid adapter: #{value.inspect}"
      end

      normalized
    end

    def validate_adapter_config(value)
      raise ArgumentError, "adapter_config must be an object" unless value.is_a?(Hash)

      JSON.parse(JSON.generate(value))
    rescue JSON::GeneratorError => error
      raise ArgumentError, "invalid adapter_config: #{error.message}"
    end

    def validate_text(field, value)
      raise ArgumentError, "#{field} must be a string" unless value.is_a?(String)

      value
    end

    def coerce_identity(identity)
      return identity if identity.is_a?(Identity)
      return Identity.parse(identity) if identity.is_a?(String)

      raise ArgumentError, "identity must be an Identity or key"
    end

    def identity_from(attributes)
      Identity.new(
        source: attributes.fetch(:source),
        hostname: attributes.fetch(:hostname),
        session_id: attributes.fetch(:session_id)
      )
    end

    def timestamp
      @clock.call.utc.iso8601(6)
    end

    def insert_row(database, attributes, now)
      values = attributes.merge(
        remote: attributes.fetch(:remote) ? 1 : 0,
        adapter_config: JSON.generate(attributes.fetch(:adapter_config)),
        created_at: now,
        updated_at: now
      )
      fields = Record::FIELDS
      placeholders = (["?"] * fields.length).join(", ")
      database.execute(
        "INSERT INTO sessions (#{fields.join(", ")}) VALUES (#{placeholders})",
        fields.map { |field| values.fetch(field) }
      )
    end

    def update_row(database, identity, changes, now)
      stored_changes = changes.to_h do |field, value|
        stored_value = case field
        when :remote then value ? 1 : 0
        when :adapter_config then JSON.generate(value)
        else value
        end
        [field, stored_value]
      end
      stored_changes[:updated_at] = now
      assignments = stored_changes.keys.map { |field| "#{field} = ?" }.join(", ")
      database.execute(
        "UPDATE sessions SET #{assignments} WHERE source = ? AND hostname = ? AND session_id = ?",
        stored_changes.values + [identity.source, identity.hostname, identity.session_id]
      )
    end

    def fetch_from(database, identity)
      row = database.get_first_row(
        "SELECT #{SELECT_FIELDS} FROM sessions WHERE source = ? AND hostname = ? AND session_id = ?",
        [identity.source, identity.hostname, identity.session_id]
      )
      row && record_from(row)
    end

    def record_from(row)
      attributes = Record::FIELDS.to_h { |field| [field, row.fetch(field.to_s)] }
      attributes[:remote] = attributes.fetch(:remote) == 1
      attributes[:adapter_config] = JSON.parse(attributes.fetch(:adapter_config))
      Record.new(**attributes).to_h
    end
  end
end
