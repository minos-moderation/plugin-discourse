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

  it "shows the gateway's last refusal with its status and code, never the key or secret" do
    MinosModeration::Store.record_problem(reason: "refused", http: 403, code: "brak_webhooka")
    message = check.call.message
    expect(message).to include("403").and include("brak_webhooka")
    expect(message).not_to include(key)
    expect(message).not_to include(secret)
  end
end
