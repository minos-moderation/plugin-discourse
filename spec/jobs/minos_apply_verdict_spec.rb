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

  # The support flags raised on a post: pending `notify_moderators` items of the review
  # queue, from the system user.
  def support_flags(post)
    ReviewableFlaggedPost
      .pending
      .where(target: post)
      .joins(:reviewable_scores)
      .where(
        reviewable_scores: {
          user_id: Discourse.system_user.id,
          reviewable_score_type: PostActionType.types[:notify_moderators],
        },
      )
  end

  # How many personal messages a user takes part in.
  def messages_to(user_id)
    TopicAllowedUser.where(user_id: user_id).count
  end

  describe "wsparcie on a published post (shared plugin rule A7)" do
    it "publishes bezpieczne and raises one pending flag for the moderators, nothing to the author" do
      support = assessed("bezpieczne", "kategorie" => ["samookaleczenie"], "wsparcie" => true)
      author = reviewable.target_created_by_id
      before = messages_to(author)
      expect_not_enqueued_with(job: :send_system_message) { apply_verdict(support) }

      expect(reviewable).to be_approved
      post = Post.find(reviewable.target_id)
      expect(support_flags(post).count).to eq(1)
      expect(messages_to(author)).to eq(before)
      expect(post).not_to be_hidden
    end

    it "flags a post published with its masks too" do
      masked = sent[:text].sub("world", mask * 5)
      apply_verdict(assessed("ocenzurowane", "ocenzurowany" => masked, "wsparcie" => true))
      expect(reviewable).to be_approved
      expect(support_flags(Post.find(reviewable.target_id)).count).to eq(1)
    end

    it "raises no flag without wsparcie" do
      apply_verdict(assessed("bezpieczne"))
      expect(support_flags(Post.find(reviewable.target_id)).count).to eq(0)
    end
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

    # Also the control of "never approves when the masked text did not persist": an edit
    # that persists is approved.
    it "publishes the masked text and keeps the original" do
      verdict = assessed("ocenzurowane", "kategorie" => ["wulgaryzmy"], "ocenzurowany" => masked)
      apply_verdict(verdict)
      expect(reviewable).to be_approved
      expect(Post.find(reviewable.target_id).raw).to eq(raw.sub("world", mask * 5))
      # The unmasked text stays in the reviewable's history, never in the plugin's store.
      expect(entry).not_to have_key("original")
      expect(entry["original_digest"]).to eq(Digest::SHA256.hexdigest(raw))
      expect(MinosModeration::Store.get(reviewable.id).to_json).not_to include("world")
      expect(entry["verdict"]).not_to have_key("ocenzurowany")
      expect(notes.join).to include("wulgaryzmy")
    end

    describe "on a new topic (shared plugin rule S5: a title is never changed)" do
      fab!(:queued) { Fabricate(:reviewable_queued_post_topic) }

      let(:topic_raw) { queued.payload["raw"] }
      let(:title) { queued.payload["title"] }
      let(:topic_sent) { MinosModeration::Text.for_submission(topic_raw, title) }

      def apply_to_topic(masked, entry = {})
        MinosModeration::Store.set(
          queued.id,
          {
            "status" => "received",
            "received_at" => Time.now.to_i,
            "text_digest" => topic_sent[:digest],
            "truncated" => false,
            "core_hold" => nil,
            "verdict" =>
              assessed("ocenzurowane", "id" => "discourse:#{queued.id}", "ocenzurowany" => masked),
          }.merge(entry),
        )
        described_class.new.execute(reviewable_id: queued.id)
        queued.reload
      end

      def topic_entry
        MinosModeration::Store.get(queued.id)
      end

      it "holds a topic whose title the gateway masked, title untouched, mask in a note" do
        masked = topic_sent[:text].sub("title", mask * 5).sub("world", mask * 5)
        apply_to_topic(masked)

        expect(queued).to be_pending
        expect(queued.payload["title"]).to eq(title)
        expect(queued.payload["raw"]).to eq(topic_raw)
        expect(topic_entry).to include("outcome" => "leave", "reason" => "title_masked")
        expect(queued.reviewable_notes.map(&:content)).to include(include(masked))
      end

      it "publishes a topic whose masks are all in its post, under its own title" do
        apply_to_topic(topic_sent[:text].sub("world", mask * 5))

        published = Post.find(queued.target_id)
        expect(published.raw).to eq(topic_raw.sub("world", mask * 5))
        # Discourse may prettify a title (capitals), so the check is on the words.
        expect(published.topic.title.downcase).to include("title")
        expect(published.topic.title).not_to include(mask)
        expect(topic_entry).not_to have_key("original_title_digest")
      end

      describe "after the failure mode published it" do
        let(:first_post) { Post.find(queued.target_id) }

        before do
          queued.perform(Discourse.system_user, :approve_post)
          queued.reload
        end

        def late_on_topic(extra = {})
          masked = topic_sent[:text].sub("title", mask * 5).sub("world", mask * 5)
          verdict = assessed("ocenzurowane", "id" => "discourse:#{queued.id}.1", "ocenzurowany" => masked)
          apply_to_topic(
            masked,
            {
              "auto_published" => true,
              "post_id" => queued.target_id,
              "attempt" => 1,
              "verdict" => verdict.merge(extra),
            },
          )
          first_post.reload
        end

        it "takes the post out of view and never changes the title" do
          before_title = first_post.topic.title
          late_on_topic
          expect(first_post).to be_hidden
          expect(first_post.raw).to eq(topic_raw)
          expect(first_post.topic.reload.title).to eq(before_title)
          expect(topic_entry).to include("outcome" => "hide", "reason" => "title_masked")
        end

        it "keeps a post with wsparcie visible and flags it, the title untouched" do
          before_title = first_post.topic.title
          late_on_topic("wsparcie" => true)
          expect(first_post).not_to be_hidden
          expect(first_post.topic.reload.title).to eq(before_title)
          expect(topic_entry).to include("outcome" => "keep", "reason" => "title_masked")
          expect(support_flags(first_post).count).to eq(1)
        end
      end
    end

    it "leaves the post when the administrator chose so" do
      SiteSetting.minos_censored_action = "zostaw_moderatorom"
      apply_verdict(assessed("ocenzurowane", "ocenzurowany" => masked))
      expect(reviewable).to be_pending
      expect(entry).to include("outcome" => "leave", "reason" => "censored_setting")
    end

    it "leaves the post when the queued text cannot be edited" do
      allow_any_instance_of(ReviewableQueuedPost).to receive(:update_fields).and_raise(
        Reviewable::UpdateConflict,
      )
      apply_verdict(assessed("ocenzurowane", "ocenzurowany" => masked))
      expect(reviewable).to be_pending
      expect(entry).to include("outcome" => "leave", "reason" => "action_failed")
    end

    it "never approves when the masked text did not persist, although the edit reported success" do
      # A save that reports success while the stored payload keeps the original text.
      allow_any_instance_of(ReviewableQueuedPost).to receive(:update_fields).and_return(true)
      apply_verdict(assessed("ocenzurowane", "ocenzurowany" => masked))
      expect(reviewable).to be_pending
      expect(reviewable.payload["raw"]).to eq(raw)
      expect(entry).to include("outcome" => "leave", "reason" => "action_failed")
      expect(reviewable.target_id).to be_nil
    end

    it "leaves the post when the masks cannot be carried onto it" do
      apply_verdict(assessed("ocenzurowane", "ocenzurowany" => "#{mask}#{sent[:text][1..]}X"))
      expect(reviewable).to be_pending
      expect(entry["reason"]).to eq("mask_unmappable")
    end
  end

  describe "the gateway's masks shown to the moderators (shared plugin rule A2d)" do
    let(:masked) { sent[:text].sub("world", mask * 5) }

    def censored(extra = {})
      assessed("ocenzurowane", { "kategorie" => ["wulgaryzmy"], "ocenzurowany" => masked }.merge(extra))
    end

    def mask_notes
      notes.select { |content| content.include?(mask * 5) }
    end

    it "notes the masked text when the setting leaves a censored post to the moderators" do
      SiteSetting.minos_censored_action = "zostaw_moderatorom"
      apply_verdict(censored)
      expect(reviewable).to be_pending
      expect(entry["reason"]).to eq("censored_setting")
      expect(mask_notes.size).to eq(1)
      expect(mask_notes.first).to include(masked)
    end

    it "notes it when only the beginning of the post was assessed" do
      apply_verdict(censored, { "truncated" => true })
      expect(reviewable).to be_pending
      expect(entry["reason"]).to eq("truncated")
      expect(mask_notes).to contain_exactly(include(masked))
    end

    it "notes it when the masks do not map onto the post" do
      unmappable = "#{mask * 5}#{sent[:text][5..]}X"
      apply_verdict(censored("ocenzurowany" => unmappable))
      expect(entry["reason"]).to eq("mask_unmappable")
      expect(mask_notes).to contain_exactly(include(unmappable))
    end

    it "notes it when the masked text could not be stored" do
      allow_any_instance_of(ReviewableQueuedPost).to receive(:update_fields).and_raise(
        Reviewable::UpdateConflict,
      )
      apply_verdict(censored)
      expect(entry["reason"]).to eq("action_failed")
      expect(mask_notes).to contain_exactly(include(masked))
    end

    it "notes no mask when the masks reached the post" do
      apply_verdict(censored)
      expect(reviewable).to be_approved
      expect(mask_notes).to be_empty
    end

    it "mentions nobody, keeps HTML as text and carries neither key nor secret" do
      SiteSetting.minos_api_key = "wgb2b_klucz_testowy_0000000000000000"
      SiteSetting.minos_webhook_secret = "sekret-testowy"
      moderator = Fabricate(:moderator, username: "moderator_a")
      SiteSetting.minos_censored_action = "zostaw_moderatorom"
      apply_verdict(censored("ocenzurowany" => "<b>x</b> @moderator_a #{mask * 5}"))

      note = reviewable.reviewable_notes.find { |item| item.content.include?(mask * 5) }
      expect(note).to be_present
      mentioned = Notification.where(user: moderator, notification_type: Notification.types[:mentioned])
      expect(mentioned.count).to eq(0)
      cooked = PlaintextMentions.new(note.content).render
      expect(cooked).not_to include("<b>")
      expect(cooked).not_to include("mention")
      reviewable.reviewable_notes.each do |item|
        expect(item.content).not_to include(SiteSetting.minos_api_key)
        expect(item.content).not_to include(SiteSetting.minos_webhook_secret)
      end
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
      # Held, so already in the moderators' queue: no post, no flag.
      expect(reviewable.target_id).to be_nil
      expect(ReviewableFlaggedPost.count).to eq(0)
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

  describe "a late verdict for a post the failure mode published" do
    let(:post) { Post.find(reviewable.target_id) }

    before do
      reviewable.perform(Discourse.system_user, :approve_post)
      reviewable.reload
    end

    def late(verdict)
      apply_verdict(
        verdict,
        { "auto_published" => true, "post_id" => reviewable.target_id, "attempt" => 1 },
      )
      post.reload
    end

    it "hides the post on zablokowane" do
      late(assessed("zablokowane", "kategorie" => ["nekanie"]))
      expect(post).to be_hidden
      expect(entry).to include("status" => "done", "outcome" => "hide")
    end

    it "tells the author when it hides a post, as Discourse does" do
      expect_enqueued_with(job: :send_system_message, args: { user_id: post.user_id }) do
        late(assessed("zablokowane"))
      end
      expect(post).to be_hidden
    end

    describe "with wsparcie" do
      let(:support_note) do
        I18n.with_locale(SiteSetting.default_locale) { I18n.t("minos_moderation.notes.support") }
      end

      it "never hides the post on zablokowane, notes the signal and does not message the author" do
        before = messages_to(post.user_id)
        expect_not_enqueued_with(job: :send_system_message) do
          late(assessed("zablokowane", "kategorie" => ["samookaleczenie"], "wsparcie" => true))
        end
        expect(post).not_to be_hidden
        expect(entry).to include("status" => "done", "outcome" => "keep", "reason" => "support")
        expect(notes).to include(support_note)
        expect(support_flags(post).count).to eq(1)
        expect(messages_to(post.user_id)).to eq(before)
      end

      it "keeps the post visible when the masks cannot be carried onto it" do
        unmappable = "#{mask}#{sent[:text][1..]}X"
        expect_not_enqueued_with(job: :send_system_message) do
          late(assessed("ocenzurowane", "ocenzurowany" => unmappable, "wsparcie" => true))
        end
        expect(post).not_to be_hidden
        expect(entry).to include("outcome" => "keep", "reason" => "mask_unmappable")
        expect(notes).to include(support_note)
      end
    end

    it "masks the post on ocenzurowane" do
      late(assessed("ocenzurowane", "ocenzurowany" => sent[:text].sub("world", mask * 5)))
      expect(post.raw).to eq(raw.sub("world", mask * 5))
      expect(post).not_to be_hidden
      expect(entry).to include("outcome" => "mask")
      expect(entry).not_to have_key("original")
    end

    it "keeps the original in a revision staff can see and readers cannot, edit history public or not" do
      SiteSetting.edit_history_visible_to_public = true
      late(assessed("ocenzurowane", "ocenzurowany" => sent[:text].sub("world", mask * 5)))

      revision = PostRevision.find_by(post_id: post.id, number: post.version)
      expect(revision).to be_present
      expect(revision.hidden).to be(true)
      # The moderators keep the original...
      expect(revision.modifications["raw"].first).to eq(raw)
      expect(Guardian.new(Fabricate(:moderator)).can_see_post_revision?(revision)).to be(true)
      # ...and no reader, signed in or not, the author included, can open it.
      [nil, Fabricate(:user), post.user].each do |reader|
        expect(Guardian.new(reader).can_see_post_revision?(revision)).to be(false), reader.inspect
      end
      expect(post.public_version).to eq(1)
      expect(PostRevision.where(post_id: post.id, hidden: false)).to be_empty
    end

    it "hides the post when the censored setting leaves such posts to moderators" do
      SiteSetting.minos_censored_action = "zostaw_moderatorom"
      late(assessed("ocenzurowane", "ocenzurowany" => sent[:text].sub("world", mask * 5)))
      expect(post).to be_hidden
    end

    it "keeps a safe post as it is" do
      late(assessed("bezpieczne"))
      expect(post).not_to be_hidden
      expect(entry["outcome"]).to eq("keep")
    end

    it "still hides a post Discourse normalised on publication (a no-break space)" do
      queued = Fabricate(:reviewable_queued_post)
      queued.payload["raw"] = "Tekst posta\u00A0z jedną twardą spacją, zupełnie zwyczajny."
      queued.save!
      queued.perform(Discourse.system_user, :approve_post)
      published = Post.find(queued.reload.target_id)
      # Discourse's own normalisation happened: the stored text is not the queued one.
      expect(published.raw).not_to eq(queued.payload["raw"])
      expect(published.version).to eq(1)

      queued_sent = MinosModeration::Text.for_submission(queued.payload["raw"])
      MinosModeration::Store.set(
        queued.id,
        {
          "status" => "received",
          "received_at" => Time.now.to_i,
          "text_digest" => queued_sent[:digest],
          "truncated" => false,
          "core_hold" => nil,
          "auto_published" => true,
          "post_id" => published.id,
          "attempt" => 1,
          "verdict" => assessed("zablokowane", "id" => "discourse:#{queued.id}.1"),
        },
      )
      described_class.new.execute(reviewable_id: queued.id)

      expect(published.reload).to be_hidden
      expect(MinosModeration::Store.get(queued.id)).to include("outcome" => "hide")
    end

    it "keeps a moderator's edit: nothing is hidden or overwritten" do
      edited = "#{raw} Poprawione przez moderatora."
      PostRevisor.new(post).revise!(Fabricate(:moderator), { raw: edited }, force_new_version: true)
      late(assessed("zablokowane"))
      expect(post).not_to be_hidden
      expect(post.raw).to eq(edited)
      expect(entry).to include("outcome" => "keep", "reason" => "person_acted")
    end

    it "keeps the author's edit within the grace period, which makes no new version" do
      edited = "#{raw} Poprawione przez autora."
      PostRevisor.new(post).revise!(post.user, { raw: edited })
      late(assessed("ocenzurowane", "ocenzurowany" => sent[:text].sub("world", mask * 5)))
      expect(post.raw).to eq(edited)
      expect(entry["reason"]).to eq("person_acted")
    end

    it "keeps a post whose flag a moderator already reviewed" do
      flagged = Fabricate(:reviewable_flagged_post, target: post, topic: post.topic)
      flagged.update!(status: :ignored)
      late(assessed("zablokowane"))
      expect(post).not_to be_hidden
      expect(entry["reason"]).to eq("person_acted")
    end
  end

  describe "a verdict for a post the failure mode held after its time-out (shared plugin rule A6)" do
    let(:timeout) { SiteSetting.minos_timeout_minutes * 60 }

    before do
      now = Time.now.to_i
      MinosModeration::Store.set(
        reviewable.id,
        {
          "status" => "submitted",
          "queued_at" => now - timeout - 60,
          "submitted_at" => now - timeout - 1,
          "attempts" => 1,
          "attempt" => 1,
          "text_digest" => sent[:digest],
          "digests" => { "1" => sent[:digest] },
          "truncated" => false,
          "core_hold" => nil,
        },
      )
      # Fail-closed, the default: the sweeper holds the post for the moderators.
      Jobs::MinosSweeper.new.execute({})
      expect(entry).to include("status" => "done", "outcome" => "leave", "reason" => "timeout")
      expect(reviewable.reload).to be_pending
    end

    def late_payload(verdict)
      {
        "id" => "discourse:#{reviewable.id}.1",
        "kategorie" => [],
        "ocenzurowany" => nil,
        "wsparcie" => false,
        "wersja" => nil,
      }.merge(verdict)
    end

    def deliver_late(verdict)
      taken = MinosModeration::Receiver.accept(late_payload(verdict))
      described_class.new.execute(reviewable_id: reviewable.id)
      reviewable.reload
      taken
    end

    it "publishes the post on bezpieczne, as if the verdict had come in time" do
      expect(deliver_late(assessed("bezpieczne"))).to eq(:accepted)
      expect(reviewable).to be_approved
      expect(entry).to include("status" => "done", "outcome" => "approve", "reason" => "verdict")
    end

    it "follows the settings for any other verdict, as in time" do
      SiteSetting.minos_blocked_action = "odrzuc"
      deliver_late(assessed("zablokowane", "kategorie" => ["nekanie"]))
      expect(reviewable).to be_rejected
    end

    it "changes nothing once a moderator decided on the post" do
      reviewable.perform(Discourse.system_user, :reject_post)
      expect(deliver_late(assessed("bezpieczne"))).to eq(:ignored)
      expect(reviewable).to be_rejected
      expect(entry).to include("status" => "done", "outcome" => "leave", "reason" => "timeout")
    end

    it "only notes the verdict when the post was edited in the queue since" do
      reviewable.update!(payload: reviewable.payload.merge("raw" => "Zupełnie inny, poprawiony tekst."))
      deliver_late(assessed("bezpieczne"))
      expect(reviewable).to be_pending
      expect(entry).to include("status" => "done", "outcome" => "leave", "reason" => "edited")
    end

    it "takes no verdict for a post held for another reason" do
      MinosModeration::Store.set(reviewable.id, entry.merge("reason" => "config"))
      expect(deliver_late(assessed("bezpieczne"))).to eq(:ignored)
      expect(reviewable).to be_pending
    end
  end

  it "applies a verdict once" do
    apply_verdict(assessed("bezpieczne"))
    expect { described_class.new.execute(reviewable_id: reviewable.id) }.not_to change {
      reviewable.reload.reviewable_notes.count
    }
  end
end
