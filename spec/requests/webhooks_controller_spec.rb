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

  it "does not answer while the plugin is disabled" do
    SiteSetting.minos_enabled = false
    deliver(JSON.generate(verdict))
    expect(response.status).to eq(404)
  end
end
