# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "sqlite3"

require_relative "adapter"
require_relative "database"
require_relative "identity"
require_relative "record"

module AgentSessionRegistry
  class CLI
    class InputError < StandardError; end
    class StorageError < StandardError; end
    class HelpRequested < StandardError; end

    COMMANDS = %w[list show register update done resume].freeze

    def self.run(argv, out:, err:, env:)
      new(out: out, err: err, env: env).run(argv.dup)
    end

    def initialize(out:, err:, env:)
      @out = out
      @err = err
      @env = env
    end

    def run(argv)
      if argv == ["--help"] || argv == ["-h"]
        @out.puts root_help
        return 0
      end

      command = argv.shift
      raise InputError, "missing command; use --help for usage" if command.nil?
      raise InputError, "unsupported command: #{command}" unless COMMANDS.include?(command)

      result = send("run_#{command}", argv)
      result.is_a?(Integer) ? result : 0
    rescue HelpRequested
      0
    rescue OptionParser::ParseError, InputError, ArgumentError, JSON::ParserError, EncodingError => error
      @err.puts "asr: #{error.message}"
      2
    rescue Adapter::Error, StorageError, SQLite3::Exception, SystemCallError => error
      @err.puts "asr: #{error.message}"
      1
    end

    private

    def root_help
      <<~HELP
        Usage: asr COMMAND [options]

        Commands:
          asr list       List sessions
          asr show       Show one session
          asr register   Register or replace a session
          asr update     Update one session
          asr done       Mark one session done
          asr resume     Resume one session through its adapter

        Run `asr COMMAND --help` for command options.
      HELP
    end

    def run_list(argv)
      options = { status: "active", all: false, remote: nil, json: false }
      status_explicit = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: asr list [options]"
        opts.on("--status STATUS", "Filter by active or done") do |value|
          options[:status] = value
          status_explicit = true
        end
        opts.on("--all", "Include active and done sessions") { options[:all] = true }
        opts.on("--remote", "Show only remote sessions") { options[:remote] = true }
        opts.on("--json", "Print a JSON array") { options[:json] = true }
        add_help(opts)
      end
      parse!(parser, argv)
      require_no_arguments(argv)
      if options[:all] && status_explicit
        raise InputError, "--status and --all are mutually exclusive"
      end

      records = if options[:all]
        database.list(status: "active", remote: options[:remote]) +
          database.list(status: "done", remote: options[:remote])
      else
        database.list(status: options[:status], remote: options[:remote])
      end
      records = sort_records(records) if options[:all]
      write_records(records, json: options[:json])
    end

    def run_show(argv)
      options = { json: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: asr show KEY [options]"
        opts.on("--json", "Print a JSON object") { options[:json] = true }
        add_help(opts)
      end
      parse!(parser, argv)
      write_record(fetch_record(one_key(argv)), json: options[:json])
    end

    def run_register(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: asr register [options]"
        opts.on("--source SOURCE") { |value| options[:source] = value }
        opts.on("--session-id ID") { |value| options[:session_id] = value }
        opts.on("--hostname HOSTNAME") { |value| options[:hostname] = value }
        opts.on("--local") { select_location(options, false) }
        opts.on("--remote") { select_location(options, true) }
        opts.on("--status STATUS") { |value| options[:status] = value }
        opts.on("--name NAME") { |value| options[:name] = value }
        opts.on("--goal GOAL") { |value| options[:goal] = value }
        opts.on("--cwd PATH") { |value| options[:cwd] = value }
        opts.on("--adapter NAME") { |value| options[:adapter] = value }
        opts.on("--adapter-config JSON") do |value|
          options[:adapter_config] = parse_object(value, "adapter config")
        end
        opts.on("--json", "Print a JSON object") { options[:json] = true }
        add_help(opts)
      end
      parse!(parser, argv)
      require_no_arguments(argv)
      require_options(options, :source, :session_id, :status, :adapter, :adapter_config)
      unless options.key?(:remote)
        raise InputError, "register requires exactly one of --local or --remote"
      end

      identity = registration_identity(options)
      record = database.register(
        source: identity.source,
        hostname: identity.hostname,
        session_id: identity.session_id,
        remote: options[:remote],
        status: options[:status],
        name: options.fetch(:name, ""),
        goal: options.fetch(:goal, ""),
        cwd: options.fetch(:cwd, ""),
        adapter: options[:adapter],
        adapter_config: options[:adapter_config]
      )
      write_record(record, json: options.fetch(:json, false))
    end

    def run_update(argv)
      identity_options = {}
      changes = {}
      output_options = { json: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: asr update [KEY | identity options] [changes]"
        add_identity_options(opts, identity_options)
        opts.on("--local", "Set the record location to local") do
          select_location(changes, false)
        end
        opts.on("--remote", "Set the record location to remote") do
          select_location(changes, true)
        end
        opts.on("--status STATUS") { |value| changes[:status] = value }
        opts.on("--name NAME") { |value| changes[:name] = value }
        opts.on("--goal GOAL") { |value| changes[:goal] = value }
        opts.on("--cwd PATH") { |value| changes[:cwd] = value }
        opts.on("--adapter NAME") { |value| changes[:adapter] = value }
        opts.on("--adapter-config JSON") do |value|
          changes[:adapter_config] = parse_object(value, "adapter config")
        end
        opts.on("--json", "Print a JSON object") { output_options[:json] = true }
        add_help(opts)
      end
      parse!(parser, argv)
      raise InputError, "update requires at least one changed field" if changes.empty?

      record = database.update(resolve_identity(argv, identity_options), changes)
      raise InputError, "record not found" unless record

      write_record(record, json: output_options[:json])
    end

    def run_done(argv)
      identity_options = {}
      output_options = { json: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: asr done [KEY | identity options] [options]"
        add_identity_options(opts, identity_options)
        opts.on("--json", "Print a JSON object") { output_options[:json] = true }
        add_help(opts)
      end
      parse!(parser, argv)
      record = database.done(resolve_identity(argv, identity_options))
      raise InputError, "record not found" unless record

      write_record(record, json: output_options[:json])
    end

    def run_resume(argv)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: asr resume KEY"
        add_help(opts)
      end
      parse!(parser, argv)
      identity = one_key(argv)
      record = fetch_record(identity)
      adapter = Adapter.new(directory: adapter_directory)
      pid = adapter.spawn(
        name: record.fetch(:adapter),
        action: "resume",
        key: identity.key,
        config: record.fetch(:adapter_config)
      )
      begin
        database.update(identity, status: "active")
      rescue StandardError => error
        begin
          adapter.stop(pid)
        rescue Adapter::Error
          nil
        end
        raise error
      end
      adapter.wait(pid)
    end

    def registration_identity(options)
      if options[:remote]
        unless options[:hostname]
          raise InputError, "--hostname is required for --remote registration"
        end
        Identity.new(
          source: options[:source],
          hostname: options[:hostname],
          session_id: options[:session_id]
        )
      else
        raise InputError, "--hostname cannot be used with --local" if options[:hostname]

        Identity.local(source: options[:source], session_id: options[:session_id])
      end
    end

    def add_identity_options(parser, options)
      parser.on("--source SOURCE") { |value| options[:source] = value }
      parser.on("--hostname HOSTNAME") { |value| options[:hostname] = value }
      parser.on("--session-id ID") { |value| options[:session_id] = value }
    end

    def add_help(parser)
      parser.on("-h", "--help", "Show help") do
        @out.puts parser
        raise HelpRequested
      end
    end

    def parse!(parser, argv)
      parser.parse!(argv)
    end

    def require_no_arguments(argv)
      raise InputError, "unexpected argument: #{argv.first}" unless argv.empty?
    end

    def require_options(options, *fields)
      missing = fields.reject { |field| options.key?(field) }
      return if missing.empty?

      rendered = missing.map { |field| "--#{field.to_s.tr("_", "-")}" }.join(", ")
      raise InputError, "missing required option: #{rendered}"
    end

    def select_location(options, remote)
      if options.key?(:remote) && options[:remote] != remote
        raise InputError, "--local and --remote are mutually exclusive"
      end
      options[:remote] = remote
    end

    def parse_object(value, name)
      parsed = JSON.parse(value)
      raise InputError, "#{name} must be a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => error
      raise InputError, "invalid #{name}: #{error.message}"
    end

    def resolve_identity(argv, options)
      if argv.length == 1
        unless options.empty?
          raise InputError, "a rendered key cannot be combined with identity options"
        end
        Identity.parse(argv.first)
      elsif argv.empty?
        require_options(options, :source, :session_id)
        if options[:hostname]
          Identity.new(
            source: options[:source],
            hostname: options[:hostname],
            session_id: options[:session_id]
          )
        else
          Identity.local(source: options[:source], session_id: options[:session_id])
        end
      else
        raise InputError, "expected exactly one rendered key"
      end
    end

    def one_key(argv)
      raise InputError, "expected exactly one rendered key" unless argv.length == 1

      Identity.parse(argv.first)
    end

    def fetch_record(identity)
      database.fetch(identity) || raise(InputError, "record not found: #{identity.key}")
    end

    def database
      @database ||= begin
        path = database_path
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        instance = Database.new(path: path)
        File.chmod(0o600, path)
        instance
      rescue ArgumentError => error
        raise StorageError, error.message
      end
    end

    def database_path
      @env.fetch(
        "ASR_DATABASE_PATH",
        File.join(Dir.home, ".local/state/agent-session-registry/registry.sqlite3")
      )
    end

    def adapter_directory
      @env.fetch(
        "ASR_ADAPTER_DIR",
        File.join(Dir.home, ".local/lib/agent-session-registry/adapters")
      )
    end

    def sort_records(records)
      records.sort do |left, right|
        order = right.fetch(:updated_at) <=> left.fetch(:updated_at)
        order = right.fetch(:created_at) <=> left.fetch(:created_at) if order.zero?
        order = left.fetch(:source) <=> right.fetch(:source) if order.zero?
        order = left.fetch(:hostname) <=> right.fetch(:hostname) if order.zero?
        order = left.fetch(:session_id) <=> right.fetch(:session_id) if order.zero?
        order
      end
    end

    def write_records(records, json:)
      if json
        @out.puts JSON.pretty_generate(records)
      elsif records.any?
        @out.puts records.map { |record| human_list_record(record) }.join("---\n")
      end
    end

    def write_record(record, json:)
      if json
        @out.puts JSON.pretty_generate(record)
      else
        @out.puts human_full_record(record)
      end
    end

    def human_list_record(record)
      lines = [
        "key: #{record_key(record)}",
        "status: #{record.fetch(:status)}",
        "location: #{record.fetch(:remote) ? "remote" : "local"}",
        "hostname: #{record.fetch(:hostname)}",
        "name: #{record.fetch(:name)}"
      ]
      goal = record.fetch(:goal)
      lines << "goal: #{goal}" unless goal.empty? || goal == record.fetch(:name)
      lines.concat(
        [
          "cwd: #{record.fetch(:cwd)}",
          "updated_at: #{record.fetch(:updated_at)}",
          "resume: asr resume #{record_key(record)}"
        ]
      )
      "#{lines.join("\n")}\n"
    end

    def human_full_record(record)
      values = Record::FIELDS.map do |field|
        value = record.fetch(field)
        value = JSON.generate(value) if field == :adapter_config
        "#{field}: #{value}"
      end
      (["key: #{record_key(record)}"] + values).join("\n")
    end

    def record_key(record)
      Identity.new(
        source: record.fetch(:source),
        hostname: record.fetch(:hostname),
        session_id: record.fetch(:session_id)
      ).key
    end
  end
end
