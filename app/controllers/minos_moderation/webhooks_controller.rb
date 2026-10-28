# frozen_string_literal: true

module ::MinosModeration
  # Receives the gateway's verdicts: `POST /minos/webhook`.
  #
  # The contract's receiving checklist, in order: read the raw body before anything parses
  # it; verify `X-Wergiliusz-Podpis` and answer 401 to a failure (the gateway retries, so a
  # clock issue gets another chance); parse, and answer 400 to what is not a payload;
  # drop an id that is not a pending post of this forum, or was already handled (delivery
  # is at least once); answer 200 at once and apply the verdict in a job.
  #
  # A `2xx` goes only to a delivery that was stored or deliberately dropped: the gateway
  # takes any `2xx` as delivered and keeps no copy. While the forum is read-only,
  # Discourse's own `block_if_readonly_mode` answers 503 before this action runs, so the
  # gateway retries; a disabled plugin answers 404 (`requires_plugin`).
  #
  # The gateway is not a browser session: no CSRF token, no XHR header, no login.
  class WebhooksController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    skip_before_action :verify_authenticity_token,
                       :check_xhr,
                       :redirect_to_login_if_required,
                       :preload_json

    # @return [void]
    def receive
      body = request.raw_post.to_s
      secret = Settings.webhook_secret
      header = request.headers["X-Wergiliusz-Podpis"].to_s
      unless !secret.empty? && Signature.verify(secret, header, body, Time.now.to_i)
        return head(:unauthorized)
      end

      payload = WebhookPayload.parse(body)
      return head(:bad_request) if payload.nil?

      Receiver.accept(payload)
      head(:ok)
    end
  end
end
