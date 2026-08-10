# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "stringio"
require "timeout"
require "agent_session_registry/cli"

class CLITest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @database_path = File.join(@directory, "registry.sqlite3")
    @adapter_directory = File.join(@directory, "adapters")
    FileUtils.mkdir_p(@adapter_directory)
    @repo_root = File.expand_path("..", __dir__)
    @executable = File.join(@repo_root, "bin/asr")
    @env = {
      "ASR_DATABASE_PATH" => @database_path,
      "ASR_ADAPTER_DIR" => @adapter_directory
    }
    @hostname = AgentSessionRegistry::Identity.local(
      source: "pi",
      session_id: "placeholder"
    ).hostname
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_help_bad_options_and_unsupported_actions
    stdout, stderr, status = run_cli("--help")
    assert status.success?, stderr
    assert_includes stdout, "asr list"
    assert_includes stdout, "asr start"
    assert_empty stderr

    stdout, stderr, status = run_cli("list", "--help")
    assert status.success?, stderr
    assert_includes stdout, "--status"
    assert_empty stderr

    _stdout, stderr, status = run_cli("list", "--not-an-option")
    assert_equal 2, status.exitstatus
    assert_match(/invalid option/i, stderr)
    refute_match(/\.rb:\d+/, stderr)

    _stdout, stderr, status = run_cli("archive")
    assert_equal 2, status.exitstatus
    assert_match(/unsupported command.*archive/i, stderr)
  end

  def test_start_parses_one_adapter_and_an_absolute_cwd
    calls = []
    runner = Object.new
    runner.define_singleton_method(:start) do |adapter_name:, cwd:|
      calls << [adapter_name, cwd]
      19
    end
    cli = AgentSessionRegistry::CLI.new(
      out: StringIO.new,
      err: StringIO.new,
      env: @env
    )
    cli.instance_variable_set(:@session_runner, runner)

    assert_equal 19, cli.run([
      "start", "pi-dev", "--cwd", "/home/brian/projects/repo"
    ])
    assert_equal [["pi-dev", "/home/brian/projects/repo"]], calls

    invalid = [
      ["start", "pi-dev"],
      ["start", "--cwd", "/home/brian/projects/repo"],
      ["start", "pi-dev", "extra", "--cwd", "/home/brian/projects/repo"],
      ["start", "pi-dev", "--cwd", "relative/path"],
      ["start", "pi-dev", "--cwd", ""],
      ["start", "pi-dev", "--cwd", "/work", "--name", "Not supported"]
    ]
    invalid.each do |arguments|
      output = StringIO.new
      errors = StringIO.new
      invalid_cli = AgentSessionRegistry::CLI.new(out: output, err: errors, env: @env)
      invalid_cli.instance_variable_set(:@session_runner, runner)
      assert_equal 2, invalid_cli.run(arguments), arguments.join(" ")
      assert_empty output.string
    end
    assert_equal 1, calls.length
  end

  def test_register_and_show_support_human_and_json_output
    stdout, stderr, status = register_local("session-1", "--json")
    assert status.success?, stderr
    record = JSON.parse(stdout)
    assert_equal "pi", record.fetch("source")
    assert_equal @hostname, record.fetch("hostname")
    assert_equal false, record.fetch("remote")
    assert_equal({ "session_file" => "/sessions/one.jsonl" }, record.fetch("adapter_config"))
    assert_equal AgentSessionRegistry::Record::FIELDS.map(&:to_s), record.keys

    key = "pi:#{@hostname}:session-1"
    stdout, stderr, status = run_cli("show", key)
    assert status.success?, stderr
    assert_equal(<<~OUTPUT, stdout)
      key: #{key}
      source: pi
      hostname: #{@hostname}
      session_id: session-1
      remote: false
      status: active
      name: Registry work
      cwd: /work/repo
      adapter: pi-local
      adapter_config: {"session_file":"/sessions/one.jsonl"}
      created_at: #{record.fetch("created_at")}
      updated_at: #{record.fetch("updated_at")}
    OUTPUT

    stdout, stderr, status = run_cli("show", key, "--json")
    assert status.success?, stderr
    assert_equal "Registry work", JSON.parse(stdout).fetch("name")

    _stdout, stderr, status = run_cli("show", "pi:#{@hostname}:session-1:extra")
    assert_equal 2, status.exitstatus
    assert_match(/exactly three fields/i, stderr)
  end

  def test_malformed_identity_bytes_are_input_errors_without_backtraces
    arguments = registration_arguments("bad-bytes") + ["--local"]
    arguments[arguments.index("--source") + 1] = "\xFF".b
    stdout = StringIO.new
    stderr = StringIO.new

    status = AgentSessionRegistry::CLI.run(
      arguments,
      out: stdout,
      err: stderr,
      env: @env
    )

    assert_equal 2, status
    assert_empty stdout.string
    assert_match(/ASCII-8BIT.*UTF-8/, stderr.string)
    assert_equal 1, stderr.string.lines.length
    refute_match(/\.rb:\d+/, stderr.string)
  end

  def test_register_validates_location_hostname_and_adapter_config
    _stdout, stderr, status = run_cli(*registration_arguments("session-1"))
    assert_equal 2, status.exitstatus
    assert_match(/--local or --remote/i, stderr)

    arguments = registration_arguments("remote-1") + ["--remote"]
    _stdout, stderr, status = run_cli(*arguments)
    assert_equal 2, status.exitstatus
    assert_match(/--hostname.*remote/i, stderr)

    arguments += ["--hostname", "Build.EXAMPLE.", "--json"]
    stdout, stderr, status = run_cli(*arguments)
    assert status.success?, stderr
    record = JSON.parse(stdout)
    assert_equal "build.example", record.fetch("hostname")
    assert_equal true, record.fetch("remote")

    arguments = registration_arguments("bad-config") + [
      "--local", "--adapter-config", "[]"
    ]
    # Replace the valid option and its value rather than passing it twice.
    index = arguments.index("--adapter-config")
    arguments.slice!(index, 2)
    arguments.concat(["--adapter-config", "[]"])
    _stdout, stderr, status = run_cli(*arguments)
    assert_equal 2, status.exitstatus
    assert_match(/adapter config.*object/i, stderr)
  end

  def test_update_and_done_accept_exact_keys_and_local_field_form
    register_local("session-1")
    key = "pi:#{@hostname}:session-1"

    stdout, stderr, status = run_cli(
      "update", "--source", "pi", "--session-id", "session-1",
      "--name", "Renamed", "--json"
    )
    assert status.success?, stderr
    record = JSON.parse(stdout)
    assert_equal "Renamed", record.fetch("name")

    stdout, stderr, status = run_cli("done", key, "--json")
    assert status.success?, stderr
    assert_equal "done", JSON.parse(stdout).fetch("status")

    stdout, stderr, status = run_cli(
      "update", key, "--status", "active", "--json"
    )
    assert status.success?, stderr
    assert_equal "active", JSON.parse(stdout).fetch("status")

    stdout, stderr, status = run_cli(
      "done", "--source", "pi", "--session-id", "session-1", "--json"
    )
    assert status.success?, stderr
    assert_equal "done", JSON.parse(stdout).fetch("status")
  end

  def test_removed_goal_options_are_rejected
    _stdout, stderr, status = run_cli(
      *registration_arguments("old-register"), "--local", "--goal", "old"
    )
    assert_equal 2, status.exitstatus
    assert_match(/invalid option: --goal/, stderr)

    register_local("old-update")
    key = "pi:#{@hostname}:old-update"
    _stdout, stderr, status = run_cli("update", key, "--goal", "old")
    assert_equal 2, status.exitstatus
    assert_match(/invalid option: --goal/, stderr)
  end

  def test_human_list_has_exact_stable_layout
    register_local("stable-layout", "--name", "Same")
    json_stdout, json_stderr, json_status = run_cli("list", "--json")
    assert json_status.success?, json_stderr
    updated_at = JSON.parse(json_stdout).fetch(0).fetch("updated_at")

    stdout, stderr, status = run_cli("list")

    assert status.success?, stderr
    assert_empty stderr
    assert_equal(<<~OUTPUT, stdout)
      key: pi:#{@hostname}:stable-layout
      status: active
      location: local
      hostname: #{@hostname}
      name: Same
      cwd: /work/repo
      updated_at: #{updated_at}
      resume: asr resume pi:#{@hostname}:stable-layout
    OUTPUT
  end

  def test_list_filters_active_all_done_and_remote_records
    register_local("active", "--name", "Active name")
    register_local("done", "--name", "Same")
    run_cli("done", "--source", "pi", "--session-id", "done")
    register_remote("remote")

    stdout, stderr, status = run_cli("list")
    assert status.success?, stderr
    assert_includes stdout, "key: pi:#{@hostname}:active"
    assert_includes stdout, "location: local"
    assert_includes stdout, "name: Active name"
    assert_match(/updated_at: \d{4}-\d\d-\d\dT.*Z/, stdout)
    assert_includes stdout, "resume: asr resume pi:#{@hostname}:active"
    assert_includes stdout, "---"
    refute_includes stdout, "session_id: done"

    stdout, stderr, status = run_cli("list", "--all", "--json")
    assert status.success?, stderr
    assert_equal %w[active done remote], JSON.parse(stdout).map { |row| row.fetch("session_id") }.sort

    stdout, stderr, status = run_cli("list", "--status", "done", "--json")
    assert status.success?, stderr
    assert_equal ["done"], JSON.parse(stdout).map { |row| row.fetch("session_id") }

    stdout, stderr, status = run_cli("list", "--remote", "--json")
    assert status.success?, stderr
    assert_equal ["remote"], JSON.parse(stdout).map { |row| row.fetch("session_id") }

    _stdout, stderr, status = run_cli("list", "--all", "--status", "done")
    assert_equal 2, status.exitstatus
    assert_match(/mutually exclusive/i, stderr)
  end

  def test_missing_records_are_input_errors_without_backtraces
    missing_key = "pi:#{@hostname}:missing"
    [
      ["show", missing_key],
      ["update", missing_key, "--name", "No record"],
      ["done", "--source", "pi", "--session-id", "missing"],
      ["resume", missing_key]
    ].each do |arguments|
      _stdout, stderr, status = run_cli(*arguments)
      assert_equal 2, status.exitstatus, arguments.join(" ")
      assert_match(/record not found/i, stderr)
      refute_match(/\.rb:\d+/, stderr)
    end
  end

  def test_resume_dispatches_the_adapter_propagates_status_and_marks_active
    register_local("session-1")
    key = "pi:#{@hostname}:session-1"
    run_cli("done", key)
    adapter_log = File.join(@directory, "adapter.json")
    install_adapter("pi-local")

    _stdout, stderr, status = run_cli(
      "resume", key,
      extra_env: { "ADAPTER_LOG" => adapter_log, "ADAPTER_EXIT" => "17" }
    )
    assert_equal 17, status.exitstatus, stderr
    assert_equal(
      [
        File.realpath(File.join(@adapter_directory, "pi-local")),
        "resume",
        key,
        { "session_file" => "/sessions/one.jsonl" }
      ],
      JSON.parse(File.read(adapter_log))
    )

    stdout, stderr, status = run_cli("show", key, "--json")
    assert status.success?, stderr
    assert_equal "active", JSON.parse(stdout).fetch("status")
  end

  def test_resume_launch_failure_preserves_done_status
    register_local("session-1", "--adapter", "missing")
    key = "pi:#{@hostname}:session-1"
    run_cli("done", key)

    _stdout, stderr, status = run_cli("resume", key)
    assert_equal 1, status.exitstatus
    assert_match(/adapter.*missing/i, stderr)

    stdout, stderr, status = run_cli("show", key, "--json")
    assert status.success?, stderr
    assert_equal "done", JSON.parse(stdout).fetch("status")
  end

  def test_done_synchronizes_once_after_local_commit_and_waits_for_acknowledgment
    register_local("session-1")
    socket_path = File.join(@directory, "sync.sock")
    server = UNIXServer.new(socket_path)
    requests = Queue.new
    observed_statuses = Queue.new
    thread = Thread.new do
      2.times do |index|
        socket = server.accept
        requests << JSON.parse(socket.gets)
        identity = AgentSessionRegistry::Identity.local(
          source: "pi", session_id: "session-1"
        )
        observed_statuses << AgentSessionRegistry::Database.new(
          path: @database_path
        ).fetch(identity).fetch(:status)
        sleep 0.1 if index == 1
        response = if index.zero?
          { "ok" => false, "error" => "sync failed" }
        else
          { "ok" => true, "status" => "done" }
        end
        socket.puts(JSON.generate(response))
        socket.close
      end
    end

    _stdout, stderr, status = run_cli(
      "done", "--source", "pi", "--session-id", "session-1",
      extra_env: { "ASR_SYNC_SOCKET" => socket_path }
    )
    assert_equal 3, status.exitstatus
    assert_match(/source record is done, but synchronization failed.*sync failed/, stderr)
    assert_equal "done", observed_statuses.pop

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = run_cli(
      "done", "--source", "pi", "--session-id", "session-1", "--json",
      extra_env: { "ASR_SYNC_SOCKET" => socket_path }
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert status.success?, stderr
    assert_operator elapsed, :>=, 0.08
    assert_equal "done", JSON.parse(stdout).fetch("status")
    assert_equal "done", observed_statuses.pop

    expected = {
      "action" => "done",
      "source" => "pi",
      "hostname" => @hostname,
      "session_id" => "session-1"
    }
    assert_equal expected, requests.pop
    assert_equal expected, requests.pop
    assert requests.empty?
  ensure
    server&.close
    thread&.join(0.5)
  end

  def test_done_validates_sync_timeout_before_marking_the_record_done
    register_local("session-1")

    _stdout, stderr, status = run_cli(
      "done", "--source", "pi", "--session-id", "session-1",
      extra_env: {
        "ASR_SYNC_SOCKET" => File.join(@directory, "sync.sock"),
        "ASR_ADAPTER_TIMEOUT" => "invalid"
      }
    )

    assert_equal 2, status.exitstatus
    assert_match(/ASR_ADAPTER_TIMEOUT must be a positive number/, stderr)
    identity = AgentSessionRegistry::Identity.local(
      source: "pi", session_id: "session-1"
    )
    assert_equal "active", AgentSessionRegistry::Database.new(
      path: @database_path
    ).fetch(identity).fetch(:status)
  end

  def test_resume_stops_adapter_promptly_when_status_update_fails
    register_local("session-1")
    key = "pi:#{@hostname}:session-1"
    run_cli("done", key)
    ready_path = File.join(@directory, "adapter-ready")
    stopped_path = File.join(@directory, "adapter-stopped")
    install_blocking_adapter("pi-local", ready_path:, stopped_path:)

    adapter = AgentSessionRegistry::Adapter.new(directory: @adapter_directory)
    spawn = adapter.method(:spawn)
    adapter.define_singleton_method(:spawn) do |**arguments|
      pid = spawn.call(**arguments)
      Timeout.timeout(1) { sleep 0.01 until File.exist?(ready_path) }
      pid
    end
    database = AgentSessionRegistry::Database.new(path: @database_path)
    database.define_singleton_method(:update) do |_identity, _changes|
      raise SQLite3::BusyException, "locked"
    end
    stdout = StringIO.new
    stderr = StringIO.new
    cli = AgentSessionRegistry::CLI.new(out: stdout, err: stderr, env: @env)
    cli.instance_variable_set(:@database, database)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = Timeout.timeout(2) do
      AgentSessionRegistry::Adapter.stub(:new, adapter) { cli.run(["resume", key]) }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_equal 1, status
    assert_operator elapsed, :<, 2
    assert_match(/locked/, stderr.string)
    assert File.exist?(stopped_path), "adapter was not terminated"
    record = AgentSessionRegistry::Database.new(path: @database_path).fetch(
      AgentSessionRegistry::Identity.parse(key)
    )
    assert_equal "done", record.fetch(:status)
  end

  private

  def run_cli(*arguments, extra_env: {})
    Open3.capture3(@env.merge(extra_env), @executable, *arguments)
  end

  def registration_arguments(session_id)
    [
      "register",
      "--source", "pi",
      "--session-id", session_id,
      "--status", "active",
      "--name", "Registry work",
      "--cwd", "/work/repo",
      "--adapter", "pi-local",
      "--adapter-config", '{"session_file":"/sessions/one.jsonl"}'
    ]
  end

  def register_local(session_id, *extra)
    run_cli(*registration_arguments(session_id), "--local", *extra)
  end

  def register_remote(session_id)
    arguments = registration_arguments(session_id)
    run_cli(*arguments, "--remote", "--hostname", "Remote.EXAMPLE.")
  end

  def install_adapter(name)
    path = File.join(@adapter_directory, name)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      File.write(
        ENV.fetch("ADAPTER_LOG"),
        JSON.generate([File.realpath(__FILE__), ARGV[0], ARGV[1], JSON.parse(ARGV[2])])
      )
      exit Integer(ENV.fetch("ADAPTER_EXIT", "0"))
    RUBY
    File.chmod(0o755, path)
  end

  def install_blocking_adapter(name, ready_path:, stopped_path:)
    path = File.join(@adapter_directory, name)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      trap("TERM") do
        File.write(#{stopped_path.inspect}, "stopped")
      end
      File.write(#{ready_path.inspect}, "ready")
      sleep 10
    RUBY
    File.chmod(0o755, path)
  end
end
