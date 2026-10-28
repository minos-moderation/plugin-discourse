# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# The admin dashboard's notice: what the administrator is told, and what never shows.
RSpec.describe MinosModeration::MinosGatewayProblem do
  subject(:check) { described_class.new }

  let(:key) { "wgb2b_klucz_testowy_0000000000000000" }
  let(:secret) { "sekret-testowy" }

  before do
    SiteSetting.minos_enabled = true
    SiteSetting.minos_api_key = key
    SiteSetting.minos_webhook_secret = secret
  end

  it "is registered with Discourse's problem checks" do
    expect(ProblemCheck.checks.map(&:identifier)).to include(:minos_gateway_problem)
  end

  it "stays silent while the plugin is disabled, or configured and never refused" do
    expect(check.call).to be_nil
    SiteSetting.minos_enabled = false
    SiteSetting.minos_api_key = ""
    expect(check.call).to be_nil
  end

  it "names a missing key and secret and an unusable gateway URL" do
    SiteSetting.minos_api_key = ""
    SiteSetting.minos_webhook_secret = ""
    SiteSetting.minos_gateway_url = "http://gateway.wergiliusz.app"
    message = check.call.message
    %w[minos_api_key minos_webhook_secret minos_gateway_url].each do |setting|
      expect(message).to include(setting)
    end
  end

  describe "a daily limit" do
    let(:now) { Time.utc(2026, 10, 28, 9, 30) }

    before do
      freeze_time(now)
      # As Submission records a 429 limit_dobowy_klucza with ponow_za_s 36000, although the
      # plugin's own retry pause is capped at 900 s.
      MinosModeration::Store.record_limit(
        reason: "daily_limit",
        until_at: now.to_i + 36_000,
        http: 429,
        code: "limit_dobowy_klucza",
      )
    end

    it "tells until when the gateway accepts nothing, from ponow_za_s and not the pause" do
      message = check.call.message
      expect(message).to include((now + 36_000).utc.strftime("%H:%M"))
      expect(message).not_to include((now + 900).utc.strftime("%H:%M"))
      expect(message).to include("limit_dobowy_klucza")
      expect(message).not_to include(key)
      expect(message).not_to include(secret)
    end

    it "is gone once that time has passed" do
      freeze_time(now + 36_001)
      expect(check.call).to be_nil
    end

    it "is gone once the gateway accepts a post again" do
      MinosModeration::Store.clear_problem
      expect(check.call).to be_nil
    end

    it "is shown together with a configuration refusal, which it never hides" do
      MinosModeration::Store.record_problem(reason: "refused", http: 403, code: "brak_webhooka")
      message = check.call.message
      expect(message).to include("brak_webhooka").and include("limit_dobowy_klucza")
    end
  end

  it "shows the gateway's last refusal with its status and code, never the key or secret" do
    MinosModeration::Store.record_problem(reason: "refused", http: 403, code: "brak_webhooka")
    message = check.call.message
    expect(message).to include("403").and include("brak_webhooka")
    expect(message).not_to include(key)
    expect(message).not_to include(secret)
  end
end
