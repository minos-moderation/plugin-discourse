# frozen_string_literal: true

module MinosModeration
  # What happens to a held post, and what a pending entry needs: pure functions of the
  # verdict, the administrator's settings and what the plugin knows about the post.
  #
  # Everything that decides publish or hold is here, so that the standalone tier proves it
  # without Discourse; `VerdictApplier` only executes the result. Unknown values fail
  # closed: an unknown failure mode is fail-closed, an unknown censored or blocked action
  # leaves the post to the moderators, and a payload without a known verdict goes to the
  # failure mode. Nothing unknown ever publishes.
  #
  # Plain Ruby: no Rails, so the standalone tier runs it without Discourse.
  module Decision
    # `minos_failure_mode` value that publishes an unassessed post.
    FAIL_OPEN = "fail-open"

    # `minos_censored_action` value that publishes the masked text.
    PUBLISH_MASKED = "publikuj_ocenzurowany"

    # `minos_blocked_action` value that rejects a blocked post.
    REJECT_BLOCKED = "odrzuc"

    # Every action a decision may take.
    ACTIONS = %i[approve approve_masked reject leave].freeze

    # Every reason a decision may give, here or when `VerdictApplier` cannot carry one out
    # (`mask_unmappable`, `topic_closed`, `action_failed`). Each but `verdict` has a text
    # under `minos_moderation.reasons` in the locales.
    REASONS = %i[
      verdict core_hold edited unassessed timeout config no_text truncated censored_setting
      no_masked_text mask_unmappable blocked_setting support topic_closed action_failed
    ].freeze

    # Seconds a finished entry is kept, to recognise a late repeated delivery.
    PURGE_AFTER_S = 30 * 24 * 3600

    # Seconds after which a received verdict whose job has not run is applied again.
    REAPPLY_AFTER_S = 120

    # Seconds after which a submission still marked as being sent is presumed lost.
    STALE_SENDING_S = 120

    # The decision about one post.
    #
    # - `action`: `:approve` (publish as it is), `:approve_masked` (publish `ocenzurowany`
    #   carried onto the Markdown), `:reject` or `:leave` (to the moderators);
    # - `reason`: why, as a key of `minos_moderation.reasons` (`:verdict` when the verdict
    #   alone decided);
    # - `unassessed`: true when the failure mode decided, not a verdict;
    # - `support`: true when the gateway set `wsparcie`, so the moderators are told.
    Result = Struct.new(:action, :reason, :unassessed, :support, keyword_init: true)

    # Decides what a delivered verdict does to its post.
    #
    # @param verdict [Hash{String => Object}] a payload read by `WebhookPayload.parse`.
    # @param settings [Hash{String => String}] `failure_mode`, `censored_action`,
    #   `blocked_action` (`Settings.decision`).
    # @param truncated [Boolean] whether the post was longer than the text sent for it.
    # @param core_hold [Boolean] whether Discourse itself held the post for review.
    # @param edited [Boolean] whether the post changed in the queue after it was sent.
    # @return [Result] the decision.
    def self.for_verdict(verdict, settings, truncated: false, core_hold: false, edited: false)
      verdict = {} unless verdict.is_a?(Hash)
      support = verdict["wsparcie"] == true
      # The forum's own review rule, or a moderator's edit, outranks the gateway.
      return leave(core_hold ? :core_hold : :edited, support) if core_hold || edited
      return for_failure(settings, :unassessed, support: support) if verdict["status"] != "ocenione"

      case verdict["kwalifikacja"]
      when "bezpieczne"
        return leave(:truncated, support) if truncated && !fail_open?(settings)

        result(:approve, truncated ? :truncated : :verdict, support, unassessed: truncated)
      when "ocenzurowane"
        censored(verdict, settings, truncated, support)
      when "zablokowane"
        # A post that reads as self-harm is never rejected automatically: `wsparcie` asks
        # for support, not punishment, so a person decides.
        return leave(:support, support) if support
        return leave(:blocked_setting, support) if settings["blocked_action"] != REJECT_BLOCKED

        result(:reject, :verdict, support)
      else
        for_failure(settings, :unassessed, support: support)
      end
    end

    # Decides what the failure mode does to a post without a verdict.
    #
    # @param settings [Hash{String => String}] as in {for_verdict}.
    # @param reason [Symbol] `:unassessed`, `:timeout`, `:config` or `:no_text`.
    # @param support [Boolean] whether a verdict set `wsparcie` anyway.
    # @return [Result] `:approve` under fail-open, `:leave` under anything else.
    def self.for_failure(settings, reason, support: false)
      return leave(reason, support, unassessed: true) unless fail_open?(settings)

      result(:approve, reason, support, unassessed: true)
    end

    # What a pending entry needs now; the sweeper's rules.
    #
    # @param entry [Hash{String => Object}] the entry as `Store` keeps it.
    # @param now [Integer] the clock, in seconds.
    # @param timeout_s [Integer] `Settings.timeout_s`.
    # @return [Symbol, nil] `:resubmit` (a retry is due, or a send was lost), `:timeout`
    #   (no verdict in time: the failure mode), `:reapply` (a received verdict was not
    #   applied), `:purge` (a finished entry is old) or nil (nothing yet).
    def self.for_entry(entry, now:, timeout_s:)
      age = ->(field) { now - entry[field].to_i }
      case entry["status"]
      when "done"
        :purge if age.call("handled_at") > PURGE_AFTER_S
      when "received"
        :reapply if age.call("received_at") > REAPPLY_AFTER_S
      when "submitted"
        :timeout if age.call("submitted_at") > timeout_s
      when "queued"
        return :timeout if age.call("queued_at") > timeout_s

        :resubmit if entry["retry_at"].to_i <= now
      when "sending"
        return :timeout if age.call("queued_at") > timeout_s

        :resubmit if age.call("sending_at") > STALE_SENDING_S
      else
        :timeout
      end
    end

    # @param settings [Hash{String => String}] as in {for_verdict}.
    # @return [Boolean] whether the administrator chose fail-open; anything else is closed.
    def self.fail_open?(settings)
      settings["failure_mode"] == FAIL_OPEN
    end

    # `ocenzurowane`: publish the masked text, or leave the post.
    #
    # @return [Result] the decision.
    def self.censored(verdict, settings, truncated, support)
      return leave(:censored_setting, support) if settings["censored_action"] != PUBLISH_MASKED

      masked = verdict["ocenzurowany"]
      return leave(:no_masked_text, support) unless masked.is_a?(String) && !masked.empty?
      return leave(:truncated, support) if truncated && !fail_open?(settings)

      result(:approve_masked, truncated ? :truncated : :verdict, support, unassessed: truncated)
    end

    # @return [Result] a `:leave` decision.
    def self.leave(reason, support, unassessed: false)
      result(:leave, reason, support, unassessed: unassessed)
    end

    # @return [Result] a decision.
    def self.result(action, reason, support, unassessed: false)
      Result.new(action: action, reason: reason, unassessed: unassessed, support: support)
    end

    private_class_method :censored, :leave, :result
  end
end
