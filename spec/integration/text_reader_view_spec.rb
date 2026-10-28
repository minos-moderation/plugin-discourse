# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# The text sent for assessment is the text a reader sees. Each post of the corpus
# (`spec/fixtures/reader_view.json`, invented text only) is rendered by Discourse itself
# (`PrettyText.cook`, its markdown-it rules, BBCode and sanitizer), and every word a reader
# can see there must occur in what the plugin sends. The property is one way: sending more
# than the reader sees is allowed (an attribute, a comment's text), dropping a word never.
RSpec.describe "The text sent for a post, against Discourse's own rendering" do
  corpus =
    JSON.parse(
      File.read(File.expand_path("../fixtures/reader_view.json", __dir__), encoding: "UTF-8"),
    )

  # Elements a browser shows on lines of their own.
  let(:blocks) do
    %w[aside blockquote br dd details div dl dt h1 h2 h3 h4 h5 h6 hr li ol p pre summary ul]
  end

  # Discourse's own words around the author's: the poll's vote count, the quote's controls.
  let(:chrome) { ".poll-info, .quote-controls" }

  # The text a reader sees in cooked HTML: the text nodes, image alt texts and titles, and
  # tooltips, with a line break around every block.
  def reader_view(html)
    fragment = Nokogiri::HTML5.fragment(html)
    fragment.css(chrome).each(&:remove)
    shown = +""
    visit = lambda do |node|
      if node.text?
        shown << node.text
        next
      end
      block = node.element? && blocks.include?(node.name)
      shown << "\n" if block
      if node.element?
        shown << " #{node["alt"]} " if node.name == "img"
        shown << " #{node["title"]} " if node["title"]
      end
      node.children.each { |child| visit.call(child) }
      shown << "\n" if block
    end
    visit.call(fragment)
    shown
  end

  # The words of a text as a reader perceives them: invisible characters do not split
  # them, and compatibility forms are the letters they show.
  def words(shown)
    shown.unicode_normalize(:nfkc).gsub(/\p{Default_Ignorable_Code_Point}/, "").scan(
      /[\p{L}\p{M}\p{N}]+/,
    )
  end

  it "has the corpus the audit named, and more" do
    expect(corpus.size).to be >= 14
  end

  corpus.each do |entry|
    it "sends every word a reader sees: #{entry["name"]}" do
      cooked = PrettyText.cook(entry["raw"])
      seen = words(reader_view(cooked))
      # A rendering that shows nothing would pass without checking anything.
      expect(seen).not_to be_empty, "nothing visible in #{cooked.inspect}"

      sent = MinosModeration::Text.for_submission(entry["raw"])[:text].unicode_normalize(:nfkc)
      missing = seen.reject { |word| sent.include?(word) }
      expect(missing).to eq([]),
      "Discourse shows #{cooked.inspect}; the plugin sends #{sent.inspect}"
    end
  end
end
