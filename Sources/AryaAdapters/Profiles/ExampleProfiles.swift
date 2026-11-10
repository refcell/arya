import Foundation

extension AdapterProfiles {
    /// Example exec profiles for the non-interactive print modes of common command-line agents,
    /// for a starting `adapters.json`. The two agent profiles run read-only, so they report
    /// `sandbox: workdir`:
    ///
    /// - `claude-code`: Claude Code's `-p` mode with `stream-json` output and partial
    ///   messages (live events, the reply as it is written, and cost), model aliases per
    ///   effort, arya's tools through `--mcp-config`, and its shell, file-writing, and web
    ///   tools disallowed.
    /// - `codex-cli`: Codex CLI's `exec --json` mode (live events and token counts) with
    ///   `--sandbox read-only` and reasoning effort per effort. Its MCP servers come from its
    ///   own configuration, so `tools` is `none`.
    /// - `shell`: runs the input as a `/bin/sh -c` command (`parse: command`), so a routine or
    ///   check streams its real output; it confines nothing itself, so `sandbox` is `none`.
    public static let examples = AdapterProfiles(profiles: [
        "claude-code": claudeCode,
        "codex-cli": codexCLI,
        "shell": shell,
    ])

    /// Runs the input as a `/bin/sh` command, so routines and checks show live output.
    static let shell: AdapterProfile = {
        let args = ["-c"]
        return AdapterProfile(
            kind: .exec, command: "/bin/sh", args: ["low": args, "medium": args, "high": args],
            promptVia: .argument, parse: .command)
    }()

    static let claudeCode: AdapterProfile = {
        let disallowed = "Bash Edit Write NotebookEdit WebFetch WebSearch"
        func args(_ model: String) -> [String] {
            [
                "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--model", model,
                "--mcp-config", "{mcpConfig}", "--disallowedTools", disallowed,
            ]
        }
        return AdapterProfile(
            kind: .exec, command: "claude",
            args: ["low": args("haiku"), "medium": args("sonnet"), "high": args("opus")],
            promptVia: .stdin, parse: .streamJSON, mcpConfig: .file, sandbox: .workdir)
    }()

    static let codexCLI: AdapterProfile = {
        func args(_ effort: String) -> [String] {
            [
                "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "-c",
                "model_reasoning_effort=\(effort)", "-",
            ]
        }
        return AdapterProfile(
            kind: .exec, command: "codex",
            args: ["low": args("low"), "medium": args("medium"), "high": args("high")],
            promptVia: .stdin, parse: .codexJSON, mcpConfig: .none, sandbox: .workdir)
    }()
}
