# frozen_string_literal: true

require "openssl"

module MinosModeration
  # Verifies the `X-Wergiliusz-Podpis` header of a webhook delivery.
  #
  # A Ruby port of the gateway's reference verifier (`docs/contract.md` in
  # `minos-moderation/client-php`, "The signature"): `v1` is the hex HMAC-SHA256 of
  # `"<t>.<body>"` keyed with the key's webhook secret. It accepts only a well-formed,
  # fresh, matching header, and is tested on the gateway's own vector
  # (`spec/fixtures/signature.json`, byte for byte).
  #
  # Plain Ruby and OpenSSL: no Rails, so the standalone tier runs it without Discourse.
  module Signature
    # The header's only accepted shape, checked after surrounding whitespace is removed.
    HEADER = /\At=(\d+),v1=([0-9a-f]{64})\z/

    # Seconds a delivery's timestamp may differ from the forum's clock.
    TOLERANCE_S = 300

    # Checks one delivery.
    #
    # @param secret [String] the key's webhook secret.
    # @param header [String] the `X-Wergiliusz-Podpis` header as received.
    # @param body [String] the exact bytes of the body, read before anything parsed it.
    # @param now [Integer, Time] the forum's clock.
    # @param tolerance [Integer] seconds the timestamp may be off, either way.
    # @return [Boolean] true only for a well-formed header whose timestamp is within the
    #   tolerance and whose `v1` matches the body; false for everything else, including an
    #   empty secret.
    def self.verify(secret, header, body, now, tolerance = TOLERANCE_S)
      return false unless secret.is_a?(String) && !secret.empty?
      return false unless header.is_a?(String) && body.is_a?(String)

      # Bytes, not text: a header with invalid UTF-8 is refused, never an exception.
      match = HEADER.match(header.b.strip)
      return false unless match
      return false if (now.to_i - match[1].to_i).abs > tolerance

      expected = mac(secret, match[1], body)
      given = match[2]
      expected.bytesize == given.bytesize && OpenSSL.fixed_length_secure_compare(expected, given)
    end

    # Signs a body the way the gateway does: for the plugin's own specs, which need genuine
    # deliveries. The plugin never signs anything it sends.
    #
    # @param secret [String] the webhook secret.
    # @param body [String] the exact bytes of the body.
    # @param timestamp [Integer] the delivery's `t`.
    # @return [String] the `X-Wergiliusz-Podpis` header value.
    def self.sign(secret, body, timestamp)
      "t=#{Integer(timestamp)},v1=#{mac(secret, Integer(timestamp).to_s, body)}"
    end

    # @param secret [String] the webhook secret.
    # @param timestamp [String] the timestamp's digits, as they appear in the header.
    # @param body [String] the exact bytes of the body.
    # @return [String] the lowercase hex HMAC-SHA256 of `"<timestamp>.<body>"`.
    def self.mac(secret, timestamp, body)
      OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.".b + body.b)
    end

    private_class_method :mac
  end
end
