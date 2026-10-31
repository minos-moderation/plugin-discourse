# Minos for Discourse

A Discourse plugin that sends new posts to the Wergiliusz gateway and applies the verdict
the gateway delivers to a signed webhook. Part of Minos; its backlog item is
`minos-moderation/minos#5`.

## The boundary
- The plugin talks only to the gateway, over HTTPS, with the forum's key. The key and the
  webhook secret never reach a log, a page or a public file.
- The gateway decides and the plugin applies. It never guesses a verdict: `nieocenione`
  goes to the administrator's fail-open or fail-closed setting.
- The contract is `docs/contract.md` in `minos-moderation/client-php`; its receiving
  checklist is binding: read the raw body first, verify the signature, drop repeated
  deliveries, answer 2xx fast.
- Ruby implements the verification (`lib/minos_moderation/signature.rb`) and tests it on
  the gateway's signature vector, copied byte for byte (`spec/fixtures/signature.json`).
- Only the sent text and two spam signals leave the forum: never an e-mail, IP or user id.
- The shared plugin rules (F1…D2) are `docs/plugin-behaviour.md` in
  `minos-moderation/client-php`; a change to one rule is a decision for every plugin, not
  for this one. Their compliance table: `docs/development.md`.

## Code
- Code, comments and commits in English. Everything an administrator or a user reads is
  in Polish (`config/locales/`; the `en` files carry the same Polish text on purpose).
- Wire strings (JSON keys, codes, headers, enum values) are Polish and never renamed.
- The oldest versions the plugin promises: Discourse `latest` (the plugin workflow's
  default core) and Ruby 3.3, tested in CI.
- Two test tiers: `bundle exec rspec spec/lib spec/repo` runs anywhere; `spec/requests`,
  `spec/jobs` and `spec/integration` need Discourse's plugin harness. What each file of
  `lib/` may depend on: `lib/minos_moderation/CLAUDE.md`.
- No real posts in tests: use the mock gateway from `minos-moderation/client-php`.
- Never `git add -A`. Sessions open PRs; only the owner or the coordinating session merges.
- Model-pinned agents in `.claude/agents/`, copied from `client-php` and fitted to the
  plugin's paths (`programista-prosty`'s risk list above all).
- This file stays small (`spec/repo/claude_rules_spec.rb` pins its size).
