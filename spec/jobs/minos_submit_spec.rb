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
    body = blad ? { "blad" => blad } : { "przyjete" => ["discourse:#{reviewable.id}"] }
    stub_request(:post, endpoint).to_return(status: status, body: body.to_json)
  end

  it "sends the text, the profile and two signals with the key, and nothing about the author" do
    sent = nil
    stub_request(:post, endpoint)
      .with(headers: { "X-Gateway-Key" => key, "Content-Type" => "application/json" })
      .to_return do |request|
        sent = request.body
        { status: 202, body: { "przyjete" => ["discourse:#{reviewable.id}"] }.to_json }
      end

    run_job

    item = JSON.parse(sent)["elementy"].sole
    expect(item["id"]).to eq("discourse:#{reviewable.id}")
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

    it "publishes the post under fail-open" do
      SiteSetting.minos_failure_mode = "fail-open"
      run_job
      expect(reviewable.reload).to be_approved
      expect(entry["outcome"]).to eq("approve")
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
