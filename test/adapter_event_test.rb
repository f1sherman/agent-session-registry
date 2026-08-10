# frozen_string_literal: true

require_relative "test_helper"
require "agent_session_registry/adapter_event"

class AdapterEventTest < Minitest::Test
  def setup
    @registered = {
      "type" => "registered",
      "source" => "pi",
      "hostname" => "dev",
      "session_id" => "session-1",
      "status" => "active",
      "name" => nil,
      "cwd" => "/home/brian/projects/repo",
      "session_file" => "/sessions/one.jsonl"
    }
    @identity = AgentSessionRegistry::Identity.parse("pi:dev:session-1")
  end

  def test_reads_one_bounded_newline_delimited_json_event
    reader, writer = IO.pipe
    writer.write("#{JSON.generate(@registered)}\nignored")

    event = AgentSessionRegistry::AdapterEvent.read(
      reader,
      timeout: 0.1,
      max_bytes: AgentSessionRegistry::AdapterEvent::MAX_BYTES
    )

    assert_equal @registered, event
    assert_equal "ignored", reader.read(7)
  ensure
    reader&.close
    writer&.close
  end

  def test_rejects_invalid_event_framing
    assert_read_error("{\n")
    assert_read_error("[]\n")
    assert_read_error("1\n")
    assert_read_error("\n")
    assert_read_error("{}", close_writer: true)
    assert_read_error("a" * 17, max_bytes: 16)
  end

  def test_enforces_the_default_sixteen_kibibyte_limit
    prefix = '{"padding":"'
    suffix = '"}'
    padding = "a" * (AgentSessionRegistry::AdapterEvent::MAX_BYTES - prefix.bytesize - suffix.bytesize)
    exact_payload = "#{prefix}#{padding}#{suffix}"

    assert_equal(
      { "padding" => padding },
      read_event(exact_payload)
    )
    assert_read_error("#{exact_payload} ")
  end

  def test_times_out_before_a_complete_event
    reader, writer = IO.pipe
    writer.write("{")

    error = assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
      AgentSessionRegistry::AdapterEvent.read(reader, timeout: 0.01, max_bytes: 100)
    end
    assert_match(/timed out/i, error.message)
  ensure
    reader&.close
    writer&.close
  end

  def test_validates_registered_event
    assert_equal(
      @registered,
      AgentSessionRegistry::AdapterEvent.validate_registered(
        @registered,
        session_id: "session-1"
      )
    )

    invalid_events(@registered).each do |event|
      assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
        AgentSessionRegistry::AdapterEvent.validate_registered(
          event,
          session_id: "session-1"
        )
      end
    end

    [
      @registered.merge("type" => "inspected"),
      @registered.merge("session_id" => "session-2"),
      @registered.merge("status" => "done")
    ].each do |event|
      assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
        AgentSessionRegistry::AdapterEvent.validate_registered(
          event,
          session_id: "session-1"
        )
      end
    end
  end

  def test_validates_inspected_event_against_the_identity
    inspected = @registered.merge(
      "type" => "inspected",
      "status" => "done",
      "name" => "Remote name"
    )

    assert_equal(
      inspected,
      AgentSessionRegistry::AdapterEvent.validate_inspected(
        inspected,
        identity: @identity
      )
    )

    [
      inspected.merge("type" => "registered"),
      inspected.merge("hostname" => "other"),
      inspected.merge("session_id" => "session-2")
    ].each do |event|
      assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
        AgentSessionRegistry::AdapterEvent.validate_inspected(
          event,
          identity: @identity
        )
      end
    end
  end

  def test_validates_done_status_event_against_the_identity
    status = {
      "type" => "status",
      "source" => "pi",
      "hostname" => "dev",
      "session_id" => "session-1",
      "status" => "done"
    }

    assert_equal(
      status,
      AgentSessionRegistry::AdapterEvent.validate_status(
        status,
        identity: @identity
      )
    )

    [
      status.merge("type" => "inspected"),
      status.merge("status" => "active"),
      status.merge("source" => "codex"),
      status.merge("extra" => true)
    ].each do |event|
      assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
        AgentSessionRegistry::AdapterEvent.validate_status(
          event,
          identity: @identity
        )
      end
    end
  end

  private

  def read_event(content)
    reader, writer = IO.pipe
    writer_thread = Thread.new do
      writer.write("#{content}\n")
      writer.close
    end

    AgentSessionRegistry::AdapterEvent.read(reader, timeout: 1)
  ensure
    reader&.close
    writer&.close unless writer&.closed?
    writer_thread&.join
  end

  def assert_read_error(content, close_writer: false, max_bytes: nil)
    reader, writer = IO.pipe
    writer_thread = Thread.new do
      writer.write(content)
      writer.close if close_writer
    end

    arguments = { timeout: 1 }
    arguments[:max_bytes] = max_bytes if max_bytes
    assert_raises(AgentSessionRegistry::AdapterEvent::Error) do
      AgentSessionRegistry::AdapterEvent.read(reader, **arguments)
    end
  ensure
    reader&.close
    writer&.close unless writer&.closed?
    writer_thread&.join
  end

  def invalid_events(event)
    [
      event.reject { |key, _| key == "cwd" },
      event.merge("extra" => true),
      event.merge("source" => 1),
      event.merge("source" => "bad source"),
      event.merge("hostname" => nil),
      event.merge("session_id" => []),
      event.merge("name" => 1),
      event.merge("cwd" => nil),
      event.merge("session_file" => false)
    ]
  end
end
