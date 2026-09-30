# frozen_string_literal: true

require "json"

module MinosModeration
  # The body of a webhook delivery, read into one normalised shape.
  #
  # Mirrors `Minos\Client\WebhookPayload` of `minos-moderation/client-php`. The gateway
  # builds the payload from zero, so it carries only the fields below, and this reader
  # takes them defensively, because the plugin must never turn a payload it does not
  # understand into a verdict:
  #
  # - a `status` other than `ocenione`, or an `ocenione` whose `kwalifikacja` is not one of
  #   the three known values, reads as `nieocenione`. What happens to such a post is the
  #   forum's fail-open or fail-closed setting, never a guess;
  # - a category label outside {CATEGORIES} is kept: the list may grow, and dropping a
  #   label would hide it from the forum's moderators;
  # - `ocenzurowany` is read only together with `ocenzurowane`; `wsparcie` only when it is
  #   the JSON `true`; `wersja` only as 16 hex characters.
  #
  # Call it only on a body whose signature {Signature.verify} accepted. Plain Ruby: no
  # Rails, so the standalone tier runs it without Discourse.
  module WebhookPayload
    # `status` of a payload that carries a verdict.
    ASSESSED = "ocenione"

    # `status` of a payload that carries none.
    UNASSESSED = "nieocenione"

    # The three verdicts a payload may carry, in order of severity.
    QUALIFICATIONS = %w[bezpieczne ocenzurowane zablokowane].freeze

    # The category labels the contract names today.
    CATEGORIES = %w[
      mowa_nienawisci grozba przemoc nekanie tresc_seksualna samookaleczenie oszustwo spam
      ujawnianie_danych dane_osobowe wulgaryzmy uzywki uwodzenie_nieletnich hazard
      niebezpieczne_zachowanie
    ].freeze

    # The item id the plugin sent: what it matches the verdict with.
    ITEM_ID = /\A[A-Za-z0-9._:-]{1,64}\z/

    # The opaque `wersja`: 16 hex characters.
    VERSION = /\A[0-9a-f]{16}\z/

    # Reads a delivery body.
    #
    # @param body [String] the exact body of a delivery whose signature was verified.
    # @return [Hash{String => Object}, nil] the normalised payload with the keys `id`,
    #   `status`, `kwalifikacja`, `kategorie`, `ocenzurowany`, `wsparcie` and `wersja`, or
    #   nil when the body is not a payload at all (not a JSON object, or no valid `id`):
    #   nothing in it can be matched to a post.
    def self.parse(body)
      return nil unless body.is_a?(String)

      data = JSON.parse(body)
      return nil unless data.is_a?(Hash)

      id = data["id"]
      return nil unless usable_string?(id) && ITEM_ID.match?(id)

      qualification = data["kwalifikacja"]
      if data["status"] != ASSESSED || !QUALIFICATIONS.include?(qualification)
        return unassessed(id)
      end

      masked = data["ocenzurowany"]
      version = data["wersja"]
      {
        "id" => id,
        "status" => ASSESSED,
        "kwalifikacja" => qualification,
        "kategorie" => categories(data["kategorie"]),
        "ocenzurowany" =>
          (qualification == "ocenzurowane" && usable_string?(masked) ? masked : nil),
        "wsparcie" => data["wsparcie"] == true,
        "wersja" => (usable_string?(version) && VERSION.match?(version) ? version : nil),
      }
    rescue JSON::ParserError, EncodingError, ArgumentError
      nil
    end

    # The normalised payload of an item without a verdict.
    #
    # @param id [String] the item id.
    # @return [Hash{String => Object}] the payload, with no verdict in it.
    def self.unassessed(id)
      {
        "id" => id,
        "status" => UNASSESSED,
        "kwalifikacja" => nil,
        "kategorie" => [],
        "ocenzurowany" => nil,
        "wsparcie" => false,
        "wersja" => nil,
      }
    end

    # The category labels, deduplicated, in the order the gateway sent them.
    #
    # Like the PHP reader, which decodes JSON objects into arrays, a JSON object is read
    # for its values: a label is never dropped for the shape it came in.
    #
    # @param value [Object] the decoded `kategorie`.
    # @return [Array<String>] the non-empty string labels.
    def self.categories(value)
      labels = value.is_a?(Hash) ? value.values : value
      return [] unless labels.is_a?(Array)

      labels.select { |label| usable_string?(label) && !label.empty? }.uniq
    end

    # @param value [Object] a decoded JSON value.
    # @return [Boolean] whether it is a string that regular expressions can read.
    def self.usable_string?(value)
      value.is_a?(String) && value.valid_encoding?
    end

    private_class_method :unassessed, :categories, :usable_string?
  end
end
