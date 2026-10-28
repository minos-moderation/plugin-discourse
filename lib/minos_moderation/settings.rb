# frozen_string_literal: true

module MinosModeration
  # The plugin's site settings (`config/settings.yml`), read in one place.
  #
  # The key and the webhook secret leave this module only to go where they are used: the
  # `X-Gateway-Key` header and the signature check. Nothing here logs, renders or raises
  # them.
  module Settings
    # @return [Boolean] whether the plugin moderates new posts.
    def self.enabled?
      SiteSetting.minos_enabled
    end

    # @return [String] the gateway's base URL as the administrator typed it.
    def self.gateway_url
      SiteSetting.minos_gateway_url.to_s.strip
    end

    # @return [String] the forum's B2B key, or an empty string when it is not set.
    def self.api_key
      SiteSetting.minos_api_key.to_s.strip
    end

    # @return [String] the key's webhook secret, or an empty string when it is not set.
    def self.webhook_secret
      SiteSetting.minos_webhook_secret.to_s.strip
    end

    # @return [String] the profile every post is assessed with (`forum_adult`, `forum_teen`).
    def self.profile
      SiteSetting.minos_profile.to_s
    end

    # @return [Integer] seconds without a verdict after which a post is treated as
    #   `nieocenione`; never under `Decision::MIN_TIMEOUT_MINUTES`, also for a value stored
    #   before that minimum (Discourse checks `min` only when a setting is written).
    def self.timeout_s
      Decision.timeout_s(SiteSetting.minos_timeout_minutes)
    end

    # @return [Boolean] whether posts by moderators and administrators skip the gateway.
    def self.skip_staff?
      SiteSetting.minos_skip_staff
    end

    # The settings that decide what happens to a post, in the shape `Decision` reads.
    #
    # @return [Hash{String => String}] `failure_mode`, `censored_action`, `blocked_action`.
    def self.decision
      {
        "failure_mode" => SiteSetting.minos_failure_mode.to_s,
        "censored_action" => SiteSetting.minos_censored_action.to_s,
        "blocked_action" => SiteSetting.minos_blocked_action.to_s,
      }
    end
  end
end
