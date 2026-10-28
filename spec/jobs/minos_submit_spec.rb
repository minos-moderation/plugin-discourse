# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# Sending one held post, and every kind of answer the contract names. No real post: the
# fabricated queued post carries invented text.
RSpec.describe Jobs::MinosSubmit do
  fab!(:reviewable) { Fabricate(:reviewable_queued_post) }

  let(:key) { "wgb2b_klucz_testowy_0000000000000000" }
  let(:endpoint) { "https://gateway.wergiliusz.app/api/v1/b2b/oceny" }
  let(:now) { Time.now.to_i }

  before do
    SiteSetting.minos_enabled = true
    SiteSetting.minos_api_key = key
    SiteSetting.minos_webhook_secret = "sekret-testowy"
    MinosModeration::Store.set(
      reviewable.id,
      {
        "status" => "queued",
        "queued_at" => now,
        "retry_at" => now,
        "attempts" => 0,
        "core_hold" => nil,
      },
    )
  end

  def entry
    MinosModeration::Store.get(reviewable.id)
  end

  def run_job
    described_class.new.execute(reviewable_id: reviewable.id)
  end

  def answer(status, blad = nil)
    body = blad ? { "blad" => blad } : { "przyjete" => ["discourse:#{reviewable.id}.1"] }
    stub_request(:post, endpoint).to_return(status: status, body: body.to_json)
  end

  it "sends the text, the profile and two signals with the key, and nothing about the author" do
    sent = nil
    stub_request(:post, endpoint)
      .with(headers: { "X-Gateway-Key" => key, "Content-Type" => "application/json" })
      .to_return do |request|
        sent = request.body
        { status: 202, body: { "przyjete" => ["discourse:#{reviewable.id}.1"] }.to_json }
      end

    run_job

    item = JSON.parse(sent)["elementy"].sole
    expect(item["id"]).to eq("discourse:#{reviewable.id}.1")
    expected = MinosModeration::Text.for_submission(reviewable.payload["raw"])[:text]
    expect(item["tekst"]).to eq(expected)
    expect(item["profil"]).to eq("forum_adult")
    expect(item["meta"].keys).to contain_exactly("links", "author_first_post")

    author = reviewable.target_created_by
    personal = [author.email, author.username, author.id.to_s, author.ip_address.to_s]
    personal.reject(&:blank?).each do |value|
      expect(sent).not_to include("\"#{value}\""), "the body names the author"
    end
    expect(entry["status"]).to eq("submitted")
    expect(entry["text_digest"]).to be_present
  end

  it "sends the registrable domains the post links to" do
    image = "![x](https://cdn.example.co.uk/i.png)"
    reviewable.payload["raw"] = "Zobacz https://www.example.com/a i #{image}"
    reviewable.save!
    sent = nil
    stub_request(:post, endpoint).to_return do |request|
      sent = JSON.parse(request.body)
      { status: 202, body: "{}" }
    end
    run_job
    expect(sent["elementy"][0]["meta"]["link_domains"]).to eq(%w[example.com example.co.uk])
  end

  it "numbers every attempt in the item id" do
    ids = []
    stub_request(:post, endpoint).to_return do |request|
      ids << JSON.parse(request.body)["elementy"][0]["id"]
      { status: 503, body: { "blad" => { "kod" => "kolejka_niedostepna" } }.to_json }
    end
    run_job
    # After the pause the refusal set for every post (shared plugin rule F5a).
    freeze_time(2.minutes.from_now)
    MinosModeration::Store.set(reviewable.id, entry.merge("retry_at" => Time.now.to_i))
    run_job
    expect(ids).to eq(["discourse:#{reviewable.id}.1", "discourse:#{reviewable.id}.2"])
    expect(entry["attempt"]).to eq(2)
  end

  it "sends the profile the administrator chose" do
    SiteSetting.minos_profile = "forum_teen"
    stub =
      stub_request(:post, endpoint).with do |request|
        JSON.parse(request.body)["elementy"][0]["profil"] == "forum_teen"
      end
    stub.to_return(status: 202, body: "{}")
    run_job
    expect(stub).to have_been_requested.once
  end

  it "does not send an entry that is not due" do
    MinosModeration::Store.set(reviewable.id, entry.merge("retry_at" => now + 60))
    stub = answer(202)
    run_job
    expect(stub).not_to have_been_requested
    expect(entry["status"]).to eq("queued")
  end

  it "does not send a post a moderator already handled" do
    reviewable.perform(Discourse.system_user, :reject_post)
    stub = answer(202)
    run_job
    expect(stub).not_to have_been_requested
    expect(entry["status"]).to eq("done")
  end

  it "retries a full queue after the gateway's ponow_za_s" do
    answer(429, { "kod" => "kolejka_pelna", "komunikat" => "x", "ponow_za_s" => 30 })
    freeze_time
    expect_enqueued_with(
      job: :minos_submit,
      args: { reviewable_id: reviewable.id },
      at: 30.seconds.from_now,
    ) { run_job }
    expect(entry).to include("status" => "queued", "attempts" => 1)
    expect(entry["retry_at"]).to eq(Time.now.to_i + 30)
  end

  it "tells the administrator until when a full queue refuses, and still retries" do
    answer(429, { "kod" => "kolejka_pelna", "komunikat" => "x", "ponow_za_s" => 30 })
    freeze_time
    run_job
    expect(entry["status"]).to eq("queued")
    expect(MinosModeration::Store.limit).to include(
      "reason" => "overloaded",
      "until" => Time.now.to_i + 30,
      "kod" => "kolejka_pelna",
    )
  end

  describe "a daily limit that ends after the post's time-out" do
    before do
      answer(429, { "kod" => "limit_dobowy_klucza", "komunikat" => "x", "ponow_za_s" => 36_000 })
      freeze_time
    end

    it "applies the failure mode at once instead of retrying within 15 minutes" do
      expect_not_enqueued_with(job: :minos_submit) { run_job }
      expect(reviewable.reload).to be_pending
      expect(entry).to include("status" => "done", "outcome" => "leave", "reason" => "limit")
    end

    it "publishes the post at once under fail-open, open for a late verdict" do
      SiteSetting.minos_failure_mode = "fail-open"
      run_job
      expect(reviewable.reload).to be_approved
      expect(entry).to include("status" => "auto_published", "reason" => "limit")
    end

    it "records until when the gateway refuses, from ponow_za_s and not the capped pause" do
      run_job
      expect(MinosModeration::Store.limit).to include(
        "reason" => "daily_limit",
        "until" => Time.now.to_i + 36_000,
        "http" => 429,
        "kod" => "limit_dobowy_klucza",
      )
      expect(MinosModeration::Store.problem).to be_nil
    end

    it "sends nothing more until the limit ends, then forgets it once the gateway accepts" do
      run_job
      freeze_time(36_001.seconds.from_now)
      later = Time.now.to_i
      MinosModeration::Store.set(
        reviewable.id,
        { "status" => "queued", "queued_at" => later, "retry_at" => later, "attempts" => 0 },
      )
      accepting = answer(202)
      run_job
      expect(accepting).to have_been_requested.once
      expect(MinosModeration::Store.limit).to be_nil
      expect(MinosModeration::Store.pause).to be_nil
    end
  end

  it "retries a success other than 202 after a backoff, never as a configuration error" do
    answer(200)
    freeze_time
    run_job
    expect(entry).to include("status" => "queued", "retry_at" => Time.now.to_i + 60)
    expect(reviewable.reload).to be_pending
    expect(MinosModeration::Store.problem).to be_nil
  end

  describe "the pause every post shares after a refusal (shared plugin rule F5a)" do
    fab!(:second) { Fabricate(:reviewable_queued_post) }
    fab!(:third) { Fabricate(:reviewable_queued_post) }

    before do
      [second, third].each do |queued|
        MinosModeration::Store.set(
          queued.id,
          {
            "status" => "queued",
            "queued_at" => now,
            "retry_at" => now,
            "attempts" => 0,
            "core_hold" => nil,
          },
        )
      end
      freeze_time
    end

    def run_for(queued)
      described_class.new.execute(reviewable_id: queued.id)
    end

    def entry_of(queued)
      MinosModeration::Store.get(queued.id)
    end

    it "makes one request for three posts after a full queue, and defers the others to its end" do
      stub = answer(429, { "kod" => "kolejka_pelna", "komunikat" => "x", "ponow_za_s" => 30 })
      run_job
      expect_enqueued_with(
        job: :minos_submit,
        args: { reviewable_id: second.id },
        at: 30.seconds.from_now,
      ) { run_for(second) }
      run_for(third)

      expect(stub).to have_been_requested.once
      [second, third].each do |queued|
        expect(entry_of(queued)).to include(
          "status" => "queued",
          "retry_at" => Time.now.to_i + 30,
          "attempts" => 0,
        )
      end
    end

    it "gives the next posts the failure mode at once after a daily limit, without a request" do
      stub =
        answer(429, { "kod" => "limit_dobowy_klucza", "komunikat" => "x", "ponow_za_s" => 36_000 })
      [reviewable, second, third].each { |queued| run_for(queued) }

      expect(stub).to have_been_requested.once
      [reviewable, second, third].each do |queued|
        expect(entry_of(queued)).to include("status" => "done", "reason" => "limit")
        expect(queued.reload).to be_pending
      end
    end

    it "pauses after an unavailable queue" do
      stub = answer(503, { "kod" => "kolejka_niedostepna", "komunikat" => "x" })
      [reviewable, second, third].each { |queued| run_for(queued) }
      expect(stub).to have_been_requested.once
      expect(entry_of(third)).to include("status" => "queued", "retry_at" => Time.now.to_i + 60)
    end

    it "pauses after a network failure" do
      stub = stub_request(:post, endpoint).to_timeout
      [reviewable, second, third].each { |queued| run_for(queued) }
      expect(stub).to have_been_requested.once
      expect(entry_of(second)).to include("status" => "queued", "attempts" => 0)
    end

    it "lifts the pause and the limit when the administrator changes the key" do
      stub =
        answer(429, { "kod" => "limit_dobowy_klucza", "komunikat" => "x", "ponow_za_s" => 36_000 })
      run_job
      expect(MinosModeration::Store.pause).to be_present
      expect(MinosModeration::Store.limit).to be_present

      SiteSetting.minos_api_key = "wgb2b_inny_klucz_testowy_000000000000"
      expect(MinosModeration::Store.pause).to be_nil
      expect(MinosModeration::Store.limit).to be_nil
      answer(202)
      run_for(second)
      expect(entry_of(second)["status"]).to eq("submitted")
      expect(stub).to have_been_requested.once
    end

    it "sends again once the pause is over, and the next 202 lifts it" do
      stub =
        stub_request(:post, endpoint).to_return(
          {
            status: 429,
            body: { "blad" => { "kod" => "kolejka_pelna", "ponow_za_s" => 30 } }.to_json,
          },
          { status: 202, body: "{}" },
        )
      run_job
      run_for(second)
      expect(stub).to have_been_requested.once

      freeze_time(31.seconds.from_now)
      run_for(second)
      expect(stub).to have_been_requested.twice
      expect(entry_of(second)["status"]).to eq("submitted")
      expect(MinosModeration::Store.pause).to be_nil
    end
  end

  it "retries an unavailable queue after a backoff" do
    answer(503, { "kod" => "kolejka_niedostepna", "komunikat" => "x" })
    freeze_time
    run_job
    expect(entry).to include("status" => "queued", "retry_at" => Time.now.to_i + 60)
  end

  it "retries when the gateway cannot be reached" do
    stub_request(:post, endpoint).to_timeout
    run_job
    expect(entry["status"]).to eq("queued")
  end

  describe "a configuration error" do
    before { answer(403, { "kod" => "brak_webhooka", "komunikat" => "x" }) }

    it "leaves the post to the moderators under fail-closed and tells the administrator" do
      run_job
      expect(reviewable.reload).to be_pending
      expect(entry).to include("status" => "done", "outcome" => "leave", "reason" => "config")
      expect(MinosModeration::Store.problem).to include(
        "reason" => "refused",
        "http" => 403,
        "kod" => "brak_webhooka",
      )
    end

    it "publishes the post under fail-open, and keeps it open for a late verdict" do
      SiteSetting.minos_failure_mode = "fail-open"
      run_job
      expect(reviewable.reload).to be_approved
      expect(entry).to include("status" => "auto_published", "post_id" => reviewable.target_id)
    end

    it "leaves a post Discourse held itself to the moderators even under fail-open" do
      SiteSetting.minos_failure_mode = "fail-open"
      MinosModeration::Store.set(reviewable.id, entry.merge("core_hold" => "post_count"))
      run_job
      expect(reviewable.reload).to be_pending
      expect(entry).to include("status" => "done", "reason" => "core_hold")
    end

    it "logs the status and the code, never the key or the text" do
      logger = track_log_messages { run_job }
      logged = logger.warnings.join("\n")
      expect(logged).to include("403").and include("brak_webhooka")
      expect(logged).not_to include(key)
      expect(logged).not_to include(reviewable.payload["raw"])
    end
  end

  it "applies the failure mode at once when the key is missing, without sending" do
    SiteSetting.minos_api_key = ""
    stub = answer(202)
    run_job
    expect(stub).not_to have_been_requested
    expect(entry).to include("status" => "done", "reason" => "config")
  end

  it "forgets the last configuration problem once the gateway accepts" do
    MinosModeration::Store.record_problem(reason: "refused", http: 403, code: "brak_webhooka")
    answer(202)
    run_job
    expect(MinosModeration::Store.problem).to be_nil
  end
end
