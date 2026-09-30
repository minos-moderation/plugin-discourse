# frozen_string_literal: true

require "digest"

module MinosModeration
  # The text of a post as the gateway sees it, and the way back from a masked verdict.
  #
  # **What is sent.** A new topic's title, a blank line, then the raw Markdown with markup
  # tokens removed where that is cheap and certain (see {MARKUP}); trimmed and cut to its
  # FIRST {MAX_CHARS} characters, the contract's limit per item. A reply has no title.
  # No text a reader can see is dropped for being "only" a quote, a spoiler or a summary:
  # removing it would let anyone smuggle words past the gateway inside
  # `[quote]…[/quote]`. HTML is sent as it is, attributes included, for the same reason.
  #
  # **What comes back.** `ocenzurowany` masks the sent text one `█` per character. Every
  # sent character remembers the title or raw character it came from, so {apply_masks}
  # masks exactly those characters, and refuses (nil) whenever a mask falls on a character
  # the reduction made up or the sent text no longer matches the post.
  #
  # Plain Ruby: no Rails, so the standalone tier runs it without Discourse.
  module Text
    # The contract's limit for `elementy[].tekst`, in characters (not bytes).
    MAX_CHARS = 3000

    # The gateway's mask character, one per masked character.
    MASK = "█"

    # The contract's ceiling for an integer spam signal.
    MAX_SIGNAL = 100_000

    # A link as counted for the `links` signal: a scheme and what follows up to whitespace
    # or Markdown punctuation.
    LINK = %r{https?://[^\s<>()\[\]"']+}i

    # BBCode tags whose markers go (the text between them stays).
    BBCODE = "quote|details|spoiler|b|i|u|s|code|url|img|color|size|center|left|right"

    # The spaces `TextCleaner.normalize_whitespaces` turns into a plain space when
    # `PostCreator#setup_post` saves a post: Discourse renders the normalised text.
    DISCOURSE_SPACES = /[\u00A0\u1680\u180E\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]/

    # JavaScript's `\s` (and `parseInt`'s leading whitespace), which Ruby's ASCII `\s` is
    # not: the Unicode space separators, the line terminators and U+FEFF.
    JS_SPACE = "\\s\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF"

    # The separator of a quote's attribute, as `quotes.js` splits it: `/\,\s*/`.
    QUOTE_SEPARATOR = /,[#{JS_SPACE}]*/o

    # What Discourse shows as a quote's title, computed from the quote's attribute exactly
    # as its markdown-it quote rule does (`frontend/discourse-markdown-it/src/features/
    # quotes.js`), on the attribute as Discourse renders it (after the whitespace
    # normalisation above; each replaced character stays one character, so offsets hold):
    #
    # - split on `,\s*`; the username is the first segment;
    # - for every later segment: `post:` sets the post number (`parseInt`), `topic:` and
    #   `full:true` are skipped, and `username:` sets the display name to the segments
    #   before the first one equal to `post:<number>` (`indexOf`; all but the last when
    #   there is none, as `slice(0, -1)` does) joined with ", ", and the username to the
    #   rest of that segment;
    # - the title is the display name, or the username when the display name is empty.
    #
    # @return [Array<Array(Integer, Integer)>] the title's pieces as character offsets in
    #   the matched text, to be joined with ", "; empty when the title is empty.
    QUOTE_TITLE =
      lambda do |match|
        group = match[1] ? 1 : 2
        base = match.begin(group)
        attribute = match[group].to_s.gsub(DISCOURSE_SPACES, " ")
        segments = []
        position = 0
        attribute.scan(QUOTE_SEPARATOR) do
          separator = Regexp.last_match
          segments << [attribute[position...separator.begin(0)], position, separator.begin(0)]
          position = separator.end(0)
        end
        segments << [attribute[position..].to_s, position, attribute.length]
        texts = segments.map(&:first)
        piece = lambda do |index, skip = 0|
          [base + segments[index][1] + skip, base + segments[index][2]]
        end

        username = [piece.call(0)]
        display = nil
        post_number = "undefined"
        (1...texts.length).each do |index|
          text = texts[index]
          if text.start_with?("post:")
            digits = text[5..][/\A[#{JS_SPACE}]*([+-]?\d+)/o, 1]
            post_number = digits ? js_number_string(Float(digits)) : "NaN"
          elsif text.start_with?("topic:") || text.match?(/full:[#{JS_SPACE}]*true/o)
            next
          elsif text.start_with?("username:")
            found = texts.index("post:#{post_number}")
            display = (0...(found || (texts.length - 1))).map { |shown| piece.call(shown) }
            username = [piece.call(index, 9)]
          end
        end
        # `displayName || username`: an empty display name ("" in JavaScript) falls back.
        title = display && !texts[0...display.length].join(", ").empty? ? display : username
        title.all? { |from, to| to <= from } ? [] : title
      end

    # The reduction from Markdown to plain text, step by step. Each step replaces a match
    # with its parts: an Integer is a capture group (kept, with its origin), a String is
    # made-up text (with no origin, so a mask on it cannot be carried back), and a Hash
    # `{group: or span:, join:, before:, after:}` is a group, or the pieces a lambda picks
    # (joined with `join:`), kept with made-up text around them, only when not empty.
    MARKUP = [
      [/\r(?=\n)/, []], # CRLF → LF
      [/\r/, ["\n"]], # a lone CR → LF
      [/^[ \t]*(?:```|~~~)[^\n]*/, []], # code fence lines (the code inside stays)
      [
        /!\[([^\]\n|]*)(?:\|[^\]\n]*)?\]\(\s*<?[^)\s>]*>?(?:\s+"([^"\n]*)")?\s*\)/,
        [1, { group: 2, before: " " }],
      ], # image → its alt text and its title (the URL goes; `link_hosts` reads it)
      [/\[([^\]\n]+)\]\(([^)\s]+)\)/, [1, " ", 2]], # link → its text and its URL
      [/\[details=(?:"([^"\]\n]*)"|([^\]\n]*))\]/i, [1, 2]], # details → its summary
      [
        /\[quote=(?:"([^"\]\n]*)"|([^\]\n]*))\]/i,
        [{ span: QUOTE_TITLE, join: ", ", after: "\n" }],
      ], # quote → the title Discourse shows (not `post:`, `topic:` or `username:`)
      [%r{\[/?(?:#{BBCODE})(?:=[^\]\n]*)?\]}io, []], # other BBCode tags
      [/<!--|-->/, []], # comment markers (the commented text stays)
      [/^[ \t]{0,3}\#{1,6}[ \t]+/, []], # ATX heading markers
      [/^(?:[ \t]{0,3}>[ \t]?)+/, []], # blockquote markers
      [/\*\*|__|~~|`/, []], # strong, strike-through, inline code
      [/[ \t]+$/, []], # trailing blanks
      [/(\n\n)\n+/, [1]], # runs of blank lines
    ].freeze

    # Markdown reduced to the text a reader sees, where that is cheap.
    #
    # @param raw [String, nil] the post's raw Markdown.
    # @return [String] the plain text, trimmed.
    def self.plain(raw)
      reduce(raw).first.join
    end

    # The text the gateway assesses for one post.
    #
    # @param raw [String, nil] the post's raw Markdown.
    # @param title [String, nil] the topic's title, for the first post of a new topic.
    # @return [Hash{Symbol => Object}] `:text` (at most {MAX_CHARS} characters; empty only
    #   for a post without any text), `:truncated` (whether characters beyond the limit were
    #   left out, so a verdict covers only the beginning) and `:digest` (SHA-256 of the
    #   sent text, to notice a post edited in the queue after it was sent).
    def self.for_submission(raw, title = nil)
      chars, _origins, truncated = submission(raw, title)
      text = chars.join
      { text: text, truncated: truncated, digest: Digest::SHA256.hexdigest(text) }
    end

    # @param raw [String, nil] the post's raw Markdown.
    # @return [Integer] how many links it carries, capped at the contract's ceiling.
    def self.link_count(raw)
      [clean(raw).scan(LINK).size, MAX_SIGNAL].min
    end

    # The host names the post links to, images included, for the `link_domains` signal.
    #
    # Only plain ASCII names: an IP address is not a domain, and a name in Unicode is left
    # out rather than guessed into its ASCII form. Reducing a host to its registrable
    # domain needs the public suffix list, which is the caller's (`Submission`).
    #
    # @param raw [String, nil] the post's raw Markdown.
    # @return [Array<String>] distinct lowercase host names, in order of appearance.
    def self.link_hosts(raw)
      hosts =
        clean(raw).scan(LINK).filter_map do |url|
          host = url[%r{\Ahttps?://(?:[^@/\s]*@)?([^/:?#\s]+)}i, 1].to_s.downcase.chomp(".")
          host if host.ascii_only? && host.include?(".") && !host.match?(/\A[0-9.]+\z/)
        end
      hosts.uniq
    end

    # Carries the gateway's masks from the sent text back onto the title and the Markdown.
    #
    # @param raw [String] the post's raw Markdown, as it is now.
    # @param sent [String] the text that was sent for it ({for_submission}`[:text]`).
    # @param masked [String] the gateway's `ocenzurowany`.
    # @param title [String, nil] the topic's title, as it is now, for a new topic.
    # @return [Hash{Symbol => String}, nil] `:raw` and `:title` (nil without a title) with
    #   exactly the masked characters replaced by {MASK}; nil when the post no longer
    #   reduces to `sent`, when `masked` differs from `sent` other than by masks, or when a
    #   mask falls on a character with no origin. Nil means: do not publish, hold the post.
    def self.apply_masks(raw, sent, masked, title: nil)
      return nil unless [raw, sent, masked].all? { |value| value.is_a?(String) }
      return nil unless masked.valid_encoding? && sent.valid_encoding?

      chars, origins, _truncated = submission(raw, title)
      return nil unless chars.join == sent && masked.length == sent.length

      body = clean(raw).chars
      heading = clean(title).chars
      masked.each_char.with_index do |char, index|
        next if char == chars[index]

        origin = origins[index]
        return nil unless char == MASK && origin

        # Title characters carry negative origins: -1 is the title's first character.
        origin.negative? ? heading[-origin - 1] = MASK : body[origin] = MASK
      end
      { raw: body.join, title: title.nil? ? nil : heading.join }
    end

    # The sent text of a post, character by character, with each character's origin.
    #
    # @param raw [String, nil] the post's raw Markdown.
    # @param title [String, nil] the topic's title, for a new topic.
    # @return [Array] the characters, their origins (a position in the cleaned raw text;
    #   `-1 - i` for the title's character `i`; nil for made-up characters) and whether
    #   the text was cut.
    def self.submission(raw, title)
      chars, origins = reduce(raw)
      if chars.empty?
        # Markup only (an image without alt text, say): the raw text is sent rather than
        # nothing, because an empty item would refuse the whole request.
        chars = spaced(clean(raw))
        origins = (0...chars.length).to_a
        chars, origins = trim(chars, origins)
      end
      heading = spaced(clean(title))
      heading, heading_origins = trim(heading, (0...heading.length).map { |i| -1 - i })
      unless heading.empty?
        separator = chars.empty? ? [] : ["\n", "\n"]
        chars = heading + separator + chars
        origins = heading_origins + ([nil] * separator.size) + origins
      end
      truncated = chars.length > MAX_CHARS
      chars, origins = trim(chars.first(MAX_CHARS), origins.first(MAX_CHARS)) if truncated
      [chars, origins, truncated]
    end

    # Applies {MARKUP}, keeping each character's origin.
    #
    # @param raw [String, nil] the post's raw Markdown.
    # @return [Array(Array<String>, Array<Integer, nil>)] the characters and their origins.
    def self.reduce(raw)
      chars = spaced(clean(raw))
      text = chars.join
      origins = (0...chars.length).to_a
      MARKUP.each do |pattern, parts|
        chars, origins = replace(text, chars, origins, pattern, parts)
        text = chars.join
      end
      trim(chars, origins)
    end

    # One step of {MARKUP}.
    #
    # @return [Array(Array<String>, Array<Integer, nil>)] the characters and their origins.
    def self.replace(text, chars, origins, pattern, parts)
      out_chars = []
      out_origins = []
      position = 0
      text.scan(pattern) do
        match = Regexp.last_match
        out_chars.concat(chars[position...match.begin(0)])
        out_origins.concat(origins[position...match.begin(0)])
        parts.each do |part|
          if part.is_a?(Integer)
            next unless match[part]

            out_chars.concat(chars[match.begin(part)...match.end(part)])
            out_origins.concat(origins[match.begin(part)...match.end(part)])
          elsif part.is_a?(Hash)
            pieces =
              if part[:span]
                part[:span].call(match)
              elsif match[part[:group]]
                [[match.begin(part[:group]), match.end(part[:group])]]
              end
            next if pieces.nil? || pieces.all? { |from, to| to <= from }

            made_up = ->(text) { [text.to_s.chars, [nil] * text.to_s.length] }
            before, before_origins = made_up.call(part[:before])
            joiner, joiner_origins = made_up.call(part[:join])
            after, after_origins = made_up.call(part[:after])
            out_chars.concat(before)
            out_origins.concat(before_origins)
            pieces.each_with_index do |(from, to), index|
              out_chars.concat(joiner) unless index.zero?
              out_origins.concat(joiner_origins) unless index.zero?
              out_chars.concat(chars[from...to])
              out_origins.concat(origins[from...to])
            end
            out_chars.concat(after)
            out_origins.concat(after_origins)
          else
            out_chars.concat(part.chars)
            out_origins.concat([nil] * part.length)
          end
        end
        position = match.end(0)
      end
      [out_chars + chars[position..], out_origins + origins[position..]]
    end

    # Strips surrounding whitespace, keeping origins aligned.
    #
    # @return [Array(Array<String>, Array<Integer, nil>)] the characters and their origins.
    def self.trim(chars, origins)
      first = chars.index { |char| char.match?(/\S/) }
      return [[], []] unless first

      last = chars.rindex { |char| char.match?(/\S/) }
      [chars[first..last], origins[first..last]]
    end

    # The characters of a text as Discourse stores and shows it: `PostCreator#setup_post`
    # (and the title's cleaning) turn every character of {DISCOURSE_SPACES} into a plain
    # space. One character for one, so every character keeps its origin.
    #
    # @param text [String] a cleaned text.
    # @return [Array<String>] its characters, those spaces made plain.
    def self.spaced(text)
      text.chars.map { |char| DISCOURSE_SPACES.match?(char) ? " " : char }
    end

    # @param raw [String, nil] the post's raw Markdown.
    # @return [String] it as valid UTF-8.
    def self.clean(raw)
      raw.to_s.dup.force_encoding(Encoding::UTF_8).scrub("�")
    end

    # A number as JavaScript prints it in `post:${postNumber}`: `parseInt` gives a double,
    # and `Number#toString` writes its shortest round-trip digits — padded with zeros
    # below 1e21 (so 2**60 prints as 1152921504606847000, not its exact value), in
    # exponent notation from 1e21 (`1e+21`, `1.5e+22`).
    #
    # @param value [Float] the number `parseInt` read.
    # @return [String] its JavaScript spelling.
    def self.js_number_string(value)
      return "NaN" if value.nan?
      return value.positive? ? "Infinity" : "-Infinity" if value.infinite?
      return "0" if value.zero?

      sign = value.negative? ? "-" : ""
      # Ruby's Float#to_s also writes the shortest round-trip digits.
      text = value.abs.to_s
      if (form = text.match(/\A(\d)\.(\d+)e([+-]\d+)\z/))
        digits = "#{form[1]}#{form[2]}"
        exponent = Integer(form[3], 10)
      else
        whole = text.delete_suffix(".0")
        digits = whole
        exponent = whole.length - 1
      end
      digits = digits.sub(/0+\z/, "")
      digits = "0" if digits.empty?
      return "#{sign}#{digits}#{"0" * (exponent + 1 - digits.length)}" if exponent < 21

      mantissa = digits.length > 1 ? "#{digits[0]}.#{digits[1..]}" : digits
      "#{sign}#{mantissa}e+#{exponent}"
    end

    private_class_method :submission, :reduce, :replace, :trim, :clean, :spaced,
                         :js_number_string
  end
end
