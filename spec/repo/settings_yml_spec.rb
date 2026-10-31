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

  describe "the scope" do
    it "keeps every post in scope by default, so an upgraded forum stays moderated" do
      scope =
        MinosModeration::Decision.scope_settings(
          categories: settings.fetch("minos_categories")["default"],
          exempt_groups: settings.fetch("minos_exempt_groups")["default"],
          max_trust_level: settings.fetch("minos_max_trust_level")["default"],
        )
      expect(scope).to eq("categories" => [], "exempt_groups" => [], "max_trust_level" => 4)
      (0..4).each do |level|
        covered =
          MinosModeration::Decision.in_scope?(
            category_ids: [5],
            group_ids: [10 + level],
            trust_level: level,
            scope: scope,
          )
        expect(covered).to be(true), "trust level #{level}"
      end
    end

    it "uses Discourse's own list and trust level types" do
      expect(settings.fetch("minos_categories")["type"]).to eq("category_list")
      expect(settings.fetch("minos_exempt_groups")["type"]).to eq("group_list")
      expect(settings.fetch("minos_max_trust_level")["enum"]).to eq("TrustLevelSetting")
    end
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
