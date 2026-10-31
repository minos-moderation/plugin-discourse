# frozen_string_literal: true

require "json"
require_relative "../../lib/minos_moderation/text" unless defined?(MinosModeration::Text)

# What the gateway is sent for a post, and how its masks come back onto the Markdown.
# Every sample is invented; no real post appears here.
RSpec.describe "MinosModeration::Text" do
  subject(:text) { MinosModeration::Text }

  let(:mask) { MinosModeration::Text::MASK }

  describe "a post with no text of its own (shared plugin rule F7)" do
    corpus =
      JSON.parse(
        File.read(File.expand_path("../fixtures/no_text.json", __dir__), encoding: "UTF-8"),
      )

    it "has both kinds of post, the review's nine probes among them" do
      expect(corpus.count { |entry| entry["sends"] == false }).to be >= 9
      expect(corpus.count { |entry| entry["sends"] == true }).to be >= 3
    end

    corpus.each do |entry|
      if entry["sends"]
        it "sends the post's own words: #{entry["name"]}" do
          sent = text.for_submission(entry["raw"])[:text]
          expect(entry["words"]).not_to be_empty
          entry["words"].each { |word| expect(sent).to include(word) }
        end
      else
        it "sends nothing, not even the title: #{entry["name"]}" do
          expect(text.for_submission(entry["raw"])[:text]).to eq("")
          expect(text.for_submission(entry["raw"], "Tytuł tematu")[:text]).to eq("")
        end
      end
    end

    it "keeps what it sends for a post with text: invisible characters change nothing else" do
      raw = "Zwykły tekst\u200B ![](upload://abc.png) dalej"
      expect(text.for_submission(raw)[:text]).to eq("Zwykły tekst  dalej")
      expect(text.for_submission("![opis](upload://abc.png) i tekst")[:text]).to eq("opis i tekst")
    end

    it "sends the text when the check itself fails: more, never less" do
      raw = %(<img src="upload://abc.png" alt="opis">)
      expect(text.for_submission(raw)[:text]).to eq("")
      own = MinosModeration::Text::OWN_MARKUP
      allow(MinosModeration::Text).to receive(:steps).and_wrap_original do |original, list, *rest, **options|
        raise RegexpError, "too long" if list.equal?(own)

        original.call(list, *rest, **options)
      end
      expect(text.for_submission(raw)[:text]).to eq("opis")
    end
  end

  describe "the text that is sent" do
    it "keeps every word a reader sees and drops only markup" do
      raw = <<~MD
        # Nagłówek

        Zwykły **pogrubiony** i ~~skreślony~~ tekst z `kodem`.
        > cytowana linia
        [quote="ktos, post:1, topic:2"]
        cytowane słowa
        [/quote]
        [details="Podsumowanie"]
        ukryta treść
        [/details]
        [spoiler]tajemnica[/spoiler] <!-- komentarz -->
        [opis](https://example.test/a) i ![alt obrazka|690x388](upload://abc.png)
        ```ruby
        puts 1
        ```
      MD
      sent = text.for_submission(raw)[:text]
      %w[
        Nagłówek pogrubiony skreślony kodem cytowana ktos cytowane Podsumowanie ukryta tajemnica
        opis https://example.test/a obrazka puts
      ].each { |word| expect(sent).to include(word) }
      markup = ["**", "~~", "`", "[quote", "[/details]", "![", "<!--", "post:1", "upload://", "```"]
      markup.each { |token| expect(sent).not_to include(token) }
      # An HTML comment is invisible: neither its markers nor its text are sent.
      expect(sent).not_to include("komentarz")
    end

    it "removes HTML tags in a word, keeping a tooltip after the word" do
      raw = %(zak<span title="podpowiedź">a</span>zane i <kbd>dalej</kbd>)
      expect(text.for_submission(raw)[:text]).to eq("zakazane podpowiedź i dalej")
    end

    it "sends nothing for a post that is markup only: it has no text to assess (F7)" do
      raw = "![](upload://abc.png)"
      expect(text.for_submission(raw)[:text]).to eq("")
    end

    it "sends nothing for a post without any text" do
      expect(text.for_submission(" \n\t ")[:text]).to eq("")
      expect(text.for_submission(nil)[:text]).to eq("")
    end

    it "cuts the text to its first 3000 characters, counting characters and not bytes" do
      raw = "ż" * 2999 + "ab" + "c" * 50
      sent = text.for_submission(raw)
      expect(sent[:text].length).to eq(3000)
      expect(sent[:text]).to eq("ż" * 2999 + "a")
      expect(sent[:truncated]).to be(true)
    end

    it "does not call a text of exactly 3000 characters truncated" do
      sent = text.for_submission("a" * 3000)
      expect(sent[:text].length).to eq(3000)
      expect(sent[:truncated]).to be(false)
    end

    it "trims the text, also at the cut" do
      raw = "  #{"a" * 2998}  \n  b"
      expect(text.for_submission(raw)[:text]).to eq("a" * 2998)
    end

    it "gives the same digest to the same text and another to another" do
      a = text.for_submission("pierwszy tekst")
      expect(text.for_submission("pierwszy tekst\r\n")[:digest]).to eq(a[:digest])
      expect(text.for_submission("drugi tekst")[:digest]).not_to eq(a[:digest])
    end

    it "reads invalid UTF-8 without raising" do
      expect(text.for_submission("zły \xFF bajt".b)[:text]).to include("zły")
    end
  end

  describe "the text a reader sees (spec/fixtures/reader_view.json)" do
    # The same corpus runs against Discourse's own rendering in
    # spec/integration/text_reader_view_spec.rb; here "reader" is what Discourse shows by
    # its source (markdown-it, the BBCode rules, the sanitizer), and "sent" what the plugin
    # sends for it.
    corpus =
      JSON.parse(
        File.read(File.expand_path("../fixtures/reader_view.json", __dir__), encoding: "UTF-8"),
      )

    # The words of a text as a reader perceives them: invisible characters do not split
    # them, and compatibility forms are the letters they show.
    def words(shown)
      shown.unicode_normalize(:nfkc).gsub(/\p{Default_Ignorable_Code_Point}/, "").scan(
        /[\p{L}\p{M}\p{N}]+/,
      )
    end

    it "has the corpus the audit named, and more" do
      expect(corpus.size).to be >= 14
      expect(corpus.map { |entry| entry["name"] }.uniq.size).to eq(corpus.size)
    end

    corpus.each do |entry|
      it "sends every word a reader sees: #{entry["name"]}" do
        sent = text.for_submission(entry["raw"])[:text]
        expect(sent).to eq(entry["sent"])
        seen = words(entry["reader"])
        expect(seen).not_to be_empty
        # Whole words: a word the reader sees whole must not reach the gateway split.
        missing = seen - words(sent)
        expect(missing).to eq([]), "#{entry["raw"].inspect} sends #{sent.inspect}"
      end
    end

    it "keeps a word split only by markup whole, as the reader sees it" do
      expect(text.for_submission("k&#117;rwa")[:text]).to eq("kurwa")
      expect(text.for_submission("zak<!-- -->azane")[:text]).to eq("zakazane")
      quote = text.for_submission("Zwykła odpowiedź [quote=Kasia, SLOWO_UKRYTE] koniec.")[:text]
      expect(quote).to include("SLOWO_UKRYTE").and include("koniec.")
    end
  end

  describe "HTML in a post" do
    def sent(raw)
      text.for_submission(raw)[:text]
    end

    it "leaves a line break for a block tag, and nothing for an inline one" do
      expect(sent("jeden<br>dwa<p>trzy</p>cztery")).to eq("jeden\ndwa\ntrzy\ncztery")
      expect(sent("<em>zak</em><strong>aza</strong><sup>ne</sup>")).to eq("zakazane")
    end

    it "keeps an image's alt text and title in place" do
      shown = sent(%(Zobacz <img alt="kot" title="mój kot"> tu))
      expect(shown).to start_with("Zobacz kot mój kot tu")
    end

    it "keeps a tooltip after the word it is on, and no other attribute" do
      expect(sent(%(<a href="https://e.test/x" class="c" title="podpowiedź">link</a> dalej))).to eq(
        "link podpowiedź dalej",
      )
      expect(sent(%(zak<abbr title="skrót">a</abbr>zane))).to eq("zakazane skrót")
      expect(sent(%(x<abbr title="k&#117;rwa">y</abbr>))).to eq("xy kurwa")
      expect(sent("<b>tekst</b> <slowo> <div title=\"ukryte\">z</div>")).to eq("tekst\nz")
      expect(sent(%(<span title="widoczna">z</span>))).to eq("z widoczna")
    end

    it "keeps pieces that follow one word apart from each other" do
      expect(sent(%(a <abbr title="x"></abbr><abbr title="y"></abbr> b))).to eq("a x y b")
      expect(sent(%(z<abbr title="x">a</abbr>[k](https://e.test)u dalej))).to eq(
        "zaku https://e.test x dalej",
      )
    end

    it "removes a comment with its text, which no reader sees" do
      expect(sent("przed <!-- ukryty komentarz --> po")).to eq("przed  po")
      expect(sent("a<!-->b")).to eq("ab")
      expect(sent("a <!-- nigdy nie zamknięty")).to eq("a <!-- nigdy nie zamknięty")
    end

    it "counts toward the limit only what is sent: no attribute, no comment" do
      raw = "#{"a" * 2950} <a href=\"https://e.test/#{"x" * 60}\">link</a><!-- #{"k" * 80} -->"
      result = text.for_submission(raw)
      expect(result[:text]).to eq("#{"a" * 2950} link")
      expect(result[:truncated]).to be(false)
    end

    it "leaves an escaped tag as text" do
      expect(sent(%(\\<b title="widoczny">x</b>))).to eq(%(\\<b title="widoczny">x))
    end
  end

  describe "code" do
    def sent(raw)
      text.for_submission(raw)[:text]
    end

    it "is sent as it is written: tags, comments, references and emphasis stay" do
      raw = %(`<b title="w kodzie">x</b> <!-- k --> &#117; *a*`)
      expect(sent(raw)).to eq(%(<b title="w kodzie">x</b> <!-- k --> &#117; *a*))
      fenced = "Tekst\n```html\n<span title=\"S\">x</span> &amp;\n```\nPo <b>kodzie</b>"
      expect(sent(fenced)).to eq("Tekst\nhtml\n<span title=\"S\">x</span> &amp;\n\nPo kodzie")
      indented = "Tekst\n\n    <i title=\"S\">x</i>\n\nakapit <i>a</i>"
      expect(sent(indented)).to eq("Tekst\n\n    <i title=\"S\">x</i>\n\nakapit a")
      expect(sent("[code]<u title=\"S\">x</u>[/code] <u>y</u>")).to eq("<u title=\"S\">x</u> y")
    end

    it "is read in a blockquote and in a list item, until its container ends" do
      quoted = "> ```\n> <b title=\"S\">x</b>\n> ```\npo <b>kodzie</b>"
      expect(sent(quoted)).to eq("<b title=\"S\">x</b>\n\npo kodzie")
      listed = "- ```\n  <b title=\"S\">x</b>\nzak<b>a</b>zane"
      expect(sent(listed)).to include("<b title=\"S\">x</b>").and end_with("zakazane")
    end

    it "loses the fence markers only; the line a fence-like marker starts stays" do
      expect(sent("```Ty SLOWO` i reszta\nkoniec")).to eq("Ty SLOWO` i reszta\nkoniec")
      expect(sent("Tekst\n~~~\n```SLOWO w kodzie\n~~~")).to eq("Tekst\n\nSLOWO w kodzie")
    end

    it "is closed only by a fence at the top, as markdown-it closes it" do
      %w[> \ \ \ \ -].map { |prefix| prefix.tr("\\", " ") }.uniq.each do |prefix|
        raw = "```\n#{prefix} ```\n[quote=Kasia, SLOWO]\ncytat\n[/quote]\n```"
        expect(sent(raw)).to include("[quote=Kasia, SLOWO]"), raw.inspect
      end
    end

    it "drops the space markdown-it trims at each end of a span, and no other" do
      expect(sent("zak` azane `")).to eq("zakazane")
      expect(sent("a ` b` c")).to eq("a  b c")
      expect(sent("a `  ` c")).to eq("a    c")
    end
  end

  describe "character references" do
    def sent(raw)
      text.for_submission(raw)[:text]
    end

    it "decodes them as a browser does, also a legacy name without its semicolon" do
      expect(sent("&lt;b&gt; &amp &AMP; &notit; &#x6B;&#X75;")).to eq("<b> & & ¬it; ku")
      expect(sent("&#150; &#0; &#1114112; &#xD800;")).to eq("– \uFFFD \uFFFD \uFFFD")
    end

    it "leaves what is no reference as it is written" do
      expect(sent("&bogus; & &#; &#x;")).to eq("&bogus; & &#; &#x;")
    end

    it "never lets a mask fall on a decoded character" do
      raw = "k&#117;rwa i kurwa"
      sent = text.for_submission(raw)[:text]
      expect(sent).to eq("kurwa i kurwa")
      expect(text.apply_masks(raw, sent, sent.sub("kurwa", mask * 5))).to be_nil
      masked = text.apply_masks(raw, sent, sent.sub(/kurwa\z/, mask * 5))
      expect(masked[:raw]).to eq("k&#117;rwa i #{mask * 5}")
    end
  end

  describe "characters a reader does not see" do
    it "go from the text and from the title" do
      sent = text.for_submission("zak\u00ADazane z\u200Bdanie", "Ty\u00ADtu\u2060ł")[:text]
      expect(sent).to eq("Tytuł\n\nzakazane zdanie")
    end

    it "go without hiding the characters around them from a mask" do
      raw = "zak\u00ADazane"
      sent = text.for_submission(raw)[:text]
      masked = text.apply_masks(raw, sent, mask * sent.length)
      expect(masked[:raw]).to eq("#{mask * 3}\u00AD#{mask * 5}")
    end
  end

  describe "emphasis" do
    def sent(raw)
      text.for_submission(raw)[:text]
    end

    it "removes single * and _ markers as markdown-it does, keeping an escaped one" do
      expect(sent("zak*a*zane i *całe słowo* i _podkreślone_")).to eq(
        "zakazane i całe słowo i podkreślone",
      )
      expect(sent("snake_case_name i 2 * 3 * 4")).to eq("snake_case_name i 2 * 3 * 4")
      expect(sent("zak\\*a\\*zane")).to eq("zak\\*a\\*zane")
    end

    it "carries a mask over the removed markers" do
      raw = "zak*a*zane"
      sent = text.for_submission(raw)[:text]
      expect(text.apply_masks(raw, sent, mask * 8)[:raw]).to eq("#{mask * 3}*#{mask}*#{mask * 4}")
    end
  end

  describe "a quote or details tag Discourse does not make a block of" do
    def sent(raw)
      text.for_submission(raw)[:text]
    end

    it "is sent as written inside code, an HTML block or another BBCode block" do
      inside_code = "```\n[quote=a, SLOWO]\nx\n[/quote]\n```"
      expect(sent(inside_code)).to eq("[quote=a, SLOWO]\nx\n[/quote]")
      inside_html = "<div>\n[quote=a, SLOWO]\nx\n[/quote]\n</div>"
      expect(sent(inside_html)).to include("[quote=a, SLOWO]")
      bounded = "[spoiler]\n[quote=a, SLOWO]\nx\n[/spoiler]\n[/quote]"
      expect(sent(bounded)).to include("[quote=a, SLOWO]").and include("[/quote]")
    end

    it "is sent as written when it heads a table" do
      raw = "[quote=Kasia, SLOWO|x]\n|---|---|\ncytat\n[/quote]"
      expect(sent(raw)).to eq(raw)
      after_table = "| a | b |\n|---|---|\n[quote=\"Kasia, post:1\"]\ncytat\n[/quote]"
      expect(sent(after_table)).to eq("| a | b |\n|---|---|\nKasia\n\ncytat")
    end

    it "is sent as written when text follows its closing tag, or it is indented" do
      expect(sent("[quote=a, SLOWO]x[/quote] dalej")).to eq("[quote=a, SLOWO]x[/quote] dalej")
      expect(sent("[quote=a, SLOWO]x[/quote] ")).to eq("[quote=a, SLOWO]x[/quote]")
      expect(sent("  [quote=a, SLOWO]\nx\n[/quote]")).to eq("[quote=a, SLOWO]\nx\n[/quote]")
    end

    it "is sent as written for an unquoted name in capitals, which Discourse does not look up" do
      expect(sent("[QUOTE=a, SLOWO]\nx\n[/QUOTE]")).to eq("[QUOTE=a, SLOWO]\nx\n[/QUOTE]")
      expect(sent("[QUOTE=\"a, post:1\"]\nx\n[/QUOTE]")).to eq("a\n\nx")
    end

    it "is a block on one line when the line ends with its closing tag" do
      expect(sent("[quote=\"a, post:1\"]cytat[/quote]")).to eq("a\ncytat")
    end

    it "is a block nested in another quote, and the outer one too" do
      raw = "[quote=\"a, post:1\"]\n[quote=\"b, post:2\"]\nx\n[/quote]\ny\n[/quote]"
      expect(sent(raw)).to eq("a\n\nb\n\nx\n\ny")
    end

    it "is not closed by a closing tag that closes a nested one" do
      raw = "[quote=a, SLOWO]\n[quote=b]\nx\n[/quote]"
      expect(sent(raw)).to eq("[quote=a, SLOWO]\nb\n\nx")
    end
  end

  describe "the links signals" do
    it "counts the links in the raw text" do
      raw = "a https://a.test/x [b](http://b.test) ![c](upload://c.png) www.d.test"
      expect(text.link_count(raw)).to eq(2)
      expect(text.link_count(nil)).to eq(0)
    end

    it "lists the hosts of links and images, once each, and no address or local file" do
      raw =
        "[a](https://WWW.Example.test/x) ![b](https://cdn.example.test/i.png) " \
          "https://www.example.test/y http://1.2.3.4/z https://user:pw@shop.example.test:8443/ " \
          "![c](upload://c.png) https://zażółć.example/ https://localhost/"
      expect(text.link_hosts(raw)).to eq(%w[www.example.test cdn.example.test shop.example.test])
    end
  end

  describe "quotes and images" do
    it "keeps the name a quote shows as its title, and nothing else of its attribute" do
      raw = "[quote=\"Jan Kowalski, post:3, topic:7, username:jkowal\"]\ncytat\n[/quote]\nok"
      sent = text.for_submission(raw)[:text]
      expect(sent).to eq("Jan Kowalski\n\ncytat\n\nok")
      %w[post:3 topic:7 username jkowal].each { |part| expect(sent).not_to include(part) }
    end

    it "keeps a display name with commas whole, as Discourse shows it in the quote's title" do
      raw = "[quote=\"ok, głupi chuju, post:3, topic:4, username:ktos\"]\ncytat\n[/quote]"
      sent = text.for_submission(raw)[:text]
      expect(sent).to eq("ok, głupi chuju\n\ncytat")
      %w[post:3 topic:4 username ktos].each { |part| expect(sent).not_to include(part) }
    end

    it "keeps all but the last segment when a display name has no post: segment" do
      raw = "[quote=\"ok, głupi chuju, username:ktos\"]\ncytat\n[/quote]"
      expect(text.for_submission(raw)[:text]).to eq("ok, głupi chuju\n\ncytat")
    end

    it "keeps only the first segment without username:, as Discourse shows only that" do
      raw = "[quote=\"ktos, post:3, topic:4\"]\ncytat\n[/quote]"
      expect(text.for_submission(raw)[:text]).to eq("ktos\n\ncytat")
    end

    it "sees the username: segment behind any Unicode space Discourse or JavaScript sees" do
      { "NBSP" => "\u00A0", "U+2003" => "\u2003", "U+FEFF" => "\uFEFF" }.each do |name, space|
        raw = "[quote=\"ok, głupi chuju,#{space}username:ktos\"]\ncytat\n[/quote]"
        expect(text.for_submission(raw)[:text]).to eq("ok, głupi chuju\n\ncytat"), name
      end
    end

    it "sees a post: segment behind an ideographic space (U+3000)" do
      raw = "[quote=\"ok, głupi chuju,\u3000post:3, topic:4, username:ktos\"]\ncytat\n[/quote]"
      expect(text.for_submission(raw)[:text]).to eq("ok, głupi chuju\n\ncytat")
    end

    it "falls back to the username when the display name is empty, as Discourse does" do
      # indexOf("post:3") finds the first segment, so the display name is empty and the
      # title is the value of username:.
      raw = "[quote=\"post:3, post:3, username:kurwa mać\"]\ncytat\n[/quote]"
      sent = text.for_submission(raw)[:text]
      expect(sent).to eq("kurwa mać\n\ncytat")
      masked = text.apply_masks(raw, sent, sent.sub("kurwa", mask * 5))[:raw]
      expect(masked).to eq(raw.sub("kurwa", mask * 5))
    end

    describe "a post: number as JavaScript reads and prints it" do
      def title_of(attribute)
        text.for_submission("[quote=\"#{attribute}\"]\ncytat\n[/quote]")[:text].delete_suffix(
          "\n\ncytat",
        )
      end

      it "misses a post: number above 2**53, which parseInt rounds, as Discourse does" do
        # parseInt gives 9007199254740992 and 1e20: indexOf finds no segment, so Discourse
        # shows every segment but the last.
        %w[9007199254740993 99999999999999999999].each do |number|
          attribute = "ok, post:#{number}, kurwa mać, username:x"
          expect(title_of(attribute)).to eq("ok, post:#{number}, kurwa mać"), number
        end
      end

      it "finds a post: number just under 2**53, which parseInt keeps exact" do
        attribute = "ok, kurwa mać, post:9007199254740991, username:x"
        expect(title_of(attribute)).to eq("ok, kurwa mać")
      end

      it "prints the double's shortest digits, as Number#toString does" do
        # 2**60 prints as 1152921504606847000 in JavaScript, not as its exact value.
        attribute = "ok, kurwa mać, post:1152921504606846976, username:x"
        expect(title_of(attribute)).to eq("ok, kurwa mać, post:1152921504606846976")
      end

      it "prints a number from 1e21 in exponent notation, as JavaScript does" do
        attribute = "a, b, post:1e+21, c, post:1000000000000000000000, username:x"
        expect(title_of(attribute)).to eq("a, b")
      end
    end

    it "sends a Unicode space in the title as the plain space Discourse shows" do
      raw = "[quote=\"a, b, post:\u00A07, username:x\"]\ncytat\n[/quote]"
      sent = text.for_submission(raw)[:text]
      expect(sent).to eq("a, b, post: 7\n\ncytat")
      masked = text.apply_masks(raw, sent, sent.sub("post: 7", mask * 7))[:raw]
      expect(masked).to eq(raw.sub("post:\u00A07", mask * 7))
    end

    it "joins the shown segments with a comma and a space, as Discourse shows them" do
      raw = "[quote=\"ok,głupi chuju, username:ktos\"]x[/quote]"
      sent = text.for_submission(raw)[:text]
      expect(sent).to eq("ok, głupi chuju\nx")
      # The joining ", " is made up: a mask on it cannot be carried back.
      expect(text.apply_masks(raw, sent, sent.sub(", ", mask * 2))).to be_nil
    end

    it "carries a mask anywhere in a quote's title back into its attribute" do
      raw = "[quote=\"ok, głupi chuju, post:3, topic:4, username:ktos\"]\ncytat\n[/quote]"
      sent = text.for_submission(raw)[:text]
      result = text.apply_masks(raw, sent, sent.sub("chuju", mask * 5))[:raw]
      expect(result).to eq(raw.sub("chuju", mask * 5))
    end

    it "keeps the name of a quote without quotation marks, apart from the quoted text" do
      expect(text.for_submission("[quote=ala, post:1]tekst[/quote]")[:text]).to eq("ala\ntekst")
    end

    it "keeps an image's title with its alt text, and not its address" do
      raw = %(Zobacz ![alt obrazka|690x388](https://cdn.example.test/a.png "tytuł obrazka") tu)
      sent = text.for_submission(raw)[:text]
      expect(sent).to eq("Zobacz alt obrazka tytuł obrazka tu")
    end

    it "carries a mask on a quote's name or an image's title back into the Markdown" do
      quote = %([quote="Zły Człowiek, post:1"]\ncytat\n[/quote]\n)
      raw = quote + %(![a](https://e.test/i "zły tytuł"))
      sent = text.for_submission(raw)[:text]
      masked = sent.gsub("Zły", mask * 3).gsub("zły", mask * 3)
      result = text.apply_masks(raw, sent, masked)[:raw]
      expect(result).to include(%([quote="#{mask * 3} Człowiek, post:1"]))
      expect(result).to include(%("#{mask * 3} tytuł"))
    end
  end

  describe "carrying masks back onto the Markdown" do
    # The masked Markdown of a reply (no title), or nil.
    def body_masks(raw, sent, masked)
      text.apply_masks(raw, sent, masked)&.fetch(:raw)
    end

    def verdict_for(raw, word)
      sent = text.for_submission(raw)[:text]
      [sent, sent.gsub(word) { mask * word.length }]
    end

    it "masks exactly the masked characters of a plain post" do
      raw = "to jest głupi pomysł, głupi"
      sent, masked = verdict_for(raw, "głupi")
      expect(body_masks(raw, sent, masked)).to eq(masked)
    end

    it "masks a word inside Markdown and keeps the markup around it" do
      raw = "# Tytuł\r\n\r\nTo jest **głupi** pomysł, [link](https://example.test)"
      sent, masked = verdict_for(raw, "głupi")
      result = body_masks(raw, sent, masked)
      expect(result).to eq(raw.sub("głupi", mask * 5))
    end

    it "masks a word that markup splits in two" do
      raw = "gł**upi** tekst"
      sent, masked = verdict_for(raw, "głupi")
      expect(body_masks(raw, sent, masked)).to eq("#{mask * 2}**#{mask * 3}** tekst")
    end

    it "masks only the occurrence the gateway masked" do
      raw = "kot i kot"
      sent = text.for_submission(raw)[:text]
      masked = "#{mask * 3} i kot"
      expect(body_masks(raw, sent, masked)).to eq(masked)
    end

    it "masks inside the assessed beginning of a truncated post" do
      raw = "zły " + "a" * 3100
      sent = text.for_submission(raw)[:text]
      masked = "#{mask * 3}#{sent[3..]}"
      result = body_masks(raw, sent, masked)
      expect(result).to start_with("#{mask * 3} a")
      expect(result.length).to eq(raw.length)
    end

    it "refuses a mask on a character the reduction made up" do
      raw = "[opis](https://example.test)"
      sent = text.for_submission(raw)[:text]
      masked = sent.sub(" ", mask)
      expect(body_masks(raw, sent, masked)).to be_nil
    end

    it "refuses a change that is not a mask" do
      raw = "to jest tekst"
      sent = text.for_submission(raw)[:text]
      expect(body_masks(raw, sent, sent.sub("tekst", "TEKST"))).to be_nil
    end

    it "refuses masks of another length" do
      raw = "to jest tekst"
      sent = text.for_submission(raw)[:text]
      expect(body_masks(raw, sent, "#{sent}#{mask}")).to be_nil
    end

    it "refuses when the post no longer reads as the text that was sent" do
      sent, masked = verdict_for("to jest głupi pomysł", "głupi")
      expect(body_masks("to jest inny pomysł", sent, masked)).to be_nil
    end

    it "refuses what is not text" do
      expect(body_masks("a", "a", nil)).to be_nil
      expect(body_masks(nil, "a", mask)).to be_nil
    end

    it "leaves the post as it is when nothing was masked" do
      raw = "**nic** tu nie ma"
      sent = text.for_submission(raw)[:text]
      expect(body_masks(raw, sent, sent)).to eq(raw)
    end

    # A mask can change how Markdown reads around it (`█` is a symbol, so a `**` next to it
    # may no longer open emphasis): the masked post must send the masked verdict, up to
    # emphasis markers the mask left standing.
    it "always produces Markdown whose sent text carries every mask of the verdict" do
      samples = [
        "a **b** c", "> cytat z **tym** słowem\n\nakapit", "[x](https://e.test) y **z**",
        "gł**up**i i ~~głupi~~", "# nagłówek\n\n* lista\n* **punkt**", "`kod` i kod",
      ]
      checked = 0
      samples.each do |raw|
        sent = text.for_submission(raw)[:text]
        sent.each_char.with_index do |char, index|
          next if char.match?(/\s/)

          masked = sent.dup
          masked[index] = mask
          result = body_masks(raw, sent, masked)
          next if result.nil?

          checked += 1
          resent = text.for_submission(result)[:text]
          expect(resent.delete("*~")).to eq(masked.delete("*~")), "#{raw.inspect} @#{index}"
        end
      end
      expect(checked).to be > 30, "almost every mask was refused: the property checks nothing"
    end
  end

  describe "a new topic's title" do
    it "is sent first, then a blank line, then the post" do
      sent = text.for_submission("Treść **pierwszego** posta.", "  Tytuł tematu ")
      expect(sent[:text]).to eq("Tytuł tematu\n\nTreść pierwszego posta.")
    end

    it "counts toward the 3000 characters" do
      sent = text.for_submission("b" * 3000, "Tytuł")
      expect(sent[:text]).to start_with("Tytuł\n\nbbb")
      expect(sent[:text].length).to eq(3000)
      expect(sent[:truncated]).to be(true)
    end

    it "changes the digest when only the title changes" do
      expect(text.for_submission("treść", "Tytuł A")[:digest]).not_to eq(
        text.for_submission("treść", "Tytuł B")[:digest],
      )
    end

    it "gets its own masks back, apart from the post's" do
      raw = "To **głupi** pomysł."
      title = "Głupi tytuł"
      sent = text.for_submission(raw, title)[:text]
      masked = sent.sub("Głupi", mask * 5).sub("głupi", mask * 5)
      result = text.apply_masks(raw, sent, masked, title: title)
      expect(result).to eq(raw: "To **#{mask * 5}** pomysł.", title: "#{mask * 5} tytuł")
    end

    it "refuses a mask on the blank line between them" do
      raw = "treść"
      sent = text.for_submission(raw, "Tytuł")[:text]
      masked = sent.sub("\n\n", mask * 2)
      expect(text.apply_masks(raw, sent, masked, title: "Tytuł")).to be_nil
    end

    it "never sends the title alone: a post with no text of its own sends nothing (F7)" do
      expect(text.for_submission("", "Sam tytuł")[:text]).to eq("")
      expect(text.for_submission("![](upload://abc.png)", "Sam tytuł")[:text]).to eq("")
      expect(text.for_submission("Treść", "Sam tytuł")[:text]).to eq("Sam tytuł\n\nTreść")
    end
  end
end
