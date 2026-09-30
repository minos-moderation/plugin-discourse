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

    it "applies a received verdict again when its job was lost" do
      expect(needs("status" => "received", "received_at" => now - 121)).to eq(:reapply)
      expect(needs("status" => "received", "received_at" => now - 5)).to be_nil
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
