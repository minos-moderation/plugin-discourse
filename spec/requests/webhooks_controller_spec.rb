# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# The receiving checklist of the contract, over HTTP: raw body first, signature, parse,
# drop repeats, answer fast. No real post: the queued post carries invented text.
RSpec.describe MinosModeration::WebhooksController do
  fab!(:reviewable) { Fabricate(:reviewable_queued_post) }

  let(:secret) { "sekret-testowy-webhooka" }
  let(:item_id) { "discourse:#{reviewable.id}.2" }
  let(:verdict) do
    {
      "id" => item_id,
      "status" => "ocenione",
      "kwalifikacja" => "bezpieczne",
      "kategorie" => [],
      "wsparcie" => false,
      "wersja" => "3f0c9a41d2b7e8c5",
    }
  end

  before do
    SiteSetting.minos_enabled = true
    SiteSetting.minos_webhook_secret = secret
    MinosModeration::Store.set(
      reviewable.id,
      {
        "status" => "submitted",
        "attempts" => 2,
        "attempt" => 2,
        "queued_at" => Time.now.to_i,
        "submitted_at" => Time.now.to_i,
        "text_digest" => MinosModeration::Text.for_submission(reviewable.payload["raw"])[:digest],
        "truncated" => false,
        "core_hold" => nil,
      },
    )
  end

  def deliver(body, header: nil, at: Time.now.to_i, signed_with: secret)
    header ||= MinosModeration::Signature.sign(signed_with, body, at)
    post "/minos/webhook",
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json; charset=utf-8",
           "X-Wergiliusz-Podpis" => header,
         }
  end

  def status
    MinosModeration::Store.get(reviewable.id)["status"]
  end

  it "takes a signed verdict, answers 200 and leaves the work to a job" do
    expect_enqueued_with(job: :minos_apply_verdict, args: { reviewable_id: reviewable.id }) do
      deliver(JSON.generate(verdict))
    end
    expect(response.status).to eq(200)
    expect(status).to eq("received")
    expect(reviewable.reload).to be_pending
  end

  it "verifies the exact bytes it received, as the gateway's vector shows" do
    path = File.expand_path("../fixtures/signature.json", __dir__)
    vector = JSON.parse(File.read(path, encoding: "UTF-8"))
    SiteSetting.minos_webhook_secret = vector["secret"]
    freeze_time(Time.at(vector["timestamp"]))
    deliver(vector["body"], header: vector["header"])
    # A valid delivery for an item that is not this forum's: accepted and dropped.
    expect(response.status).to eq(200)
  end

  describe "a delivery that fails the signature" do
    it "is refused with 401 and changes nothing" do
      body = JSON.generate(verdict)
      genuine = MinosModeration::Signature.sign(secret, body, Time.now.to_i)
      [
        -> { deliver(body, signed_with: "#{secret}x") },
        -> { deliver("#{body} ", header: genuine) },
        -> { deliver(JSON.pretty_generate(verdict), header: genuine) },
        -> { deliver(body, at: Time.now.to_i - 301) },
        -> { deliver(body, at: Time.now.to_i + 301) },
        -> { deliver(body, header: "") },
        -> { deliver(body, header: "t=1,v1=zly") },
      ].each do |attempt|
        expect_not_enqueued_with(job: :minos_apply_verdict) { attempt.call }
        expect(response.status).to eq(401)
      end
      expect(status).to eq("submitted")
    end

    it "is refused while no webhook secret is set" do
      SiteSetting.minos_webhook_secret = ""
      deliver(JSON.generate(verdict), signed_with: "")
      expect(response.status).to eq(401)
    end
  end

  it "answers 400 to a signed body that is not a payload" do
    ["[]", '{"status":"ocenione"}', "nie json"].each do |body|
      deliver(body)
      expect(response.status).to eq(400), body
    end
    expect(status).to eq("submitted")
  end

  it "drops a repeated delivery with 200, and applies the verdict once" do
    body = JSON.generate(verdict)
    deliver(body)
    expect_not_enqueued_with(job: :minos_apply_verdict) { deliver(body) }
    expect(response.status).to eq(200)
  end

  it "drops a verdict for an earlier attempt, with 200" do
    ["discourse:#{reviewable.id}.1", "discourse:#{reviewable.id}"].each do |id|
      expect_not_enqueued_with(job: :minos_apply_verdict) do
        deliver(JSON.generate(verdict.merge("id" => id)))
      end
      expect(response.status).to eq(200), id
    end
    expect(status).to eq("submitted")
  end

  describe "a verdict for an earlier attempt of the same post" do
    let(:digest) { MinosModeration::Text.for_submission(reviewable.payload["raw"])[:digest] }
    let(:first) { JSON.generate(verdict.merge("id" => "discourse:#{reviewable.id}.1")) }

    # Attempt 2 was sent and refused, so the entry waits for its retry.
    def waiting_with(digests)
      entry = MinosModeration::Store.get(reviewable.id)
      MinosModeration::Store.set(
        reviewable.id,
        entry.merge("status" => "queued", "retry_at" => Time.now.to_i + 60, "digests" => digests),
      )
    end

    it "is applied when that attempt sent the same text" do
      waiting_with("1" => digest, "2" => digest)
      expect_enqueued_with(job: :minos_apply_verdict, args: { reviewable_id: reviewable.id }) do
        deliver(first)
      end
      expect(response.status).to eq(200)
      expect(status).to eq("received")
      expect(MinosModeration::Store.get(reviewable.id)["verdict"]["id"]).to end_with(".1")
    end

    it "is ignored with 200 when that attempt sent another text" do
      waiting_with("1" => "0" * 64, "2" => digest)
      expect_not_enqueued_with(job: :minos_apply_verdict) { deliver(first) }
      expect(response.status).to eq(200)
      expect(status).to eq("queued")
    end

    it "and the current attempt's verdict for the same text are applied once" do
      waiting_with("1" => digest, "2" => digest)
      second = JSON.generate(verdict)
      deliver(first)
      expect_not_enqueued_with(job: :minos_apply_verdict) { deliver(second) }
      expect(response.status).to eq(200)
      expect(MinosModeration::Store.get(reviewable.id)["verdict"]["id"]).to end_with(".1")
    end
  end

  it "takes a late verdict for a post the failure mode published" do
    entry = MinosModeration::Store.get(reviewable.id)
    MinosModeration::Store.set(reviewable.id, entry.merge("status" => "auto_published"))
    expect_enqueued_with(job: :minos_apply_verdict, args: { reviewable_id: reviewable.id }) do
      deliver(JSON.generate(verdict))
    end
    expect(status).to eq("received")
  end

  describe "a late verdict for a post the failure mode held after its time-out" do
    before do
      entry = MinosModeration::Store.get(reviewable.id)
      MinosModeration::Store.set(
        reviewable.id,
        entry.merge(
          "status" => "done",
          "outcome" => "leave",
          "reason" => "timeout",
          "handled_at" => Time.now.to_i,
        ),
      )
    end

    it "is taken while no one has decided on the post" do
      expect_enqueued_with(job: :minos_apply_verdict, args: { reviewable_id: reviewable.id }) do
        deliver(JSON.generate(verdict))
      end
      expect(response.status).to eq(200)
      expect(status).to eq("received")
    end

    it "is dropped with 200 once a moderator decided" do
      reviewable.perform(Discourse.system_user, :approve_post)
      expect_not_enqueued_with(job: :minos_apply_verdict) { deliver(JSON.generate(verdict)) }
      expect(response.status).to eq(200)
      expect(status).to eq("done")
    end
  end

  # Shared plugin rule A7: `wsparcie` reaches the moderators also when a person decided
  # first, with a note that it came after that decision; the post stays as it was left.
  describe "a verdict with wsparcie after a moderator's decision" do
    let(:support) do
      verdict.merge(
        "kwalifikacja" => "zablokowane",
        "kategorie" => ["samookaleczenie"],
        "wsparcie" => true,
      )
    end
    let(:after_note) do
      I18n.with_locale(SiteSetting.default_locale) do
        I18n.t("minos_moderation.notes.support_after_decision")
      end
    end
    let(:flag_message) do
      I18n.with_locale(SiteSetting.default_locale) do
        I18n.t("minos_moderation.flags.support_after_decision")
      end
    end

    # Jobs run inline, so Discourse's own `process_post` cooks the flag's message to the
    # moderators right in the request: the post's link in it oneboxes with the author's
    # letter avatar, whose size Discourse fetches over HTTP from the test host. Nothing
    # serves it in tests; a 404 is the ordinary "image not reachable" path Discourse
    # already takes, so the request stays offline.
    before do
      Jobs.run_immediately!
      stub_request(:get, %r{/letter_avatar_proxy/}).to_return(status: 404)
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

    def notes
      reviewable.reload.reviewable_notes.map(&:content)
    end

    def published
      Post.find(reviewable.reload.target_id)
    end

    # A post the failure mode held after its time-out (fail-closed), then approved by a
    # moderator before the verdict came.
    def approved_after_timeout
      entry = MinosModeration::Store.get(reviewable.id)
      MinosModeration::Store.set(
        reviewable.id,
        entry.merge(
          "status" => "done",
          "outcome" => "leave",
          "reason" => "timeout",
          "verdict" => nil,
          "handled_at" => Time.now.to_i,
        ),
      )
      reviewable.perform(Discourse.system_user, :approve_post)
    end

    it "flags the approved post once, leaves it published, and drops a repeat" do
      approved_after_timeout
      post = published
      body = JSON.generate(support)
      deliver(body)
      expect(response.status).to eq(200)

      expect(support_flags(post.reload).count).to eq(1)
      expect(post).not_to be_hidden
      expect(post.deleted_at).to be_nil
      expect(reviewable.reload).to be_approved
      expect(notes).to include(a_string_including(after_note))
      expect(MinosModeration::Store.get(reviewable.id)).not_to have_key("support_due")
      # The flag's message to the moderators' group says when the verdict came.
      message = Post.where(topic: Topic.private_messages).order(:id).last
      expect(message&.raw.to_s).to include(flag_message)

      deliver(body)
      expect(response.status).to eq(200)
      expect(support_flags(post.reload).count).to eq(1)
      expect(notes.count { |content| content.include?(after_note) }).to eq(1)
    end

    it "flags a post a moderator approved while its verdict was on the way" do
      reviewable.perform(Discourse.system_user, :approve_post)
      deliver(JSON.generate(support))
      expect(response.status).to eq(200)
      post = published
      expect(support_flags(post).count).to eq(1)
      expect(post).not_to be_hidden
      expect(MinosModeration::Store.get(reviewable.id)).to include(
        "status" => "done",
        "outcome" => "resolved_elsewhere",
      )
      deliver(JSON.generate(support))
      expect(response.status).to eq(200)
      expect(support_flags(post.reload).count).to eq(1)
    end

    it "raises nothing without wsparcie" do
      approved_after_timeout
      before = reviewable.reload.reviewable_notes.count
      deliver(JSON.generate(support.merge("wsparcie" => false)))
      expect(response.status).to eq(200)
      expect(support_flags(published).count).to eq(0)
      expect(reviewable.reload.reviewable_notes.count).to eq(before)
      expect(published).not_to be_hidden
    end

    it "notes the signal on a post a moderator rejected, which stays rejected" do
      reviewable.perform(Discourse.system_user, :reject_post)
      deliver(JSON.generate(support))
      expect(response.status).to eq(200)
      expect(reviewable.reload).to be_rejected
      expect(reviewable.target_id).to be_nil
      expect(notes).to include(a_string_including(after_note))
    end

    it "notes the signal on a post a moderator edited in the queue, which stays held" do
      reviewable.update!(payload: reviewable.payload.merge("raw" => "Tekst poprawiony w kolejce."))
      deliver(JSON.generate(support))
      expect(response.status).to eq(200)
      expect(reviewable.reload).to be_pending
      expect(notes).to include(after_note)
      expect(MinosModeration::Store.get(reviewable.id)).to include("reason" => "edited")
    end
  end

  it "drops an id that is not a pending post of this forum, with 200" do
    ["k-1", "discourse:999999999.1", "discourse:0.1"].each do |id|
      expect_not_enqueued_with(job: :minos_apply_verdict) do
        deliver(JSON.generate(verdict.merge("id" => id)))
      end
      expect(response.status).to eq(200), id
    end
  end

  it "needs no login, even on a forum that requires one" do
    SiteSetting.login_required = true
    deliver(JSON.generate(verdict))
    expect(response.status).to eq(200)
  end

  describe "while the forum is read-only" do
    after { Discourse.disable_readonly_mode }

    # The gateway counts any 2xx as delivered and keeps no verdict, so a delivery the forum
    # cannot store must never get one: Discourse's own read-only filter answers 503 to a
    # POST, the delivery is retried, and nothing changes meanwhile.
    it "refuses a delivery with 503, which the gateway retries, and stores nothing" do
      Discourse.enable_readonly_mode
      expect_not_enqueued_with(job: :minos_apply_verdict) { deliver(JSON.generate(verdict)) }
      expect(response.status).to eq(503)
      expect(status).to eq("submitted")
    end

    it "takes the same delivery once the forum can write again" do
      Discourse.enable_readonly_mode
      deliver(JSON.generate(verdict))
      Discourse.disable_readonly_mode
      deliver(JSON.generate(verdict))
      expect(response.status).to eq(200)
      expect(status).to eq("received")
    end
  end

  # Shared plugin rule F10: `PluginStore.set` answers `false` for a row it did not save. A
  # verdict the plugin could not store gets no 2xx, so the gateway delivers it again.
  it "answers 500, not 2xx, when the verdict could not be saved" do
    allow(PluginStore).to receive(:set).and_call_original
    allow(PluginStore).to receive(:set).with(
      MinosModeration::PLUGIN_NAME,
      "pending:#{reviewable.id}",
      anything,
    ).and_return(false)
    expect_not_enqueued_with(job: :minos_apply_verdict) { deliver(JSON.generate(verdict)) }
    expect(response.status).to eq(500)
    expect(status).to eq("submitted")
  end

  it "does not answer while the plugin is disabled" do
    SiteSetting.minos_enabled = false
    deliver(JSON.generate(verdict))
    expect(response.status).to eq(404)
  end
end
