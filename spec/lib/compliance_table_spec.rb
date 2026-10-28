# frozen_string_literal: true

# The compliance table of `docs/development.md` names every shared plugin rule of
# client-php's `docs/plugin-behaviour.md` (shared plugin rule D1), and no other: a rule
# added there without a row here fails, and so does a row for a rule that does not exist.
#
# Needs a checkout of `minos-moderation/client-php` in MINOS_CLIENT_PHP, like the mock
# gateway's spec. Without it the example is skipped, unless MINOS_REQUIRE_MOCK_GATEWAY=1
# (CI's standalone job) turns the skip into a failure.
RSpec.describe "The compliance table of the shared plugin rules" do
  # An identifier as the rules file writes it: a letter, a number, maybe a letter.
  let(:identifier) { /[A-Z][0-9]{1,2}[a-z]?/ }

  def rules_file
    dir = ENV.fetch("MINOS_CLIENT_PHP", "")
    if dir.empty?
      raise "MINOS_CLIENT_PHP is required here" if ENV["MINOS_REQUIRE_MOCK_GATEWAY"] == "1"

      skip "MINOS_CLIENT_PHP is not set: no shared rules to check against"
    end
    File.read(File.join(dir, "docs/plugin-behaviour.md"), encoding: "UTF-8")
  end

  # The rows of the table: the identifier in the first cell of a row.
  def rows(text)
    text.scan(/^\| `(#{identifier.source})` \|/).flatten
  end

  def table
    docs = File.read(File.expand_path("../../docs/development.md", __dir__), encoding: "UTF-8")
    section = docs[/^## Shared plugin rules: compliance\n(.*?)(?=^## )/m, 1]
    expect(section).not_to be_nil, "docs/development.md has no compliance section"
    section
  end

  it "maps every rule of client-php's file exactly once, and no rule it does not have" do
    rules = rules_file
    stated = rules.scan(/\*\*(#{identifier.source})\*\*/).flatten
    indexed = rows(rules[/^## Index\n.*/m].to_s)
    # A scan that finds nothing would pass silently: the file has at least the 24 rules
    # of 2026-09-30, each stated in bold once and listed in its index.
    expect(stated.size).to be >= 24
    expect(indexed).to match_array(stated)

    mapped = rows(table)
    expect(mapped.size).to eq(mapped.uniq.size), "a rule is mapped twice"
    expect(mapped).to match_array(stated)
  end

  it "gives every row a place in the code, a test or a named deviation" do
    rules_file
    table.each_line.grep(/^\| `#{identifier.source}` \|/).each do |row|
      cells = row.split(" | ")
      expect(cells.size).to be >= 3, row
      expect(cells.last.strip.delete_suffix("|").strip).not_to be_empty, row
    end
  end
end
