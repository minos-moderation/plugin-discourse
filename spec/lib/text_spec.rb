# frozen_string_literal: true

require_relative "../../lib/minos_moderation/text" unless defined?(MinosModeration::Text)

# What the gateway is sent for a post, and how its masks come back onto the Markdown.
# Every sample is invented; no real post appears here.
RSpec.describe "MinosModeration::Text" do
  subject(:text) { MinosModeration::Text }

  let(:mask) { MinosModeration::Text::MASK }

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
        komentarz opis https://example.test/a obrazka puts
      ].each { |word| expect(sent).to include(word) }
      markup = ["**", "~~", "`", "[quote", "[/details]", "![", "<!--", "post:1", "upload://", "```"]
      markup.each { |token| expect(sent).not_to include(token) }
    end

    it "sends HTML as it is, attributes included, so nothing hides in them" do
      raw = %(<span title="ukryty tytuł">widoczny</span>)
      expect(text.for_submission(raw)[:text]).to eq(raw)
    end

    it "sends the raw text of a post that is markup only, rather than nothing" do
      raw = "![](upload://abc.png)"
      expect(text.for_submission(raw)[:text]).to eq(raw)
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
          expect(text.for_submission(result)[:text][index]).to eq(mask), "#{raw.inspect} @#{index}"
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

    it "sends the title alone when the post has no text at all" do
      expect(text.for_submission("", "Sam tytuł")[:text]).to eq("Sam tytuł")
    end
  end
end
