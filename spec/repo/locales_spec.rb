# frozen_string_literal: true

require "yaml"
require_relative "../../lib/minos_moderation/decision" unless defined?(MinosModeration::Decision)
require_relative "../../lib/minos_moderation/metrics" unless defined?(MinosModeration::Metrics)

# The plugin speaks Polish only. Discourse falls back to `en`, so the `en` files carry the
# same Polish text as `pl_PL`, key for key (docs/development.md, "Locales"). Plain Ruby: it
# runs in the standalone tier and inside Discourse's harness alike.
RSpec.describe "The plugin's locale files" do
  let(:root) { File.expand_path("../..", __dir__) }

  def tree(kind, locale)
    path = File.join(root, "config/locales/#{kind}.#{locale}.yml")
    YAML.safe_load(File.read(path, encoding: "UTF-8")).fetch(locale)
  end

  def leaves(hash, prefix = nil)
    hash.flat_map do |key, value|
      name = [prefix, key].compact.join(".")
      value.is_a?(Hash) ? leaves(value, name) : [[name, value]]
    end
  end

  %w[server client].each do |kind|
    it "gives #{kind}.en.yml the same keys and Polish text as #{kind}.pl_PL.yml" do
      polish = tree(kind, "pl_PL")
      expect(leaves(polish)).not_to be_empty
      expect(tree(kind, "en")).to eq(polish)
    end
  end

  it "describes every site setting" do
    path = File.join(root, "config/settings.yml")
    settings = YAML.safe_load(File.read(path, encoding: "UTF-8")).fetch("plugins")
    expect(settings).not_to be_empty
    descriptions = tree("server", "pl_PL").fetch("site_settings")
    settings.each_key do |name|
      expect(descriptions[name].to_s).not_to be_empty, "#{name} has no description"
    end
  end

  it "has a text for every translation key the code names literally" do
    polish = tree("server", "pl_PL")
    sources = Dir.glob(File.join(root, "{lib,app}/**/*.rb"))
    keys =
      sources.flat_map do |file|
        File.read(file, encoding: "UTF-8").scan(/"(minos_moderation\.[a-z_.]+)"/).flatten
      end
    expect(keys).not_to be_empty, "no literal key found: the scan is broken"
    keys.uniq.each do |key|
      expect(polish.dig(*key.split("."))).to be_a(String), "#{key} has no text"
    end
  end

  it "has a text for every reason and action a decision may give" do
    texts = tree("server", "pl_PL").fetch("minos_moderation")
    (MinosModeration::Decision::REASONS - [:verdict]).each do |reason|
      expect(texts.dig("reasons", reason.to_s)).to be_a(String), "reason #{reason}"
    end
    actions =
      MinosModeration::Decision::ACTIONS.map(&:to_s) +
        %w[approve_unassessed approve_masked_unassessed]
    actions.each do |action|
      expect(texts.dig("actions", action)).to be_a(String), "action #{action}"
    end
  end

  it "has a text for every row and label of the administrator's report" do
    report = tree("server", "pl_PL").dig("reports", "minos_moderation")
    expect(report).to be_a(Hash)
    %w[title description seconds minutes no_data].each do |key|
      expect(report[key]).to be_a(String), key
    end
    %w[measure value].each { |key| expect(report.dig("labels", key)).to be_a(String), key }
    rows = MinosModeration::Metrics::ROWS.map(&:first)
    expect(rows).not_to be_empty
    rows.each { |row| expect(report.dig("rows", row)).to be_a(String), "row #{row}" }
  end

  it "has a text for every problem the dashboard may show" do
    problems = tree("server", "pl_PL").dig("minos_moderation", "problems")
    %w[
      invalid_url missing_key missing_secret refused unexpected disallowed_address daily_limit
      overloaded
    ].each do |key|
      expect(problems[key]).to be_a(String), key
    end
  end

  it "keeps to the rules of Discourse's i18n lint for the en files" do
    %w[server client].each do |kind|
      leaves(tree(kind, "en")).each do |key, value|
        text = value.to_s
        expect(text).not_to match(/\{\{(?!settings?:).+?\}\}/), "#{kind}: #{key} uses {{…}}"
        expect(text).not_to match(%r{href\s*=\s*["']/[^/]|\]\(/[^/]}i),
        "#{kind}: #{key} has a relative link without %{base_path}"
        expect(key.split(".").last).not_to match(/\A(zero|one|two|few|many|other)\z/),
        "#{kind}: #{key} is plural; Polish plurals do not fit the en file's one/other"
      end
    end
  end
end
