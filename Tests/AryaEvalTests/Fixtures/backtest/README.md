# Backtest scenario

Invented data for the M3.5 backtest: the support inbox triage steward, current charter versus
a proposed one, on the eight-case triage casebook (case-0006 corrected to `billing`).

- `charter-current.json` is the example charter. Scripted by `fake-current.json`, it files
  case-0006 (a card-on-file question) as `how-to`: 7/8 pass.
- `charter-proposed.json` adds "A question about the card on file is a billing question." but
  drops the security routing guardrail. Scripted by `fake-proposed.json`, case-0006 improves to
  `billing` and case-0005 (a suspicious login) regresses to `account`: 7/8 pass, the gate fails.

`BacktestScenarioTests` pins the comparison; demo seeding can pick the script by charter.
