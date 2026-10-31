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
  # inside `[quote]…[/quote]`; and where removing something is not certain, it is sent.
  # So:
  #
  # - a `[quote=…]` or `[details=…]` is a block only where Discourse makes it one (at the
  #   start of a line, with its closing tag; {block_tags}); anywhere else it is sent as
  #   it is written; another BBCode tag's markers go only where Discourse pairs them;
  # - code (fenced, indented, between backticks, in `[code]`) is shown as it is written,
  #   so it is sent as it is written ({inline_reading}): only the fence markers and the
  #   backticks go; so is a bare link (markdown-it's linkify) and every line of an HTML
  #   block, where Markdown's own syntax is not read;
  # - everywhere else HTML tags and comments go, within one paragraph or HTML block, so
  #   that `zak<b>a</b>zane` or `zak<!-- -->azane` reaches the gateway as the reader's one
  #   word: a block tag leaves a line break, an image (`<img>` or Markdown's) its alt text
  #   and title in its place, apart from the words around it; a tooltip (a `title` the
  #   sanitizer keeps: {TOOLTIP_TAGS}) and a link's address, title and label follow the
  #   word they are in (a reference link only where the post defines its label);
  #   a comment's text and the attributes the sanitizer removes, which no reader sees,
  #   are not sent;
  # - emphasis markers go where markdown-it reads them as delimiters, entities are
  #   decoded as a browser decodes them, and characters invisible by default (a soft
  #   hyphen, a zero-width space) go.
  #
  # **A post with no text of its own sends nothing** (shared plugin rule F7): when what a
  # reader sees of the post, apart from images, videos, attachments, the address of a
  # link without a visible label and the alt texts, titles and tooltips that only go
  # next to other words, is invisible characters at most ({own_text?}), the text is empty
  # and the failure mode decides the post, its title included. A bare address the reader
  # sees is text. Where that check itself fails, the text is sent: more, never less.
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

    # BBCode tags whose markers go (the text between them stays) where Discourse renders
    # them: paired in one paragraph, or as a block. A quote's and a details' go only where
    # Discourse makes a block of them ({block_tags}).
    BBCODE = "spoiler|b|i|u|s|code|url|img|color|size|center|left|right"

    # One of them: group 1 "/" for a closing tag, group 2 its name.
    INLINE_BBCODE = %r{\[(/?)(#{BBCODE})(?:=[^\]\n]*)?\]}io

    # A bare link as markdown-it's inline linkify rule takes one, with linkify-it's
    # expressions (`linkify-it/lib/re.mjs`): a scheme not glued to a letter, a digit, one
    # of ".+-" or a backslash before it; a host of "pseudo letters" (not punctuation, a
    # space or a control character); a port; a path that stops at a blank, at "<" or
    # ">", and before a trailing "." "," ";" "!" "?" or unpaired bracket. markdown-it then
    # drops trailing "*" ({inline_scan}). Its characters are shown as they are written.
    LINKIFY_SPACE = "[\\p{Z}\\p{Cc}]"
    LINKIFY_LETTER = "(?:(?![<>\\uFF5C]|[\\p{Z}\\p{P}\\p{Cc}]).)"
    LINKIFY_DOMAIN =
      "(?:xn--[a-z0-9\\-]{1,59}|#{LINKIFY_LETTER}|" \
      "#{LINKIFY_LETTER}(?:-|#{LINKIFY_LETTER}){0,61}#{LINKIFY_LETTER})"
    LINKIFY_PATH =
      "(?:[/?#](?:(?!#{LINKIFY_SPACE}|[<>\\uFF5C]|[()\\[\\]{}.,\"'?!\\-;]).|" \
      "\\[(?:(?!#{LINKIFY_SPACE}|\\]).)*\\]|\\((?:(?!#{LINKIFY_SPACE}|\\)).)*\\)|" \
      "\\{(?:(?!#{LINKIFY_SPACE}|\\}).)*\\}|\"(?:(?!#{LINKIFY_SPACE}|\").)+\"|" \
      "'(?:(?!#{LINKIFY_SPACE}|').)+'|'(?=#{LINKIFY_LETTER}|-)|\\.{2,}[a-zA-Z0-9%/&]|" \
      "\\.(?!#{LINKIFY_SPACE}|\\.|\\z)|-+|,(?!#{LINKIFY_SPACE}|\\z)|;(?!#{LINKIFY_SPACE}|\\z)|" \
      "!+(?!#{LINKIFY_SPACE}|!|\\z)|\\?(?!#{LINKIFY_SPACE}|\\?|\\z))+|/)?"
    BARE_LINK =
      Regexp.new(
        "\\G(?<![A-Za-z0-9.+\\-\\\\])(?:https?|ftp)://" \
          "(?:(?:(?!#{LINKIFY_SPACE}|[@/\\[\\]()]).)+@)?" \
          "(?:#{LINKIFY_DOMAIN}\\.)*#{LINKIFY_DOMAIN}" \
          "(?::(?:6(?:[0-4]\\d{3}|5(?:[0-4]\\d{2}|5(?:[0-2]\\d|3[0-5])))|[1-5]?\\d{1,4}))?" \
          "(?=\\z|[<>\\uFF5C]|[\\p{Z}\\p{P}\\p{Cc}])" \
          "(?!-|_|:\\d|\\.-|\\.(?!\\z|[\\p{Z}\\p{P}\\p{Cc}]))" \
          "#{LINKIFY_PATH}",
        Regexp::IGNORECASE,
        timeout: 1.0,
      )

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
      /\A\[(quote|details)=([#{JS_SPACE}]*[^#{BBCODE_QUOTES.join}][^\n\r\u2028\u2029]+?)\]/io

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

    # A list item's marker: group 1 its indentation, group 2 the marker, group 3 the spaces
    # after it.
    LIST_ITEM = /\A( *)([-+*]|\d{1,9}[.)])( +|\z)/

    # A fence opening a code block, read after its container's indentation: group 1 the
    # spaces before it, group 2 the fence, group 3 what follows it.
    FENCE_OPEN = /\A( *)(`{3,}|~{3,})(.*)\z/

    # A fence closing a code block, as markdown-it closes one: at most three spaces, the
    # fence, nothing else.
    FENCE_CLOSE = /\A {0,3}(`{3,}|~{3,})[ \t]*\z/

    # A fence marker at the start of a line, also in a blockquote or after a list marker
    # (group 1 what precedes it); the marker goes, what follows it stays.
    FENCE_MARKER =
      /^((?:[ \t]{0,3}>[ \t]?)*(?:[ \t]*(?:[-+*]|\d{1,9}[.)])[ \t]+)?)[ \t]*(?:`{3,}|~{3,})/

    # A table's delimiter row (`|---|:---:|`): under a line, it makes that line a table
    # header, which no BBCode block can start.
    DELIMITER_ROW = /\A(?=[^|]*\|)(?=[^-]*-)[ \t|:-]+\z/

    # An ATX heading, which is a block of its own.
    ATX_HEADING = /\A {0,3}\#{1,6}(?:[ \t]|\z)/

    # A link reference definition (`[label]: /address "title"`, group 1 the label), which
    # markdown-it reads only where a paragraph could start, and which shows nothing. Its
    # address may stand on the next line: a label alone is read as one too, so that a
    # link to it is read as a link (which sends its words joined, never split).
    REFERENCE =
      /\A[ ]{0,3}\[((?:[^\[\]\\]|\\.)*[^\[\]\\\s](?:[^\[\]\\]|\\.)*)\]:
       (?:[ \t]*(?:<[^<>\n]*>|[^<\s]\S*)(?:[ \t]+(?:"[^"]*"|'[^']*'|\([^()]*\)))?)?[ \t]*\z/x

    # A definition's label alone, whose address is on the next line ({REFERENCE_DEST}).
    REFERENCE_LABEL = /\A {0,3}\[(?:[^\[\]\\]|\\.)*[^\[\]\\\s](?:[^\[\]\\]|\\.)*\]:[ \t]*\z/
    REFERENCE_DEST =
      /\A[ \t]*(?:<[^<>\n]*>|[^<\s]\S*)(?:[ \t]+(?:"[^"]*"|'[^']*'|\([^()]*\)))?[ \t]*\z/

    # A thematic break (`---`, `***`, `___`, spaces allowed between).
    HR = /\A {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})\z/

    # The underline of a setext heading, under a paragraph's line.
    SETEXT = /\A {0,3}(?:=+|-+)[ \t]*\z/

    # Tag names that start an HTML block of CommonMark's kind 6.
    HTML_BLOCK_NAMES = %w[
      address article aside base basefont blockquote body caption center col colgroup dd
      details dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1
      h2 h3 h4 h5 h6 head header hr html iframe legend li link main menu menuitem nav
      noframes ol optgroup option p param search section summary table tbody td tfoot th
      thead title tr track ul
    ].freeze

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

    # At a "<", what markdown-it's inline rules take whole: an autolink, an HTML tag or
    # comment.
    INLINE_HTML =
      Regexp.new(
        "\\G(?:<[A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\\x00-\\x20]*>|(?:#{HTML_TAG.source})" \
          "|<!--(?:-?>|.*?-->))",
        Regexp::MULTILINE,
      )

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

    # Tags whose `title` Discourse's sanitizer keeps, so that a reader sees it as a tooltip:
    # `a[title]` and `abbr[title]` (the default allow list, `allow-lister.js`),
    # `summary[title]` (the details plugin) and `span[title]` (the chat plugin's
    # transcripts). An `<img>`'s title is handled with its alt text.
    TOOLTIP_TAGS = %w[a abbr span summary].freeze

    # An HTML tag goes: a block tag leaves a line break, an `<img>` its alt text and title
    # in its place; a tooltip follows the word the tag is in, so it never splits a word
    # the reader sees whole. Any other attribute goes with the tag: Discourse's sanitizer
    # removes it or it is not text a reader sees (an `href`, a class).
    TAG_PARTS =
      lambda do |match|
        name = (match[1] || match[3]).downcase
        ops = []
        if match[1]
          values = attribute_values(match)
          if name == "img"
            shown = values.values_at("alt", "title").compact.reject { |from, to| to <= from }
            ops.concat(spaced_image(match, shown))
          elsif TOOLTIP_TAGS.include?(name) && values["title"]
            ops << [:after_word, *values["title"]]
          end
        end
        ops << [:text, "\n"] if BLOCK_TAGS.include?(name)
        ops
      end

    # A Markdown image becomes its alt text and title, apart from the words around it; a
    # reference's label follows the word after it (its address is not sent: `link_hosts`
    # reads it).
    IMAGE_PARTS =
      lambda do |match|
        shown = [match.offset(:alt)]
        if match[:title]
          from, to = match.offset(:title)
          shown << [from + 1, to - 1]
        end
        ops = spaced_image(match, shown.reject { |from, to| to <= from })
        ops << [:after_word, *match.offset(:label)] if match[:label]
        ops
      end

    # A Markdown link becomes its text; its address, its title (a tooltip) and its label
    # follow the word the link ends in, so that none of them splits a word.
    LINK_PARTS =
      lambda do |match|
        ops = [[:keep, *match.offset(:text)]]
        if match[:dest]
          from, to = match.offset(:dest)
          angle = match[:dest].start_with?("<") ? 1 : 0
          ops << [:after_word, from + angle, to - angle]
        end
        if match[:title]
          from, to = match.offset(:title)
          ops << [:after_word, from + 1, to - 1]
        end
        ops << [:after_word, *match.offset(:label)] if match[:label]
        ops
      end

    # {TAG_PARTS} for {own_text?}: a tag leaves only the line break of a block tag; an
    # image's alt text and title and a tooltip are not the post's own text.
    TAG_PARTS_OWN =
      lambda do |match|
        BLOCK_TAGS.include?((match[1] || match[3]).downcase) ? [[:text, "\n"]] : []
      end

    # {LINK_PARTS} for {own_text?}: a link is its visible text only.
    LINK_TEXT_ONLY = ->(match) { [[:keep, *match.offset(:text)]] }

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

    # A Markdown image as markdown-it's image rule reads one: its label (`inner`: the `alt`
    # text, then a Discourse size, `|690x400`), then an inline `(dest "title")`, a full
    # reference `[label]`, a collapsed one `[]`, or none (a shortcut). A reference is an
    # image only where the post defines its label ({image_shown?}).
    MD_IMAGE = /
      !\[(?<inner>(?<alt>[^\]\n|]*)(?:\|[^\]\n]*)?)\]
      (?:
        \(\s*
          (?<dest><(?:[^<>\n\\]|\\.)*>|(?:[^()\s\\]|\\.|\((?:[^()\s\\]|\\.)*\))*)
          (?:\s+(?<title>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^()\\]|\\.)*\)))?
        \s*\)
      | \[(?<label>(?:[^\[\]\\]|\\.)*)\]
      )?
    /x

    # A Markdown link as markdown-it's link rule reads one: its `text` (brackets in it
    # balanced, one level deep), then an inline `(dest "title")` (parentheses in the
    # address balanced, one level deep; the title in quotes or parentheses), a full
    # reference `[label]`, a collapsed one `[]`, or none (a shortcut). A reference is a
    # link only where the post defines its label ({link_shown?}).
    MD_LINK = /
      \[(?<text>(?:[^\[\]\\]|\\.|\[(?:[^\[\]\\]|\\.)*\])+)\]
      (?:
        \(\s*
          (?<dest><(?:[^<>\n\\]|\\.)*>|(?:[^()\s\\]|\\.|\((?:[^()\s\\]|\\.)*\))*)
          (?:\s+(?<title>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^()\\]|\\.)*\)))?
        \s*\)
      | \[(?<label>(?:[^\[\]\\]|\\.)*)\]
      )?
    /x

    # An autolink, `<scheme:…>`, which markdown-it shows without its brackets (not one it
    # refuses to link: `javascript:`, `vbscript:`, `file:`, `data:`). Group 1 the link.
    AUTOLINK =
      %r{
        (?<!\\)<
        ((?!(?:javascript|vbscript|file|data):)[A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\x00-\x20]*)
        >
      }ix

    # An inline `[code]` tag as `parseBBCodeTag` reads one (an attribute allowed), and the
    # closing tag `bbcode-inline.js` looks for, in any case.
    INLINE_CODE_OPEN = /\G\[code(?:=[^\]\n]*)?\]/i
    INLINE_CODE_CLOSE = %r{\[/code\]}i

    # The same, matched only where a scan stands.
    MD_IMAGE_AT = /\G#{MD_IMAGE}/
    MD_LINK_AT = /\G#{MD_LINK}/

    # A Markdown link with no text at all, `[](https://…)`, which markdown-it shows as an
    # empty anchor: nothing a reader sees ({own_text?}).
    EMPTY_LINK = /
      \[(?<text>)\]
      \(\s*
        (?<dest><(?:[^<>\n\\]|\\.)*>|(?:[^()\s\\]|\\.|\((?:[^()\s\\]|\\.)*\))*)
        (?:\s+(?<title>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^()\\]|\\.)*\)))?
      \s*\)
    /x

    # An attachment as Discourse's composer writes one, `[name|attachment](upload://…)`
    # and the file's size after it, `(12.3 KB)`: the file is not text to assess
    # ({own_text?}).
    ATTACHMENT = /
      \[(?<text>[^\[\]\n]*\|attachment)\]
      \(\s*(?<dest>[^()\s]*)\s*\)
      (?:[ \t]*\([ \t]*\d[\d.,\u00A0 \t]*[^\s()]{1,16}[ \t]*\))?
    /xi

    # A BBCode image, `[img]address[/img]`, which Discourse shows as an image: its address
    # is not text a reader sees ({own_text?}; the full reduction sends it, as written).
    BBCODE_IMAGE = %r{\[img(?:=[^\]\n]*)?\][^\n]*?\[/img\]}i

    # Lines that are Markdown's syntax and nothing else, which {own_text?} reads as no
    # text (outside code and HTML blocks, where they are shown as written): a thematic
    # break, a heading or a list item with nothing in it, a table's delimiter row and a
    # row of empty cells. Read last, after the other steps took the text out of them.
    EMPTY_BLOCKS = [
      /^[ \t]{0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$/, # a thematic break
      /^[ \t]{0,3}\#{1,6}[ \t]*$/, # an empty ATX heading
      /^[ \t]*(?:[-+*]|\d{1,9}[.)])[ \t]*$/, # an empty list item
      /^(?=[^|\n]*\|)[ \t|:-]*$/, # a delimiter row, or a table row of empty cells
    ].freeze

    # What does not make a post a text to assess (shared plugin rule F7): format and
    # control characters (a zero-width space, a soft hyphen, a word joiner, a byte order
    # mark), separators and white space, combining marks without a letter, and the fillers
    # that show as blanks (Hangul, Braille), as well as every character invisible by
    # default. Unicode classes, not `\s` alone, which is ASCII.
    NOT_TEXT = /
      [\p{Cf}\p{Z}\p{M}\p{Cc}\s\p{Default_Ignorable_Code_Point}\u115F\u1160\u3164\uFFA0\u2800]
    /x

    # What a backslash escapes in Markdown: ASCII punctuation.
    ESCAPABLE = /[!-\/:-@\[-`{-~]/

    # The steps that run before the analysis of the text's blocks: line endings.
    LINE_ENDINGS = [
      [/\r(?=\n)/, []], # CRLF → LF
      [/\r/, ["\n"]], # a lone CR → LF
    ].freeze

    # The reduction from Markdown to plain text, step by step. Each step replaces a match
    # with its parts: an Integer is a capture group (kept, with its origin), a String is
    # made-up text (with no origin, so a mask on it cannot be carried back), a Hash
    # `{group: or span:, join:, before:, after:}` is a group, or the pieces a lambda picks
    # (joined with `join:`), kept with made-up text around them, only when not empty; a
    # lambda returns operations (`[:keep, from, to]`, `[:text, made_up]`, `[:after_word,
    # from, to]`, which keeps the characters after the word the match is in). A step marked
    # `:block` leaves a match as it is unless {block_tags} found a Discourse block there;
    # one marked `:markdown` leaves a match that touches code or an HTML block's line
    # ({inline_reading}) as it is, and one marked `:emphasis` also a pair whose markers
    # markdown-it would not read as delimiters ({delimiters?}); one
    # marked `:dropped` replaces only what a code span shows nothing of. Markup a reader
    # sees as it is written (a lone `*`, an unpaired backtick) stays, so that it never
    # joins the words around it.
    MARKUP = [
      [/(?<!\\)#{HTML_COMMENT.source}/m, [], :inline_html], # comments, with their text
      [/(?<!\\)(?:#{HTML_TAG.source})/, [TAG_PARTS], :inline_html], # tags (not escaped ones)
      [FENCE_MARKER, [1]], # code fence markers (an info string stays)
      [MD_IMAGE, [IMAGE_PARTS], :image], # image → its alt text and title, not its URL
      [MD_LINK, [LINK_PARTS], :link], # link → its text, then its URL, title and label
      [AUTOLINK, [1], :markdown], # `<https://…>` → the link without its brackets
      [DETAILS_OPEN, [{ group: 1, after: "\n" }, { group: 2, after: "\n" }], :block],
      # details → its summary, on a line of its own
      [QUOTE_OPEN, [{ span: QUOTE_TITLE, join: ", ", after: "\n" }], :block],
      # quote → the title Discourse shows (not `post:`, `topic:` or `username:`)
      [BLOCK_BARE, [], :block], # `[quote]`, `[details]` and the closing tags of blocks
      [INLINE_BBCODE, [], :paired], # other BBCode tags, where Discourse pairs them
      [/^[ \t]{0,3}\#{1,6}[ \t]+/, []], # ATX heading markers
      [/^(?:[ \t]{0,3}>[ \t]?)+/, []], # blockquote markers
      [/[ \n`]/, [], :dropped], # a code span's backticks and the spaces markdown-it trims
      [
        /(?<!\\)\*\*(?![#{JS_SPACE}*])([^\n]*?[^#{JS_SPACE}*\\])\*\*/o,
        [1],
        :emphasis,
      ], # **strong**
      [/(?<!\\)~~(?![#{JS_SPACE}~])([^\n]*?[^#{JS_SPACE}~\\])~~/o, [1], :emphasis], # ~~struck~~
      [
        /(?<![\\_\p{Alnum}])__(?![#{JS_SPACE}_])([^\n]*?[^#{JS_SPACE}_\\])__(?![_\p{Alnum}])/o,
        [1],
        :emphasis,
      ], # __strong__
      [
        /(?<![\\*])\*(?![#{JS_SPACE}*])([^*\n]*?[^#{JS_SPACE}*\\])\*(?!\*)/o,
        [1],
        :emphasis,
      ], # *emphasis*
      [
        /(?<![\\_\p{Alnum}])_(?![#{JS_SPACE}_])([^_\n]*?[^#{JS_SPACE}_\\])_(?![_\p{Alnum}])/o,
        [1],
        :emphasis,
      ], # _emphasis_ (not inside a word, as markdown-it)
      [ENTITY, [ENTITY_PARTS], :entity], # character references → characters
      [INVISIBLE, []], # characters invisible by default
      [/[ \t]+$/, []], # trailing blanks
      [/(\n\n)\n+/, [1]], # runs of blank lines
    ].freeze

    # {MARKUP} as {own_text?} reads it: what a reader sees of the post itself. Images (with
    # their alt texts and titles), BBCode images, attachments, empty links and a link's
    # address, title and label go; a tag keeps no alt text or tooltip.
    OWN_MARKUP =
      MARKUP
        .flat_map do |step|
          pattern, parts, guard = step
          if parts == [TAG_PARTS]
            [[pattern, [TAG_PARTS_OWN], guard]]
          elsif parts == [IMAGE_PARTS]
            [[pattern, [], guard], [EMPTY_LINK, [], :link]]
          elsif parts == [LINK_PARTS]
            [[ATTACHMENT, [], :link], [pattern, [LINK_TEXT_ONLY], guard]]
          elsif pattern == INLINE_BBCODE
            [[BBCODE_IMAGE, [], :paired_ends], step]
          else
            [step]
          end
        end
        .concat(EMPTY_BLOCKS.map { |pattern| [pattern, [], :markdown] })
        .freeze

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
    # @return [Hash{Symbol => Object}] `:text` (at most {MAX_CHARS} characters; empty for a
    #   post with no text of its own, title or not: {own_text?}), `:truncated` (whether characters beyond the limit were
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
    #   the text was cut; no characters for a post with no text of its own.
    def self.submission(raw, title)
      analysed = analyse(raw)
      # No text of its own (an image, an attachment, a link without a label, invisible
      # characters): nothing is sent, not even the title (shared plugin rule F7).
      return [[], [], false] unless own_text?(*analysed)

      chars, origins, blocks, reading = analysed
      chars, origins = trim(*steps(MARKUP, chars, origins, blocks: blocks, reading: reading))
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
      chars, origins, blocks, reading = analyse(raw)
      trim(*steps(MARKUP, chars, origins, blocks: blocks, reading: reading))
    end

    # Whether a post has text of its own to assess (shared plugin rule F7): any character
    # that is not {NOT_TEXT} once {OWN_MARKUP} took away what is not the post's own text.
    # An image, a video, an attachment or a link with no visible label is not; a bare
    # address the reader sees is. When the check fails (a regular expression gives up),
    # the post counts as text: more is sent, never less.
    #
    # @param chars [Array<String>] {analyse}'s characters, and its origins, blocks and
    #   reading after them.
    # @return [Boolean]
    def self.own_text?(chars, origins, blocks, reading)
      shown, _origins = steps(OWN_MARKUP, chars, origins, blocks: blocks, reading: reading)
      shown.any? { |char| !NOT_TEXT.match?(char) }
    rescue RegexpError
      true
    end

    # Reads a post's blocks and inline structure, before any {MARKUP} step.
    #
    # @param raw [String, nil] the post's raw Markdown.
    # @return [Array] the characters (line endings made "\n") and their origins, the
    #   {block_tags} and the {inline_reading}.
    def self.analyse(raw)
      chars = spaced(clean(raw))
      source = chars
      origins = (0...chars.length).to_a
      chars, origins = steps(LINE_ENDINGS, chars, origins)
      text = chars.join
      lines = line_spans(text)
      kinds = line_kinds(text, lines)
      seen = { lines: {}, code: [], markers: [] }
      blocks = block_tags(text, origins, lines, kinds, seen)
      unless seen[:lines].empty?
        # A BBCode block's line ends a paragraph: what follows it is read again.
        kinds = line_kinds(text, lines, seen[:lines])
        seen = { lines: {}, code: [], markers: [] }
        blocks = block_tags(text, origins, lines, kinds, seen)
      end
      reading = inline_reading(text, origins, lines, kinds, seen, source)
      [chars, origins, blocks, reading]
    end

    # Runs steps of {MARKUP}'s shape over a text.
    #
    # @param blocks [Hash{Integer => Integer}] {block_tags}, for the steps marked `:block`.
    # @param reading [Reading] {inline_reading}, for the other guards.
    # @return [Array(Array<String>, Array<Integer, nil>)] the characters and their origins.
    def self.steps(list, chars, origins, blocks: {}, reading: nil)
      reading ||= Reading.new({}, {}, {}, {}, {}, {}, [], {})
      list.each do |pattern, parts, guard|
        text = chars.join
        allowed = guard && guard_for(guard, text, blocks, reading)
        chars, origins =
          replace(text, chars, origins, pattern, parts, allowed, inside: guard == :link)
      end
      [chars, origins]
    end

    # The test a step marked with `guard` puts to each of its matches.
    #
    # @return [Proc] given the match and the origins, whether to replace it.
    def self.guard_for(guard, text, blocks, reading)
      code = reading.code
      prose = ->(match, at) { (match.begin(0)...match.end(0)).none? { |index| code[at[index]] } }
      case guard
      when :block
        ->(match, at) { block_tag?(match, at, blocks) }
      when :markdown
        # Markdown's inline syntax, which an HTML block shows as it is written, and a bare
        # link too: its markers must not stand in one. An escaped one is text.
        lambda do |match, at|
          prose.call(match, at) && !escaped?(reading, at[match.begin(0)]) &&
            (match.begin(0)...match.end(0)).none? { |index| reading.html[at[index]] } &&
            !reading.urls[at[match.begin(0)]] && !reading.urls[at[match.end(0) - 1]]
        end
      when :link
        ->(match, at) { link_shown?(match, at, reading) }
      when :image
        markdown = guard_for(:markdown, text, blocks, reading)
        ->(match, at) { markdown.call(match, at) && image_shown?(match, reading) }
      when :inline_html
        # markdown-it reads an inline tag or comment within one paragraph, or an HTML
        # block's lines; one that reaches past them is text.
        lambda do |match, at|
          segment = reading.segments[at[match.begin(0)]]
          !segment.nil? && prose.call(match, at) &&
            (match.begin(0)...match.end(0)).all? { |index| reading.segments[at[index]] == segment }
        end
      when :emphasis
        markdown = guard_for(:markdown, text, blocks, reading)
        ->(match, at) { markdown.call(match, at) && delimiters?(match, at, reading.source) }
      when :entity
        # A bare link shows a reference in it as it is written.
        lambda do |match, at|
          prose.call(match, at) && !reading.urls[at[match.begin(0)]] &&
            !escaped?(reading, at[match.begin(0)])
        end
      when :paired
        ->(match, at) { (match.begin(0)...match.end(0)).all? { |index| reading.paired[at[index]] } }
      when :paired_ends
        # A BBCode tag pair whose two tags Discourse pairs: the text between them is theirs.
        ->(match, at) { reading.paired[at[match.begin(0)]] && reading.paired[at[match.end(0) - 1]] }
      when :dropped
        ->(match, at) { reading.dropped[at[match.begin(0)]] }
      end
    end

    # Whether markdown-it shows a {MD_LINK} match as a link: the match is in one paragraph,
    # its brackets are not code, escaped, in an HTML block or in a bare link (its text
    # may hold a code span), and a reference names a label the post defines.
    #
    # @return [Boolean]
    def self.link_shown?(match, at, reading)
      first = at[match.begin(0)]
      return false if first.nil? || reading.code[first] || escaped?(reading, first)
      # After a `!` not escaped, markdown-it reads an image, never a link.
      return false if first.positive? && reading.source[first - 1] == "!" &&
                      !escaped?(reading, first - 1)
      return false if reading.urls[first] || reading.urls[at[match.end(0) - 1]]

      span = (match.begin(0)...match.end(0))
      segment = reading.segments[first]
      return false if segment.nil? || span.any? { |index| reading.segments[at[index]] != segment }
      return false if span.any? { |index| reading.html[at[index]] }
      return false if (match.end(:text)...match.end(0)).any? { |index| reading.code[at[index]] }
      return true if match[:dest]

      label = match[:label].to_s.empty? ? match[:text] : match[:label]
      reading.refs.key?(reference_key(label))
    end

    # @return [Boolean] whether a {MD_IMAGE} match is an image: an inline one, or a
    #   reference to a label the post defines.
    def self.image_shown?(match, reading)
      return true if match[:dest]

      label = match[:label].to_s.empty? ? match[:inner] : match[:label]
      reading.refs.key?(reference_key(label))
    end

    # @return [String] a link label as markdown-it's `normalizeReference` compares it.
    def self.reference_key(label)
      label.strip.gsub(/\s+/, " ").downcase.upcase
    end

    # @return [Boolean] whether the source character at `origin` follows an odd run of
    #   backslashes outside code: escaped, so a reader sees it as it is written.
    def self.escaped?(reading, origin)
      return false unless origin

      index = origin - 1
      index -= 1 while index >= 0 && reading.source[index] == "\\" && !reading.code[index]
      (origin - 1 - index).odd?
    end

    # Unicode punctuation and symbols, which markdown-it's `isPunctChar` reads as
    # punctuation (ASCII punctuation among them).
    MD_PUNCTUATION = /[\p{P}\p{S}]/

    # Whether markdown-it's `scanDelims` lets an emphasis pair's first markers open and its
    # last markers close, by the characters around each run of markers in the source.
    #
    # @param match [MatchData] an emphasis step's match: the markers around group 1.
    # @return [Boolean]
    def self.delimiters?(match, at, source)
      size = (match[0].length - match[1].length) / 2
      opening = at[match.begin(0)]
      closing = at[match.end(0) - size]
      return false unless opening && closing

      flanking(source, opening, match[0][0])[0] && flanking(source, closing, match[0][0])[1]
    end

    # @return [Array(Boolean, Boolean)] whether the run of markers at `from` can open and
    #   whether it can close, as `scanDelims` decides (`_` cannot split a word).
    def self.flanking(source, from, marker)
      start = from
      start -= 1 while start.positive? && source[start - 1] == marker
      stop = from
      stop += 1 while source[stop] == marker
      before = start.positive? ? source[start - 1] : " "
      after = source[stop] || " "
      last_space = MD_WHITESPACE.match?(before)
      next_space = MD_WHITESPACE.match?(after)
      last_punctuation = MD_PUNCTUATION.match?(before)
      next_punctuation = MD_PUNCTUATION.match?(after)
      left = !next_space && (!next_punctuation || last_space || last_punctuation)
      right = !last_space && (!last_punctuation || next_space || next_punctuation)
      split = marker != "_"
      [left && (split || !right || last_punctuation), right && (split || !left || next_punctuation)]
    end

    # One step of {MARKUP}.
    #
    # @param allowed [Proc, nil] given the match and the origins, whether to replace it;
    #   a match it refuses stays as it is.
    # @param inside [Boolean] whether a match may start inside a refused one.
    # @return [Array(Array<String>, Array<Integer, nil>)] the characters and their origins.
    def self.replace(text, chars, origins, pattern, parts, allowed = nil, inside: false)
      out_chars = []
      out_origins = []
      later = []
      keep = lambda do |from, to|
        out_chars.concat(chars[from...to])
        out_origins.concat(origins[from...to])
      end
      made_up = lambda do |piece|
        out_chars.concat(piece.to_s.chars)
        out_origins.concat([nil] * piece.to_s.length)
      end
      position = 0
      while position < text.length && (match = pattern.match(text, position))
        keep.call(position, match.begin(0))
        position = match.end(0)
        if match.end(0) == match.begin(0) || (allowed && !allowed.call(match, origins))
          # Refused: as written. With `inside`, only its first character is passed over, so
          # that a match starting inside it is still read (markdown-it reads a link inside
          # brackets that are not one).
          stop = inside || match.end(0) == match.begin(0) ? match.begin(0) + 1 : match.end(0)
          keep.call(match.begin(0), stop)
          position = stop
          next
        end

        parts.each do |part|
          if part.is_a?(Integer)
            keep.call(match.begin(part), match.end(part)) if match[part]
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
              when :after_word
                from, to = args
                later << [out_chars.length, chars[from...to], origins[from...to]] if to > from
              end
            end
          else
            made_up.call(part)
          end
        end
      end
      keep.call(position, chars.length)
      after_words(out_chars, out_origins, later)
    end

    # Puts each piece after the word it was found in: at the first blank from its place
    # on, after a made-up space unless a blank precedes it, so that it never splits a word.
    #
    # @param later [Array<Array>] `[position, chars, origins]` of each piece.
    # @return [Array(Array<String>, Array<Integer, nil>)] the characters and their origins.
    def self.after_words(chars, origins, later)
      return [chars, origins] if later.empty?

      # The first blank at or after each place, found once for the whole text.
      blank = Array.new(chars.length + 1, chars.length)
      (chars.length - 1).downto(0) do |index|
        blank[index] = chars[index].match?(/\s/) ? index : blank[index + 1]
      end
      out_chars = []
      out_origins = []
      from = 0
      later.group_by { |position, _chars, _origins| blank[position] }.sort.each do |at, pieces|
        out_chars.concat(chars[from...at])
        out_origins.concat(origins[from...at])
        pieces.each do |_position, piece_chars, piece_origins|
          if !out_chars.empty? && !out_chars.last.match?(/\s/)
            out_chars << " "
            out_origins << nil
          end
          out_chars.concat(piece_chars)
          out_origins.concat(piece_origins)
        end
        from = at
      end
      [out_chars.concat(chars[from..]), out_origins.concat(origins[from..])]
    end

    # An image's alt text and title, in its place: a space before and after it where a
    # word touches it, so that neither joins the image's words.
    #
    # @param shown [Array<Array(Integer, Integer)>] the alt text's and title's ranges.
    # @return [Array<Array>] the operations of a {MARKUP} lambda.
    def self.spaced_image(match, shown)
      text = match.string
      ops = []
      ops << [:text, " "] if match.begin(0).positive? && text[match.begin(0) - 1].match?(/\S/)
      shown.each_with_index do |(from, to), index|
        ops << [:text, " "] unless index.zero?
        ops << [:keep, from, to]
      end
      ops << [:text, " "] if text[match.end(0)].to_s.match?(/\S/)
      ops
    end

    # The values of an open tag's attributes, by lower-case name (the first of a name).
    #
    # @param match [MatchData] a {HTML_TAG} match of an open tag.
    # @return [Hash{String => Array(Integer, Integer)}] each value's start and end.
    def self.attribute_values(match)
      values = {}
      match[2].scan(ATTRIBUTE_PARTS) do
        attribute = Regexp.last_match
        name = attribute[1].downcase
        group = (2..4).find { |index| attribute[index] }
        next if group.nil? || values.key?(name)

        offset = match.begin(2)
        values[name] = [offset + attribute.begin(group), offset + attribute.end(group)]
      end
      values
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
    # column counts, never one in a code block, in an HTML block, in a table's header,
    # inside another BBCode block (other than a quote or details), or one the plugin's own
    # regular expression would read with another length.
    #
    # @param text [String] the text after its line endings were made "\n".
    # @param origins [Array<Integer, nil>] its characters' origins.
    # @param lines [Array<Array(Integer, Integer)>] {line_spans}.
    # @param kinds [Array<Symbol>] {line_kinds}.
    # @param seen [Hash] collects, for any BBCode block: `:lines` (the lines that open or
    #   close it, for {line_kinds}), `:markers` (its tags, as text ranges) and `:code` (the
    #   content of a `[code]` block).
    # @return [Hash{Integer => Integer}] the origin of each such tag's "[" => its length.
    def self.block_tags(text, origins, lines, kinds, seen = { lines: {}, code: [], markers: [] })
      # Each line's tag as a closing line reads it, once: the search for a block's end
      # then only looks the lines up.
      marks =
        lines.map do |from, to|
          line = text[from...to]
          indent = line[/\A[ \t]*/]
          next if columns(indent) >= 4 || line[indent.length] != "["

          bbcode_tag(line[indent.length..], true)&.merge(indent: indent.length)
        end
      opaque = kinds.each_index.select do |index|
        %i[fence html table delimiter row].include?(kinds[index])
      end
      found = {}
      opaque = opaque.to_h { |index| [index, true] }
      walk_blocks(text, origins, lines, marks, opaque, 0, lines.size, found, seen)
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

    # What each line is, as markdown-it's block rules read it, closely enough to know
    # which lines are code and where no BBCode block can start: `:fence` (a fenced code
    # block, its fences included), `:code` (an indented code block), `:html` (an HTML
    # block), `:table` (a table's header line), `:bbcode` (a line that opens or closes a
    # BBCode block, from `block_lines`), `:break` (a thematic break or a setext heading's
    # underline), `:deep` (a paragraph's line indented four columns or more), `:reference`
    # (a link reference definition), a table's `:delimiter` row and `:row`s ({table_rows}),
    # `:blank` or `:text`. Fences and indented code are
    # read at the top level, in a blockquote and in a list item.
    #
    # @param block_lines [Hash{Integer => true}] the lines {block_tags} found opening or
    #   closing a BBCode block.
    # @return [Array<Symbol>] one kind per line.
    def self.line_kinds(text, lines, block_lines = {})
      kinds = Array.new(lines.size, :text)
      fence = nil
      html = nil
      list = nil
      list_depth = 0
      address = nil
      item_quote = false
      lazy = {}
      # A label alone that gets no address on its next line is no definition: a paragraph.
      no_address = lambda do
        kinds[address[:line]] = :text if address
        address = nil
      end
      previous = :blank
      outer = 0
      lines.each_with_index do |(from, to), index|
        line = text[from...to]
        if block_lines[index]
          # A BBCode block's tag line ends whatever its content left open, and a list it
          # is not indented into.
          kinds[index] = :bbcode
          fence = html = nil
          no_address.call
          list = nil if list && columns(line[/\A[ \t]*/]) < list
          previous = :bbcode
          next
        end
        if fence
          inner = fence_content(line, fence)
          if inner
            kinds[index] = :fence
            fence = nil if fence_closed?(inner, fence)
            previous = :fence
            next
          end
          fence = nil
        end
        if html
          inner = fence_content(line, html)
          if inner.nil? || (html[:end] == :blank && inner.strip.empty?)
            html = nil
          else
            kinds[index] = :html
            html = nil if html[:end] != :blank && line.downcase.include?(html[:end])
            previous = :html
            next
          end
        end

        depth, rest = quote_prefix(line)
        # A line opening a deeper blockquote starts a new container: what came before it
        # cannot continue there. A line with fewer markers continues a blockquote's
        # paragraph lazily, and the blockquote stays open, unless it starts a block that
        # ends the blockquote ({lazy_end?}); then it may be indented code.
        previous = :blank if depth > outer
        if depth >= outer || previous != :text || rest.strip.empty?
          outer = depth
        elsif lazy_end?(rest.lstrip, outer)
          previous = :blank
          outer = depth
        else
          lazy[index] = true
        end
        if rest.strip.empty?
          kinds[index] = :blank
          previous = :blank
          no_address.call
          next
        end
        # The address of a definition whose label stood alone on the line before: not a
        # line that starts a block markdown-it ends a definition at.
        if address
          below = index + 1 < lines.size ? text[lines[index + 1][0]...lines[index + 1][1]] : nil
          if depth <= address[:depth] && REFERENCE_DEST.match?(rest) &&
             !definition_end?(rest, below && quote_prefix(below)[1])
            address = nil
            kinds[index] = :reference
            previous = :blank
            next
          end
          no_address.call
          previous = :text
        end

        indent = columns(rest[/\A[ \t]*/])
        loose = rest.lstrip
        item = LIST_ITEM.match(rest)
        item = nil if item && indent - (list || 0) >= 4
        # A list item ends at a line less indented than its content, unless that line
        # continues the item's paragraph (only text does; a block never does), and with
        # the blockquote it is in.
        if depth.positive? || (list && depth < list_depth && previous != :text) ||
             (list && !item && indent < list &&
               (previous != :text || FENCE_OPEN.match?(loose) || ATX_HEADING.match?(loose) ||
                 HR.match?(loose) || html_start(loose, previous)))
          # A blockquote left of the item's content is not the one inside the item.
          if item_quote && depth.positive? && columns(line[/\A[ \t]*/]) < list.to_i
            previous = :blank
          end
          item_quote = false
          list = nil
        end
        base = list || 0
        item = nil if item && indent - base >= 4
        relative = indent - base
        # A thematic break, or the underline of a heading: a block of its own, so the next
        # line can start anything (indented code too). It comes before a list item.
        if relative < 4 && (SETEXT.match?(loose) && previous == :text || HR.match?(loose))
          kinds[index] = :break
          previous = :break
          next
        end
        if item
          spaces = item[3].empty? || item[3].length > 4 ? 1 : item[3].length
          list = item[1].length + item[2].length + spaces
          list_depth = depth
          content = rest[list..].to_s
          relative = content[/\A */].length
          container = list
        else
          content = loose
          container = base
        end

        if (opener = FENCE_OPEN.match(content.lstrip)) && relative < 4 &&
             !(opener[2].start_with?("`") && opener[3].include?("`"))
          kinds[index] = :fence
          fence = { char: opener[2][0], length: opener[2].length, depth: depth, indent: container }
          previous = :fence
          next
        end
        # A link reference definition, where a paragraph could start: shown as nothing,
        # and no paragraph for the next line to continue.
        if (item || previous != :text) && relative < 4 && REFERENCE.match?(content)
          kinds[index] = :reference
          address = REFERENCE_LABEL.match?(content) ? { line: index, depth: depth } : nil
          previous = :blank
          next
        end
        # Indented code: anywhere but on a paragraph's next line, which it cannot interrupt.
        if !item && relative >= 4 && previous != :text
          kinds[index] = :code
          previous = :code
          next
        end
        if relative < 4 && (ending = html_start(content.lstrip, item ? :blank : previous))
          kinds[index] = :html
          unless ending != :blank && line.downcase.include?(ending)
            html = { end: ending, depth: depth, indent: container }
          end
          previous = :html
          next
        end
        # An item that opens with a blockquote: a fence there runs on the lines that keep
        # both containers; an HTML block there is read on that line only (the blockquote
        # inside a list item is not followed further).
        if item && (inner = quote_prefix(content)).first.positive?
          # Its paragraph is in the blockquote: a line with fewer markers is lazy.
          outer = depth + inner.first
          item_quote = true
          quoted = inner.last
          opener = FENCE_OPEN.match(quoted.lstrip)
          if opener && columns(quoted[/\A[ \t]*/]) < 4 &&
               !(opener[2].start_with?("`") && opener[3].include?("`"))
            kinds[index] = :fence
            fence = {
              char: opener[2][0], length: opener[2].length, depth: depth, indent: container,
              inner: inner.first,
            }
            previous = :fence
            next
          end
          if html_start(quoted.lstrip, :blank)
            kinds[index] = :html
            previous = :html
            next
          end
        end
        # A paragraph's line indented four columns or more continues it, whatever it starts
        # with: no block interrupts it there.
        kinds[index] = :deep if !item && relative >= 4
        # A heading is a block of its own: the next line can start anything; so is an empty
        # list item, which leaves no paragraph to continue.
        previous =
          if item && content.strip.empty? then :blank
          elsif !item && ATX_HEADING.match?(content) then :heading
          else :text
          end
      end
      no_address.call
      table_rows(text, lines, kinds, lazy)
    end

    # Whether a line starts a block that ends a link reference definition (markdown-it's
    # terminators of the reference rule): a fence, a thematic break, a heading, a list
    # item, an HTML block that may interrupt a paragraph, a BBCode block or a table. A
    # line indented four columns or more never does.
    #
    # @param start [String] the line, without its blockquote markers.
    # @param below [String, nil] the next line, without its blockquote markers.
    # @return [Boolean]
    def self.definition_end?(start, below)
      return false if columns(start[/\A[ \t]*/]) >= 4

      loose = start.lstrip
      fence = FENCE_OPEN.match(loose)
      return true if fence && !(fence[2].start_with?("`") && fence[3].include?("`"))
      return true if HR.match?(start) || ATX_HEADING.match?(start) || LIST_ITEM.match?(start)
      return true if html_start(loose, :text) || block_opener?(loose)

      !below.nil? && loose.include?("|") && DELIMITER_ROW.match?(below.strip) &&
        cell_count(loose) == cell_count(below)
    end

    # Marks tables as markdown-it's table rule reads them: a text line with a pipe, over a
    # delimiter row with as many cells, in the same blockquote, is a header (`:table`); the
    # delimiter row is `:delimiter`, and the text lines after it are its rows (`:row`), up
    # to a blank line or one that starts another block or leaves the table's blockquote.
    #
    # @return [Array<Symbol>] the kinds, tables marked.
    # @param lazy [Hash{Integer => true}] the lines that continue a blockquote's paragraph
    #   lazily: no table starts there.
    def self.table_rows(text, lines, kinds, lazy)
      line = ->(index) { quote_prefix(text[lines[index][0]...lines[index][1]]) }
      index = 0
      while index + 1 < lines.size
        depth, header = line.call(index)
        below_depth, below = line.call(index + 1)
        unless kinds[index] == :text && kinds[index + 1] == :text && depth == below_depth &&
               !lazy[index] && !lazy[index + 1] &&
               header.include?("|") && DELIMITER_ROW.match?(below.strip) &&
               cell_count(header) == cell_count(below)
          index += 1
          next
        end

        kinds[index] = :table
        kinds[index + 1] = :delimiter
        index += 2
        while index < lines.size && kinds[index] == :text
          row_depth, rest = line.call(index)
          break if row_depth != depth || LIST_ITEM.match?(rest) || ATX_HEADING.match?(rest) ||
                   block_opener?(rest.lstrip)

          kinds[index] = :row
          index += 1
        end
      end
      kinds
    end

    # Whether a line with fewer blockquote markers than the paragraph it follows ends the
    # blockquote rather than continuing the paragraph: a BBCode block's opening tag does,
    # whatever its indentation (Discourse's block rule does not look at it); in a nested
    # blockquote, so does any block start (markdown-it then reads a lazy line's
    # indentation as -1, so no terminator finds it too deep).
    #
    # @param start [String] the line from its first non-blank character.
    # @param depth [Integer] how many blockquotes are open.
    # @return [Boolean]
    def self.lazy_end?(start, depth)
      return true if block_opener?(start)
      return false if depth < 2

      fence = FENCE_OPEN.match(start)
      (fence && !(fence[2].start_with?("`") && fence[3].include?("`"))) || HR.match?(start) ||
        ATX_HEADING.match?(start) || LIST_ITEM.match?(start) || !html_start(start, :text).nil?
    end

    # @return [Array(Integer, String)] how many blockquote markers open a line, and the
    #   rest of it.
    def self.quote_prefix(line)
      depth = 0
      rest = line
      while (marker = rest.match(/\A {0,3}>[ \t]?/))
        depth += 1
        rest = rest[marker.end(0)..]
      end
      [depth, rest]
    end

    # @return [String, nil] a line of a fenced code block without its containers'
    #   markers and indentation (`:depth` blockquotes, then `:indent` columns of a list
    #   item, then `:inner` blockquotes in it), or nil when the line is outside them.
    def self.fence_content(line, fence)
      rest = quote_markers(line, fence[:depth])
      return nil unless rest
      return quote_markers(rest, fence[:inner].to_i) if fence[:indent].zero? || rest.strip.empty?
      return nil if columns(rest[/\A[ \t]*/]) < fence[:indent]

      # Drop the container's indentation, a tab counting to the next multiple of 4, then the
      # markers of a blockquote inside it.
      column = 0
      taken = rest.each_char.take_while do |char|
        next false if column >= fence[:indent]

        column = char == "\t" ? column + 4 - (column % 4) : column + 1
      end
      quote_markers(rest[taken.length..], fence[:inner].to_i)
    end

    # @return [String, nil] a line without its first `count` blockquote markers, or nil
    #   when it has fewer.
    def self.quote_markers(line, count)
      count.times.reduce(line) do |rest, _|
        marker = rest.match(/\A {0,3}>[ \t]?/)
        return nil unless marker

        rest[marker.end(0)..]
      end
    end

    # @return [Boolean] whether a fenced code block's line closes it.
    def self.fence_closed?(inner, fence)
      closing = FENCE_CLOSE.match(inner)
      !closing.nil? && closing[1][0] == fence[:char] && closing[1].length >= fence[:length]
    end

    # The start of an HTML block (CommonMark's seven kinds).
    #
    # @param start [String] a line from its first non-blank character.
    # @param previous [Symbol] the kind of the line before: kind 7 cannot interrupt text.
    # @return [String, Symbol, nil] the text that ends the block, `:blank` for a blank
    #   line, or nil for no HTML block.
    def self.html_start(start, previous)
      case start
      when /\A<(script|pre|style|textarea)(?:[\s>]|\z)/i then "</#{Regexp.last_match(1).downcase}>"
      when /\A<!--/ then "-->"
      when /\A<\?/ then "?>"
      when /\A<!\[CDATA\[/ then "]]>"
      when /\A<![A-Za-z]/ then ">"
      when %r{\A</?(?:#{HTML_BLOCK_NAMES.join("|")})(?:[ \t>]|/>|\z)}io then :blank
      else
        tag = HTML_TAG.match(start)
        whole = tag && tag.begin(0).zero? && start[tag.end(0)..].strip.empty?
        :blank if whole && previous != :text
      end
    end

    # What {inline_reading} found: the origins of `code` (shown as written), of what a code
    # span shows nothing of (`dropped`: its backticks, the spaces markdown-it trims), the
    # `segments` (paragraph or HTML block, by number) an inline tag must stay within, and
    # `paired` BBCode markers that Discourse renders (and so removes), `urls`: the
    # characters of bare links, which markdown-it's linkify shows as they are written, and
    # `html`: the lines of HTML blocks, where Markdown's inline syntax is shown as written;
    # the `source` characters the origins point at; and the `refs`: the link labels the post
    # defines ({reference_key}).
    Reading = Struct.new(:code, :dropped, :segments, :paired, :urls, :html, :source, :refs)

    # Reads what markdown-it's inline rules make of the text: code (fenced and indented
    # blocks, a `[code]` block, code spans by markdown-it's backtick rule with escapes and
    # HTML tags passed over, an inline `[code]…[/code]`), the paragraphs and HTML blocks
    # that bound an inline tag, and the BBCode markers that pair up (an opening tag closed
    # in the same paragraph, as `bbcode-inline.js` pairs them, or a block's own tags).
    #
    # @param seen [Hash] from {block_tags}: `:code` and `:markers` as text ranges.
    # @return [Reading] the origins found.
    def self.inline_reading(text, origins, lines, kinds, seen, source)
      reading = Reading.new({}, {}, {}, {}, {}, {}, source, {})
      lines.each_with_index do |(from, to), index|
        next unless kinds[index] == :reference

        rest = quote_prefix(text[from...to]).last
        item = LIST_ITEM.match(rest)
        label = REFERENCE.match(item ? rest[item.end(0)..] : rest)&.[](1)
        reading.refs[reference_key(label)] = true if label
      end
      mark = lambda do |from, to, into|
        (from...to).each { |index| into[origins[index]] = true if origins[index] }
      end
      lines.each_with_index do |(from, to), index|
        mark.call(from, to, reading.code) if %i[fence code].include?(kinds[index])
      end
      seen[:code].each { |from, to| mark.call(from, to, reading.code) }
      seen[:markers].each { |from, to| mark.call(from, to, reading.paired) }
      stretches = paragraphs(text, lines, kinds)
      stretches.each_with_index do |(from, to), number|
        (from...to).each { |index| reading.segments[origins[index]] = number if origins[index] }
        marks = {
          code: ->(start, stop) { mark.call(start, stop, reading.code) },
          url: ->(start, stop) { mark.call(start, stop, reading.urls) },
          pair: ->(start, stop) { mark.call(start, stop, reading.paired) },
          refs: reading.refs,
        }
        inline_scan(text, from, to, marks) do |span_from, inside_from, inside_to, span_to|
          gone = (span_from...inside_from).to_a + (inside_to...span_to).to_a
          # markdown-it reads a newline in a span as a space, then trims one space off
          # each end of a span that has more than spaces.
          inside = text[inside_from...inside_to].tr("\n", " ")
          if inside.length > 2 && inside.start_with?(" ") && inside.end_with?(" ")
            gone += [inside_from, inside_to - 1]
          end
          gone.each { |at| reading.dropped[origins[at]] = true if origins[at] }
        end
        inline_bbcode(text, origins, from, to, reading, mark)
      end
      number = stretches.size
      lines.each_with_index do |(from, to), index|
        next unless kinds[index] == :html

        number += 1 unless index.positive? && kinds[index - 1] == :html
        stop = index + 1 < lines.size && kinds[index + 1] == :html ? lines[index + 1][0] : to
        (from...stop).each { |at| reading.segments[origins[at]] = number if origins[at] }
        mark.call(from, stop, reading.html)
      end
      reading
    end

    # Pairs the inline BBCode markers of one paragraph, outside code and bare links: an
    # opening tag with the next closing tag of its name.
    #
    # @return [void]
    def self.inline_bbcode(text, origins, from, to, reading, mark)
      open = Hash.new { |hash, name| hash[name] = [] }
      text[from...to].scan(INLINE_BBCODE) do
        tag = Regexp.last_match
        start = from + tag.begin(0)
        stop = from + tag.end(0)
        next if (start...stop).any? do |index|
          reading.code[origins[index]] || reading.urls[origins[index]]
        end

        name = tag[2].downcase
        # An inline `[code]` is {inline_scan}'s: what it did not take stays as written.
        next if name == "code"

        if tag[1].empty?
          open[name] << [start, stop]
        elsif (opening = open[name].pop)
          mark.call(opening[0], opening[1], reading.paired)
          mark.call(start, stop, reading.paired)
        end
      end
    end

    # The stretches of text whose inline content markdown-it reads as one: runs of text
    # lines, broken by any other line and by a line that starts a block of its own.
    #
    # @return [Array<Array(Integer, Integer)>] each stretch's start and end.
    def self.paragraphs(text, lines, kinds)
      stretches = []
      current = nil
      outer = 0
      lines.each_with_index do |(from, to), index|
        depth, rest = quote_prefix(text[from...to])
        if %i[table row].include?(kinds[index])
          # A table's every cell is read on its own.
          stretches << current if current
          current = nil
          stretches.concat(table_cells(text, to - rest.length, to))
          next
        end
        texty = %i[text bbcode deep].include?(kinds[index])
        alone = kinds[index] == :bbcode || ATX_HEADING.match?(rest)
        # A deeper blockquote is a new block; a shallower line may continue the paragraph
        # (lazily), and its blockquotes stay open. A deep line only continues it.
        starts = kinds[index] != :deep &&
          (alone || depth > outer || LIST_ITEM.match?(rest) || block_opener?(rest.lstrip))
        outer = depth unless texty && !starts && current && depth < outer
        if texty && !starts && current
          current[1] = to
        else
          stretches << current if current
          current = texty ? [from, to] : nil
        end
        if alone && current
          stretches << current
          current = nil
        end
      end
      stretches << current if current
      stretches
    end

    # @return [Integer] how many cells a table's line has, as markdown-it counts them: split
    #   at the pipes not escaped, without an empty first or last cell.
    def self.cell_count(line)
      cells = line.strip.split(/(?<!\\)\|/, -1)
      cells.shift if cells.first&.strip&.empty?
      cells.pop if cells.last&.strip&.empty?
      cells.size
    end

    # @return [Array<Array(Integer, Integer)>] the cells of a table's line: the stretches
    #   between its pipes (one escaped with a backslash excepted).
    def self.table_cells(text, from, to)
      cells = []
      start = from
      index = from
      while index < to
        if text[index] == "\\"
          index += 2
          next
        end
        if text[index] == "|"
          cells << [start, index]
          start = index + 1
        end
        index += 1
      end
      cells << [start, to]
      cells.reject { |cell_from, cell_to| text[cell_from...cell_to].strip.empty? }
    end

    # BBCode blocks Discourse and its bundled plugins register: a line opening one ends a
    # paragraph, whether or not the block is then closed.
    REGISTERED_BLOCKS = %w[quote details code spoiler poll excerpt wrap grid chat].freeze

    # @return [Boolean] whether a line starts with the opening tag of a registered block.
    def self.block_opener?(line)
      return false unless line.start_with?("[")

      tag = bbcode_tag(line, false)
      !tag.nil? && !tag[:closing] && REGISTERED_BLOCKS.include?(tag[:tag])
    rescue Regexp::TimeoutError
      true
    end

    # Scans one stretch of text as markdown-it's inline rules do, from left to right: an
    # escape, an HTML tag or comment, and a link or an image (its text read in turn) are
    # passed over whole; a bare link goes to `:url` (not inside a link, where markdown-it's
    # `linkLevel` turns linkify off); a code span goes to `:code` and, with its backticks'
    # places, to the block; so does an inline `[code]…[/code]` (Discourse's
    # `bbcode-inline.js` takes it up to the next closing tag), its tags to `:pair`.
    #
    # @param marks [Hash{Symbol => Object}] `:code`, `:url` and `:pair`: given a range,
    #   mark it; `:refs`: the link labels the post defines.
    # @param links [Integer] how many links are open around the stretch.
    # @return [void]
    def self.inline_scan(text, from, to, marks, links = 0, &spans)
      index = from
      while index < to
        char = text[index]
        if char == "\\" && index + 1 < to && text[index + 1].match?(ESCAPABLE)
          index += 2
        elsif char == "`"
          run = text[index...to][/\A`+/].length
          close = backtick_run(text, index + run, to, run)
          if close
            marks[:code].call(index, close + run)
            spans&.call(index, index + run, close, close + run)
          end
          index = close ? close + run : index + run
        elsif char == "<" && (tag = INLINE_HTML.match(text, index)) && tag.end(0) <= to
          links += 1 if tag[0].match?(/\A<a[>#{JS_SPACE}]/io)
          links -= 1 if tag[0].match?(%r{\A</a[#{JS_SPACE}]*>}io)
          index = tag.end(0)
        elsif (link = markdown_link(text, index, to, marks[:refs]))
          # An image's alt text is read anew; a link's text is inside a link.
          inside = text[index] == "!" ? 0 : links + 1
          inline_scan(text, link.begin(1), link.end(1), marks, inside, &spans)
          index = link.end(0)
        elsif char == "[" && (tag = INLINE_CODE_OPEN.match(text, index)) &&
              (close = text.index(INLINE_CODE_CLOSE, tag.end(0))) && close + 7 <= to
          marks[:pair].call(index, tag.end(0))
          marks[:code].call(tag.end(0), close)
          marks[:pair].call(close, close + 7)
          index = close + 7
        elsif links <= 0 && "hHfF".include?(char) && (bare = bare_link(text, index)) &&
              bare.end(0) <= to
          # markdown-it leaves trailing asterisks out of a link: they may close emphasis.
          stop = bare.end(0)
          stop -= 1 while text[stop - 1] == "*"
          marks[:url].call(index, stop)
          index = stop
        else
          index += 1
        end
      end
    end

    # @return [MatchData, nil] the bare link that starts at `index`; none when the
    #   expression runs out of time (the characters are then read as Markdown).
    def self.bare_link(text, index)
      BARE_LINK.match(text, index)
    rescue Regexp::TimeoutError
      nil
    end

    # A link or an image that starts at `index`, read whole: not a reference to a label
    # the post does not define, not an image whose alt text has a backtick, and not a link
    # whose text opens a code span reaching past it (markdown-it would read its brackets
    # as code).
    #
    # @param refs [Hash{String => true}] the labels the post defines.
    # @return [MatchData, nil]
    def self.markdown_link(text, index, to, refs)
      image = text[index] == "!"
      return nil unless image || text[index] == "["

      # After a `!` not escaped, markdown-it reads an image, never a link.
      if !image && index.positive? && text[index - 1] == "!"
        before = index - 1
        before -= 1 while before.positive? && text[before - 1] == "\\"
        return nil if (index - 1 - before).even?
      end

      link = (image ? MD_IMAGE_AT : MD_LINK_AT).match(text, index)
      return nil unless link && link.end(0) <= to
      return nil if image && link[:inner].include?("`")
      return nil if !image && !code_spans_within?(text, link.begin(1), link.end(1), to)
      return link if link[:dest]

      label = link[:label].to_s.empty? ? link[1] : link[:label]
      refs.key?(reference_key(label)) ? link : nil
    end

    # @return [Boolean] whether every code span opened between `from` and `to` closes
    #   before `to`, looking for its close up to `limit`.
    def self.code_spans_within?(text, from, to, limit)
      index = from
      while index < to
        if text[index] == "\\" && index + 1 < to
          index += 2
        elsif text[index] == "`"
          run = text[index...to][/\A`+/].length
          close = backtick_run(text, index + run, limit, run)
          return false if close && close + run > to

          index = close ? close + run : index + run
        else
          index += 1
        end
      end
      true
    end

    # @return [Integer, nil] where the next run of exactly `length` backticks starts.
    def self.backtick_run(text, from, to, length)
      index = from
      while index < to
        if text[index] == "`"
          run = text[index...to][/\A`+/].length
          return index if run == length

          index += run
        else
          index += 1
        end
      end
      nil
    end

    # Reads the BBCode blocks of lines `first...last` into `found`, as Discourse's block
    # rule does at one level, and the blocks inside a quote or details one level down.
    #
    # @return [void]
    def self.walk_blocks(text, origins, lines, marks, opaque, first, last, found, seen)
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
          if start + length == line.length
            seen[:lines][index] = true
            seen[:markers] << [from + indent.length, from + after]
            seen[:markers] << [from + start, from + start + length]
            seen[:code] << [from + after, from + start] if opener[:tag] == "code"
            if ours
              found[origins[from]] = opener[:length]
              found[origins[from + start]] = length
            end
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
        seen[:lines][index] = true
        seen[:lines][close_line] = true
        closer = lines[close_line][0] + close_indent
        seen[:markers] << [from + indent.length, from + after] << [closer, closer + close_length]
        seen[:code] << [lines[index][1] + 1, lines[close_line][0]] if opener[:tag] == "code"
        if ours
          found[origins[from]] = opener[:length]
          found[origins[lines[close_line][0] + close_indent]] = close_length
          walk_blocks(text, origins, lines, marks, opaque, index + 1, close_line, found, seen)
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

    private_class_method :submission, :reduce, :analyse, :own_text?, :steps, :replace, :after_words, :attribute_values,
                         :code_point, :block_tags, :line_spans, :line_kinds, :definition_end?,
                         :table_rows, :table_cells, :cell_count, :lazy_end?, :quote_prefix,
                         :fence_content, :quote_markers, :fence_closed?, :html_start,
                         :inline_reading, :inline_bbcode, :paragraphs, :block_opener?, :inline_scan,
                         :bare_link, :markdown_link, :code_spans_within?, :link_shown?,
                         :image_shown?, :reference_key, :guard_for, :escaped?, :delimiters?,
                         :flanking, :spaced_image, :backtick_run, :walk_blocks, :bbcode_tag,
                         :inline_close, :block_close, :plugin_opener?, :block_tag?, :blank_from?,
                         :columns, :trim, :clean, :spaced, :js_number_string
  end
end
