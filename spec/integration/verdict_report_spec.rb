# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# The administrator's report, through the public entries: posts are held and sent (the
# gateway stubbed), their verdicts delivered to the webhook, and the report Discourse
# serves at /admin/reports shows the times and the counts. Every text is invented.
RSpec.describe "The Minos report for administrators", type: :request do
  fab!(:admin)
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic)

  let(:secret) { "sekret-testowy-webhooka" }
  let(:key) { "wgb2b_klucz_testowy_0000000000000000" }
  let(:endpoint) { "https://gateway.wergiliusz.app/api/v1/b2b/oceny" }

  before do
    Jobs.run_immediately!
    SiteSetting.minos_enabled = true
    SiteSetting.minos_api_key = key
    SiteSetting.minos_webhook_secret = secret
    stub_request(:post, endpoint).to_return(status: 202, body: "{}")
  end

  def hold(raw)
    result = NewPostManager.new(user, raw: raw, topic_id: topic.id).perform
    expect(result.action).to eq(:enqueued)
    result.reviewable
  end

  def deliver(reviewable, payload)
    attempt = MinosModeration::Store.get(reviewable.id)["attempt"]
    body = JSON.generate({ "id" => "discourse:#{reviewable.id}.#{attempt}" }.merge(payload))
    post "/minos/webhook",
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json; charset=utf-8",
           "X-Wergiliusz-Podpis" => MinosModeration::Signature.sign(secret, body, Time.now.to_i),
         }
    expect(response.status).to eq(200)
  end

  def assessed(qualification)
    {
      "status" => "ocenione",
      "kwalifikacja" => qualification,
      "kategorie" => [],
      "wsparcie" => false,
      "wersja" => nil,
    }
  end

  def report_rows
    sign_in(admin)
    get "/admin/reports/#{MinosModeration::VerdictReport::NAME}.json"
    expect(response.status).to eq(200)
    response.parsed_body["report"]["data"].to_h { |row| [row["key"], row["y"]] }
  end

  it "shows the time from submission to verdict and the verdict counts, and no text" do
    freeze_time
    texts = [
      "Pierwsza zupełnie zwyczajna odpowiedź w temacie.",
      "Druga zupełnie zwyczajna odpowiedź w temacie.",
      "Trzecia zupełnie zwyczajna odpowiedź w temacie.",
    ]
    held = texts.map { |raw| hold(raw) }
    expect(held.map { |reviewable| MinosModeration::Store.get(reviewable.id)["status"] }).to all(
      eq("submitted"),
    )

    freeze_time(10.seconds.from_now)
    deliver(held[0], assessed("bezpieczne"))
    freeze_time(10.seconds.from_now)
    deliver(held[1], assessed("zablokowane"))
    freeze_time(20.seconds.from_now)
    deliver(held[2], { "status" => "nieocenione", "kwalifikacja" => nil })

    rows = report_rows
    expect(rows.keys).to eq(MinosModeration::Metrics::ROWS.map(&:first))
    expect(rows.values_at("bezpieczne", "zablokowane", "nieocenione", "ocenzurowane")).to eq(
      %w[1 1 1 0],
    )
    expect(rows["timed"]).to eq("3")
    seconds = ->(value) { I18n.t("reports.minos_moderation.seconds", sekundy: value) }
    expect(rows["p50"]).to eq(seconds.call(20))
    expect(rows["p95"]).to eq(seconds.call(40))

    texts.each { |raw| expect(response.body).not_to include(raw) }
    expect(response.body).not_to include(key)
    expect(response.body).not_to include(secret)
  end

  it "is listed for staff while the plugin is enabled, and served to staff only" do
    sign_in(admin)
    get "/admin/reports.json"
    types = response.parsed_body["reports"].map { |report| report["type"] }
    expect(types).to include(MinosModeration::VerdictReport::NAME)

    sign_in(user)
    get "/admin/reports/#{MinosModeration::VerdictReport::NAME}.json"
    expect(response.status).to eq(404)
  end
end
