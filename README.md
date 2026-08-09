# Agent Session Registry

Agent Session Registry (`asr`) keeps a small, queryable record of agent sessions.
Each machine owns its registry database. A registry can describe sessions on the
local machine and sessions on remote machines, but it does not synchronize data
between machines.

`asr` has no daemon. It runs one command, updates SQLite when necessary, and
exits. It does not run arbitrary commands from the database. A named adapter
can perform only a supported action such as `resume`.

## Requirements

- Ruby
- The Ruby `sqlite3` gem and its SQLite requirement
- Git, for installation from this repository

Install from Git and run the public executable:

```sh
git clone https://github.com/f1sherman/agent-session-registry agent-session-registry
cd agent-session-registry
bundle install
bin/asr --help
```

You can add the repository `bin` directory to `PATH`, or invoke `bin/asr`
directly.

## Commands

The rendered key has exactly three fields: `source:hostname:session-id`.

Register a local session. The hostname comes from the local machine:

```sh
asr register \
  --source pi \
  --session-id session-1 \
  --local \
  --status active \
  --name "Registry work" \
  --goal "Build registry" \
  --cwd /work/repo \
  --adapter pi-local \
  --adapter-config '{"session_file":"/sessions/one.jsonl"}'
```

Register a remote session. Remote registration requires an explicit hostname:

```sh
asr register \
  --source pi \
  --session-id session-2 \
  --remote \
  --hostname build.example \
  --status active \
  --name "Remote work" \
  --goal "Run remote checks" \
  --cwd /work/repo \
  --adapter pi-local \
  --adapter-config '{"session_file":"/sessions/two.jsonl"}'
```

List active sessions, all sessions, done sessions, or active remote sessions:

```sh
asr list
asr list --all
asr list --status done
asr list --remote
asr list --all --json
```

Show one session:

```sh
asr show pi:workstation:session-1
asr show pi:workstation:session-1 --json
```

Update by rendered key or by local identity fields. Field form uses the local
canonical hostname when `--hostname` is omitted:

```sh
asr update pi:workstation:session-1 --name "New name"
asr update --source pi --session-id session-1 --goal "New goal"
asr update \
  --source pi \
  --hostname build.example \
  --session-id session-2 \
  --status active
```

Mark a session done by key or local identity fields:

```sh
asr done pi:workstation:session-1
asr done --source pi --session-id session-1
```

Resume a session through its registered adapter:

```sh
asr resume pi:workstation:session-1
```

Mutation commands and `show` accept `--json`. `list --json` returns an array;
other JSON outputs are one object.

## Records and status

Every record has these fixed columns:

- `source`, `hostname`, and `session_id`, which form the rendered key
- `remote`
- `status`
- `name`, `goal`, and `cwd`
- `adapter` and `adapter_config`
- `created_at` and `updated_at`

`active` means that the session is current and appears in the default list.
`done` removes it from the default list but keeps its history. `asr resume`
starts the adapter first. After the process starts, `asr` changes the record to
`active`, waits for the adapter, and returns the adapter exit status.

## Storage and adapter locations

The default database is:

```text
~/.local/state/agent-session-registry/registry.sqlite3
```

Set `ASR_DATABASE_PATH` to use another database:

```sh
ASR_DATABASE_PATH=/tmp/registry.sqlite3 asr list
```

Adapters are executable files in:

```text
~/.local/lib/agent-session-registry/adapters
```

Set `ASR_ADAPTER_DIR` to use another directory:

```sh
ASR_ADAPTER_DIR=/opt/asr/adapters asr resume pi:workstation:session-1
```

An adapter name selects one direct executable child of this directory. `asr`
resolves symlinks and rejects a target outside the adapter directory. It starts
the adapter without a shell and passes exactly three arguments:

```text
ACTION RENDERED_KEY JSON_CONFIG
```

Currently, the CLI dispatches only the `resume` action. The JSON value is the
object stored in `adapter_config`. The adapter must validate the action and all
configuration before it starts another program. For example, install this as
an executable file named `pi-local` in the adapter directory:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

action, key, raw_config = ARGV
abort "unsupported action" unless action == "resume"
abort "invalid key" unless key&.split(":", -1)&.length == 3

config = JSON.parse(raw_config)
abort "invalid config" unless config.is_a?(Hash)
session_file = config.fetch("session_file")
abort "invalid session file" unless session_file.is_a?(String) &&
  session_file.start_with?("/sessions/")

exec("pi", "--session", session_file)
```

This example uses an argument array with `exec`; it does not build a shell
command from record values.

## Tests

Run the complete test suite:

```sh
rake test
```
