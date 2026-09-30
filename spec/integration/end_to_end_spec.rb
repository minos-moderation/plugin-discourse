# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# One post through the whole plugin: held, sent (the gateway stubbed), its verdict
# delivered to the webhook, applied. Every text is invented.
RSpec.describe "Minos moderation, end to end", type: :request do
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic)

  let(:secret) { "sekret-testowy-webhooka" }
  let(:endpoint) { "https://gateway.wergiliusz.app/api/v1/b2b/oceny" }
  let(:mask) { MinosModeration::Text::MASK }

  before do
    Jobs.run_immediately!
    SiteSetting.minos_enabled = true
    SiteSetting.minos_api_key = "wgb2b_klucz_testowy_0000000000000000"
    SiteSetting.minos_webhook_secret = secret
  end

  def hold(raw)
    stub_request(:post, endpoint).to_return(status: 202, body: "{}")
    result = NewPostManager.new(user, raw: raw, topic_id: topic.id).perform
    expect(result.action).to eq(:enqueued)
    result.reviewable
  end

  def item_id(reviewable)
    "discourse:#{reviewable.id}.#{MinosModeration::Store.get(reviewable.id)["attempt"]}"
  end

  def deliver(payload)
    body = JSON.generate(payload)
    post "/minos/webhook",
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json; charset=utf-8",
           "X-Wergiliusz-Podpis" => MinosModeration::Signature.sign(secret, body, Time.now.to_i),
         }
    expect(response.status).to eq(200)
  end

  it "publishes a post the gateway finds safe" do
    reviewable = hold("Dziękuję za pomocną odpowiedź w tym wątku.")
    deliver(
      "id" => item_id(reviewable),
      "status" => "ocenione",
      "kwalifikacja" => "bezpieczne",
      "kategorie" => [],
      "wsparcie" => false,
      "wersja" => nil,
    )
    expect(reviewable.reload).to be_approved
    expect(topic.posts.last.raw).to eq("Dziękuję za pomocną odpowiedź w tym wątku.")
  end

  it "publishes the masked text of a censored post" do
    reviewable = hold("To jest **głupi** pomysł, naprawdę.")
    sent = MinosModeration::Text.for_submission(reviewable.payload["raw"])[:text]
    deliver(
      "id" => item_id(reviewable),
      "status" => "ocenione",
      "kwalifikacja" => "ocenzurowane",
      "kategorie" => ["wulgaryzmy"],
      "ocenzurowany" => sent.sub("głupi", mask * 5),
      "wsparcie" => false,
      "wersja" => "3f0c9a41d2b7e8c5",
    )
    expect(reviewable.reload).to be_approved
    expect(topic.posts.last.raw).to eq("To jest **#{mask * 5}** pomysł, naprawdę.")
  end
end
