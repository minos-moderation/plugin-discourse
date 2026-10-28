# frozen_string_literal: true

module MinosModeration
  # Sends one held post to the gateway (`Jobs::MinosSubmit`) and records what came back.
  #
  # The contract's rules for an answer: `202` means the verdict will be delivered to the
  # webhook; `429` and `503` (and a timeout or a `5xx`) mean "keep it pending and send it
  # again after `ponow_za_s`, or after a backoff" — unless `ponow_za_s` ends after the
  # post's time-out, when the failure mode applies at once; any other `4xx` is a
  # configuration error that sending again cannot fix, so the failure mode decides the
  # post and the administrator sees the code on the dashboard. A daily limit or an
  # overload (`Scores::LIMITS`) is shown there too, with the time it ends, until the next
  # `202`. The log gets the status and the code, never the text, the key or the body.
  class Submission
    # Creates a post's entry and schedules its first attempt.
    #
    # @param reviewable [ReviewableQueuedPost] the held post.
    # @param core_hold [String, nil] Discourse's own reason for holding it, if any.
    # @return [void]
    def self.enqueue(reviewable, core_hold:)
      now = Time.now.to_i
      Store.set(
        reviewable.id,
        {
          "status" => "queued",
          "queued_at" => now,
          "retry_at" => now,
          "attempts" => 0,
          "core_hold" => core_hold,
        },
      )
      ::Jobs.enqueue(:minos_submit, reviewable_id: reviewable.id)
    end

    # @param reviewable_id [Integer] the held post's reviewable.
    def initialize(reviewable_id)
      @id = Integer(reviewable_id)
    end

    # One attempt. A no-op unless the entry is due: a repeated or late job sends nothing.
    #
    # @return [void]
    def run
      return unless Settings.enabled?

      attempt = claim
      return unless attempt

      reviewable = ::ReviewableQueuedPost.find_by(id: @id)
      return VerdictApplier.new(@id).finish("resolved_elsewhere") unless reviewable&.pending?

      endpoint = Scores.endpoint(Settings.gateway_url)
      key = Settings.api_key
      return VerdictApplier.new(@id).apply_failure(:config) if endpoint.nil? || key.empty?

      raw = reviewable.payload["raw"].to_s
      text = Text.for_submission(raw, reviewable.payload["title"])
      return VerdictApplier.new(@id).apply_failure(:no_text) if text[:text].empty?

      Store.update(@id) do |entry|
        # Every attempt's digest, so a verdict for an earlier attempt of the same text
        # still counts (`Decision.verdict_for_entry?`).
        digests = entry["digests"].is_a?(Hash) ? entry["digests"] : {}
        entry.merge(
          "text_digest" => text[:digest],
          "truncated" => text[:truncated],
          "digests" => digests.merge(attempt.to_s => text[:digest]),
        )
      end
      meta = {
        "links" => Text.link_count(raw),
        "author_first_post" => first_post?(reviewable.target_created_by),
      }
      domains = link_domains(raw)
      meta["link_domains"] = domains if domains.any?
      body =
        Scores.request_body(
          item_id: Scores.item_id(@id, attempt),
          text: text[:text],
          profile: Settings.profile,
          meta: meta,
        )
      handle(send_request(endpoint, key, body))
    end

    private

    # Marks the entry as being sent, if it is due, and numbers the attempt: its item id is
    # `discourse:<id>.<attempt>`, and only a verdict for the latest attempt is taken.
    #
    # @return [Integer, nil] the attempt's number, or nil when nothing is due.
    def claim
      now = Time.now.to_i
      claimed =
        Store.update(@id) do |entry|
          due =
            (entry["status"] == "queued" && entry["retry_at"].to_i <= now) ||
              (
                entry["status"] == "sending" &&
                  now - entry["sending_at"].to_i > Decision::STALE_SENDING_S
              )
          next nil unless due

          attempt = entry["attempts"].to_i + 1
          entry.merge(
            "status" => "sending",
            "sending_at" => now,
            "attempts" => attempt,
            "attempt" => attempt,
          )
        end
      claimed && claimed["attempt"]
    end

    # The registrable domains the post links to, images included, for `link_domains`.
    #
    # @param raw [String] the post's raw Markdown.
    # @return [Array<String>] at most ten distinct domains; empty without the public
    #   suffix list (the `public_suffix` gem, which Discourse bundles through addressable).
    def link_domains(raw)
      return [] unless defined?(::PublicSuffix)

      domains =
        Text.link_hosts(raw).filter_map do |host|
          domain = ::PublicSuffix.domain(host)
          domain if domain.is_a?(String) && Scores::DOMAIN.match?(domain)
        rescue StandardError
          nil
        end
      domains.uniq.first(Scores::MAX_LINK_DOMAINS)
    end

    # @return [Scores::Outcome] the gateway's answer, read.
    def send_request(endpoint, key, body)
      response = GatewayClient.new(http_class: http_class).post(endpoint, key, body)
      Scores.classify(response.status, response.body)
    rescue GatewayClient::TransportError => e
      Scores.classify_transport(e.kind)
    end

    # Records an outcome and does what it calls for.
    #
    # @param outcome [Scores::Outcome] the answer, read.
    # @return [void]
    def handle(outcome)
      case outcome.kind
      when :accepted
        accepted
      when :retry
        retry_later(outcome)
      else
        refused(outcome)
      end
    end

    def accepted
      now = Time.now.to_i
      Store.update(@id) do |entry|
        # A fast gateway may have delivered the verdict already: keep what it recorded.
        next nil unless entry["status"] == "sending"

        entry.merge("status" => "submitted", "submitted_at" => now)
      end
      Store.clear_problem
    end

    def retry_later(outcome)
      now = Time.now.to_i
      timeout_s = Settings.timeout_s
      delay = nil
      too_late = false
      Store.update(@id) do |entry|
        next nil unless entry["status"] == "sending"

        too_late =
          Decision.refusal_outlasts_timeout?(
            entry,
            now: now,
            timeout_s: timeout_s,
            retry_in: outcome.retry_in,
          )
        next nil if too_late

        delay = Scores.backoff(entry["attempts"].to_i, outcome.retry_in)
        entry.merge("status" => "queued", "retry_at" => now + delay)
      end
      record_limit(outcome, now)
      if too_late
        log("refuses until after the post's time-out", outcome)
        return VerdictApplier.new(@id).apply_failure(:limit)
      end
      return unless delay

      log("will retry in #{delay} s", outcome)
      ::Jobs.enqueue_in(delay, :minos_submit, reviewable_id: @id)
    end

    # Tells the administrator that the gateway accepts nothing until a given time.
    #
    # @param outcome [Scores::Outcome] a `:retry` answer.
    # @param now [Integer] the clock, in seconds.
    # @return [void]
    def record_limit(outcome, now)
      reason = Scores.limit_state(outcome)
      return unless reason

      # The gateway's own ponow_za_s, not the plugin's pause capped to 15 minutes.
      wait = outcome.retry_in || Scores::BACKOFF_S
      Store.record_limit(
        reason: reason,
        until_at: now + wait,
        http: outcome.http,
        code: outcome.code,
      )
    end

    def refused(outcome)
      reason =
        if outcome.http.nil?
          "disallowed_address"
        elsif outcome.http.between?(400, 499)
          "refused"
        else
          "unexpected"
        end
      Store.record_problem(reason: reason, http: outcome.http, code: outcome.code)
      log("refused the configuration", outcome)
      VerdictApplier.new(@id).apply_failure(:config)
    end

    # @param user [User, nil] the post's author.
    # @return [Boolean] whether this is the author's first post on the forum.
    def first_post?(user)
      !user.nil? && user.post_count.to_i.zero? && user.topic_count.to_i.zero?
    end

    # @return [Class] Discourse's SSRF-safe Net::HTTP.
    def http_class
      defined?(::FinalDestination::HTTP) ? ::FinalDestination::HTTP : ::Net::HTTP
    end

    def log(what, outcome)
      ::Rails.logger.warn(
        "[#{PLUGIN_NAME}] the gateway #{what}: reviewable #{@id}, " \
          "HTTP #{outcome.http || "-"}, kod #{outcome.code || "-"}",
      )
    end
  end
end
