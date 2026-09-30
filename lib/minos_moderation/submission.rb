# frozen_string_literal: true

module MinosModeration
  # Sends one held post to the gateway (`Jobs::MinosSubmit`) and records what came back.
  #
  # The contract's rules for an answer: `202` means the verdict will be delivered to the
  # webhook; `429` and `503` (and a timeout or a `5xx`) mean "keep it pending and send it
  # again after `ponow_za_s`, or after a backoff"; any other `4xx` is a configuration
  # error that sending again cannot fix, so the failure mode decides the post and the
  # administrator sees the code on the dashboard. The log gets the status and the code,
  # never the text, the key or the body.
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
      return unless claim

      reviewable = ::ReviewableQueuedPost.find_by(id: @id)
      return VerdictApplier.new(@id).finish("resolved_elsewhere") unless reviewable&.pending?

      endpoint = Scores.endpoint(Settings.gateway_url)
      key = Settings.api_key
      return VerdictApplier.new(@id).apply_failure(:config) if endpoint.nil? || key.empty?

      raw = reviewable.payload["raw"].to_s
      text = Text.for_submission(raw)
      return VerdictApplier.new(@id).apply_failure(:no_text) if text[:text].empty?

      Store.update(@id) do |entry|
        entry.merge("text_digest" => text[:digest], "truncated" => text[:truncated])
      end
      body =
        Scores.request_body(
          item_id: Scores.item_id(@id),
          text: text[:text],
          profile: Settings.profile,
          meta: {
            "links" => Text.link_count(raw),
            "author_first_post" => first_post?(reviewable.target_created_by),
          },
        )
      handle(send_request(endpoint, key, body))
    end

    private

    # Marks the entry as being sent, if it is due.
    #
    # @return [Boolean] whether this attempt goes ahead.
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
          entry.merge("status" => "sending", "sending_at" => now) if due
        end
      !claimed.nil?
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

        entry.merge(
          "status" => "submitted",
          "submitted_at" => now,
          "attempts" => entry["attempts"].to_i + 1,
        )
      end
      Store.clear_problem
    end

    def retry_later(outcome)
      now = Time.now.to_i
      delay = nil
      Store.update(@id) do |entry|
        next nil unless entry["status"] == "sending"

        attempts = entry["attempts"].to_i + 1
        delay = Scores.backoff(attempts, outcome.retry_in)
        entry.merge("status" => "queued", "attempts" => attempts, "retry_at" => now + delay)
      end
      return unless delay

      log("will retry in #{delay} s", outcome)
      ::Jobs.enqueue_in(delay, :minos_submit, reviewable_id: @id)
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
