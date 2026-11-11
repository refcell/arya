- (from app-shell, 2026-11-10) `GovernanceText.autonomyLine` now says the level as a sentence
  via `ActionWords.autonomy` ("Acts alone on medium risk"), from review VC36. One line changed.
- (from app-shell, 2026-11-10) `BindingPolicy` shows a person binding by name ("Sam"), not
  "person:sam person" (CEO review 21). "Sam · owner" would need the charter owner or the
  binding role on `PolicySummary.Binding`; the inspector's Connections list already says it.
- 2026-11-11 (app-shell): `PolicyPanel` action rows and `GovernanceText.ruleScope` read in
  words ("send email on crm", not "send_email@crm"), because the raw-id gate now fails any
  snake_case key and the policy panel shows in the steward inspector.
