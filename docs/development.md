# Developing the Minos plugin for Discourse

The administrator's manual is `README.md` (Polish). This page is for whoever changes the
plugin. The gateway's contract, from the client's side, is `docs/contract.md` in
`minos-moderation/client-php`; its receiving checklist is binding here.

## Layout

| Path | What |
|---|---|
| `plugin.rb` | Metadata, `enabled_site_setting :minos_enabled`, the `NewPostManager` handler, the problem check |
| `config/settings.yml` | The ten settings, all under `plugins:` |
| `config/locales/` | Server and client strings, Polish, for `pl_PL` and `en` (see "Locales") |
| `config/routes.rb` | `POST /minos/webhook`, through `MinosModeration::Engine` mounted at `/minos` |
| `app/controllers/minos_moderation/webhooks_controller.rb` | The receiver: raw body, signature, parse, hand over, 200 |
| `app/jobs/regular/minos_submit.rb` | Sends one held post (`Submission`) |
| `app/jobs/regular/minos_apply_verdict.rb` | Applies one received verdict (`VerdictApplier`) |
| `app/jobs/scheduled/minos_sweeper.rb` | Every 5 minutes: timeouts, lost retries, lost verdict jobs, old entries (`Sweep`) |
| `lib/minos_moderation/` | The plugin's classes; `lib/minos_moderation/CLAUDE.md` says which are standalone |
| `spec/lib/`, `spec/repo/` | The standalone tier (plain rspec) |
| `spec/requests/`, `spec/jobs/`, `spec/integration/` | The Discourse tier (plugin harness) |
| `spec/fixtures/signature.json` | The gateway's signature vector, a byte-for-byte copy of client-php's `vectors/signature.json` |
| `.github/workflows/release.yml` | On a `v*` tag: checks `plugin.rb`'s version against the tag (`.github/scripts/check-release-version.sh`) and creates the GitHub Release |

The standalone files (`signature.rb`, `webhook_payload.rb`, `scores.rb`, `text.rb`,
`decision.rb`, `gateway_client.rb`) use plain Ruby and its standard library, so every
rule that decides what is sent and what happens to a post is proven without Discourse.
Every Discourse touch point sits in a thin class (`settings.rb`, `store.rb`,
`new_post_handler.rb`, `submission.rb`, `receiver.rb`, `verdict_applier.rb`, `sweep.rb`,
`minos_gateway_problem.rb`).

## A post's way through the plugin

1. `NewPostHandler` (priority -100, after other plugins' handlers) holds the post with
   `manager.enqueue(:minos_pending)`, or lets `NewPostManager.default_handler` hold it when
   Discourse would hold it anyway (then `core_hold` is recorded and the verdict is only a
   note). It skips a disabled plugin, staff (`minos_skip_staff`), bots and personal
   messages. `Submission.enqueue` creates the entry and enqueues `Jobs::MinosSubmit`.
2. `Submission#run` claims the entry (`queued` → `sending`) under `Store.lock` and numbers
   the attempt, reduces the post with `Text.for_submission` (title, blank line, Markdown
   reduced to plain text — quote names, image alt texts and titles kept — first 3000
   characters), stores the digest, builds the body with `Scores.request_body` (item id
   `discourse:<reviewable id>.<attempt>`, `links`, `author_first_post`, and
   `link_domains` from `Text.link_hosts` reduced with `PublicSuffix.domain`) and POSTs it
   with `GatewayClient` over `FinalDestination::HTTP`. `Scores.classify` reads the answer:
   `202` → `submitted`; `429`/`503`/`408`/`5xx`/no answer → `queued` again with
   `retry_at` (`ponow_za_s`, or 60 s doubling to 15 minutes) and an `enqueue_in`;
   anything else → a configuration problem for the dashboard and the failure mode.
3. The webhook verifies and parses the delivery; `Receiver` moves a waiting entry to
   `received` with the verdict and enqueues `Jobs::MinosApplyVerdict`. Only the current
   attempt's id is taken; a repeat, an earlier attempt or a foreign id is dropped with a
   200.
4. `VerdictApplier#apply_verdict` asks `Decision.for_verdict` what to do and does it
   through the reviewable: `perform(system user, :approve_post)`, `update_fields` of the
   queued `raw` (and `title`) followed by `:approve_post`, `:reject_post`, or nothing. A
   `ReviewableNote` records the outcome. The entry ends `done`.
5. The failure mode (`Decision.for_failure`) never publishes a post Discourse held itself
   or a moderator edited. When it publishes one (fail-open), the entry ends
   `auto_published` with the post's id, and a verdict that still arrives goes through
   `Decision.for_late_verdict`: `keep`, `mask` (`PostRevisor#revise!` as the system user)
   or `hide` (`Post#hide!`) — unless a person acted on the post since (deleted, hid,
   edited it, or reviewed a flag on it), whose decision stays.
6. `Sweep` applies `Decision.for_entry` to every entry: the failure mode after
   `minos_timeout_minutes`, a resubmission of a due retry or of a send stuck for 2 min, a
   second application of a verdict whose job was lost after 2 min, giving up (a note, the
   post left) on a verdict that could not be applied for 24 h, and removal of a `done` or
   `auto_published` entry after 30 days.

State lives in `PluginStore` (`minos-moderation`, key `pending:<reviewable id>`, plus
`problem`); see `Store` for the fields. It never holds the unmasked text of a masked post
(a digest at most): the reviewable's history and the post's revisions keep it where
Discourse's own permissions guard it. Every read-modify-write of an entry runs under a
`DistributedMutex` per reviewable, so the job, the webhook and the sweeper never apply
two outcomes to one post.

## Tests

**Standalone tier** — runs anywhere with Ruby 3.3:

```bash
bundle install
bundle exec rspec spec/lib spec/repo
```

It covers the signature on the gateway's vector, the payload reader (client-php's rules),
the request body and the reading of every answer, the text reduction and the masks,
every publish/hold decision (including a property over all combinations of verdict,
setting and flags), the Claude Code rules and the locales.

`spec/lib/mock_gateway_spec.rb` runs the wire code against the mock gateway over real
HTTP. It needs a checkout of `minos-moderation/client-php` and `php` with ext-curl:

```bash
git clone https://github.com/minos-moderation/client-php.git ../client-php
MINOS_CLIENT_PHP=../client-php bundle exec rspec spec/lib/mock_gateway_spec.rb
```

Without `MINOS_CLIENT_PHP` that group is skipped. CI's `standalone` job checks client-php
out at a pinned commit of its main (`.github/workflows/tests.yml`, fb8d1ff at present),
runs `composer install --no-dev` there, sets `MINOS_REQUIRE_MOCK_GATEWAY=1`, which turns
the skip into a failure, and then reads the JSON report: any pending example, or a
mock-gateway example that did not pass, fails the job. The Discourse tier keeps the
group pending: it runs inside Discourse's own test container through the reusable
workflow, which has no PHP and no step of ours to install it.

**Discourse tier** — `spec/requests`, `spec/jobs`, `spec/integration`, written for the
plugin harness (`fab!`, `Fabricate`, `SiteSetting`, `stub_request`,
`expect_enqueued_with`). They run inside a Discourse checkout with the plugin in
`plugins/`:

```bash
LOAD_PLUGINS=1 bin/rspec plugins/minos-moderation/spec
```

CI runs them through Discourse's reusable workflow
(`discourse/.github/.github/workflows/discourse-plugin.yml@v1`) against core's `latest`.
Its linting job is skipped: the Gemfile carries rspec alone (no `rubocop-discourse`).

## The mock gateway with a development Discourse

The B2B route of the real gateway is not open yet. The mock in client-php answers like
it and delivers signed verdicts; you choose each verdict with markers such as
`[minos:blokuj]` (its README has the list). Never send real users' posts to it: it keeps
its queue as plain JSON on disk.

```bash
# 1. The mock's API (terminal 1), delivering to the development forum's webhook
export MINOS_MOCK_WEBHOOK_URL=http://localhost:3000/minos/webhook
php -S 127.0.0.1:8100 -t ../client-php/mock-gateway/public

# 2. Its worker (terminal 2, same variables)
export MINOS_MOCK_WEBHOOK_URL=http://localhost:3000/minos/webhook
php ../client-php/mock-gateway/bin/worker.php
```

Then, in the development forum's settings: `minos_gateway_url` =
`http://localhost:8100` (plain http is accepted only for a loopback host),
`minos_api_key` = `wgb2b_atrapa_minos_0000000000000000`, `minos_webhook_secret` =
`atrapa-minos-sekret-webhooka-tylko-lokalnie`, and `minos_enabled`. Post as a non-staff
user. Discourse's `FinalDestination` refuses private addresses unless the host is the
forum's own (`localhost` in development) or listed in `allowed_internal_hosts`; use
`localhost`, not `127.0.0.1`, in the URL.

The mock masks every `[[fragment]]` per character and keeps the brackets (client-php
f85c6ed), so `ocenzurowany` has the sent text's length, as the contract says, and the
plugin carries its masks back onto the Markdown. An older mock dropped the brackets, and
with it every censored post was left to the moderators (`mask_unmappable`).

## Locales

- Discourse's Polish locale is **`pl_PL`**, not `pl`, so the files are
  `server.pl_PL.yml` and `client.pl_PL.yml`.
- The `en` files carry the **same Polish text**. The product speaks Polish only, and
  Discourse falls back to `en`: a forum set to any other language would otherwise show
  raw translation keys to its administrator and moderators. `spec/repo/locales_spec.rb`
  pins the parity, a description for every setting, a text for every key the code names
  and every decision reason, and the rules of Discourse's `script/i18n_lint.rb` (no
  `{{…}}`, relative links through `%{base_path}`, no plural keys).
- Setting descriptions can interpolate only `%{base_path}`, which is how the webhook URL
  appears in them.
- Plain `choices` of an enum setting are shown to the administrator untranslated
  (`SiteSettings::TypeSupervisor` sets `translate_names: false`), so the choice values are
  Polish words (`publikuj_ocenzurowany`, `zostaw_moderatorom`, `odrzuc`); `fail-open`,
  `fail-closed` and the profile names are the contract's own terms. The values are
  stored, so they are never renamed.
- The client files hold only the product name: the plugin has no client-side UI.

## Releasing

Discourse installs a plugin from its git URL (a `git clone` in the forum's `app.yml`), not
from an archive, so there is no build script and a release carries no asset: the tagged
tree is the release. The version lives in ONE place the release workflow checks: the
`# version:` line of `plugin.rb`'s header (the last one, as Discourse reads it). The
repository keeps no changelog; the release notes are GitHub's generated ones. The
workflow, not a person, creates the release, and only after its check passes.

1. Bump `# version:` in `plugin.rb` in a pull request, and merge it. On every pull request
   the `release-version` job of `tests.yml` already runs the release check against it.
2. The dry run on `main`: Actions → Release → "Run workflow", branch `main`, the tag to
   be (`v0.2.0`); see it green.
3. The owner creates and pushes the TAG ONLY, on the commit the dry run checked, from a
   local clone: `git tag -a v0.2.0 -m v0.2.0 <commit>` and `git push origin v0.2.0`. Not
   GitHub's "Draft a new release" form: a tag created there is published together with
   its release, before any check. Tag pushes from Claude Code sessions are refused.
4. The tag's push starts `.github/workflows/release.yml`. Its `check` job fails unless
   `plugin.rb`'s `# version:` (read as Discourse's `Plugin::Metadata.parse` reads it: the
   header's comment lines, the last `# version:` winning) equals the tag without the `v`,
   naming both, and `LICENSE` is in the tree and not blank. Only then the `publish` job
   creates the release (`--verify-tag`, generated notes, a pre-release for a tag with `-`).

When a release for the tag already exists at that point, `publish` fails: such a release
was published unchecked. Delete it (keep the tag) and re-run the failed jobs. A failed
check publishes nothing: delete the tag, fix `main`, start again from step 1. By hand:
`.github/scripts/check-release-version.sh v0.1.0` from the repository's root.

The repository is private today: a forum cannot `git clone` it without credentials until
it is made public.

Nothing in this repository enforces that only the owner tags (the session refusal lives
outside GitHub): the owner should add a tag ruleset on `v*` that only they may bypass, or
a `release` environment with a required reviewer on the `publish` job.

## Discourse APIs

Verified in Discourse's source (`main`, September 2026) or in
`discourse-plugin-skeleton`:

- plugin metadata comments, `enabled_site_setting`, `after_initialize`,
  `register_problem_check` (`lib/plugin/instance.rb`, `lib/plugin/metadata.rb`);
- `config/settings.yml` keys `default`, `secret: true`, `type: enum` + `choices`,
  `min`/`max`, and descriptions via `site_settings.<name>` with `%{base_path}`;
- the engine and routes pattern, and the `Jobs` inflection of `app/jobs/regular` and
  `app/jobs/scheduled` (`config/initializers/000-zeitwerk.rb`);
- `NewPostManager.add_handler(priority)`, `manager.enqueue(reason)`,
  `NewPostManager.post_needs_approval?`, `NewPostManager.default_handler`; handlers run
  before Discourse's own check for personal messages, which is why the handler skips
  them itself;
- `ReviewableQueuedPost`: `perform(user, :approve_post / :reject_post)` (`approve_post`
  is offered only while the topic is open, hence `topic_closed`), `update_fields` with a
  `payload` hash and its history entry, `payload["raw"]` and `payload["title"]`,
  `pending?`, `reviewable_notes` / `ReviewableNote::MAX_CONTENT_LENGTH`;
- the score reason text `reviewables.reasons.<reason>` (`ReviewableScoreSerializer`);
- `ProblemCheck` (realtime when `perform_every` is unset; `problem`, `no_problem`,
  `translation_data`, the key `dashboard.problem.<identifier>`);
- `PluginStore.get/set/remove/cast_value`, `PluginStoreRow`, `DistributedMutex.synchronize`;
- `Jobs::Base` (`sidekiq_options`), `Jobs::Scheduled` + `every`, `Jobs.enqueue`,
  `Jobs.enqueue_in`;
- `FinalDestination::HTTP` (Net::HTTP with SSRF checks and pinned addresses);
- `Post#hide!(post_action_type_id)` with `PostActionType.types[:inappropriate]` (it
  also messages the author and hides a first post's topic), `Post.with_deleted`,
  `Post#version`, `PostRevisor#revise!(editor, fields, skip_validations:, bypass_bump:,
  bypass_rate_limiter:)` with an `edit_reason`, `ReviewableFlaggedPost` statuses;
- the per-IP limits `max_reqs_per_ip_per_10_seconds` (50), `max_reqs_per_ip_per_minute`
  (200) and `max_reqs_per_ip_mode` (`block`) in `config/discourse_defaults.conf`;
- `public_suffix` in Discourse's `Gemfile.lock` (through `addressable`);
- `ApplicationController` filters `verify_authenticity_token`, `check_xhr`,
  `redirect_to_login_if_required`, `preload_json`, and `requires_plugin`;
- spec helpers `fab!`, `expect_enqueued_with`, `track_log_messages`, the
  `reviewable_queued_post` and `reviewable_queued_post_topic` fabricators, WebMock with
  `allow_localhost`;
- the reusable CI workflow `discourse/.github/.github/workflows/discourse-plugin.yml@v1`
  and its inputs `name` and `skip_linting`.

Not verified (no Discourse checkout here; only CI runs the Discourse tier):

- that the Discourse-tier specs added after the first CI run pass as written;
- `PublicSuffix.domain` is called as the gem documents it (nil for an invalid name); the
  plugin sends no `link_domains` when the constant is missing;
- the exact oldest Discourse version with every API above (`ReviewableNote` in
  particular is recent; `VerdictApplier` skips notes when it is missing, and
  `plugin.rb` registers the problem check only when `register_problem_check` exists).
  `plugin.rb` sets no `required_version`; the promise is `latest`, tested in CI;
- whether a problem check's message is re-rendered later from its stored details with
  the same text (the details carry the finished Polish sentence, so it should be);
- `NewPostManager` handlers after a development-mode code reload (the handler is added
  once, in `after_initialize`, like core's poll plugin does).

## Assumptions and limitations

- The gateway's masks keep the sent text's length (one `█` per masked character). A mask
  that does not map exactly leaves the post to the moderators; it never publishes.
- Edits of published posts are not sent; only new posts and new topics are.
- A long post is assessed on its first 3000 characters; the failure mode decides
  whether the rest may be published unassessed, except after an `ocenzurowane` head,
  which always waits for a moderator.
- Hiding a published post on a late verdict uses Discourse's own hiding, which sends the
  author Discourse's standard "post hidden" message.
- Every gateway delivery counts against Discourse's per-IP request limit; bursts get 429
  and rely on the gateway's retries (README, "Limit żądań").
- `wsparcie` on a published post is a note on a resolved review item, which moderators
  see only in its history; a more visible alert is a follow-up.
- Configuration errors reach the admin dashboard through a problem check; on a
  Discourse without `register_problem_check` they reach only the log.
