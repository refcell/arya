import Foundation

extension AdapterProfiles {
    /// Example exec profiles for the non-interactive print modes of common command-line agents,
    /// for a starting `adapters.json`. Both run read-only, so they report `sandbox: workdir`:
    ///
    /// - `claude-code`: Claude Code's `-p` mode with model aliases per effort, arya's tools
    ///   through `--mcp-config`, and its shell, file-writing, and web tools disallowed.
    /// - `codex-cli`: Codex CLI's `exec` mode with `--sandbox read-only` and reasoning effort
    ///   per effort. Its MCP servers come from its own configuration, so `tools` is `none`.
    public static let examples = AdapterProfiles(profiles: [
        "claude-code": claudeCode,
        "codex-cli": codexCLI,
    ])

    static let claudeCode: AdapterProfile = {
        let disallowed = "Bash Edit Write NotebookEdit WebFetch WebSearch"
        func args(_ model: String) -> [String] {
            [
                "-p", "--model", model, "--mcp-config", "{mcpConfig}", "--disallowedTools",
                disallowed,
            ]
        }
        return AdapterProfile(
            kind: .exec, command: "claude",
            args: ["low": args("haiku"), "medium": args("sonnet"), "high": args("opus")],
            promptVia: .stdin, parse: .text, mcpConfig: .file, sandbox: .workdir)
    }()

    static let codexCLI: AdapterProfile = {
        func args(_ effort: String) -> [String] {
            [
                "exec", "--sandbox", "read-only", "--skip-git-repo-check", "-c",
                "model_reasoning_effort=\(effort)", "-",
            ]
        }
        return AdapterProfile(
            kind: .exec, command: "codex",
            args: ["low": args("low"), "medium": args("medium"), "high": args("high")],
            promptVia: .stdin, parse: .text, mcpConfig: .none, sandbox: .workdir)
    }()
}
