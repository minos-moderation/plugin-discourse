# frozen_string_literal: true

require "digest"
require "json"

module MinosModeration
  # The text of a post as the gateway sees it, and the way back from a masked verdict.
  #
  # **What is sent: the text a reader sees.** A new topic's title, a blank line, then the
  # raw Markdown reduced to what Discourse shows (see {MARKUP}); trimmed and cut to its
  # FIRST {MAX_CHARS} characters, the contract's limit per item. A reply has no title.
  # Nothing a reader can see is dropped: no text goes for being "only" a quote, a spoiler
  # or a summary, because removing it would let anyone smuggle words past the gateway
  # inside `[quote]…[/quote]`; and sending more than the reader sees is the safe direction
  # wherever removal is not certain. So:
  #
  # - a `[quote=…]` or `[details=…]` is a block only where Discourse makes it one (at the
  #   start of a line, with its closing tag; {block_tags}); anywhere else it is sent as
  #   it is written;
  # - HTML tags and comments go, so that `zak<b>a</b>zane` or `zak<!-- -->azane` reaches
  #   the gateway as the reader's one word; a block tag leaves a line break, an `<img>`
  #   its alt text and title. Whatever a tag or comment carried that a reader could
  #   still see somewhere (an attribute value, a tooltip, a comment's text, a tag shown as
  #   code) is added at the END of the text, after a blank line, instead of in the middle
  #   of a word;
  # - single `*` and `_` emphasis markers go, entities are decoded as a browser decodes
  #   them, and characters invisible by default (a soft hyphen, a zero-width space) go.
  #
  # **What comes back.** `ocenzurowany` masks the sent text one `█` per character. Every
  # sent character remembers the title or raw character it came from, so {apply_masks}
  # masks exactly those characters, and refuses (nil) whenever a mask falls on a character
  # the reduction made up (a decoded entity among them) or the sent text no longer
  # matches the post.
  #
  # Plain Ruby: no Rails, so the standalone tier runs it without Discourse. It reads one
  # data file next to it, `html_entities.json` (HTML's named character references).
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

    # BBCode tags whose markers go (the text between them stays). A quote's and a details'
    # go only where Discourse makes a block of them ({block_tags}).
    BBCODE = "spoiler|b|i|u|s|code|url|img|color|size|center|left|right"

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

    # markdown-it's `isWhiteSpace`: what may follow a BBCode block tag on its line.
    MD_WHITESPACE = /[\t\n\v\f\r \u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]/

    # The quotation marks Discourse's BBCode parser accepts around an attribute, as
    # opening and closing pairs (`QUOTATION_MARKS` in `bbcode-block.js`).
    BBCODE_QUOTES = [
      %w[" "], %w[' '], %w[« »], %w[“ ”], %w[” ”], %w[‘ ’], %w[„ “], %w[‚ ’], %w[‹ ›],
    ].freeze

    # `parseBBCodeTag` of `bbcode-block.js`, case 1: a closing tag.
    BBCODE_CLOSE = %r{\A\[/([-A-Za-z0-9_]+)\]}

    # Case 2: `[quote=…]` or `[details=…]` with an attribute not in quotation marks. The
    # name stays as typed: Discourse looks its rule up by this exact name.
    BBCODE_BARE_ATTRIBUTE =
      /\A\[(quote|details)=([#{JS_SPACE}]*[^#{BBCODE_QUOTES.flatten.uniq.join}][^\n\r\u2028\u2029]+?)\]/io

    # Case 3: any other opening tag, up to (not including) its "]". Linear in Ruby 3.3
    # (no backreference or lookaround), with a timeout all the same.
    BBCODE_TAG =
      Regexp.new(
        "\\A\\[(?:(?:[-A-Za-z0-9_]+(?:=(?:" \
          "#{BBCODE_QUOTES.map { |open, close| "#{open}[^#{close}]+#{close}" }.join("|")}" \
          "|[^#{JS_SPACE}\\]]+))?)+[#{JS_SPACE}]*)+",
        Regexp::IGNORECASE,
        timeout: 1.0,
      )

    # The plugin's own reading of a quote's and a details' opening tag.
    QUOTE_OPEN = /\[quote=(?:"([^"\]\n]*)"|([^\]\n]*))\]/i
    DETAILS_OPEN = /\[details=(?:"([^"\]\n]*)"|([^\]\n]*))\]/i
    BLOCK_BARE = %r{\[/?(?:quote|details)\]}i

    # A fence line of a code block, also inside a quote or a list item; group 1 is the
    # fence, group 2 what follows it.
    FENCE = /\A[ \t>]*(?:(?:[-+*]|\d{1,9}[.)])[ \t]+)?[ \t>]*(`{3,}|~{3,})(.*)\z/

    # The start of an HTML block (CommonMark's seven kinds, read generously).
    HTML_BLOCK = %r{\A {0,3}<[A-Za-z/!?]}

    # An HTML open or close tag as markdown-it's `html_re` reads one: group 1 the open
    # tag's name, group 2 its attributes, group 3 a close tag's name.
    ATTRIBUTE_NAME = "[a-zA-Z_:][a-zA-Z0-9:._-]*"
    ATTRIBUTE_VALUE = "(?:[^\"'=<>`\\x00-\\x20]+|'[^']*'|\"[^\"]*\")"
    ATTRIBUTE =
      "(?:[#{JS_SPACE}]+#{ATTRIBUTE_NAME}" \
        "(?:[#{JS_SPACE}]*=[#{JS_SPACE}]*#{ATTRIBUTE_VALUE})?)"
    HTML_TAG =
      Regexp.new(
        "<([A-Za-z][A-Za-z0-9-]*)((?:#{ATTRIBUTE})*)[#{JS_SPACE}]*/?>" \
          "|</([A-Za-z][A-Za-z0-9-]*)[#{JS_SPACE}]*>",
      )

    # One attribute of a tag: group 1 its name, group 2, 3 or 4 its value (unquoted, in
    # single or in double quotation marks).
    ATTRIBUTE_PARTS =
      Regexp.new(
        "[#{JS_SPACE}]+(#{ATTRIBUTE_NAME})(?:[#{JS_SPACE}]*=[#{JS_SPACE}]*" \
          "(?:([^\"'=<>`\\x00-\\x20]+)|'([^']*)'|\"([^\"]*)\"))?",
      )

    # An HTML comment, complete: `<!-->`, `<!--->`, or up to the first `-->` (group 1 its
    # text), as both markdown-it and Discourse's sanitizer end one.
    HTML_COMMENT = /<!--(?:-?>|(.*?)-->)/m

    # Tags Discourse's sanitizer keeps that a browser shows as a block: a removed one
    # leaves a line break. Any other tag goes without a trace, as an inline one does or as
    # the sanitizer removes one it does not allow.
    BLOCK_TAGS = %w[
      aside blockquote br dd details div dl dt h1 h2 h3 h4 h5 h6 hr li ol p pre summary ul
    ].freeze

    # HTML element names: a bare tag of one of these (no attributes) carries no word.
    KNOWN_TAGS = (
      BLOCK_TAGS +
        %w[
          a abbr address article audio b bdi bdo big button caption center cite code col
          colgroup del dfn em figcaption figure font footer form header i iframe img input
          ins kbd label legend main mark nav picture q rb rp rt ruby s samp section small
          source span strike strong sub sup table tbody td tfoot th thead tr track tt u var
          video wbr
        ]
    ).freeze

    # HTML's named character references, name (with or without its ";") => characters.
    ENTITIES =
      JSON.parse(File.read(File.join(__dir__, "html_entities.json"), encoding: "UTF-8")).freeze

    # A character reference: group 1 hexadecimal, group 2 decimal, group 3 a name.
    ENTITY = /&(?:#(?:[xX](\h{1,6})|(\d{1,7}));?|([A-Za-z][A-Za-z0-9]{0,31});?)/

    # The code points 0x80-0x9F a browser reads as Windows-1252 in `&#…;`.
    WINDOWS_1252 = {
      0x80 => 0x20AC, 0x82 => 0x201A, 0x83 => 0x0192, 0x84 => 0x201E, 0x85 => 0x2026,
      0x86 => 0x2020, 0x87 => 0x2021, 0x88 => 0x02C6, 0x89 => 0x2030, 0x8A => 0x0160,
      0x8B => 0x2039, 0x8C => 0x0152, 0x8E => 0x017D, 0x91 => 0x2018, 0x92 => 0x2019,
      0x93 => 0x201C, 0x94 => 0x201D, 0x95 => 0x2022, 0x96 => 0x2013, 0x97 => 0x2014,
      0x98 => 0x02DC, 0x99 => 0x2122, 0x9A => 0x0161, 0x9B => 0x203A, 0x9C => 0x0153,
      0x9E => 0x017E, 0x9F => 0x0178,
    }.freeze

    # Characters a reader does not see (a soft hyphen, zero-width spaces and joiners).
    INVISIBLE = /\p{Default_Ignorable_Code_Point}/

    # An HTML comment goes; its text, if any, to the end of the sent text.
    COMMENT_PARTS = ->(match) { match[1] ? [[:appendix, match.begin(1), match.end(1)]] : [] }

    # An HTML tag goes: a block tag leaves a line break, an `<img>` its alt text and title;
    # a tag with attributes or an unknown name is also added, as written, to the end.
    TAG_PARTS =
      lambda do |match|
        name = (match[1] || match[3]).downcase
        ops = name == "img" && match[1] ? image_parts(match) : []
        ops << [:text, "\n"] if BLOCK_TAGS.include?(name)
        unless KNOWN_TAGS.include?(name) && match[2].to_s.empty?
          ops << [:appendix, match.begin(0), match.end(0)]
        end
        ops
      end

    # A character reference becomes its characters, which have no origin (so a mask on
    # one is refused). Like a browser, a legacy name also decodes without its ";".
    ENTITY_PARTS =
      lambda do |match|
        next [[:text, code_point(Integer(match[1], 16))]] if match[1]
        next [[:text, code_point(Integer(match[2], 10))]] if match[2]

        name = match[3]
        exact = ENTITIES["#{name};"] if match[0].end_with?(";")
        next [[:text, exact]] if exact

        legacy = [name.length, 6].min.downto(2).map { |size| name[0, size] }.find do |prefix|
          ENTITIES.key?(prefix)
        end
        next [[:keep, match.begin(0), match.end(0)]] unless legacy

        [[:text, ENTITIES[legacy]], [:keep, match.begin(3) + legacy.length, match.end(0)]]
      end

    # The steps that run before the analysis of the text's blocks: line endings.
    LINE_ENDINGS = [
      [/\r(?=\n)/, []], # CRLF → LF
      [/\r/, ["\n"]], # a lone CR → LF
    ].freeze

    # The reduction from Markdown to plain text, step by step. Each step replaces a match
    # with its parts: an Integer is a capture group (kept, with its origin), a String is
    # made-up text (with no origin, so a mask on it cannot be carried back), a Hash
    # `{group: or span:, join:, before:, after:}` is a group, or the pieces a lambda picks
    # (joined with `join:`), kept with made-up text around them, only when not empty, and
    # `{appendix: group}` sends a group at the end of the text; a lambda returns operations
    # (`[:keep, from, to]`, `[:text, made_up]`, `[:appendix, from, to]`). A step with
    # `:block` leaves a match as it is unless {block_tags} found a Discourse block there.
    MARKUP = [
      [HTML_COMMENT, [COMMENT_PARTS]], # comments, with their text (it goes to the end)
      [HTML_TAG, [TAG_PARTS]], # tags (their attributes go to the end)
      [/^[ \t]*(?:```|~~~)[^\n]*/, []], # code fence lines (the code inside stays)
      [
        /!\[([^\]\n|]*)(?:\|[^\]\n]*)?\]\(\s*<?[^)\s>]*>?(?:\s+"([^"\n]*)")?\s*\)/,
        [1, { group: 2, before: " " }],
      ], # image → its alt text and its title (the URL goes; `link_hosts` reads it)
      [/\[([^\]\n]+)\]\(([^)\s]+)\)/, [1, " ", 2]], # link → its text and its URL
      [DETAILS_OPEN, [1, 2], :block], # details → its summary
      [QUOTE_OPEN, [{ span: QUOTE_TITLE, join: ", ", after: "\n" }], :block],
      # quote → the title Discourse shows (not `post:`, `topic:` or `username:`)
      [BLOCK_BARE, [], :block], # `[quote]`, `[details]` and the closing tags of blocks
      [%r{\[/?(?:#{BBCODE})(?:=([^\]\n]*))?\]}io, [{ appendix: 1 }]],
      # other BBCode tags (an attribute, such as `[color=…]`'s, goes to the end)
      [/^[ \t]{0,3}\#{1,6}[ \t]+/, []], # ATX heading markers
      [/^(?:[ \t]{0,3}>[ \t]?)+/, []], # blockquote markers
      [/\*\*|__|~~|`/, []], # strong, strike-through, inline code
      [/(?<![\\*])\*(?![#{JS_SPACE}*])([^*\n]*?[^#{JS_SPACE}*\\])\*(?!\*)/o, [1]], # *emphasis*
      [
        /(?<![\\_\p{Alnum}])_(?![#{JS_SPACE}_])([^_\n]*?[^#{JS_SPACE}_\\])_(?![_\p{Alnum}])/o,
        [1],
      ], # _emphasis_ (not inside a word, as markdown-it)
    ].freeze

    # The steps after the appendix is added, so that they reach it too.
    FINISH = [
      [ENTITY, [ENTITY_PARTS]], # character references → characters
      [INVISIBLE, []], # characters invisible by default
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
      # A title is plain text: only the characters a reader does not see go.
      shown = heading.each_index.reject { |i| INVISIBLE.match?(heading[i]) }
      heading, heading_origins =
        trim(heading.values_at(*shown), shown.map { |i| -1 - i })
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
      origins = (0...chars.length).to_a
      chars, origins = steps(LINE_ENDINGS, chars, origins)
      blocks = block_tags(chars.join, origins)
      appendix = []
      chars, origins = steps(MARKUP, chars, origins, blocks: blocks, appendix: appendix)
      chars, origins = append(chars, origins, appendix)
      chars, origins = steps(FINISH, chars, origins)
      trim(chars, origins)
    end

    # Runs steps of {MARKUP}'s shape over a text.
    #
    # @param blocks [Hash{Integer => Integer}] {block_tags}, for the steps marked `:block`.
    # @param appendix [Array, nil] collects `[chars, origins]` sent at the end.
    # @return [Array(Array<String>, Array<Integer, nil>)] the characters and their origins.
    def self.steps(list, chars, origins, blocks: {}, appendix: nil)
      list.each do |pattern, parts, guard|
        allowed = guard == :block ? ->(match, at) { block_tag?(match, at, blocks) } : nil
        chars, origins = replace(chars.join, chars, origins, pattern, parts, allowed, appendix)
      end
      [chars, origins]
    end

    # One step of {MARKUP}.
    #
    # @param allowed [Proc, nil] given the match and the origins, whether to replace it;
    #   a match it refuses stays as it is.
    # @param appendix [Array, nil] collects the pieces a step sends to the end.
    # @return [Array(Array<String>, Array<Integer, nil>)] the characters and their origins.
    def self.replace(text, chars, origins, pattern, parts, allowed = nil, appendix = nil)
      out_chars = []
      out_origins = []
      keep = lambda do |from, to|
        out_chars.concat(chars[from...to])
        out_origins.concat(origins[from...to])
      end
      made_up = lambda do |piece|
        out_chars.concat(piece.to_s.chars)
        out_origins.concat([nil] * piece.to_s.length)
      end
      to_end = lambda do |from, to|
        next unless appendix && chars[from...to].any? { |char| char.match?(/\S/) }

        appendix << [chars[from...to], origins[from...to]]
      end
      position = 0
      text.scan(pattern) do
        match = Regexp.last_match
        keep.call(position, match.begin(0))
        position = match.end(0)
        if allowed && !allowed.call(match, origins)
          keep.call(match.begin(0), match.end(0))
          next
        end

        parts.each do |part|
          if part.is_a?(Integer)
            keep.call(match.begin(part), match.end(part)) if match[part]
          elsif part.is_a?(Hash) && part.key?(:appendix)
            group = part[:appendix]
            to_end.call(match.begin(group), match.end(group)) if match[group]
          elsif part.is_a?(Hash)
            pieces =
              if part[:span]
                part[:span].call(match)
              elsif match[part[:group]]
                [[match.begin(part[:group]), match.end(part[:group])]]
              end
            next if pieces.nil? || pieces.all? { |from, to| to <= from }

            made_up.call(part[:before])
            pieces.each_with_index do |(from, to), index|
              made_up.call(part[:join]) unless index.zero?
              keep.call(from, to)
            end
            made_up.call(part[:after])
          elsif part.respond_to?(:call)
            part.call(match).each do |kind, *args|
              case kind
              when :keep
                keep.call(*args)
              when :text
                made_up.call(args.first)
              when :appendix
                to_end.call(*args)
              end
            end
          else
            made_up.call(part)
          end
        end
      end
      keep.call(position, chars.length)
      [out_chars, out_origins]
    end

    # Adds what a step sent to the end: after a blank line, one piece per line.
    #
    # @return [Array(Array<String>, Array<Integer, nil>)] the characters and their origins.
    def self.append(chars, origins, appendix)
      return [chars, origins] if appendix.empty?

      appendix.each_with_index do |(piece_chars, piece_origins), index|
        separator = index.zero? ? "\n\n" : "\n"
        chars += separator.chars + piece_chars
        origins += ([nil] * separator.length) + piece_origins
      end
      [chars, origins]
    end

    # An `<img>`'s alt text and title, in its place.
    #
    # @param match [MatchData] a {HTML_TAG} match of an open tag.
    # @return [Array<Array>] the operations of a {MARKUP} lambda.
    def self.image_parts(match)
      values = {}
      match[2].scan(ATTRIBUTE_PARTS) do
        attribute = Regexp.last_match
        name = attribute[1].downcase
        group = (2..4).find { |index| attribute[index] }
        next unless %w[alt title].include?(name) && group && !values.key?(name)

        offset = match.begin(2)
        values[name] = [offset + attribute.begin(group), offset + attribute.end(group)]
      end
      shown = values.values_at("alt", "title").compact.reject { |from, to| to <= from }
      shown.each_with_index.flat_map do |(from, to), index|
        index.zero? ? [[:keep, from, to]] : [[:text, " "], [:keep, from, to]]
      end
    end

    # @param number [Integer] the number of a `&#…;` reference.
    # @return [String] the character a browser shows for it: U+FFFD for none.
    def self.code_point(number)
      number = WINDOWS_1252.fetch(number, number)
      return "\uFFFD" if number.zero? || number > 0x10FFFF || (0xD800..0xDFFF).cover?(number)

      [number].pack("U")
    end

    # The `[quote]` and `[details]` tags Discourse makes blocks of, found the way its
    # `bbcode-block.js` finds them: an opening tag at the start of a line, followed either
    # by its closing tag at the very end of that line, or by nothing on that line and a
    # closing tag alone on a later one (nested tags of the same name counted). Anything
    # else is shown as it is written, and so it is sent.
    #
    # Where this reading is not sure, it reads no block, so the tag is sent as written,
    # which is more than the reader sees and never less: only a tag at the very first
    # column counts, never one in a code block, in an HTML block, inside another BBCode
    # block (other than a quote or details), or one the plugin's own regular expression
    # would read with another length.
    #
    # @param text [String] the text after its line endings were made "\n".
    # @param origins [Array<Integer, nil>] its characters' origins.
    # @return [Hash{Integer => Integer}] the origin of each such tag's "[" => its length.
    def self.block_tags(text, origins)
      lines = line_spans(text)
      # Each line's tag as a closing line reads it, once: the search for a block's end
      # then only looks the lines up.
      marks =
        lines.map do |from, to|
          line = text[from...to]
          indent = line[/\A[ \t]*/]
          next if columns(indent) >= 4 || line[indent.length] != "["

          bbcode_tag(line[indent.length..], true)&.merge(indent: indent.length)
        end
      found = {}
      walk_blocks(text, origins, lines, marks, opaque_lines(text, lines), 0, lines.size, found)
      found
    rescue Regexp::TimeoutError
      {}
    end

    # @return [Array<Array(Integer, Integer)>] each line's start and end (before "\n").
    def self.line_spans(text)
      spans = []
      start = 0
      loop do
        stop = text.index("\n", start) || text.length
        spans << [start, stop]
        break if stop >= text.length

        start = stop + 1
      end
      spans
    end

    # Lines where Discourse reads no BBCode block: fenced code (also in a quote or a list
    # item) and HTML blocks, each to its end or, generously, further.
    #
    # @return [Hash{Integer => true}] the lines' indexes.
    def self.opaque_lines(text, lines)
      line = ->(index) { text[lines[index][0]...lines[index][1]] }
      opaque = {}
      index = 0
      while index < lines.size
        fence = FENCE.match(line.call(index))
        last =
          if fence && !(fence[1].start_with?("`") && fence[2].include?("`"))
            closing =
              (index + 1...lines.size).find do |other|
                candidate = FENCE.match(line.call(other))
                candidate && candidate[1][0] == fence[1][0] &&
                  candidate[1].length >= fence[1].length && candidate[2].strip.empty?
              end
            closing || (lines.size - 1)
          elsif HTML_BLOCK.match?(line.call(index))
            html_block_end(line, lines.size, index)
          end
        if last
          (index..last).each { |covered| opaque[covered] = true }
          index = last + 1
        else
          index += 1
        end
      end
      opaque
    end

    # The last line of an HTML block: its end marker's line or the line before a blank
    # one, whichever comes later.
    #
    # @return [Integer] a line's index.
    def self.html_block_end(line, count, first)
      start = line.call(first)
      marker =
        case start
        when /\A {0,3}<!--/ then "-->"
        when /\A {0,3}<\?/ then "?>"
        when /\A {0,3}<!\[CDATA\[/ then "]]>"
        when /\A {0,3}<![A-Za-z]/ then ">"
        when /\A {0,3}<(script|pre|style|textarea)(?:[\s>]|\z)/i
          "</#{Regexp.last_match(1).downcase}>"
        end
      blank = (first + 1...count).find { |index| line.call(index).strip.empty? }
      last = blank ? blank - 1 : count - 1
      return last unless marker

      ending = (first...count).find { |index| line.call(index).downcase.include?(marker) }
      [last, ending || (count - 1)].max
    end

    # Reads the BBCode blocks of lines `first...last` into `found`, as Discourse's block
    # rule does at one level, and the blocks inside a quote or details one level down.
    #
    # @return [void]
    def self.walk_blocks(text, origins, lines, marks, opaque, first, last, found)
      index = first
      while index < last
        from, to = lines[index]
        line = text[from...to]
        indent = line[/\A[ \t]*/]
        opener = !opaque[index] && columns(indent) < 4 && line[indent.length] == "[" &&
          bbcode_tag(line[indent.length..], false)
        unless opener && !opener[:closing]
          index += 1
          next
        end

        after = indent.length + opener[:length]
        ours = indent.empty? && plugin_opener?(line, opener)
        inline = inline_close(line, opener[:tag], after)
        if inline
          start, length = inline
          if ours && start + length == line.length
            found[origins[from]] = opener[:length]
            found[origins[from + start]] = length
          end
          index += 1
          next
        end
        closing = blank_from?(line, after) && block_close(marks, opener[:tag], index + 1, last)
        unless closing
          index += 1
          next
        end

        close_line, close_indent, close_length = closing
        if ours
          found[origins[from]] = opener[:length]
          found[origins[lines[close_line][0] + close_indent]] = close_length
          walk_blocks(text, origins, lines, marks, opaque, index + 1, close_line, found)
        end
        # Any other block's content is left alone: nothing inside it counts as a block.
        index = close_line + 1
      end
    end

    # `parseBBCodeTag` of `bbcode-block.js`.
    #
    # @param text [String] from a "[" to the end of its line.
    # @param multiline [Boolean] whether only blanks may follow the tag on its line.
    # @return [Hash{Symbol => Object}, nil] `tag`, `closing`, `length`; nil for no tag.
    def self.bbcode_tag(text, multiline)
      if (match = BBCODE_CLOSE.match(text))
        return nil if multiline && !blank_from?(text, match.end(0))

        return { tag: match[1].downcase, closing: true, length: match.end(0) }
      end
      if (match = BBCODE_BARE_ATTRIBUTE.match(text))
        return nil if multiline && !blank_from?(text, match.end(0))

        return { tag: match[1], closing: false, length: match.end(0) }
      end
      match = BBCODE_TAG.match(text)
      return nil unless match && text[match.end(0)] == "]"
      return nil if multiline && !blank_from?(text, match.end(0) + 1)

      name = match[0][/\A\[([-A-Za-z0-9_]+)/, 1].downcase
      { tag: name, closing: false, length: match.end(0) + 1 }
    end

    # `findInlineCloseTag`: the closing tag the line ends with, past only blanks.
    #
    # @return [Array(Integer, Integer), nil] its start in the line and its length.
    def self.inline_close(line, tag, after)
      possible = false
      (line.length - 1).downto(after + 1) do |index|
        char = line[index]
        unless possible
          if char == "]"
            possible = true
            next
          end
          return nil unless MD_WHITESPACE.match?(char)

          next
        end
        next unless char == "["

        closing = bbcode_tag(line[index..], false)
        return [index, closing[:length]] if closing && closing[:closing] && closing[:tag] == tag
      end
      nil
    end

    # `findBlockCloseTag`: the line that closes a block, counting nested blocks of the
    # same name.
    #
    # @param marks [Array<Hash, nil>] each line's tag, read as on a closing line.
    # @return [Array(Integer, Integer, Integer), nil] the line's index, the closing tag's
    #   start in it and its length.
    def self.block_close(marks, tag, first, last)
      nesting = 0
      (first...last).each do |index|
        found = marks[index]
        next unless found && found[:tag] == tag

        if found[:closing]
          return [index, found[:indent], found[:length]] if nesting.zero?

          nesting -= 1
        else
          nesting += 1
        end
      end
      nil
    end

    # @return [Boolean] whether the plugin's own regular expression reads the same quote
    #   or details opening tag at the start of the line.
    def self.plugin_opener?(line, opener)
      patterns =
        case opener[:tag]
        when "quote" then [QUOTE_OPEN, /\[quote\]/i]
        when "details" then [DETAILS_OPEN, /\[details\]/i]
        else []
        end
      patterns.any? do |pattern|
        match = pattern.match(line)
        match && match.begin(0).zero? && match.end(0) == opener[:length]
      end
    end

    # @return [Boolean] whether a step's match is, unchanged, a tag {block_tags} found.
    def self.block_tag?(match, origins, blocks)
      start = match.begin(0)
      length = match.end(0) - start
      first = origins[start]
      return false unless first && blocks[first] == length

      (0...length).all? { |offset| origins[start + offset] == first + offset }
    end

    # @return [Boolean] whether a line has only blanks from a position on.
    def self.blank_from?(text, position)
      text[position..].to_s.each_char.all? { |char| MD_WHITESPACE.match?(char) }
    end

    # @return [Integer] the columns of a line's indentation, a tab to the next multiple of 4.
    def self.columns(indent)
      indent.each_char.reduce(0) do |column, char|
        char == "\t" ? column + 4 - (column % 4) : column + 1
      end
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

    private_class_method :submission, :reduce, :steps, :replace, :append, :image_parts,
                         :code_point, :block_tags, :line_spans, :opaque_lines,
                         :html_block_end, :walk_blocks, :bbcode_tag, :inline_close,
                         :block_close, :plugin_opener?, :block_tag?, :blank_from?, :columns,
                         :trim, :clean, :spaced, :js_number_string
  end
end
