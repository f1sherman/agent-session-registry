# Agent Session Registry

Agent Session Registry (`asr`) keeps a small, queryable record of agent sessions.
Each machine owns its registry database. A registry can describe sessions on the
local machine and sessions on remote machines. An active adapter connection can
synchronize one remote session with its source record.

`asr` has no daemon. It runs one command, updates SQLite when necessary, and
exits. It does not run arbitrary commands from the database. A named adapter
can perform only a supported action such as `start`, `inspect`, or `resume`.

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
asr update pi:workstation:session-1 --cwd /work/other-repo
asr update --source pi --session-id session-1 --name "New name"
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

Start and register a remote session through an adapter:

```sh
asr start pi-dev --cwd /home/user/projects/repository
```

The start command generates the session ID. It does not accept a display name.
The adapter reports the source name and other authoritative metadata after the
source record appears.

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
- `name` and `cwd`
- `adapter` and `adapter_config`
- `created_at` and `updated_at`

`active` means that the session is current and appears in the default list.
`done` removes it from the default list but keeps its history. Local resume keeps
the existing local behavior. Remote resume first asks its adapter to inspect the
source record. A source `done` status is authoritative and cannot change back to
`active`. ASR then waits for the interactive adapter and returns its exit status.

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

Resume and inspect receive the rendered record key and the object stored in
`adapter_config`. Start receives an empty rendered key and this exact generic
configuration:

```json
{"session_id":"<generated-id>","cwd":"<requested-working-directory>"}
```

A start-capable remote adapter name has the exact form `<source>-<hostname>`.
ASR derives the expected new record identity from that name. For example,
`pi-dev` can register only `pi:dev:<generated-id>`. The registered working
directory must equal the requested directory, and the returned session file
must be a non-empty absolute path. The hostname can contain hyphens. For
example, `pi-dev-box` can register `pi:dev-box:<generated-id>`.

The adapter must validate its action, key, configuration, host, and path policy
before it starts another program. For example, install this as an executable
file named `pi-local` in the adapter directory:

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

## Interactive adapter protocol

For start, inspect, and connected remote resume, ASR creates a private inherited
file descriptor. Its number is in `ASR_ADAPTER_EVENT_FD`. The adapter writes
newline-delimited JSON only to this descriptor. Terminal output stays on
standard input, output, and error.

The exact event schemas are:

```json
{"type":"registered","source":"pi","hostname":"host","session_id":"id","status":"active","name":null,"cwd":"/path","session_file":"/path/session.jsonl"}
{"type":"inspected","source":"pi","hostname":"host","session_id":"id","status":"active","name":"Name","cwd":"/path","session_file":"/path/session.jsonl"}
{"type":"status","source":"pi","hostname":"host","session_id":"id","status":"done"}
```

ASR validates exact keys, types, identity, status, size, framing, and timeouts.
The selected adapter name comes from the command or stored record, never from an
event. Adapter code remains responsible for environment-specific host and path
validation.

During connected start and remote resume, ASR also creates one private Unix
socket and passes its path in `ASR_ADAPTER_SYNC_SOCKET`. An adapter can forward
that socket to the source host. The adapter must set the forwarded path as
`ASR_SYNC_SOCKET` for the source-side `asr done` process. That process sends:

```json
{"action":"done","source":"pi","hostname":"host","session_id":"id"}
```

The connection-scoped listener accepts only the active identity and responds
with one of:

```json
{"ok":true,"status":"done"}
{"ok":false,"error":"message"}
```

This channel grants only an idempotent done transition for the active record.
It is not a general command endpoint. ASR removes the socket when the adapter
exits. No daemon, TCP listener, or standard-output protocol is used.

`asr done` exits with status `3` only when it has already marked the source
record done but the connection-scoped synchronization failed. Input failures
exit with status `2`. Other runtime failures exit with status `1`.

## Tests

Run the complete test suite:

```sh
rake test
```
