# frozen_string_literal: true

require "fileutils"
require "pathname"
require "securerandom"
require "timeout"

require_relative "adapter_event"
require_relative "completion_server"
require_relative "identity"

module AgentSessionRegistry
  class SessionRunner
    class Error < StandardError; end

    POLL_INTERVAL = 0.05

    def initialize(
      database:,
      adapter:,
      runtime_root:,
      session_id_generator: -> { SecureRandom.uuid },
      event_timeout: 5.0
    )
      @database = database
      @adapter = adapter
      @runtime_root = runtime_root.to_s
      @session_id_generator = session_id_generator
      @event_timeout = Float(event_timeout)
      raise ArgumentError, "event timeout must be positive" unless @event_timeout.positive?
    end

    def start(adapter_name:, cwd:)
      session_id = @session_id_generator.call.to_s
      validate_session_id(session_id)
      identity = nil
      record = nil
      status = with_connection(identity_provider: -> { identity }) do |event_reader, event_writer, sync_socket|
        pid = @adapter.spawn(
          name: adapter_name,
          action: "start",
          key: "",
          config: { "session_id" => session_id, "cwd" => cwd },
          event_io: event_writer,
          sync_socket: sync_socket
        )
        event_writer.close
        begin
          event = AdapterEvent.validate_registered(
            AdapterEvent.read(event_reader, timeout: @event_timeout),
            session_id: session_id
          )
          registered_identity = validate_start_event(
            event,
            adapter_name: adapter_name,
            session_id: session_id,
            cwd: cwd
          )
          record = @database.register(
            source: registered_identity.source,
            hostname: registered_identity.hostname,
            session_id: registered_identity.session_id,
            remote: true,
            status: event.fetch("status"),
            name: event.fetch("name") || "",
            cwd: event.fetch("cwd"),
            adapter: adapter_name,
            adapter_config: { "session_file" => event.fetch("session_file") }
          )
          identity = registered_identity
          wait_with_status_events(pid, event_reader, identity)
        rescue StandardError
          stop_adapter(pid)
          raise
        end
      end
      inspect(identity: identity, record: record)
      status
    end

    def resume(identity:, record:)
      identity = coerce_identity(identity)
      return resume_local(identity, record) unless record.fetch(:remote)

      reconciled = inspect(identity: identity, record: record)
      raise Error, "source session is done: #{identity.key}" if reconciled.fetch(:status) == "done"

      with_connection(identity_provider: -> { identity }) do |event_reader, event_writer, sync_socket|
        pid = @adapter.spawn(
          name: reconciled.fetch(:adapter),
          action: "resume",
          key: identity.key,
          config: reconciled.fetch(:adapter_config),
          event_io: event_writer,
          sync_socket: sync_socket
        )
        event_writer.close
        begin
          wait_with_status_events(pid, event_reader, identity)
        rescue StandardError
          stop_adapter(pid)
          raise
        end
      end
    end

    def inspect(identity:, record:)
      identity = coerce_identity(identity)
      event_reader = nil
      event_writer = nil
      pid = nil
      begin
        event_reader, event_writer = IO.pipe
        pid = @adapter.spawn(
          name: record.fetch(:adapter),
          action: "inspect",
          key: identity.key,
          config: record.fetch(:adapter_config),
          event_io: event_writer
        )
        event_writer.close
        event = AdapterEvent.validate_inspected(
          AdapterEvent.read(event_reader, timeout: @event_timeout),
          identity: identity
        )
        status = Timeout.timeout(@event_timeout) { @adapter.wait(pid) }
        raise Error, "adapter inspection failed with status #{status}" unless status.zero?

        validate_inspection_authority(event, record)
        reconciled = @database.reconcile(
          identity,
          status: event.fetch("status"),
          name: event.fetch("name") || ""
        )
        raise Error, "record not found during inspection: #{identity.key}" unless reconciled

        reconciled
      rescue Timeout::Error
        stop_adapter(pid) if pid
        raise Error, "adapter inspection timed out"
      rescue StandardError
        stop_adapter(pid) if pid
        raise
      ensure
        event_reader&.close unless event_reader&.closed?
        event_writer&.close unless event_writer&.closed?
      end
    end

    private

    def resume_local(identity, record)
      pid = @adapter.spawn(
        name: record.fetch(:adapter),
        action: "resume",
        key: identity.key,
        config: record.fetch(:adapter_config)
      )
      begin
        updated = @database.update(identity, status: "active")
        raise Error, "record not found during resume: #{identity.key}" unless updated
      rescue StandardError
        stop_adapter(pid)
        raise
      end
      @adapter.wait(pid)
    end

    def with_connection(identity_provider:)
      prepare_runtime_root
      socket_path = File.join(@runtime_root, "d-#{SecureRandom.hex(6)}.sock")
      event_reader, event_writer = IO.pipe
      completion = CompletionServer.new(
        path: socket_path,
        database: @database,
        identity_provider: identity_provider
      ).start
      yield event_reader, event_writer, socket_path
    ensure
      completion&.stop
      event_reader&.close unless event_reader&.closed?
      event_writer&.close unless event_writer&.closed?
    end

    def wait_with_status_events(pid, event_reader, identity)
      waiter = Thread.new { @adapter.wait(pid) }
      waiter.report_on_exception = false
      begin
        until waiter.join(POLL_INTERVAL)
          result = consume_ready_status(event_reader, identity)
          next unless result == :eof
          break if waiter.join(POLL_INTERVAL)

          raise Error, "adapter event channel closed while adapter was active"
        end
        drain_status_events(event_reader, identity)
        waiter.value
      rescue StandardError
        stop_adapter(pid)
        waiter.join
        raise
      end
    end

    def consume_ready_status(event_reader, identity)
      return :none unless IO.select([event_reader], nil, nil, 0)

      event = AdapterEvent.read(event_reader, timeout: @event_timeout)
      apply_status_event(event, identity)
      :event
    rescue AdapterEvent::Error => error
      return :eof if error.message.include?("ended before newline")

      raise
    end

    def drain_status_events(event_reader, identity)
      loop do
        result = consume_ready_status(event_reader, identity)
        break unless result == :event
      end
    end

    def apply_status_event(event, identity)
      AdapterEvent.validate_status(event, identity: identity)
      record = @database.reconcile(identity, status: "done")
      raise Error, "record not found during status update: #{identity.key}" unless record
    end

    def prepare_runtime_root
      FileUtils.mkdir_p(@runtime_root, mode: 0o700)
      File.chmod(0o700, @runtime_root)
    end

    def validate_session_id(session_id)
      Identity.new(source: "adapter", hostname: "localhost", session_id: session_id)
      session_id
    rescue ArgumentError => error
      raise Error, "generated session ID is invalid: #{error.message}"
    end

    def event_identity(event)
      Identity.new(
        source: event.fetch("source"),
        hostname: event.fetch("hostname"),
        session_id: event.fetch("session_id")
      )
    end

    def validate_start_event(event, adapter_name:, session_id:, cwd:)
      source, hostname = adapter_name.to_s.split("-", 2)
      unless source && hostname && !source.empty? && !hostname.empty?
        raise Error, "start adapter name must be <source>-<hostname>"
      end
      expected = Identity.new(source: source, hostname: hostname, session_id: session_id)
      actual = event_identity(event)
      raise Error, "registered event identity does not match adapter" unless actual == expected
      raise Error, "registered event cwd does not match request" unless event.fetch("cwd") == cwd

      session_file = event.fetch("session_file")
      unless !session_file.empty? && Pathname.new(session_file).absolute?
        raise Error, "registered event session_file must be an absolute path"
      end

      actual
    rescue ArgumentError => error
      raise Error, "start adapter identity is invalid: #{error.message}"
    end

    def validate_inspection_authority(event, record)
      unless event.fetch("cwd") == record.fetch(:cwd)
        raise Error, "inspected event cwd does not match stored record"
      end
      expected_file = record.fetch(:adapter_config).fetch("session_file")
      unless event.fetch("session_file") == expected_file
        raise Error, "inspected event session_file does not match stored record"
      end
    rescue KeyError
      raise Error, "stored record is missing session_file"
    end

    def coerce_identity(identity)
      return identity if identity.is_a?(Identity)

      Identity.parse(identity)
    end

    def stop_adapter(pid)
      @adapter.stop(pid)
    rescue Adapter::Error, SystemCallError
      nil
    end
  end
end
