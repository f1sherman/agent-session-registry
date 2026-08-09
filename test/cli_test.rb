# frozen_string_literal: true

require_relative "test_helper"
require "open3"

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

  def test_register_and_show_support_human_and_json_output
    stdout, stderr, status = register_local("session-1", "--json")
    assert status.success?, stderr
    record = JSON.parse(stdout)
    assert_equal "pi", record.fetch("source")
    assert_equal @hostname, record.fetch("hostname")
    assert_equal false, record.fetch("remote")
    assert_equal({ "session_file" => "/sessions/one.jsonl" }, record.fetch("adapter_config"))

    key = "pi:#{@hostname}:session-1"
    stdout, stderr, status = run_cli("show", key)
    assert status.success?, stderr
    assert_includes stdout, "key: #{key}"
    assert_includes stdout, "adapter_config: {\"session_file\":\"/sessions/one.jsonl\"}"

    stdout, stderr, status = run_cli("show", key, "--json")
    assert status.success?, stderr
    assert_equal "Registry work", JSON.parse(stdout).fetch("name")

    _stdout, stderr, status = run_cli("show", "pi:#{@hostname}:session-1:extra")
    assert_equal 2, status.exitstatus
    assert_match(/exactly three fields/i, stderr)
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
      "--name", "Renamed", "--goal", "A new goal", "--json"
    )
    assert status.success?, stderr
    record = JSON.parse(stdout)
    assert_equal "Renamed", record.fetch("name")
    assert_equal "A new goal", record.fetch("goal")

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

  def test_list_filters_active_all_done_and_remote_records
    register_local("active", "--name", "Active name")
    register_local("done", "--name", "Same", "--goal", "Same")
    run_cli("done", "--source", "pi", "--session-id", "done")
    register_remote("remote")

    stdout, stderr, status = run_cli("list")
    assert status.success?, stderr
    assert_includes stdout, "key: pi:#{@hostname}:active"
    assert_includes stdout, "location: local"
    assert_includes stdout, "name: Active name"
    assert_includes stdout, "goal: Build registry"
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
      "--goal", "Build registry",
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
end
