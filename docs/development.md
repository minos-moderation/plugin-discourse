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
| `spec/fixtures/reader_view.json` | The corpus of posts whose sent text must hold every word a reader sees (both tiers) |
| `lib/minos_moderation/html_entities.json` | HTML's named character references, the data `Text` decodes them with |
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
   the attempt, reduces the post with `Text.for_submission` (title, blank line, the text
   a reader sees — see "What `tekst` is" below — first 3000 characters), stores the
   digest, builds the body with `Scores.request_body` (item id
   `discourse:<reviewable id>.<attempt>`, `links`, `author_first_post`, and
   `link_domains` from `Text.link_hosts` reduced with `PublicSuffix.domain`) and POSTs it
   with `GatewayClient` over `FinalDestination::HTTP`. `Scores.classify` reads the answer:
   `202` → `submitted`; `429`/`503`/`408`/`5xx`/no answer → `queued` again with
   `retry_at` (`ponow_za_s`, or 60 s doubling to 15 minutes) and an `enqueue_in`, unless
   the gateway's `ponow_za_s`, uncapped, ends after the post's time-out
   (`Decision.refusal_outlasts_timeout?`, shared plugin rule 3(a)): then the failure mode
   at once, reason `limit`; anything else → a configuration problem for the dashboard and
   the failure mode. A `429` `limit_dobowy_klucza`, `limit_globalny_b2b` or
   `kolejka_pelna` (`Scores::LIMITS`) also records `Store.limit` — the state and the time
   until which the gateway refuses, from the uncapped `ponow_za_s` — which the dashboard
   shows until that time or the next `202`.
3. The webhook verifies and parses the delivery; `Receiver` moves a waiting entry to
   `received` with the verdict and enqueues `Jobs::MinosApplyVerdict`. The current
   attempt's id is taken, and an earlier attempt's when its stored digest equals the
   current attempt's (`digests`, `Decision.verdict_for_entry?`: the same text was
   assessed); a repeat, any later verdict for the same post, an earlier attempt of another
   text (or of an entry written before per-attempt digests) and a foreign id are dropped
   with a 200.
4. `VerdictApplier#apply_verdict` asks `Decision.for_verdict` what to do and does it
   through the reviewable: `perform(system user, :approve_post)`, `update_fields` of the
   queued `raw` (and `title`), a `reload` that must read the masks back exactly, followed
   by `:approve_post`, `:reject_post`, or nothing. A `ReviewableNote` records the
   outcome. The entry ends `done`.
5. The failure mode (`Decision.for_failure`) never publishes a post Discourse held itself
   or a moderator edited. When it publishes one (fail-open), the entry ends
   `auto_published` with the post's id, and a verdict that still arrives goes through
   `Decision.for_late_verdict`: `keep`, `mask` (`PostRevisor#revise!` as the system user)
   or `hide` (`Post#hide!`) — unless a person acted on the post since (deleted, hid,
   edited it, or reviewed a flag on it), whose decision stays. A verdict with `wsparcie`
   never hides the post (nor does a mask that cannot be carried out): it is kept, with
   the support note, because `Post#hide!` is a sanction and messages the author.
6. `Sweep` applies `Decision.for_entry` to every entry: the failure mode after
   `minos_timeout_minutes` (never under `Decision::MIN_TIMEOUT_MINUTES`, 20, also for a
   lower value stored before that minimum: Discourse checks `min` only on write), a
   resubmission of a due retry or of a send stuck for 2 min, a
   second application of a verdict whose job was lost after 2 min, giving up (a note, the
   post left) on a verdict that could not be applied for 24 h, and removal of a `done` or
   `auto_published` entry after 30 days.

### What `tekst` is

The rule: **the text sent for assessment is the text a reader sees**, and nothing a
reader can see is dropped; where removing something is not certain, more is sent. So
`Text.for_submission` reduces the raw Markdown as Discourse renders it:

- Markdown markup goes where markdown-it reads it as markup: emphasis (`**`, `__`, `~~`,
  `*`, `_`) only where its `scanDelims` lets the markers open and close (so `kur~~<i>wa~~`
  keeps its tildes: a tilde next to punctuation does not open), heading and blockquote
  markers, fence markers (an info string stays), an autolink's brackets. A link keeps
  its text in place (a code span in it too) and its address, title and label follow the
  word the link ends in, so a link inside a word (`Ty [ku](…)rwa`) never splits it:
  inline (`[t](u "x")`, `[t](<u>)`), full (`[t][l]`), collapsed (`[t][]`) and shortcut
  (`[t]`) links, a reference one only where the post defines its label (in any case; a
  definition, also in a list item, may have its address on the next line, unless that
  line starts a block that ends it: a fence, a break, a heading, a list item, a
  blockquote, an HTML or BBCode block, a table), as markdown-it reads them, also
  inside brackets that are not a link. An image (inline or by reference, read the same
  way; `[…]` after a `!` is never a link) keeps its alt text and title in its place,
  apart from the words around it; a reference's label follows the next word. A lone or
  escaped marker (`\[`, `\&`) a reader sees as it is written stays, so that it never
  joins two words. A quote leaves the title Discourse shows, a details block its
  summary, each on a line of its own.
- Each line is read as markdown-it's block rules read it (`Text.line_kinds`): fenced code
  (closed only by a fence of at most three spaces, at the top, in a blockquote or in a
  list item, or by the end of its container), indented code (also after a thematic
  break or a setext underline, and a list marker indented four or more columns past its
  list), HTML blocks (in a list item too), tables (a header with a pipe over a delimiter
  row with as many cells, in the same blockquote, not on lazy lines; each cell read on
  its own), a link reference definition (shown as nothing; sent as written). A fence or
  an HTML block may open in a blockquote on a list item's own line (`- > ```…`); the
  fence runs on the lines that keep both containers. A paragraph's line indented four
  columns or more continues it, whatever it starts with. A lazy line (fewer blockquote
  markers than the paragraph it follows, also the blockquote of a list item) keeps the
  blockquote open, unless it opens a BBCode block, or in a nested blockquote any block:
  then it ends the blockquote, as markdown-it's terminators do, and a list in it. A
  blockquote left of a list item's content is a new one, not the item's.
- Code is shown as it is written, so it is sent as it is written (`Text.inline_reading`):
  fenced and indented code blocks, code spans (markdown-it's backtick rule, escapes, HTML
  tags and links passed over) and `[code]…[/code]` (inline, taken in the same left to
  right order, up to the next closing tag). Only a span's backticks and the space
  markdown-it trims at each of its ends go. Also as written: a bare link, as
  markdown-it's inline linkify takes one (`Text::BARE_LINK`, linkify-it's expressions:
  brackets and parentheses balanced in its path, trailing `*` left out, none inside a
  link), and the lines of an HTML block, where Markdown's inline syntax is not read.
- `[quote=…]`/`[details=…]` is a block only where Discourse's `bbcode-block.js` makes one
  (`Text.block_tags`): at the first column, closed by its tag at the very end of the line
  or alone on a later line (nested tags counted), never in code, an HTML block, a table's
  header or another BBCode block. Elsewhere it is sent as written, attribute included.
  Other BBCode markers (`[b]`, `[code]`, `[spoiler]`, …) go only where Discourse pairs
  them within one paragraph; an unclosed one stays.
- Outside code, HTML tags and comments (markdown-it's grammar, an escaped `\<` excepted)
  go, each within one paragraph or HTML block (one that reaches past it is text): a
  block tag leaves a line break, an `<img>` its alt text and title in its place, and a
  tooltip Discourse's sanitizer keeps (`title` of `a` and `abbr` by its default allow
  list, of `summary` by the details plugin, of `span` by the chat plugin) follows the
  word it is on, so it never splits it. An HTML comment goes with its text. No other
  attribute is sent: the sanitizer removes it or a reader does not see it (an `href`).
  What is not sent does not count toward the 3000 characters. A plugin that allows
  `title` on another tag would need that tag in `Text::TOOLTIP_TAGS`.
- Character references are decoded as a browser decodes them (`html_entities.json`, the
  HTML standard's named references, generated from Python's `html.entities.html5`),
  except in code; decoded characters have no origin, so a mask on one holds the post.
- Characters invisible by default (`\p{Default_Ignorable_Code_Point}`: a soft hyphen,
  zero-width spaces) go, from the title too.

`spec/fixtures/reader_view.json` is the corpus: `spec/lib/text_spec.rb` checks the sent
text of each entry and the property "every word a reader sees is a word of the sent
text" (whole words: a split word fails it) against the reader's view as Discourse's
source describes it; `spec/integration/text_reader_view_spec.rb` checks the same
property against Discourse's own `PrettyText.cook` in CI. A change of this reduction changes the digest of
a post in flight at the upgrade: its verdict is then not applied (`edited`) and a
moderator decides, the safe direction.

State lives in `PluginStore` (`minos-moderation`, key `pending:<reviewable id>`, plus
`problem` and `limit`); see `Store` for the fields. It never holds the unmasked text of a masked post
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
(`discourse/.github/.github/workflows/discourse-plugin.yml`, pinned to the commit of its
tag `v1`) against core's `latest`. Its linting job is skipped: the Gemfile carries rspec
alone (no `rubocop-discourse`).

**CI** (`.github/workflows/tests.yml`) runs on every pull request, on every push to
`main` and **weekly** (`schedule`, Tuesdays 03:41 UTC), so the promise "works on
Discourse `latest`" is checked even when nobody opens a pull request. GitHub starts a
scheduled run from the default branch only, so the schedule takes effect once it is on
`main`; a failed weekly run is an ordinary red run, without retries. The
`workflow-lint` job runs `actionlint` (which also passes every `run:` script through the
runner's `shellcheck`) on the workflows and `shellcheck` on `.github/scripts/*.sh`.

**Pins.** Every `uses:` names a commit SHA with the version in a trailing comment (no
`@v<n>`: a moving tag could change CI without a commit here), one SHA per action across
`tests.yml` and `release.yml`; `actionlint` is a pinned release whose tarball is checked
against its SHA-256. Pins do not move by themselves, which is the point and the price:
refresh them in a pull request of their own, now and then and whenever an upstream fix
is needed. To refresh one, resolve the upstream tag itself, never a SHA from memory or a
third-party list, and check that the tag names a commit (no `^{}` line, or take the
`^{}` one):

```bash
git ls-remote https://github.com/actions/checkout 'refs/tags/v5.0.0*'
git ls-remote https://github.com/ruby/setup-ruby 'refs/tags/v1.335.0*'
git ls-remote https://github.com/discourse/.github 'refs/tags/v1*'
```

and for `actionlint`, take `ACTIONLINT_SHA256` from the release's
`actionlint_<version>_checksums.txt` (line `…_linux_amd64.tar.gz`) and compare it with
`sha256sum` of the downloaded tarball. Discourse's reusable workflow follows core, so a
weekly run that fails in the `discourse` job after a core change may need its pin moved
to the current `v1` first.

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
  `min`/`max`, and descriptions via `site_settings.<name>` with `%{base_path}`; `min` is
  checked only when a value is written (`SiteSettings::TypeSupervisor#to_db_value`), a
  stored value is read back as it is (`to_rb_value`);
- the engine and routes pattern, and the `Jobs` inflection of `app/jobs/regular` and
  `app/jobs/scheduled` (`config/initializers/000-zeitwerk.rb`);
- `NewPostManager.add_handler(priority)`, `manager.enqueue(reason)`,
  `NewPostManager.post_needs_approval?`, `NewPostManager.default_handler`; handlers run
  before Discourse's own check for personal messages, which is why the handler skips
  them itself;
- `ReviewableQueuedPost`: `perform(user, :approve_post / :reject_post)` (`approve_post`
  is offered only while the topic is open, hence `topic_closed`, and creates the post from
  the object's in-memory `payload` through `create_options`), `update_fields` with a
  `payload` hash and its history entry (it assigns the payload, then returns `save`),
  `payload["raw"]` and `payload["title"]`,
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
- the reusable CI workflow `discourse/.github/.github/workflows/discourse-plugin.yml`
  (tag `v1`, pinned by its commit) and its inputs `name` and `skip_linting`.

Not verified (no Discourse checkout here; only CI runs the Discourse tier):

- that the Discourse-tier specs added after the first CI run pass as written.
  `text_reader_view_spec.rb` ran against `PrettyText.cook` in CI (runs 40664872308 and
  40673051491): every entry passed but one, which showed that Discourse keeps `title` on
  `span` (the chat plugin's allow list); `span` is now a tooltip tag. Run 40696799542
  passed all 99 entries of that time; the 9 added after it (definitions ended by the
  block on their next line) have not run there yet;
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
- The reduction of `tekst` models markdown-it and Discourse's BBCode rules; it is not
  their renderer. It was checked against them (markdown-it 15 with Discourse's
  `bbcode-block.js` and `bbcode-inline.js`, the reader's words taken from an HTML5 tree,
  a tooltip apart from the words it sits in) on 118 000 random posts of the review's
  generators (link references among them): 18 posts lose a word, all of the first limit
  below. The limits, each with
  its direction ("more": the gateway gets markup or words a reader does not see, never
  a word less; "less": a word a reader sees may reach the gateway split or not at all):
  - **less**: an attribute left open at the end of an HTML block (`<span title="a` with
    its closing quote on the next line) runs on, in the browser, into the following
    blocks, and that tooltip may show text the reduction removes (a comment's, a
    tag's). 18 of 118 000 fuzz posts, 14 of them from the generator of multi-line
    titles;
  - **less**: emphasis markers are paired left to right among the markers that can
    open and close, not by markdown-it's whole balancing (its rule of three, nesting),
    so a marker may be kept or removed inside a word where the reader sees the
    opposite. No fuzz post found it;
  - **less**, tooltips only: a third-party plugin that allows `title` on another tag
    needs that tag in `Text::TOOLTIP_TAGS`;
  - **more**: a reference definition whose address is not valid, a link or an image to
    a label defined only that way (a link's words then reach the gateway joined, as
    the link shows them, never split), and a definition's lines themselves are sent as
    written.
