# frozen_string_literal: true

module MinosModeration
  # The admin dashboard's notice when the plugin cannot work as configured.
  #
  # A site setting's description is static, so a configuration error the gateway reports
  # (`4xx` other than `429`, contract "What a plugin does with a refusal") is shown here:
  # a missing or unusable gateway URL, key or webhook secret, and the gateway's last
  # refusal with its HTTP status and `kod`. Never the key, the secret or any content.
  # A realtime check (no `perform_every`): it runs when the dashboard loads.
  class MinosGatewayProblem < ::ProblemCheck
    self.priority = "high"

    # The stored refusal reasons that have a text.
    STORED = %w[refused unexpected disallowed_address].freeze

    # @return [ProblemCheck::Problem, nil] the problem, or nil when there is none.
    def call
      return no_problem unless Settings.enabled?

      @details = details
      @details.empty? ? no_problem : problem
    end

    private

    # @return [Array<String>] one Polish sentence fragment per thing that is wrong.
    def details
      found = []
      found << text("invalid_url") if Scores.endpoint(Settings.gateway_url).nil?
      found << text("missing_key") if Settings.api_key.empty?
      found << text("missing_secret") if Settings.webhook_secret.empty?
      stored = Store.problem
      if stored
        reason = STORED.include?(stored["reason"]) ? stored["reason"] : "unexpected"
        found << text(reason, http: stored["http"] || "-", kod: stored["kod"] || "-")
      end
      found
    end

    def translation_data(_target = nil)
      { szczegoly: @details.join("; ") }
    end

    def text(key, **args)
      ::I18n.t("minos_moderation.problems.#{key}", **args)
    end
  end
end
