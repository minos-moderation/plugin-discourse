# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# The receiving checklist of the contract, over HTTP: raw body first, signature, parse,
# drop repeats, answer fast. No real post: the queued post carries invented text.
RSpec.describe MinosModeration::WebhooksController do
  fab!(:reviewable) { Fabricate(:reviewable_queued_post) }

  let(:secret) { "sekret-testowy-webhooka" }
  let(:item_id) { "discourse:#{reviewable.id}" }
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

  it "drops an id that is not a pending post of this forum, with 200" do
    ["k-1", "discourse:999999999", "discourse:0"].each do |id|
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

  it "does not answer while the plugin is disabled" do
    SiteSetting.minos_enabled = false
    deliver(JSON.generate(verdict))
    expect(response.status).to eq(404)
  end
end
