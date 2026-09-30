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
    end
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
end
