# Demo charter v2

A proposed version of the example triage charter for the demo home, so the Improve screen has
a real backtest. It drops the security routing guardrail and treats card-on-file questions as
how-to. Its adapter profile `fake-triage-v2` runs `fake-script-v2.json`, the example script with
two answers changed: case-0006 (card on file) becomes `how-to` and case-0005 (suspicious login)
becomes `account`.

Proposed right after the demo's first rehearsal (casebook as imported, 7/8), the gate compares:
case-0006 improves, case-0005 regresses, 7/8 against 7/8, and the gate fails ("case regressed").

Seeding (cli-e2e): copy both JSON files to `etc/examples/triage/`, add a `fake-triage-v2`
profile to `adapters.json` running `fake-script-v2.json`, and after `rehearse it` run
`propose st_triage --charter etc/examples/triage/charter-v2.json`.
`DemoProposalTests` pins the result.
