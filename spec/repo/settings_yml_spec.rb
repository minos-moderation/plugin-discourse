# frozen_string_literal: true

require "yaml"
require_relative "../../lib/minos_moderation/decision" unless defined?(MinosModeration::Decision)

# The site settings an administrator can choose, read from `config/settings.yml` as
# Discourse reads it. Plain Ruby: it runs in the standalone tier and inside Discourse's
# harness alike.
RSpec.describe "The plugin's site settings" do
  let(:settings) do
    path = File.expand_path("../../config/settings.yml", __dir__)
    YAML.safe_load(File.read(path, encoding: "UTF-8")).fetch("plugins")
  end

  describe "minos_timeout_minutes" do
    let(:timeout) { settings.fetch("minos_timeout_minutes") }

    # The gateway tries to deliver a verdict for 15 minutes; the plugin waits longer, with a
    # margin for the sweeper's five-minute pass.
    let(:delivery_window_minutes) { 15 }

    it "never lets a post time out while the gateway may still deliver its verdict" do
      expect(timeout["min"]).to be_a(Integer)
      expect(timeout["min"]).to be >= delivery_window_minutes + 5
    end

    it "offers exactly the minimum the code enforces on a stored value" do
      floor = MinosModeration::Decision::MIN_TIMEOUT_MINUTES
      expect(timeout["min"]).to eq(floor)
      expect(MinosModeration::Decision.timeout_s(timeout["min"] - 4)).to eq(floor * 60)
    end

    it "has a default and a maximum the minimum allows" do
      expect(timeout["default"]).to be >= timeout["min"]
      expect(timeout["max"]).to be >= timeout["default"]
    end
  end
end
