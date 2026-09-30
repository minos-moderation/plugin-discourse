# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# What each verdict does to a held post under the administrator's settings. No real post:
# the queued post carries invented text ("hello world post contents.").
RSpec.describe Jobs::MinosApplyVerdict do
  fab!(:reviewable) { Fabricate(:reviewable_queued_post) }

  let(:raw) { reviewable.payload["raw"] }
  let(:sent) { MinosModeration::Text.for_submission(raw) }
  let(:mask) { MinosModeration::Text::MASK }

  before { SiteSetting.minos_enabled = true }

  # Stores a received verdict for the queued post and runs the job on it. Both arguments
  # are positional Hashes: a braceless `"status" => …` must not be read as keywords.
  # (Named `apply_verdict`, not `receive`, which is rspec-mocks' matcher.)
  def apply_verdict(verdict, entry = {})
    MinosModeration::Store.set(
      reviewable.id,
      {
        "status" => "received",
        "queued_at" => Time.now.to_i,
        "received_at" => Time.now.to_i,
        "text_digest" => sent[:digest],
        "truncated" => false,
        "core_hold" => nil,
        "verdict" => { "id" => "discourse:#{reviewable.id}", "kategorie" => [] }.merge(verdict),
      }.merge(entry),
    )
    described_class.new.execute(reviewable_id: reviewable.id)
    reviewable.reload
  end

  def assessed(qualification, extra = {})
    { "status" => "ocenione", "kwalifikacja" => qualification }.merge(extra)
  end

  def entry
    MinosModeration::Store.get(reviewable.id)
  end

  def notes
    reviewable.reviewable_notes.map(&:content)
  end

  it "publishes bezpieczne and notes it" do
    apply_verdict(assessed("bezpieczne"))
    expect(reviewable).to be_approved
    expect(Post.find(reviewable.target_id).raw).to eq(raw)
    expect(entry).to include("status" => "done", "outcome" => "approve")
    expect(notes.join).to include("bezpieczne")
  end

  describe "ocenzurowane" do
    let(:masked) { sent[:text].sub("world", mask * 5) }

    it "publishes the masked text and keeps the original" do
      verdict = assessed("ocenzurowane", "kategorie" => ["wulgaryzmy"], "ocenzurowany" => masked)
      apply_verdict(verdict)
      expect(reviewable).to be_approved
      expect(Post.find(reviewable.target_id).raw).to eq(raw.sub("world", mask * 5))
      expect(entry["original"]).to eq(raw)
      expect(entry["verdict"]).not_to have_key("ocenzurowany")
      expect(notes.join).to include("wulgaryzmy")
    end

    it "masks a new topic's title as well as its first post" do
      queued = Fabricate(:reviewable_queued_post_topic)
      topic_raw = queued.payload["raw"]
      title = queued.payload["title"]
      topic_sent = MinosModeration::Text.for_submission(topic_raw, title)
      MinosModeration::Store.set(
        queued.id,
        {
          "status" => "received",
          "received_at" => Time.now.to_i,
          "text_digest" => topic_sent[:digest],
          "truncated" => false,
          "core_hold" => nil,
          "verdict" =>
            assessed(
              "ocenzurowane",
              "id" => "discourse:#{queued.id}",
              "ocenzurowany" => topic_sent[:text].sub("title", mask * 5).sub("world", mask * 5),
            ),
        },
      )
      described_class.new.execute(reviewable_id: queued.id)

      published = Post.find(queued.reload.target_id)
      expect(published.raw).to eq(topic_raw.sub("world", mask * 5))
      # Discourse may prettify a title (capitals), so the check is on the words.
      expect(published.topic.title).to include(mask * 5)
      expect(published.topic.title).not_to include("title")
      expect(MinosModeration::Store.get(queued.id)["original_title"]).to eq(title)
    end

    it "leaves the post when the administrator chose so" do
      SiteSetting.minos_censored_action = "zostaw_moderatorom"
      apply_verdict(assessed("ocenzurowane", "ocenzurowany" => masked))
      expect(reviewable).to be_pending
      expect(entry).to include("outcome" => "leave", "reason" => "censored_setting")
    end

    it "leaves the post when the masks cannot be carried onto it" do
      apply_verdict(assessed("ocenzurowane", "ocenzurowany" => "#{mask}#{sent[:text][1..]}X"))
      expect(reviewable).to be_pending
      expect(entry["reason"]).to eq("mask_unmappable")
    end
  end

  describe "zablokowane" do
    it "leaves the post by default" do
      apply_verdict(assessed("zablokowane", "kategorie" => ["nekanie"]))
      expect(reviewable).to be_pending
      expect(entry["reason"]).to eq("blocked_setting")
    end

    it "rejects the post when the administrator chose so" do
      SiteSetting.minos_blocked_action = "odrzuc"
      apply_verdict(assessed("zablokowane"))
      expect(reviewable).to be_rejected
    end

    it "never rejects a post that reads as self-harm, and asks for support" do
      SiteSetting.minos_blocked_action = "odrzuc"
      apply_verdict(assessed("zablokowane", "kategorie" => ["samookaleczenie"], "wsparcie" => true))
      expect(reviewable).to be_pending
      expect(notes.join).to include("wsparcie")
    end
  end

  describe "nieocenione" do
    it "leaves the post under fail-closed, the default" do
      apply_verdict({ "status" => "nieocenione" })
      expect(reviewable).to be_pending
      expect(entry["reason"]).to eq("unassessed")
    end

    it "publishes the post under fail-open" do
      SiteSetting.minos_failure_mode = "fail-open"
      apply_verdict({ "status" => "nieocenione" })
      expect(reviewable).to be_approved
    end
  end

  it "leaves a post edited in the queue after it was sent" do
    apply_verdict(assessed("bezpieczne"), { "text_digest" => "0" * 64 })
    expect(reviewable).to be_pending
    expect(entry["reason"]).to eq("edited")
  end

  it "only notes the verdict on a post Discourse holds itself" do
    apply_verdict(assessed("bezpieczne"), { "core_hold" => "post_count" })
    expect(reviewable).to be_pending
    expect(entry["reason"]).to eq("core_hold")
  end

  it "leaves a post whose topic was closed meanwhile" do
    reviewable.topic.update!(closed: true)
    apply_verdict(assessed("bezpieczne"))
    expect(reviewable).to be_pending
    expect(entry["reason"]).to eq("topic_closed")
  end

  it "does nothing to a post a moderator already handled" do
    reviewable.perform(Discourse.system_user, :reject_post)
    apply_verdict(assessed("bezpieczne"))
    expect(reviewable).to be_rejected
    expect(entry["outcome"]).to eq("resolved_elsewhere")
  end

  it "applies a verdict once" do
    apply_verdict(assessed("bezpieczne"))
    expect { described_class.new.execute(reviewable_id: reviewable.id) }.not_to change {
      reviewable.reload.reviewable_notes.count
    }
  end
end
