# Adapter profiles for command-line agents

`adapters.json` here holds exec profiles for the non-interactive modes of two public
command-line agents. arya runs the agent once per run through `arya-exec-adapter`, with the
prompt on stdin, in a scratch working directory.

| Profile | Command | Output | arya's tools | Effort |
| --- | --- | --- | --- | --- |
| `claude-code` | `claude -p` | `stream-json`: live events and cost | `--mcp-config` file | model per effort |
| `codex-cli` | `codex exec --sandbox read-only` | plain text | none (its own config) | reasoning effort |

Both run read-only: Claude Code with its shell, file-writing, and web tools disallowed, Codex
CLI in its read-only sandbox. Proposed actions still go through the charter's policy.

To use one, install the agent and sign in, copy the profile into `<home>/adapters.json`, and
name it in the charter's `adapter` field (for example `"adapter": "claude-code"`). The file is
read at each run, so no restart is needed. Check a profile against the adapter conformance suite
with `just conformance "arya-exec-adapter --profile claude-code --profiles
etc/examples/adapters/adapters.json"`.

Fields are described in [docs/PROTOCOL.md](../../../docs/PROTOCOL.md) (adapter profiles).
These profiles are equal to `AdapterProfiles.examples`; `ExamplesTests` keeps them in sync.
