# `lib/minos_moderation/`

Two kinds of file, kept apart so that the rules which decide a post run without Discourse.

- **Standalone** (plain Ruby and its standard library; no Rails, no Discourse constant):
  `signature.rb`, `webhook_payload.rb`, `scores.rb`, `text.rb`, `decision.rb`,
  `gateway_client.rb`, `metrics.rb`. `spec/lib/` requires them directly and CI runs those specs with
  `rspec` alone. None requires another: in Discourse, Zeitwerk loads them. `text.rb`
  reads `html_entities.json`, plain data (Zeitwerk loads only `.rb` files).
- **Platform touch points**, thin, and the only way in to Discourse: `engine.rb`,
  `settings.rb`, `store.rb`, `new_post_handler.rb`, `submission.rb`, `receiver.rb`,
  `verdict_applier.rb`, `sweep.rb`, `minos_gateway_problem.rb`, `verdict_report.rb`. Their specs need the
  plugin harness (`spec/requests`, `spec/jobs`, `spec/integration`).
- What happens to a post (publish, mask, reject, leave) is decided in `decision.rb` and
  only executed in `verdict_applier.rb`. An unknown value or setting never publishes.
- One file, one constant named after it (`bin/rails zeitwerk:check` in CI). No file named
  `version.rb`, `http.rb` or `json.rb`: Discourse's inflector renames those.
