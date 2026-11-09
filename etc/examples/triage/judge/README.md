# Judge example: tone and policy adherence

A rubric judge for the triage steward, runnable offline.

| File | What it is |
| --- | --- |
| `rubric.md` | the rubric: tone of any reply, and adherence to the charter's policy |
| `verdicts.json` | what a judge answered for each casebook case, served by `CaseVerdicts` |

Rehearsing the example casebook with this judge passes seven of eight cases. Each case's
score reads as one sentence built from the judge's notes, for example
`polite, no reply needed, followed policy`, and for `case-0006`
`polite, no reply needed, routed a how-to question to billing` (score 0.5, failed).
A live judge (`AdapterJudge`) sends the same rubric to an adapter and validates its verdict.
`judgeExampleScoresInSentences` in the eval tests pins these results.
