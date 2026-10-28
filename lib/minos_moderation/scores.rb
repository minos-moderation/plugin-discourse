# frozen_string_literal: true

require "json"
require "uri"

module MinosModeration
  # The client side of the gateway's `POST /api/v1/b2b/oceny` ("scores"): the request the
  # plugin sends for one held post and the reading of the gateway's answer.
  #
  # The body carries the item id (the reviewable's id and the attempt, never content), the
  # text and the spam signals `links`, `author_first_post` and `link_domains`. It never
  # carries an e-mail, an IP address or a user id: {request_body} takes no author at all
  # and refuses any other signal.
  #
  # Plain Ruby: no Rails, so the standalone tier runs it without Discourse.
  module Scores
    # The route, relative to the gateway's base URL.
    PATH = "/api/v1/b2b/oceny"

    # An item id as the contract allows it.
    ITEM_ID = /\A[A-Za-z0-9._:-]{1,64}\z/

    # The plugin's item ids: the prefix, the reviewable's id and the attempt. Each attempt
    # has its own id, so a verdict for an earlier attempt is recognised and ignored.
    OWN_ID = /\Adiscourse:([1-9][0-9]{0,17})\.([1-9][0-9]{0,5})\z/

    # The spam signals the plugin sends, and nothing else.
    META_KEYS = %w[links author_first_post link_domains].freeze

    # The contract's limit for `link_domains`.
    MAX_LINK_DOMAINS = 10

    # A registrable domain as the plugin sends it: lowercase ASCII labels, at least two,
    # the last one starting with a letter (so never an IP address).
    LABEL = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    DOMAIN = /\A(?=.{1,253}\z)(?:#{LABEL}\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]\z/o

    # The contract's limit for `tekst`, in characters.
    MAX_CHARS = 3000

    # Hosts to which the key may travel over plain http: the mock gateway on this machine.
    LOOPBACK = %w[localhost 127.0.0.1 ::1 [::1]].freeze

    # The first retry pause without `ponow_za_s`, in seconds; it doubles per attempt.
    BACKOFF_S = 60

    # The longest retry pause, in seconds.
    MAX_BACKOFF_S = 900

    # A gateway error code, as the contract spells them. Anything else is not repeated.
    CODE = /\A[a-z0-9_]{1,64}\z/

    # The `429` codes after which the gateway accepts nothing for a while, and the state
    # the administrator is shown for each: the key's daily limit, or the gateway's shared
    # ceiling and full queue. The key's per-minute and in-flight limits pass in seconds.
    LIMITS = {
      "limit_dobowy_klucza" => "daily_limit",
      "limit_globalny_b2b" => "overloaded",
      "kolejka_pelna" => "overloaded",
    }.freeze

    # What an answer means for the plugin: `:accepted`, `:retry` (keep the post pending
    # and send again after `retry_in` seconds, or after a backoff when nil) or
    # `:config_error` (the request is wrong and sending again will not help).
    Outcome = Struct.new(:kind, :http, :code, :retry_in, keyword_init: true)

    # @param reviewable_id [Integer, String] the reviewable's id.
    # @param attempt [Integer, String] the attempt's number, from 1.
    # @return [String] the item id sent for that attempt, `discourse:<id>.<attempt>`.
    # @raise [ArgumentError] when either is not a positive integer (or the attempt is over
    #   999999).
    def self.item_id(reviewable_id, attempt)
      id = positive(reviewable_id)
      number = positive(attempt)
      raise ArgumentError, "an attempt is at most 999999" if number > 999_999

      "discourse:#{id}.#{number}"
    end

    # @param item_id [String] an item id from a webhook payload.
    # @return [Array(Integer, Integer), nil] the reviewable's id and the attempt, or nil when
    #   the item is not this plugin's.
    def self.parse_item_id(item_id)
      match = OWN_ID.match(item_id.to_s)
      match && [Integer(match[1], 10), Integer(match[2], 10)]
    end

    # The JSON body for one held post.
    #
    # @param item_id [String] from {item_id}.
    # @param text [String] the text to assess, at most {MAX_CHARS} characters.
    # @param profile [String] the profile to assess it with.
    # @param meta [Hash{String => Object}] `links` (Integer) and `author_first_post`
    #   (Boolean); optionally `link_domains` (up to {MAX_LINK_DOMAINS} distinct {DOMAIN}s);
    #   no other key.
    # @return [String] the request body.
    # @raise [ArgumentError] on a malformed id, an empty or too long text, or any signal
    #   other than {META_KEYS}.
    def self.request_body(item_id:, text:, profile:, meta:)
      raise ArgumentError, "malformed item id" unless ITEM_ID.match?(item_id.to_s)
      raise ArgumentError, "no text" if text.to_s.strip.empty?
      raise ArgumentError, "text over #{MAX_CHARS} characters" if text.length > MAX_CHARS

      signals = meta.to_h.transform_keys(&:to_s)
      unknown = signals.keys - META_KEYS
      raise ArgumentError, "signals not in the contract: #{unknown.join(", ")}" if unknown.any?
      unless signals["links"].is_a?(Integer) && [true, false].include?(signals["author_first_post"])
        raise ArgumentError, "links is an Integer and author_first_post a Boolean"
      end
      if signals.key?("link_domains") && !domains?(signals["link_domains"])
        raise ArgumentError, "link_domains is a list of at most #{MAX_LINK_DOMAINS} domains"
      end

      item = { "id" => item_id, "tekst" => text, "profil" => profile.to_s, "meta" => signals }
      JSON.generate("elementy" => [item])
    end

    # The route's URL for a gateway base URL, if the key may travel there.
    #
    # @param base_url [String] the administrator's `minos_gateway_url`.
    # @return [URI::HTTP, nil] the URL of {PATH}; nil unless it is `https` with a host
    #   name and no credentials, query or fragment (plain `http` only to a loopback host,
    #   for the mock gateway).
    def self.endpoint(base_url)
      uri = URI.parse(base_url.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
      return nil if uri.userinfo || uri.query || uri.fragment
      return nil unless uri.scheme == "https" || LOOPBACK.include?(uri.host.downcase)

      uri.dup.tap { |url| url.path = "#{uri.path.chomp("/")}#{PATH}" }
    rescue URI::Error
      nil
    end

    # Reads the gateway's answer to one request (shared plugin rules F5a and F5b).
    #
    # Only `202` accepts a request. Any other `2xx` accepted nothing, so the post is sent
    # again after a backoff, like a `5xx`: it is never read as a configuration error, which
    # would give the post the failure mode for an answer that says nothing about the
    # forum's configuration. `408` is a network failure.
    #
    # @param status [Integer] the HTTP status.
    # @param body [String, nil] the answer's body.
    # @return [Outcome] `:accepted` for `202`; `:retry` for `429`, any `5xx`, `408` and any
    #   other `2xx`, with `ponow_za_s` when the gateway sent one; `:config_error` for every
    #   other status (another `4xx`, a redirect). `code` is the gateway's `blad.kod` when it
    #   has the contract's shape, and nil otherwise.
    def self.classify(status, body)
      status = status.to_i
      error = error_of(body)
      code = error["kod"].is_a?(String) && CODE.match?(error["kod"]) ? error["kod"] : nil
      return Outcome.new(kind: :accepted, http: status) if status == 202

      if status == 429 || status == 408 || (500..599).cover?(status) || (200..299).cover?(status)
        return Outcome.new(kind: :retry, http: status, code: code, retry_in: retry_in(error))
      end

      Outcome.new(kind: :config_error, http: status, code: code)
    end

    # Reads a failure to get any answer at all.
    #
    # @param error_class [String] the class name of the transport error.
    # @return [Outcome] `:config_error` when Discourse refused the gateway's address as
    #   private (`DisallowedIpError`), `:retry` for everything else (a timeout, a refused
    #   connection, a DNS failure).
    def self.classify_transport(error_class)
      if error_class.to_s.end_with?("DisallowedIpError")
        return Outcome.new(kind: :config_error, code: nil, http: nil)
      end

      Outcome.new(kind: :retry, http: nil, code: nil, retry_in: nil)
    end

    # @param outcome [Outcome] an answer, read.
    # @return [String, nil] the {LIMITS} state the answer puts the gateway in, or nil.
    def self.limit_state(outcome)
      outcome.http == 429 ? LIMITS[outcome.code] : nil
    end

    # @param attempts [Integer] how many attempts have failed so far (at least 1).
    # @param retry_in [Integer, nil] the gateway's `ponow_za_s`.
    # @return [Integer] seconds to wait: `retry_in` when given, otherwise {BACKOFF_S}
    #   doubled per earlier attempt, never over {MAX_BACKOFF_S}.
    def self.backoff(attempts, retry_in = nil)
      return retry_in.clamp(1, MAX_BACKOFF_S) if retry_in.is_a?(Integer)

      exponent = [attempts.to_i - 1, 0].max.clamp(0, 10)
      [BACKOFF_S * (2**exponent), MAX_BACKOFF_S].min
    end

    # @param body [String, nil] an answer's body.
    # @return [Hash] its `blad` object, or an empty Hash.
    def self.error_of(body)
      data = JSON.parse(body.to_s)
      data.is_a?(Hash) && data["blad"].is_a?(Hash) ? data["blad"] : {}
    rescue JSON::ParserError, EncodingError
      {}
    end

    # @param error [Hash] a `blad` object.
    # @return [Integer, nil] its `ponow_za_s` when it is a positive integer.
    def self.retry_in(error)
      value = error["ponow_za_s"]
      value.is_a?(Integer) && value.positive? ? value : nil
    end

    # @param value [Object] a `link_domains` signal.
    # @return [Boolean] whether it is distinct domains, at most {MAX_LINK_DOMAINS} of them.
    def self.domains?(value)
      value.is_a?(Array) && value.size <= MAX_LINK_DOMAINS && value.uniq.size == value.size &&
        value.all? { |domain| domain.is_a?(String) && DOMAIN.match?(domain) }
    end

    # @param value [Integer, String] a positive integer, or its decimal digits.
    # @return [Integer] the integer.
    # @raise [ArgumentError] when it is not a positive integer.
    def self.positive(value)
      number = value.is_a?(Integer) ? value : Integer(value.to_s, 10)
      raise ArgumentError, "not a positive integer" unless number.positive?

      number
    end

    private_class_method :error_of, :retry_in, :domains?, :positive
  end
end
