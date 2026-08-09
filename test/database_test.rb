# frozen_string_literal: true

require_relative "test_helper"

class IdentityTest < Minitest::Test
  def test_normalizes_and_round_trips_public_key
    identity = AgentSessionRegistry::Identity.new(
      source: "PI",
      hostname: "Build.EXAMPLE.",
      session_id: "019fe7a6-a219-7548-a6ef-1f23885864f4"
    )

    assert_equal "pi:build.example:019fe7a6-a219-7548-a6ef-1f23885864f4", identity.key
    assert_equal identity, AgentSessionRegistry::Identity.parse(identity.key)
    assert identity.frozen?
  end

  def test_equality_is_symmetric_and_hashes_match_for_subclasses
    subclass = Class.new(AgentSessionRegistry::Identity)
    attributes = { source: "pi", hostname: "host", session_id: "session-1" }
    identity = AgentSessionRegistry::Identity.new(**attributes)
    subclass_identity = subclass.new(**attributes)
    equivalent_subclass_identity = subclass.new(**attributes)

    refute_equal identity, subclass_identity
    refute_equal subclass_identity, identity
    assert_equal subclass_identity, equivalent_subclass_identity
    assert_equal subclass_identity.hash, equivalent_subclass_identity.hash
  end

  def test_local_uses_the_system_hostname
    Socket.stub(:gethostname, "Workstation.EXAMPLE.") do
      identity = AgentSessionRegistry::Identity.local(source: "PI", session_id: "session-1")

      assert_equal "pi:workstation.example:session-1", identity.key
    end
  end

  def test_parse_requires_exactly_three_valid_fields
    invalid_keys = [
      "pi:host", "pi:host:session:extra", ":host:session", "pi::session",
      "pi:host:", "bad source:host:session", "pi:bad host:session",
      "pi:host:bad/session"
    ]

    invalid_keys.each do |key|
      assert_raises(ArgumentError, key) { AgentSessionRegistry::Identity.parse(key) }
    end
  end
end

class RecordTest < Minitest::Test
  def test_fields_and_hash_conversion
    expected_fields = %i[
      source hostname session_id remote status name goal cwd adapter adapter_config
      created_at updated_at
    ].freeze
    attributes = expected_fields.to_h { |field| [field, field.to_s] }
    record = AgentSessionRegistry::Record.new(**attributes)

    assert_equal expected_fields, AgentSessionRegistry::Record::FIELDS
    assert_equal attributes, record.to_h
  end
end

class DatabaseTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "registry.sqlite3")
    @now = Time.utc(2026, 8, 9, 12)
    @database = AgentSessionRegistry::Database.new(path: @path, clock: -> { @now })
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_creates_schema_version_one
    connection = SQLite3::Database.new(@path)

    assert_equal 1, connection.get_first_value("PRAGMA user_version")
    assert_equal ["sessions"], connection.execute(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
    ).flatten
  ensure
    connection&.close
  end

  def test_rejects_a_newer_schema_before_mutation
    path = File.join(@directory, "newer.sqlite3")
    connection = SQLite3::Database.new(path)
    connection.execute("CREATE TABLE sentinel (value TEXT)")
    connection.execute("PRAGMA user_version = 2")
    before = connection.execute(
      "SELECT type, name, sql FROM sqlite_master ORDER BY type, name"
    )
    connection.close

    assert_raises(ArgumentError) { AgentSessionRegistry::Database.new(path: path) }

    connection = SQLite3::Database.new(path)
    assert_equal 2, connection.get_first_value("PRAGMA user_version")
    assert_equal before, connection.execute(
      "SELECT type, name, sql FROM sqlite_master ORDER BY type, name"
    )
  ensure
    connection&.close
  end

  def test_local_identity_hostname_round_trips_as_sqlite_text_and_rendered_key
    binary_hostname = "Workstation.EXAMPLE.".dup.force_encoding(Encoding::ASCII_8BIT)

    Socket.stub(:gethostname, binary_hostname) do
      identity = AgentSessionRegistry::Identity.local(
        source: "PI".dup.force_encoding(Encoding::ASCII_8BIT),
        session_id: "session-local"
      )
      record = @database.register(
        registration_attributes.merge(
          source: identity.source,
          hostname: identity.hostname,
          session_id: identity.session_id
        )
      )
      connection = SQLite3::Database.new(@path)

      assert_equal Encoding::UTF_8, identity.source.encoding
      assert_equal Encoding::UTF_8, identity.hostname.encoding
      assert_equal "text", connection.get_first_value(
        "SELECT typeof(hostname) FROM sessions WHERE session_id = ?",
        identity.session_id
      )
      assert_equal record, @database.fetch(AgentSessionRegistry::Identity.parse(identity.key))
    ensure
      connection&.close
    end
  end

  def test_register_sets_every_fixed_column
    record = @database.register(registration_attributes)

    assert_equal(
      {
        source: "pi",
        hostname: "workstation",
        session_id: "session-1",
        remote: false,
        status: "active",
        name: "Registry work",
        goal: "Build session registry",
        cwd: "/work/repo",
        adapter: "pi-local",
        adapter_config: { "session_file" => "/sessions/one.jsonl" },
        created_at: "2026-08-09T12:00:00.000000Z",
        updated_at: "2026-08-09T12:00:00.000000Z"
      },
      record
    )
    assert_equal record, @database.fetch(identity)
  end

  def test_equivalent_register_does_not_change_timestamps
    original = @database.register(registration_attributes)
    advance_clock

    registered = @database.register(registration_attributes)

    assert_equal original, registered
  end

  def test_changed_register_preserves_created_at_and_advances_updated_at
    original = @database.register(registration_attributes)
    advance_clock

    changed = @database.register(registration_attributes.merge(name: "New name"))

    assert_equal original.fetch(:created_at), changed.fetch(:created_at)
    assert_equal "2026-08-09T12:01:00.000000Z", changed.fetch(:updated_at)
    assert_equal "New name", changed.fetch(:name)
  end

  def test_update_changes_only_supplied_mutable_fields
    original = @database.register(registration_attributes)
    advance_clock

    changed = @database.update(
      identity,
      name: "Updated name",
      adapter_config: { "session_file" => "/sessions/two.jsonl" }
    )

    assert_equal "Updated name", changed.fetch(:name)
    assert_equal({ "session_file" => "/sessions/two.jsonl" }, changed.fetch(:adapter_config))
    unchanged = original.keys - %i[name adapter_config updated_at]
    unchanged.each { |field| assert_equal original.fetch(field), changed.fetch(field), field }
    assert_equal "2026-08-09T12:01:00.000000Z", changed.fetch(:updated_at)
  end

  def test_done_changes_only_status_and_updated_at
    original = @database.register(registration_attributes)
    advance_clock

    done = @database.done(identity)

    assert_equal "done", done.fetch(:status)
    unchanged = original.keys - %i[status updated_at]
    unchanged.each { |field| assert_equal original.fetch(field), done.fetch(field), field }
    assert_equal "2026-08-09T12:01:00.000000Z", done.fetch(:updated_at)
  end

  def test_repeated_done_does_not_change_updated_at
    @database.register(registration_attributes)
    advance_clock
    first = @database.done(identity)
    advance_clock

    second = @database.done(identity)

    assert_equal first, second
  end

  def test_list_defaults_to_active_and_orders_newest_first
    @database.register(registration_attributes.merge(session_id: "older"))
    advance_clock
    @database.register(registration_attributes.merge(session_id: "done", status: "done"))
    advance_clock
    newest = @database.register(registration_attributes.merge(session_id: "newer", remote: true))

    assert_equal [newest.fetch(:session_id), "older"], @database.list.map { |row| row.fetch(:session_id) }
    assert_equal ["done"], @database.list(status: "done").map { |row| row.fetch(:session_id) }
  end

  def test_list_filters_remote_true_or_false
    @database.register(registration_attributes.merge(session_id: "local", remote: false))
    @database.register(registration_attributes.merge(session_id: "remote", remote: true))

    assert_equal ["remote"], @database.list(remote: true).map { |row| row.fetch(:session_id) }
    assert_equal ["local"], @database.list(remote: false).map { |row| row.fetch(:session_id) }
  end

  def test_rejects_invalid_registration_values
    invalid_values = {
      source: "bad source",
      hostname: "bad host",
      session_id: "bad/session",
      status: "paused",
      adapter: "bad adapter",
      adapter_config: ["not", "an", "object"]
    }

    invalid_values.each do |field, value|
      error = assert_raises(ArgumentError, field.to_s) do
        @database.register(registration_attributes.merge(field => value))
      end
      assert_match field.to_s, error.message
    end
  end

  def test_two_processes_can_register_concurrently
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    start_read, start_write = IO.pipe
    pids = 2.times.map do |index|
      fork do
        start_write.close
        start_read.read(1)
        database = AgentSessionRegistry::Database.new(path: @path, clock: -> { @now })
        database.register(registration_attributes.merge(session_id: "child-#{index}"))
        exit! 0
      rescue StandardError => error
        warn error.full_message
        exit! 1
      end
    end
    start_read.close
    2.times { start_write.write("x") }
    start_write.close

    statuses = pids.map { |pid| Process.wait2(pid).last }

    assert statuses.all?(&:success?), statuses.map(&:inspect).join(", ")
    assert_equal %w[child-0 child-1], @database.list.map { |row| row.fetch(:session_id) }.sort
  end

  private

  def advance_clock
    @now += 60
  end

  def identity
    AgentSessionRegistry::Identity.new(
      source: "pi",
      hostname: "workstation",
      session_id: "session-1"
    )
  end

  def registration_attributes
    {
      source: "pi",
      hostname: "workstation",
      session_id: "session-1",
      remote: false,
      status: "active",
      name: "Registry work",
      goal: "Build session registry",
      cwd: "/work/repo",
      adapter: "pi-local",
      adapter_config: { "session_file" => "/sessions/one.jsonl" }
    }
  end
end
