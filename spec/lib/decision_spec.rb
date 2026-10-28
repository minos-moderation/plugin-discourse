# frozen_string_literal: true

require_relative "../../lib/minos_moderation/decision" unless defined?(MinosModeration::Decision)

# What happens to a held post under every setting, and what a pending entry needs. The
# rules the contract makes binding: `bezpieczne` publishes, `ocenzurowane` publishes the
# masked text or holds, `zablokowane` holds or rejects as configured, `nieocenione` goes to
# the failure mode, `wsparcie` asks for support whatever the verdict — and nothing unknown
# ever publishes.
RSpec.describe "MinosModeration::Decision" do
  subject(:decision) { MinosModeration::Decision }

  let(:defaults) do
    {
      "failure_mode" => "fail-closed",
      "censored_action" => "publikuj_ocenzurowany",
      "blocked_action" => "zostaw_moderatorom",
    }
  end

  def verdict(qualification, extra = {})
    {
      "id" => "discourse:1",
      "status" => "ocenione",
      "kwalifikacja" => qualification,
      "kategorie" => [],
      "ocenzurowany" => nil,
      "wsparcie" => false,
      "wersja" => nil,
    }.merge(extra)
  end

  def unassessed
    { "id" => "discourse:1", "status" => "nieocenione", "kwalifikacja" => nil }
  end

  def decide(value, with: {}, **flags)
    decision.for_verdict(value, defaults.merge(with), **flags)
  end

  it "publishes bezpieczne" do
    result = decide(verdict("bezpieczne"))
    expect([result.action, result.reason, result.unassessed]).to eq([:approve, :verdict, false])
  end

  describe "ocenzurowane" do
    let(:censored) { verdict("ocenzurowane", "ocenzurowany" => "to jest █████") }

    it "publishes the masked text by default" do
      expect(decide(censored).action).to eq(:approve_masked)
    end

    it "leaves the post when the administrator chose so" do
      result = decide(censored, with: { "censored_action" => "zostaw_moderatorom" })
      expect([result.action, result.reason]).to eq(%i[leave censored_setting])
    end

    it "leaves the post when the masked text is missing, as the contract says" do
      [nil, "", 7].each do |masked|
        result = decide(verdict("ocenzurowane", "ocenzurowany" => masked))
        expect([result.action, result.reason]).to eq(%i[leave no_masked_text]), masked.inspect
      end
    end
  end

  describe "zablokowane" do
    it "leaves the post by default and rejects it when the administrator chose so" do
      expect(decide(verdict("zablokowane")).action).to eq(:leave)
      rejecting = { "blocked_action" => "odrzuc" }
      expect(decide(verdict("zablokowane"), with: rejecting).action).to eq(:reject)
    end

    it "never rejects a post that reads as self-harm: a person decides" do
      rejecting = { "blocked_action" => "odrzuc" }
      result = decide(verdict("zablokowane", "wsparcie" => true), with: rejecting)
      expect([result.action, result.reason, result.support]).to eq([:leave, :support, true])
    end
  end

  describe "without a verdict" do
    it "follows the failure mode for nieocenione" do
      expect(decide(unassessed).action).to eq(:leave)
      result = decide(unassessed, with: { "failure_mode" => "fail-open" })
      expect([result.action, result.reason, result.unassessed]).to eq([:approve, :unassessed, true])
    end

    it "follows the failure mode for a timeout, a configuration error and an empty post" do
      %i[timeout config no_text].each do |reason|
        closed = decision.for_failure(defaults, reason)
        open = decision.for_failure(defaults.merge("failure_mode" => "fail-open"), reason)
        expect([closed.action, closed.reason]).to eq([:leave, reason])
        expect([open.action, open.reason, open.unassessed]).to eq([:approve, reason, true])
      end
    end

    it "never publishes a post Discourse holds itself, or a moderator edited, even fail-open" do
      open_mode = defaults.merge("failure_mode" => "fail-open")
      %i[timeout config no_text unassessed].each do |reason|
        held = decision.for_failure(open_mode, reason, core_hold: true)
        expect([held.action, held.reason]).to eq(%i[leave core_hold]), reason.to_s
        edited = decision.for_failure(open_mode, reason, edited: true)
        expect([edited.action, edited.reason]).to eq(%i[leave edited]), reason.to_s
      end
    end

    it "reads a payload that is not one as nieocenione" do
      [nil, {}, "bezpieczne", { "status" => "ocenione", "kwalifikacja" => "inne" }].each do |value|
        expect(decide(value).action).to eq(:leave), value.inspect
      end
    end
  end

  describe "a post only partly sent" do
    it "publishes on the head's verdict only under fail-open" do
      closed = decide(verdict("bezpieczne"), truncated: true)
      expect([closed.action, closed.reason]).to eq(%i[leave truncated])
      open_mode = { "failure_mode" => "fail-open" }
      open = decide(verdict("bezpieczne"), with: open_mode, truncated: true)
      expect([open.action, open.reason, open.unassessed]).to eq([:approve, :truncated, true])
    end

    it "still rejects on a blocked head" do
      rejecting = { "blocked_action" => "odrzuc" }
      result = decide(verdict("zablokowane"), with: rejecting, truncated: true)
      expect(result.action).to eq(:reject)
    end

    it "leaves a censored head to the moderators under both modes" do
      censored = verdict("ocenzurowane", "ocenzurowany" => "█")
      %w[fail-open fail-closed].each do |mode|
        result = decide(censored, with: { "failure_mode" => mode }, truncated: true)
        expect([result.action, result.reason]).to eq(%i[leave truncated]), mode
      end
    end
  end

  describe "a verdict for a post the failure mode already published" do
    def late(value, with: {}, **flags)
      decision.for_late_verdict(value, defaults.merge(with), **flags)
    end

    let(:censored) { verdict("ocenzurowane", "ocenzurowany" => "to jest █████") }

    it "keeps a safe post, and one without a verdict" do
      expect(late(verdict("bezpieczne")).action).to eq(:keep)
      expect(late(unassessed).action).to eq(:keep)
    end

    it "hides a blocked post, whatever the blocked setting" do
      %w[zostaw_moderatorom odrzuc].each do |blocked|
        expect(late(verdict("zablokowane"), with: { "blocked_action" => blocked }).action)
          .to eq(:hide), blocked
      end
    end

    it "masks a censored post, or hides it when the setting, the text or the cut says so" do
      expect(late(censored).action).to eq(:mask)
      leaving = { "censored_action" => "zostaw_moderatorom" }
      expect(late(censored, with: leaving).reason).to eq(:censored_setting)
      expect(late(verdict("ocenzurowane")).reason).to eq(:no_masked_text)
      expect(late(censored, truncated: true).reason).to eq(:truncated)
      [late(censored, with: leaving), late(censored, truncated: true)].each do |result|
        expect(result.action).to eq(:hide)
      end
    end

    it "never hides a post that reads as self-harm, and keeps it for a person to decide" do
      support = { "wsparcie" => true }
      blocked = late(verdict("zablokowane", support))
      expect([blocked.action, blocked.reason, blocked.support]).to eq([:keep, :support, true])
      leaving = { "censored_action" => "zostaw_moderatorom" }
      [
        late(verdict("ocenzurowane", support.merge("ocenzurowany" => "█")), with: leaving),
        late(verdict("ocenzurowane", support)),
        late(verdict("ocenzurowane", support.merge("ocenzurowany" => "█")), truncated: true),
      ].each { |result| expect([result.action, result.reason]).to eq(%i[keep support]) }
      # A mask that can be carried out still is: it hides nothing.
      mappable = verdict("ocenzurowane", support.merge("ocenzurowany" => "█"))
      expect(late(mappable).action).to eq(:mask)
    end

    it "keeps whatever a person decided since" do
      [verdict("zablokowane"), censored, verdict("bezpieczne")].each do |value|
        result = late(value, acted: true)
        expect([result.action, result.reason]).to eq(%i[keep person_acted])
      end
    end

    it "never publishes, rejects or deletes anything" do
      [nil, unassessed, verdict("bezpieczne"), censored, verdict("zablokowane")].each do |value|
        [false, true].product([false, true]).each do |truncated, acted|
          result = late(value, truncated: truncated, acted: acted)
          expect(%i[keep mask hide]).to include(result.action)
          expect(decision::REASONS).to include(result.reason)
        end
      end
    end
  end

  it "leaves a post Discourse holds itself, or a moderator edited, whatever the verdict" do
    %w[bezpieczne ocenzurowane zablokowane].each do |qualification|
      value = verdict(qualification, "ocenzurowany" => "█")
      expect(decide(value, core_hold: true).reason).to eq(:core_hold)
      expect(decide(value, edited: true).reason).to eq(:edited)
      rejecting = { "blocked_action" => "odrzuc" }
      expect(decide(value, with: rejecting, core_hold: true).action).to eq(:leave)
    end
  end

  it "carries wsparcie into every decision" do
    %w[bezpieczne ocenzurowane zablokowane].each do |qualification|
      value = verdict(qualification, "wsparcie" => true, "ocenzurowany" => "█")
      expect(decide(value).support).to be(true), qualification
    end
    expect(decide(verdict("bezpieczne", "wsparcie" => "true")).support).to be(false)
  end

  describe "over every combination" do
    let(:verdicts) do
      [nil, unassessed, { "status" => "ocenione", "kwalifikacja" => "nowa" }] +
        %w[bezpieczne ocenzurowane zablokowane].flat_map do |qualification|
          [
            verdict(qualification),
            verdict(qualification, "ocenzurowany" => "█", "wsparcie" => true),
          ]
        end
    end
    let(:settings) do
      %w[fail-open fail-closed FAIL-OPEN].product(
        %w[publikuj_ocenzurowany zostaw_moderatorom nieznane],
        %w[zostaw_moderatorom odrzuc nieznane],
      )
    end

    def each_result
      count = 0
      verdicts.each do |value|
        settings.each do |failure_mode, censored_action, blocked_action|
          chosen = {
            "failure_mode" => failure_mode,
            "censored_action" => censored_action,
            "blocked_action" => blocked_action,
          }
          [false, true].product([false, true], [false, true]).each do |truncated, core, edited|
            flags = { truncated: truncated, core_hold: core, edited: edited }
            count += 1
            yield(value, chosen, flags, decision.for_verdict(value, chosen, **flags))
          end
        end
      end
      expect(count).to be > 500
    end

    it "gives only known actions and reasons" do
      each_result do |_value, _chosen, _flags, result|
        expect(decision::ACTIONS).to include(result.action)
        expect(decision::REASONS).to include(result.reason)
      end
    end

    it "never publishes a post without a known verdict unless fail-open is chosen exactly" do
      each_result do |value, chosen, _flags, result|
        known = value.is_a?(Hash) && value["status"] == "ocenione" &&
          %w[bezpieczne ocenzurowane zablokowane].include?(value["kwalifikacja"])
        next if known || chosen["failure_mode"] == "fail-open"

        expect(result.action).not_to eq(:approve), value.inspect
      end
    end

    it "never publishes a post Discourse holds itself, with or without a verdict" do
      each_result do |_value, chosen, flags, result|
        next unless flags[:core_hold]

        expect(result.action).to eq(:leave)
        %i[timeout config no_text].each do |reason|
          failure = decision.for_failure(chosen, reason, core_hold: true)
          expect(failure.action).to eq(:leave)
        end
      end
    end

    it "never publishes or rejects on an unknown setting value" do
      each_result do |value, chosen, flags, result|
        next unless value.is_a?(Hash) && value["status"] == "ocenione"

        if value["kwalifikacja"] == "ocenzurowane" && chosen["censored_action"] == "nieznane"
          expect(result.action).to eq(:leave)
        end
        if value["kwalifikacja"] == "zablokowane" && chosen["blocked_action"] == "nieznane"
          expect(result.action).to eq(:leave)
        end
        next unless flags[:truncated] && chosen["failure_mode"] != "fail-open"

        expect(%i[approve approve_masked]).not_to include(result.action)
      end
    end
  end

  describe "wsparcie over every combination" do
    let(:qualifications) { %w[bezpieczne ocenzurowane zablokowane nowa] }

    it "is never rejected or hidden, on time or late (shared plugin rule 9)" do
      visited = []
      count = 0
      statuses = %w[ocenione nieocenione inny]
      masked_texts = [nil, "", "█"]
      settings =
        %w[fail-open fail-closed nieznany].product(
          %w[publikuj_ocenzurowany zostaw_moderatorom nieznane],
          %w[zostaw_moderatorom odrzuc nieznane],
        )
      statuses.product(qualifications, masked_texts).each do |status, qualification, masked|
        value =
          verdict(qualification, "status" => status, "ocenzurowany" => masked, "wsparcie" => true)
        settings.each do |failure_mode, censored_action, blocked_action|
          chosen = {
            "failure_mode" => failure_mode,
            "censored_action" => censored_action,
            "blocked_action" => blocked_action,
          }
          [false, true].product([false, true], [false, true], [false, true]).each do |flags|
            truncated, acted, edited, core_hold = flags
            on_time =
              decision.for_verdict(
                value,
                chosen,
                truncated: truncated,
                core_hold: core_hold,
                edited: edited,
              )
            late = decision.for_late_verdict(value, chosen, truncated: truncated, acted: acted)
            [on_time, late].each do |result|
              expect(%i[reject hide]).not_to include(result.action), [value, chosen, flags].inspect
              expect(result.support).to be(true)
            end
            count += 1
          end
        end
        visited << qualification
      end
      # A loop over nothing passes silently: every qualification, the unknown one included,
      # was decided under every setting and flag.
      expect(visited.uniq).to match_array(qualifications)
      expect(count).to eq(statuses.size * qualifications.size * masked_texts.size * 27 * 16)
    end
  end

  describe "which attempt's verdict an entry takes" do
    let(:same) { "a" * 64 }
    let(:other) { "b" * 64 }

    def takes?(entry, attempt)
      decision.verdict_for_entry?(entry, attempt)
    end

    it "takes the current attempt's verdict, as before" do
      expect(takes?({ "attempt" => 2 }, 2)).to be(true)
      expect(takes?({ "attempt" => 2, "digests" => { "2" => same } }, 2)).to be(true)
    end

    it "takes an earlier attempt's verdict when that attempt sent the same text" do
      entry = { "attempt" => 3, "digests" => { "1" => same, "2" => other, "3" => same } }
      expect(takes?(entry, 1)).to be(true)
      expect(takes?(entry, 2)).to be(false)
    end

    it "takes nothing it cannot tie to the text: no digests, no current digest, a later id" do
      expect(takes?({ "attempt" => 2 }, 1)).to be(false)
      expect(takes?({ "attempt" => 2, "digests" => { "1" => same } }, 1)).to be(false)
      expect(takes?({ "attempt" => 2, "digests" => { "1" => "", "2" => "" } }, 1)).to be(false)
      expect(takes?({ "attempt" => 2, "digests" => "nie" }, 1)).to be(false)
      expect(takes?({ "attempt" => 2, "digests" => { "2" => same, "3" => same } }, 3)).to be(false)
      expect(takes?({}, 1)).to be(false)
      expect(takes?({ "attempt" => 0 }, 0)).to be(false)
    end
  end

  describe "what a pending entry needs" do
    let(:now) { 1_000_000 }
    let(:timeout) { 20 * 60 }

    def needs(entry)
      decision.for_entry(entry, now: now, timeout_s: timeout)
    end

    it "resubmits a due retry and waits for one that is not due" do
      entry = { "status" => "queued", "queued_at" => now - 60, "retry_at" => now }
      expect(needs(entry)).to eq(:resubmit)
      expect(needs(entry.merge("retry_at" => now + 1))).to be_nil
    end

    it "resubmits a send that has been in flight too long, and waits on a recent one" do
      entry = { "status" => "sending", "queued_at" => now - 300, "sending_at" => now - 121 }
      expect(needs(entry)).to eq(:resubmit)
      expect(needs(entry.merge("sending_at" => now - 30))).to be_nil
    end

    it "times out a post without a verdict after the timeout, and not before" do
      expect(needs("status" => "submitted", "submitted_at" => now - timeout - 1)).to eq(:timeout)
      expect(needs("status" => "submitted", "submitted_at" => now - timeout)).to be_nil
      stuck = { "status" => "queued", "queued_at" => now - timeout - 1, "retry_at" => now + 60 }
      expect(needs(stuck)).to eq(:timeout)
    end

    it "waits at least twenty minutes, also when a lower timeout is stored" do
      # Saved as 16 before the minimum was raised: Discourse keeps it, the floor applies.
      stored = decision.timeout_s(16)
      expect(stored).to eq(20 * 60)
      expect(decision.timeout_s("25")).to eq(25 * 60)
      accepted = { "status" => "submitted", "submitted_at" => now - (16 * 60) - 1 }
      expect(decision.for_entry(accepted, now: now, timeout_s: stored)).to be_nil
      late = accepted.merge("submitted_at" => now - (20 * 60) - 1)
      expect(decision.for_entry(late, now: now, timeout_s: stored)).to eq(:timeout)
    end

    it "gives the failure mode at once to a refusal that ends after the post's time-out" do
      # A daily limit: the gateway refuses for 36000 s, while the plugin's own pause is
      # capped at 900 s. The uncapped value decides, so the post does not wait 20 minutes
      # for a retry that can only be refused again.
      queued = { "status" => "sending", "queued_at" => now, "sending_at" => now }
      outlasts = ->(entry, seconds) do
        decision.refusal_outlasts_timeout?(entry, now: now, timeout_s: timeout, retry_in: seconds)
      end
      expect(outlasts.call(queued, 36_000)).to be(true)
      expect(outlasts.call(queued, timeout + 1)).to be(true)
      expect(outlasts.call(queued, timeout)).to be(false)
      expect(outlasts.call(queued, 30)).to be(false)
      # The time already waited counts: 19 minutes in, a 90 s refusal ends too late.
      waited = queued.merge("queued_at" => now - (19 * 60))
      expect(outlasts.call(waited, 90)).to be(true)
      expect(outlasts.call(waited, 30)).to be(false)
      # Without ponow_za_s the backoff stays, and the sweeper times the post out.
      [nil, 0, -1, "36000"].each { |value| expect(outlasts.call(queued, value)).to be(false) }
    end

    it "sends a due entry and no other" do
      expect(decision.due?({ "status" => "queued", "retry_at" => now }, now: now)).to be(true)
      expect(decision.due?({ "status" => "queued", "retry_at" => now + 1 }, now: now)).to be(false)
      stale = { "status" => "sending", "sending_at" => now - 121 }
      expect(decision.due?(stale, now: now)).to be(true)
      expect(decision.due?(stale.merge("sending_at" => now - 120), now: now)).to be(false)
      %w[submitted received done auto_published nieznany].each do |status|
        expect(decision.due?({ "status" => status, "retry_at" => 0 }, now: now)).to be(false)
      end
    end

    it "pauses every post after a refusal, for ponow_za_s or the plugin's own delay" do
      expect(decision.pause_until(now: now, retry_in: 30, delay: 60)).to eq(now + 30)
      # The gateway's value is kept beyond the plugin's capped retry pause.
      expect(decision.pause_until(now: now, retry_in: 36_000, delay: 900)).to eq(now + 36_000)
      [nil, 0, -5, "30"].each do |value|
        expect(decision.pause_until(now: now, retry_in: value, delay: 120)).to eq(now + 120)
      end
      # Never longer than a day, never shorter than a second.
      expect(decision.pause_until(now: now, retry_in: 10**9, delay: 60)).to eq(now + 86_400)
      expect(decision.pause_until(now: now, retry_in: nil, delay: 0)).to eq(now + 1)
    end

    it "keeps a pause only while it is in force and readable" do
      expect(decision.paused_until({ "until" => now + 30 }, now: now)).to eq(now + 30)
      [nil, {}, "x", { "until" => now }, { "until" => now - 1 }, { "until" => "#{now + 30}" },
       { "until" => now + 86_401 }].each do |pause|
        expect(decision.paused_until(pause, now: now)).to be_nil, pause.inspect
      end
    end

    it "applies a received verdict again when its job was lost" do
      expect(needs("status" => "received", "received_at" => now - 121)).to eq(:reapply)
      expect(needs("status" => "received", "received_at" => now - 5)).to be_nil
    end

    it "gives up on a received verdict it could not apply for a day" do
      expect(needs("status" => "received", "received_at" => now - (24 * 3600) - 1)).to eq(:abandon)
      expect(needs("status" => "received", "received_at" => now - (24 * 3600))).to eq(:reapply)
    end

    it "keeps a post the failure mode published open for a late verdict, then purges it" do
      auto = { "status" => "auto_published", "handled_at" => now - 60 }
      expect(needs(auto)).to be_nil
      expect(needs(auto.merge("handled_at" => now - (30 * 24 * 3600) - 1))).to eq(:purge)
    end

    it "purges a finished entry after thirty days" do
      expect(needs("status" => "done", "handled_at" => now - (30 * 24 * 3600) - 1)).to eq(:purge)
      expect(needs("status" => "done", "handled_at" => now - 60)).to be_nil
    end

    it "treats an entry it does not understand as timed out: the failure mode decides" do
      expect(needs("status" => "nieznany")).to eq(:timeout)
      expect(needs({})).to eq(:timeout)
    end
  end
end
