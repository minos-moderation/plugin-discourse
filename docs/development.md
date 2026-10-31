# Developing the Minos plugin for Discourse

The administrator's manual is `README.md` (Polish). This page is for whoever changes the
plugin. The gateway's contract, from the client's side, is `docs/contract.md` in
`minos-moderation/client-php`; its receiving checklist is binding here.

## Layout

| Path | What |
|---|---|
| `plugin.rb` | Metadata, `enabled_site_setting :minos_enabled`, the `NewPostManager` handler, the problem check, the report |
| `config/settings.yml` | The thirteen settings, all under `plugins:` |
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
| `spec/fixtures/no_text.json` | Posts with no text of their own (nothing sent) and controls with text (shared rule F7; both tiers) |
| `lib/minos_moderation/html_entities.json` | HTML's named character references, the data `Text` decodes them with |
| `.github/workflows/release.yml` | On a `v*` tag: checks `plugin.rb`'s version against the tag (`.github/scripts/check-release-version.sh`) and creates the GitHub Release |

The standalone files (`signature.rb`, `webhook_payload.rb`, `scores.rb`, `text.rb`,
`decision.rb`, `gateway_client.rb`, `metrics.rb`) use plain Ruby and its standard library,
so every rule that decides what is sent and what happens to a post is proven without
Discourse. Every Discourse touch point sits in a thin class (`settings.rb`, `store.rb`,
`new_post_handler.rb`, `submission.rb`, `receiver.rb`, `verdict_applier.rb`, `sweep.rb`,
`minos_gateway_problem.rb`, `verdict_report.rb`).

## The administrator's report

`plugin.rb` registers the report `minos_moderation` with `add_report` (Admin → Reports,
"Minos — czas do werdyktu i werdykty"; staff only, listed while the plugin is enabled).
`VerdictReport.fill` reads every entry and `Metrics.summary` computes, for the last seven
days: the median (P50) and 95th percentile (P95, both nearest rank) of the seconds from
the gateway's `202` (`submitted_at`, noted also when the verdict came first) to the
verdict's delivery (`received_at`; a verdict that came before the `202` was noted counts
as 0), how many posts were measured, one count per verdict value (`bezpieczne`,
`ocenzurowane`, `zablokowane`, `nieocenione`, an unknown one as `nieocenione`) and the
posts that finished without a verdict (the failure mode; not those a person handled
first). Nothing new is stored and no request is made: the entries already keep the times
and the verdict without its masked text, for 30 days. A table without dates
(`dates_filtering = false`); its texts are `reports.minos_moderation.*` in the locales.

## A post's way through the plugin

1. `NewPostHandler` (priority -100, after other plugins' handlers) holds the post with
   `manager.enqueue(:minos_pending)`, or lets `NewPostManager.default_handler` hold it when
   Discourse would hold it anyway (then `core_hold` is recorded and the verdict is only a
   note). It skips a disabled plugin, staff (`minos_skip_staff`), bots, personal
   messages and a post outside the administrator's scope (`Decision.in_scope?` over
   `minos_categories`, a category or one above it; `minos_exempt_groups`;
   `minos_max_trust_level`): such a post is Discourse's alone, published or held by its
   rules, with no entry, no request and no verdict. Whatever cannot be told (an unknown
   category, a setting that does not read as ids, a list whose categories were all
   deleted) keeps the post in scope; nothing about the scope is sent. `Submission.enqueue` creates the entry and enqueues `Jobs::MinosSubmit`.
2. `Submission#run` claims the entry (`queued` → `sending`) under `Store.lock` and numbers
   the attempt, reduces the post with `Text.for_submission` (title, blank line, the text
   a reader sees — see "What `tekst` is" below — first 3000 characters), stores the
   digest, builds the body with `Scores.request_body` (item id
   `discourse:<reviewable id>.<attempt>`, `links`, `author_first_post`, and
   `link_domains` from `Text.link_hosts` reduced with `PublicSuffix.domain`) and POSTs it
   with `GatewayClient` over `FinalDestination::HTTP`. `Scores.classify` reads the answer
   (shared plugin rules F5a, F5b): only `202` accepts, → `submitted`;
   `429`/`5xx`/`408`/any other `2xx`/no answer → `queued` again with `retry_at`
   (`ponow_za_s`, or 60 s doubling to 15 minutes) and an `enqueue_in`, unless the
   gateway's `ponow_za_s`, uncapped, ends after the post's time-out
   (`Decision.refusal_outlasts_timeout?`, F5c): then the failure mode at once, reason
   `limit`; any other status (another `4xx`, a redirect) → a configuration problem for the
   dashboard and the failure mode. Every answer to be retried also records the shared
   pause `Store.pause` (`Decision.pause_until`: now plus the uncapped `ponow_za_s`, or the
   refused post's own delay; at most a day), and a never-shortened one: while it is in
   force `Submission#run` sends nothing, but moves a due post to its end
   (`retry_at` and an `enqueue_in`), or gives it the failure mode at once (reason `limit`)
   when the gateway's `ponow_za_s` ends after the post's time-out. A full queue or a spent
   limit thus costs one refused request, not one per post. A `429`
   `limit_dobowy_klucza`, `limit_globalny_b2b` or `kolejka_pelna` (`Scores::LIMITS`)
   also records `Store.limit` — the state and the time until which the gateway refuses,
   from the uncapped `ponow_za_s` — which the dashboard shows until that time or the next
   `202`. The next `202` clears the pause too, and a change of `minos_api_key` or
   `minos_gateway_url` clears both (`Store.forget_refusals`, from `on(:site_setting_changed)`
   in `plugin.rb`): they came for the old key or address.
3. The webhook verifies and parses the delivery; `Receiver` moves a waiting entry to
   `received` with the verdict and enqueues `Jobs::MinosApplyVerdict`. A post the
   failure mode held after its time-out (`done`, `leave`, `timeout`:
   `Decision.held_after_timeout?`) still waits while its review item is pending (shared
   plugin rule A6): the late verdict is applied as if it had come in time (an edit in the
   queue since then only notes it, `edited`); once a moderator approved or rejected the
   post, the verdict is dropped with a 200 and the entry stays as it was. The current
   attempt's id is taken, and an earlier attempt's when its stored digest equals the
   current attempt's (`digests`, `Decision.verdict_for_entry?`: the same text was
   assessed); a repeat, any later verdict for the same post, an earlier attempt of another
   text (or of an entry written before per-attempt digests) and a foreign id are dropped
   with a 200. Only a stored verdict gets a `2xx` (the gateway takes any `2xx` as
   delivered and keeps no copy): a disabled plugin answers 404 (`requires_plugin`), and a
   read-only forum (`Discourse.enable_readonly_mode`, a read-only database) answers 503
   before the action runs (`ApplicationController#block_if_readonly_mode` raises
   `Discourse::ReadOnly` for every request but `GET` and `HEAD`). The gateway retries a
   failed delivery with a growing backoff for about 12.5 minutes after it accepted the
   post; a read-only spell longer than that loses the verdict, and the post waits for
   `minos_timeout_minutes` and the failure mode.
4. `VerdictApplier#apply_verdict` asks `Decision.for_verdict` what to do and does it
   through the reviewable: `perform(system user, :approve_post)`, `update_fields` of the
   queued `raw`, a `reload` that must read the masks back exactly, followed by
   `:approve_post`, `:reject_post`, or nothing. A plugin never changes a title (shared
   plugin rule S5): a mask on a new topic's title leaves the post to the moderators
   (`title_masked`), and on a late verdict it is handled like a mask that cannot be
   carried out (the post hidden, or kept and flagged with `wsparcie`). A `ReviewableNote`
   records the outcome; when an `ocenzurowane` verdict's masks did not reach the post
   (left by `minos_censored_action`, a cut text, masks that do not map or fall on the
   title, a failed edit, or a published post hidden instead; never when the post was
   edited since it was sent or a person acted on it: the masks are of an older text), a second note shows the gateway's masked text (shared
   plugin rule A2d): `@` made inert with U+2060, control characters removed, cut to
   `ReviewableNote::MAX_CONTENT_LENGTH` with an ellipsis; Discourse escapes a note's HTML
   when it renders it (`PlaintextMentions#render`). The entry ends `done`.
5. The failure mode (`Decision.for_failure`) never publishes a post Discourse held itself
   or a moderator edited. When it publishes one (fail-open), the entry ends
   `auto_published` with the post's id, and a verdict that still arrives goes through
   `Decision.for_late_verdict`: `keep`, `mask` (`PostRevisor#revise!` as the system user,
   a hidden revision: the original is for staff only)
   or `hide` (`Post#hide!`) — unless a person acted on the post since (deleted, hid,
   edited it, or reviewed a flag on it), whose decision stays. A verdict with `wsparcie`
   never hides the post (nor does a mask that cannot be carried out): it is kept, with
   the support note, because `Post#hide!` is a sanction and messages the author.
   `wsparcie` is an active signal for the moderators whatever the verdict (shared plugin
   rule A7): a post still held is in their review queue already, with the note; a post
   that is published — on time (`approve`, `approve_masked`), late (`keep`, `mask`) or
   kept when a verdict could not be applied — gets a `notify_moderators` flag by the system
   user (`PostActionCreator.create`, a Polish message naming no content), a pending
   `ReviewableFlaggedPost` in the same queue. Discourse sends the flag's message to the
   moderators' group; nothing reaches the author. A post already deleted or hidden gets
   no flag.
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
- **A post with no text of its own sends nothing** (shared plugin rule F7,
  `Text.own_text?`): the same analysis is run through `Text::OWN_MARKUP`, `MARKUP`
  without what is not the post's own text — images (Markdown, `<img>`, `[img]`, uploads,
  videos and audio, alt texts and titles included), attachments
  (`[name|attachment](upload://…) (12.3 KB)`), links with no text (`[](…)`), a link's
  address, title and label, tooltips. When nothing of that is left but `Text::NOT_TEXT`
  (format and control characters such as U+200B, U+00AD, U+2060, U+FEFF; separators and
  white space; lone combining marks such as U+034F or U+FE0F; the Hangul and Braille
  fillers; anything invisible by default), the sent text is empty, title included, and
  `Submission` applies the failure mode (`no_text`) without a request. A bare address
  the reader sees (linkify, an autolink, `[url]…[/url]`) is text. An alt text or a title
  is still sent next to the post's own words (S1), and what is sent for a post with
  text does not change. When the check raises (`RegexpError`), the post counts as text:
  more is sent, never less. When the extraction itself raises anything else, the text is
  not an empty one: `Submission#extract` logs the error's class (never its message) and
  applies the failure mode at once (`extraction_failed`), with no request. `spec/fixtures/no_text.json` holds the cases, the S8a
  review's nine probes among them; both tiers read it, the Discourse one against
  `PrettyText.cook`.

`spec/fixtures/reader_view.json` is the corpus: `spec/lib/text_spec.rb` checks the sent
text of each entry and the property "every word a reader sees is a word of the sent
text" (whole words: a split word fails it) against the reader's view as Discourse's
source describes it; `spec/integration/text_reader_view_spec.rb` checks the same
property against Discourse's own `PrettyText.cook` in CI. A change of this reduction changes the digest of
a post in flight at the upgrade: its verdict is then not applied (`edited`) and a
moderator decides, the safe direction.

State lives in `PluginStore` (`minos-moderation`, key `pending:<reviewable id>`, plus
`problem`, `limit` and `pause`); see `Store` for the fields. An entry is removed 30 days
after it finished (shared plugin rule A8). It never holds the unmasked text of a masked
post (a digest at most): the reviewable's history (a post masked in the queue) and a
hidden revision of the post (a post masked after a fail-open publication,
`PostRevisor#revise!(…, hidden: true)`) keep it where only staff can see it, also on a
forum with `edit_history_visible_to_public`. Those, the plugin's notes on the review item
and the support flag are Discourse's own records: they follow the forum's retention,
not the plugin's 30 days, and the README names them. Every read-modify-write of an entry runs under a
`DistributedMutex` per reviewable, so the job, the webhook and the sweeper never apply
two outcomes to one post.

## Shared plugin rules: compliance

The rules every Minos plugin shares are `docs/plugin-behaviour.md` in
`minos-moderation/client-php` (shared plugin rule D1); this plugin follows the version at
the commit CI checks out (`.github/workflows/tests.yml`, e5df7d6, v0.2.0). A change to one
rule is a decision for every plugin, made there first. The table maps each identifier, with
its short name copied from the file's index, to the code and the test that implement it
here, or to `odstępstwo: …` (a deviation) with the issue that closes it.
`spec/lib/compliance_table_spec.rb` reads the file from `MINOS_CLIENT_PHP` and fails when an
identifier is missing here (in CI a missing checkout fails too, as for the mock gateway).
Starting point: the audit's matrix of 2026-10-27, checked again against the code after S8a
and S8b.

| Id | In short (client-php's index) | Discourse: code and test, or deviation |
|---|---|---|
| `F1` | fail-closed by default | `config/settings.yml` (`fail-closed`), `Decision.fail_open?` (anything else is closed); `spec/lib/decision_spec.rb` "never publishes a post without a known verdict unless fail-open is chosen exactly" |
| `F2` | a time-out of at least 20 minutes | `Decision::MIN_TIMEOUT_MINUTES`, `Decision.timeout_s`, `min: 20`; `spec/repo/settings_yml_spec.rb`, `spec/jobs/minos_sweeper_spec.rb` "waits twenty minutes even when a lower timeout was stored" |
| `F3` | switched off: 404, and nothing happens | `requires_plugin` (404), `Submission#run`, `Jobs::MinosSweeper`, `Jobs::MinosApplyVerdict` return while disabled; `spec/requests/webhooks_controller_spec.rb` "does not answer while the plugin is disabled", `spec/jobs/minos_sweeper_spec.rb` "does nothing while the plugin is disabled" |
| `F4` | 401 without a usable secret | `WebhooksController#receive`; `spec/requests/webhooks_controller_spec.rb` "is refused while no webhook secret is set" |
| `F5a` | retry 429, 5xx, 408, network failures and a 2xx that accepts nothing; only `202` accepts | `Scores.classify`, `Scores.classify_transport`, the shared pause (`Store.pause`, `Decision.pause_until`, `Submission#defer`); `spec/lib/scores_spec.rb` "reads every status by the rule", `spec/jobs/minos_submit_spec.rb` "the pause every post shares after a refusal" |
| `F5b` | any other 4xx is a configuration error | `Scores.classify`, `Submission#refused` (`Store.record_problem`, the dashboard, the failure mode `config`); `spec/jobs/minos_submit_spec.rb` "a configuration error" |
| `F5c` | a `ponow_za_s` past the time-out: the failure mode at once | `Decision.refusal_outlasts_timeout?` with the uncapped `ponow_za_s`, `Submission#retry_later`, `#defer`; `spec/lib/decision_spec.rb` "gives the failure mode at once to a refusal that ends after the post's time-out", `spec/jobs/minos_submit_spec.rb` "a daily limit that ends after the post's time-out" |
| `F5d` | optional: re-send what fail-open published unassessed once the limit renews | odstępstwo: not implemented (optional and off by default; outside minos-moderation/minos#71, no issue yet) |
| `F6` | a failing row never stops a loop | `Sweep.run` (a `rescue` per entry, logged by step, reviewable and exception class); odstępstwo: no test of a failing entry yet (no issue) |
| `F7` | no text to assess (a title alone, only an image, a video, an attachment or a link without a label, an image's `alt` notwithstanding), or a failed extraction: the failure mode; a bare URL the reader sees is text | `Text.own_text?`, `Text::OWN_MARKUP`, `Text::NOT_TEXT`, `Submission#run` (`no_text`); `spec/lib/text_spec.rb` "a post with no text of its own", `spec/fixtures/no_text.json`, `spec/lib/mock_gateway_spec.rb`, `spec/integration/text_reader_view_spec.rb`; a failed extraction (any exception) → `Submission#extract`, the failure mode at once (`extraction_failed`), the error's class alone in the log; `spec/jobs/minos_submit_spec.rb` "applies the failure mode at once when the text cannot be read" |
| `F8` | switched on without a usable configuration: the failure mode; a fresh install is off | `minos_enabled` off by default; no key, no webhook secret or an unusable address → `Submission#run` applies `config` at once, without a request; `MinosGatewayProblem` on the dashboard; `spec/jobs/minos_submit_spec.rb` "applies the failure mode at once when the key is missing", "… when the webhook secret is missing". Odstępstwo: the notice is on the admin dashboard, not on every admin page (issue: w rejestracji) |
| `F9` | switched on again: what waited is re-sent with a fresh time-out | odstępstwo: not implemented — switched on again, the sweeper gives every entry past its time-out the failure mode (no issue) |
| `S1` | `tekst` is what the reader sees, `title`/`alt` included; nothing hidden is added | `Text.for_submission` ("What `tekst` is" above); `spec/fixtures/reader_view.json` in `spec/lib/text_spec.rb` and `spec/integration/text_reader_view_spec.rb` (`PrettyText.cook`) |
| `S2` | links, domains, first post; never account data | `Scores.request_body` (`META_KEYS`), `Submission#link_domains`; `spec/lib/scores_spec.rb` "never carries an author's e-mail, IP address or id", `spec/jobs/minos_submit_spec.rb` "sends the text, the profile and two signals with the key, and nothing about the author" |
| `S3` | an edit of a waiting post is `<id>.<n>`; an older revision's verdict is ignored | `Scores.item_id` (`discourse:<review item>.<attempt>`: the post does not exist while it waits), `Decision.verdict_for_entry?`, `VerdictApplier#changed_since_sent?`; `spec/requests/webhooks_controller_spec.rb` "drops a verdict for an earlier attempt". Odstępstwo: an edit in the queue (only staff can make one) is not sent again: the verdict is not applied (`edited`) and a moderator decides (by the platform; no issue) |
| `S4a` | above 3000 characters: the beginning is assessed, the decision is `nieocenione` | `Text::MAX_CHARS`, `Decision.for_verdict` (`truncated`); `spec/lib/decision_spec.rb` "a post only partly sent" |
| `S4b` | the note about a cut post | `minos_moderation.reasons.truncated` ("wpis dłuższy niż 3000 znaków — oceniono początek", the rule's wording) in the note; `spec/repo/locales_spec.rb` "gives the note about a cut post the shared wording" |
| `S4c` | `ocenzurowane` on a cut post is never applied automatically | `Decision.censored`, `Decision.late` (`truncated`); `spec/lib/decision_spec.rb` "leaves a censored head to the moderators under both modes" |
| `S5` | a topic's title (a visible reply subject, a poll) is part of `tekst`; a title is never changed | `Text.submission` (title, blank line; a reply has no subject; a `[poll]` is in `raw`); `spec/lib/text_spec.rb` "a new topic's title"; a mask on the title holds the post (`VerdictApplier#title_masked?` in `#approve_masked` and `#mask`, reason `title_masked`); `spec/jobs/minos_apply_verdict_spec.rb` "on a new topic (shared plugin rule S5: a title is never changed)" |
| `S6` | an edit of a published post is reassessed (after the capacity decision) | odstępstwo: not implemented, as the rule allows until the gateway's capacity decision (K-38, K-44) |
| `S7` | a post the platform holds is sent and annotated (after the capacity decision) | `NewPostHandler.call` (`core_hold`), `Decision.for_verdict` (`core_hold`: a note, never published); `spec/integration/new_post_handler_spec.rb` "lets Discourse hold a post it holds itself", `spec/jobs/minos_apply_verdict_spec.rb` "only notes the verdict on a post Discourse holds itself" |
| `A1` | the digest of the sent text is checked before applying | `Submission#run` (`text_digest`, `digests`), `VerdictApplier#changed_since_sent?`, `#acted_on?` (`TextCleaner` normalisation); `spec/jobs/minos_apply_verdict_spec.rb` "leaves a post edited in the queue after it was sent", "still hides a post Discourse normalised on publication" |
| `A2a` | a mask has the sent length and differs only in `█` | `Text.apply_masks`; `spec/lib/text_spec.rb` (masks), `spec/lib/mock_gateway_spec.rb` |
| `A2b` | what was sent is what is stored | `Text.apply_masks` (the post must still reduce to the sent text); `spec/lib/text_spec.rb` |
| `A2c` | the write is checked and read back | `VerdictApplier#stored?` (`reload`); `spec/jobs/minos_apply_verdict_spec.rb` "never approves when the masked text did not persist" |
| `A2d` | the mask is shown to the moderator | `VerdictApplier#mask_note`; `spec/jobs/minos_apply_verdict_spec.rb` "the gateway's masks shown to the moderators" |
| `A2e` | never the original instead of a failed mask | `VerdictApplier#approve_masked` (`mask_unmappable`, `action_failed` leave the post); `spec/jobs/minos_apply_verdict_spec.rb` "leaves the post when the masks cannot be carried onto it" |
| `A3` | fail-open is marked; a late verdict applies | `auto_published`, `VerdictApplier#apply_late`, `Decision.for_late_verdict`; `spec/jobs/minos_apply_verdict_spec.rb` "a late verdict for a post the failure mode published" |
| `A4` | notifications once, sent by the plugin where approval sends none | `perform(:approve_post)` sends Discourse's own notifications; a late verdict publishes nothing again. Not verified: the "edited" notification a late mask sends the author through `PostRevisor` |
| `A5` | a hold is the platform's own state | `ReviewableQueuedPost` (`NewPostManager#enqueue`); `spec/integration/new_post_handler_spec.rb` "holds a new reply as a queued post" |
| `A6` | a late verdict also applies to a post the failure mode held | `Decision.held_after_timeout?`, `Receiver.accept`; `spec/jobs/minos_apply_verdict_spec.rb` "a verdict for a post the failure mode held after its time-out", `spec/requests/webhooks_controller_spec.rb` |
| `A7` | `wsparcie` is an active signal for moderators, never an automatic removal | `VerdictApplier#signal_support` (a `notify_moderators` flag), `Decision` (never `reject` or `hide` with `wsparcie`); `spec/jobs/minos_apply_verdict_spec.rb` "wsparcie on a published post", `spec/lib/decision_spec.rb` "wsparcie over every combination" |
| `A8` | the plugin's own data (the original, the verdicts) is kept 30 days; the platform's records follow the forum's rules | `Decision::PURGE_AFTER_S`, `Sweep` (`purge`); the original only in Discourse's records, for staff (`PostRevisor#revise!(…, hidden: true)`); README "Co wtyczka przechowuje i jak długo"; `spec/jobs/minos_sweeper_spec.rb` "forgets a finished entry after thirty days", `spec/jobs/minos_apply_verdict_spec.rb` "keeps the original in a revision staff can see and readers cannot" |
| `P1` | the archive carries no lock file, tests or mock, and pins the client | n/d: Discourse installs the plugin from its git repository, with no archive, and the plugin runs no client-php code |
| `D1` | this file is the one source; `CLAUDE.md` points at it, `docs/development.md` maps it | `CLAUDE.md` (one line), this table; `spec/lib/compliance_table_spec.rb` |
| `D2` | shared compliance scenarios in `scenarios/` | odstępstwo: client-php has no scenarios yet (minos-moderation/minos#44, step 5) |

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

Without `MINOS_CLIENT_PHP` that group is skipped, and so is
`spec/lib/compliance_table_spec.rb`, which reads client-php's `docs/plugin-behaviour.md`
from the same checkout (see "Shared plugin rules: compliance"). CI's `standalone` job
checks client-php out at a pinned commit of its main (`.github/workflows/tests.yml`,
e5df7d6 at present), runs `composer install --no-dev` there, sets `MINOS_REQUIRE_MOCK_GATEWAY=1`, which turns
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

The repository is public, so a forum clones it without credentials. Until the first tag
(`v0.1.0`, which the owner creates) the README installs from `main` and says that this is
an interim state; once the tag exists, the install line names it
(`git clone --branch v0.1.0 …`), so a forum takes nothing its administrator did not
choose.

Nothing in this repository enforces that only the owner tags (the session refusal lives
outside GitHub): the owner should add a tag ruleset on `v*` that only they may bypass, or
a `release` environment with a required reviewer on the `publish` job.

## Discourse APIs

Verified in Discourse's source (`main`, September 2026) or in
`discourse-plugin-skeleton`:

- plugin metadata comments, `enabled_site_setting`, `after_initialize`,
  `on(:site_setting_changed)` (`Plugin::Instance#on`, called only while the plugin is
  enabled; the event is triggered by every site setting change, with its name),
  `register_problem_check` (`lib/plugin/instance.rb`, `lib/plugin/metadata.rb`);
- `config/settings.yml` keys `default`, `secret: true`, `type: enum` + `choices`,
  `min`/`max`, and descriptions via `site_settings.<name>` with `%{base_path}`; `min` is
  checked only when a value is written (`SiteSettings::TypeSupervisor#to_db_value`), a
  stored value is read back as it is (`to_rb_value`); `type: category_list` and
  `type: group_list` (ids joined by "|", no check that they exist) and
  `enum: "TrustLevelSetting"` (0–4), as core's `config/site_settings.yml` uses them;
  `Group::AUTO_GROUPS` (`everyone` 0, `logged_in_users` 5), `User#group_ids`,
  `Category#parent_category`, and the `topic_id` / `category` arguments of
  `NewPostManager` (`post_needs_approval_in_its_category?`) (`main`, 2026-10-28);
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
  `pending?`, `reviewable_notes` / `ReviewableNote::MAX_CONTENT_LENGTH` (2000); a note's
  content is plain text, rendered by `PlaintextMentions#render` (HTML-escaped, `@name`
  linked and notified when preceded by a space, punctuation or a symbol) (`main`,
  2026-10-28);
- the score reason text `reviewables.reasons.<reason>` (`ReviewableScoreSerializer`);
- `ProblemCheck` (realtime when `perform_every` is unset; `problem`, `no_problem`,
  `translation_data`, the key `dashboard.problem.<identifier>`);
- `add_report(name) { |report| … }` (`Report.add_report` defines `report_<name>`),
  `Report::MODES[:table]`, `report.modes`, `report.dates_filtering`, `report.labels`
  (`property`, `title`), `report.data`, the texts `reports.<name>.title` and
  `.description`, `GET /admin/reports/<name>.json` (`Admin::StaffController`) and the
  list `Reports::ListQuery`, which shows a plugin's report while the plugin is enabled
  (`main`, 2026-10-28);
- `PluginStore.get/set/remove/cast_value`, `PluginStoreRow`, `DistributedMutex.synchronize`;
- `Jobs::Base` (`sidekiq_options`), `Jobs::Scheduled` + `every`, `Jobs.enqueue`,
  `Jobs.enqueue_in`;
- `FinalDestination::HTTP` (Net::HTTP with SSRF checks and pinned addresses);
- `PostActionCreator.create(user, post, :notify_moderators, message:)` (a
  `ReviewableFlaggedPost.needs_review!` item and a message to the `moderators` group from
  the flagger, never to the author; the system user may flag, `User#in_any_groups?`
  treats it as staff; a hidden post cannot be flagged), `PostActionType.types`
  (`main`, 2026-10-28);
- `Post#hide!(post_action_type_id)` with `PostActionType.types[:inappropriate]` (it
  also messages the author and hides a first post's topic), `Post.with_deleted`,
  `Post#version`, `PostRevisor#revise!(editor, fields, skip_validations:, bypass_bump:,
  bypass_rate_limiter:)` with an `edit_reason`, `ReviewableFlaggedPost` statuses;
- `PostRevisor#revise!(…, hidden: true)` ("Force the created revision to be hidden from
  non-staff users": `PostRevision#hidden`, `public_version` not raised),
  `PostRevision#hide!`, `PostRevisionGuardian#can_see_post_revision?` (a hidden revision
  only for `can_view_hidden_post_revisions?`, i.e. staff, before
  `edit_history_visible_to_public` is read), `PostRevisionSerializer` leaving hidden
  revisions out for non-staff, `PostsController#latest_revision` (`main`, 2026-10-28);
- the per-IP limits `max_reqs_per_ip_per_10_seconds` (50), `max_reqs_per_ip_per_minute`
  (200) and `max_reqs_per_ip_mode` (`block`) in `config/discourse_defaults.conf`;
- `public_suffix` in Discourse's `Gemfile.lock` (through `addressable`);
- `ApplicationController` filters `verify_authenticity_token`, `check_xhr`,
  `redirect_to_login_if_required`, `preload_json`, and `requires_plugin` (a disabled
  plugin raises `PluginDisabled`, answered 404); `block_if_readonly_mode`
  (`ReadOnlyMixin`: every request but `GET`/`HEAD` raises `Discourse::ReadOnly` while
  `Discourse.readonly_mode?`, answered 503) and `Discourse.enable_readonly_mode` /
  `disable_readonly_mode` (`main`, 2026-10-28);
- spec helpers `fab!`, `expect_enqueued_with`, `track_log_messages`, the
  `reviewable_queued_post` and `reviewable_queued_post_topic` fabricators, WebMock with
  `allow_localhost`;
- the reusable CI workflow `discourse/.github/.github/workflows/discourse-plugin.yml`
  (tag `v1`, pinned by its commit) and its inputs `name` and `skip_linting`.

Not verified (no Discourse checkout here; only CI runs the Discourse tier):

- that the Discourse-tier specs added after the first CI run pass as written.
  `text_reader_view_spec.rb` ran against `PrettyText.cook` in CI (runs 40664872308 and
  40673051491): every entry passed but one, which showed that Discourse keeps `title` on
  `span` (the chat plugin's allow list); `span` is now a tooltip tag. Run 40699706658
  passed all 108 entries of that time. The 9 added in S8b (a definition's next line that
  is a thematic break, an empty heading, an HTML block, a quote block or a details tag;
  an address indented four columns; a next line in a deeper blockquote; a label without
  an address continued as a paragraph; a label alone at the end), one for each branch of
  `Text.definition_end?` and of the label's handling that no entry guarded, and the
  `spec/fixtures/no_text.json` checks (F7) have not run there yet; their "reader" fields
  come from markdown-it 15 with Discourse's `bbcode-block.js`;
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
