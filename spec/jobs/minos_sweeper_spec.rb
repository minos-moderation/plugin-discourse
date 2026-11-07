# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# The five-minute sweep: timeouts, lost retries, lost verdict jobs, old entries.
RSpec.describe Jobs::MinosSweeper do
  fab!(:reviewable) { Fabricate(:reviewable_queued_post) }

  let(:now) { Time.now.to_i }
  let(:timeout) { SiteSetting.minos_timeout_minutes * 60 }

  before { SiteSetting.minos_enabled = true }

  def store(entry)
    MinosModeration::Store.set(reviewable.id, entry)
  end

  def entry
    MinosModeration::Store.get(reviewable.id)
  end

  def sweep
    described_class.new.execute({})
  end

  it "is scheduled every five minutes" do
    expect(described_class.every).to eq(5.minutes)
  end

  describe "a post without a verdict after the timeout" do
    before do
      store("status" => "submitted", "queued_at" => now, "submitted_at" => now - timeout - 1)
    end

    it "is left to the moderators under fail-closed" do
      sweep
      expect(reviewable.reload).to be_pending
      expect(entry).to include("status" => "done", "reason" => "timeout")
    end

    it "is published under fail-open" do
      SiteSetting.minos_failure_mode = "fail-open"
      sweep
      expect(reviewable.reload).to be_approved
      expect(entry["status"]).to eq("auto_published")
    end

    it "stays with the moderators under fail-open when Discourse held it itself" do
      SiteSetting.minos_failure_mode = "fail-open"
      store(entry.merge("core_hold" => "watched_word"))
      sweep
      expect(reviewable.reload).to be_pending
      expect(entry).to include("status" => "done", "reason" => "core_hold")
    end
  end

  it "waits twenty minutes even when a lower timeout was stored before the minimum" do
    # Discourse checks `min` only when a value is written, so a 16 saved earlier stays.
    allow(SiteSetting).to receive(:minos_timeout_minutes).and_return(16)
    store("status" => "submitted", "queued_at" => now, "submitted_at" => now - (16 * 60) - 1)
    sweep
    expect(entry["status"]).to eq("submitted")

    store("status" => "submitted", "queued_at" => now, "submitted_at" => now - (20 * 60) - 1)
    sweep
    expect(entry).to include("status" => "done", "reason" => "timeout")
  end

  it "waits for a post still within the timeout" do
    store("status" => "submitted", "queued_at" => now, "submitted_at" => now - 60)
    sweep
    expect(entry["status"]).to eq("submitted")
  end

  it "resubmits a due retry whose job was lost" do
    store("status" => "queued", "queued_at" => now - 120, "retry_at" => now - 1)
    expect_enqueued_with(job: :minos_submit, args: { reviewable_id: reviewable.id }) { sweep }
  end

  it "resubmits a send that died half-way" do
    store("status" => "sending", "queued_at" => now - 300, "sending_at" => now - 200)
    expect_enqueued_with(job: :minos_submit, args: { reviewable_id: reviewable.id }) { sweep }
  end

  it "applies again a verdict whose job was lost" do
    verdict = { "status" => "nieocenione" }
    store("status" => "received", "received_at" => now - 300, "verdict" => verdict)
    expect_enqueued_with(job: :minos_apply_verdict, args: { reviewable_id: reviewable.id }) do
      sweep
    end
  end

  it "gives up on a verdict it could not apply for a day, and leaves the post" do
    verdict = { "status" => "ocenione", "kwalifikacja" => "bezpieczne" }
    store("status" => "received", "received_at" => now - (24 * 3600) - 1, "verdict" => verdict)
    expect_not_enqueued_with(job: :minos_apply_verdict) { sweep }
    expect(reviewable.reload).to be_pending
    expect(entry).to include("status" => "done", "reason" => "apply_stuck")
  end

  describe "a finished entry whose support signal waits (support_due)" do
    let(:support) do
      { "status" => "ocenione", "kwalifikacja" => "zablokowane", "wsparcie" => true }
    end

    def finished(due_at)
      store(
        "status" => "done",
        "outcome" => "leave",
        "reason" => "timeout",
        "handled_at" => now - 3600,
        "received_at" => due_at,
        "support_due" => due_at,
        "verdict" => support,
      )
    end

    it "raises the signal again when its job was lost" do
      finished(now - 300)
      expect_enqueued_with(job: :minos_apply_verdict, args: { reviewable_id: reviewable.id }) do
        sweep
      end
    end

    it "gives the signal up after a day, with a warning in the log, and stops trying" do
      finished(now - (24 * 3600) - 1)
      allow(Rails.logger).to receive(:warn).and_call_original
      expect_not_enqueued_with(job: :minos_apply_verdict) { sweep }
      expect(Rails.logger).to have_received(:warn).with(a_string_including("given up"))
      expect(entry).not_to have_key("support_due")
      expect(entry["support_given_up_at"]).to be_a(Integer)
      expect(entry).to include("status" => "done", "verdict" => support)
      expect_not_enqueued_with(job: :minos_apply_verdict) { sweep }
    end
  end

  it "forgets a finished entry after thirty days, and keeps a recent one" do
    store("status" => "done", "handled_at" => now - (31 * 24 * 3600))
    sweep
    expect(entry).to be_nil

    store("status" => "done", "handled_at" => now - 3600)
    sweep
    expect(entry).to be_present
  end

  it "gives an entry it does not understand the failure mode" do
    store("status" => "nieznany")
    sweep
    expect(entry).to include("status" => "done", "reason" => "timeout")
  end

  it "does nothing while the plugin is disabled" do
    SiteSetting.minos_enabled = false
    store("status" => "submitted", "queued_at" => now, "submitted_at" => now - timeout - 1)
    sweep
    expect(entry["status"]).to eq("submitted")
  end

  # Shared plugin rule A8 holds whatever the switch: the README and the privacy notices
  # promise 30 days, and at most a day for the gateway's masked text.
  describe "while the plugin is disabled, its own retention" do
    before { SiteSetting.minos_enabled = false }

    it "forgets a finished entry after thirty days" do
      store("status" => "done", "handled_at" => now - (31 * 24 * 3600))
      sweep
      expect(entry).to be_nil
    end

    it "drops the masked text of a verdict that waited over a day, and applies nothing" do
      masked = {
        "id" => "discourse:#{reviewable.id}",
        "status" => "ocenione",
        "kwalifikacja" => "ocenzurowane",
        "kategorie" => [],
        "ocenzurowany" => "#{MinosModeration::Text::MASK * 5} tekst",
      }
      store("status" => "received", "received_at" => now - (24 * 3600) - 1, "verdict" => masked)
      expect_not_enqueued_with(job: :minos_apply_verdict) { sweep }
      expect(entry["status"]).to eq("received")
      expect(entry["verdict"]).to include("kwalifikacja" => "ocenzurowane")
      expect(entry["verdict"]).not_to have_key("ocenzurowany")
      expect(reviewable.reload).to be_pending
    end

    it "keeps a verdict's masked text for its first day" do
      masked = { "status" => "ocenione", "kwalifikacja" => "ocenzurowane", "ocenzurowany" => "x" }
      store("status" => "received", "received_at" => now - 3600, "verdict" => masked)
      sweep
      expect(entry["verdict"]).to have_key("ocenzurowany")
    end
  end
end
