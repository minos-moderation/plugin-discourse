# frozen_string_literal: true

require "yaml"

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
