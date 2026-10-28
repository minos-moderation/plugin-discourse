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

    # Every action a decision may take: on a held post `approve`, `approve_masked`, `reject`
    # or `leave`; on a post the failure mode already published, `keep`, `mask` or `hide`.
    ACTIONS = %i[approve approve_masked reject leave keep mask hide].freeze

    # Every reason a decision may give, here or when `VerdictApplier` cannot carry one out
    # (`mask_unmappable`, `topic_closed`, `action_failed`, `apply_stuck`). Each but
    # `verdict` has a text under `minos_moderation.reasons` in the locales.
    REASONS = %i[
      verdict core_hold edited unassessed timeout limit config no_text truncated
      censored_setting no_masked_text mask_unmappable blocked_setting support topic_closed
      action_failed apply_stuck person_acted
    ].freeze

    # Seconds a finished entry is kept, to recognise a late repeated delivery.
    PURGE_AFTER_S = 30 * 24 * 3600

    # Seconds after which a received verdict whose job has not run is applied again.
    REAPPLY_AFTER_S = 120

    # Seconds after which a received verdict that still could not be applied is given up:
    # the post stays with the moderators, and the sweeper stops trying every five minutes.
    MAX_REAPPLY_S = 24 * 3600

    # Seconds after which a submission still marked as being sent is presumed lost.
    STALE_SENDING_S = 120

    # The longest shared pause, in seconds: a day, the longest window the gateway's limits
    # count in. A `ponow_za_s` beyond it pauses the plugin for a day, so that a malformed
    # answer can never stop it for longer.
    MAX_PAUSE_S = 24 * 3600

    # The lowest `minos_timeout_minutes` the plugin works with. The gateway tries to deliver
    # a verdict for 15 minutes; a shorter wait would give a post the failure mode while its
    # verdict is still on the way. `config/settings.yml` offers nothing lower, and
    # {timeout_s} raises a value stored before the minimum was raised.
    MIN_TIMEOUT_MINUTES = 20

    # The trust levels Discourse knows (`TrustLevel.valid_range`).
    TRUST_LEVELS = (0..4).freeze

    # The decision about one post.
    #
    # - `action`: `:approve` (publish as it is), `:approve_masked` (publish `ocenzurowany`
    #   carried onto the Markdown), `:reject` or `:leave` (to the moderators); for a post
    #   already published by the failure mode, `:keep`, `:mask` or `:hide`;
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
    # Fail-open never overrides the forum's own review: a post Discourse held itself (a new
    # user, a watched word, a category that needs approval, a fast typer, an auto-silenced
    # or e-mail-spam author) or a post a moderator edited in the queue stays with the
    # moderators, with a note — approving it would also unsilence an auto-silenced author.
    #
    # @param settings [Hash{String => String}] as in {for_verdict}.
    # @param reason [Symbol] `:unassessed`, `:timeout`, `:limit`, `:config` or `:no_text`.
    # @param support [Boolean] whether a verdict set `wsparcie` anyway.
    # @param core_hold [Boolean] whether Discourse itself held the post for review.
    # @param edited [Boolean] whether the post changed in the queue after it was sent.
    # @return [Result] `:approve` under fail-open, `:leave` under anything else, and always
    #   `:leave` for a post Discourse held or a moderator edited.
    def self.for_failure(settings, reason, support: false, core_hold: false, edited: false)
      return leave(:core_hold, support, unassessed: true) if core_hold
      return leave(:edited, support, unassessed: true) if edited
      return leave(reason, support, unassessed: true) unless fail_open?(settings)

      result(:approve, reason, support, unassessed: true)
    end

    # Decides what a verdict that arrives after the failure mode published its post does.
    #
    # Only fail-open publishes a post without a verdict, and the gateway may still deliver
    # one. A person's decision since the publication stays final; otherwise the verdict
    # is carried out on the published post, as far as a published post allows: `hide`
    # takes it out of view (a moderator can show it again), `mask` edits the masked
    # fragments in. Nothing here publishes or deletes. A post with `wsparcie` is never
    # hidden: hiding is an automatic sanction, and Discourse also messages the author
    # about it, while `wsparcie` asks for support — the post stays as it is, with the note,
    # and a person decides (shared plugin rule 9).
    #
    # @param verdict [Hash{String => Object}] a payload read by `WebhookPayload.parse`.
    # @param settings [Hash{String => String}] as in {for_verdict}.
    # @param truncated [Boolean] whether the post was longer than the text sent for it.
    # @param acted [Boolean] whether a person acted on the published post since.
    # @return [Result] `:keep`, `:mask` or `:hide`; never `:hide` with `wsparcie`.
    def self.for_late_verdict(verdict, settings, truncated: false, acted: false)
      verdict = {} unless verdict.is_a?(Hash)
      support = verdict["wsparcie"] == true
      return result(:keep, :person_acted, support) if acted
      return result(:keep, :unassessed, support) if verdict["status"] != "ocenione"

      decision = late(verdict, settings, truncated, support)
      return result(:keep, :support, support) if support && decision.action == :hide

      decision
    end

    # The seconds without a verdict after which a post gets the failure mode.
    #
    # @param minutes [Integer, String, nil] `minos_timeout_minutes` as stored.
    # @return [Integer] the minutes in seconds, never below {MIN_TIMEOUT_MINUTES}: a value
    #   saved before the minimum was raised stays in the database, and Discourse checks
    #   `min` only when a value is written.
    def self.timeout_s(minutes)
      [minutes.to_i, MIN_TIMEOUT_MINUTES].max * 60
    end

    # {for_late_verdict} for an assessed post, before the support rule.
    #
    # @return [Result] `:keep`, `:mask` or `:hide`.
    def self.late(verdict, settings, truncated, support)
      case verdict["kwalifikacja"]
      when "bezpieczne"
        result(:keep, truncated ? :truncated : :verdict, support)
      when "ocenzurowane"
        masked = verdict["ocenzurowany"]
        publish = settings["censored_action"] == PUBLISH_MASKED
        return result(:hide, :censored_setting, support) unless publish
        return result(:hide, :no_masked_text, support) unless masked.is_a?(String) && !masked.empty?
        return result(:hide, :truncated, support) if truncated

        result(:mask, :verdict, support)
      when "zablokowane"
        result(:hide, :verdict, support)
      else
        result(:keep, :unassessed, support)
      end
    end

    # Whether a delivered verdict is for the text the entry waits on. Each attempt has its
    # own item id (`discourse:<review item>.<attempt>`), and only the current attempt's
    # verdict used to count; but an earlier attempt's verdict assessed the same text when
    # its digest equals the current attempt's, and one verdict is enough (the current
    # attempt may even have been refused). An entry without per-attempt digests (written
    # before them), or whose current attempt has no digest yet, takes only the current
    # attempt: nothing unknown is taken.
    #
    # @param entry [Hash{String => Object}] the entry as `Store` keeps it (`attempt`,
    #   `digests`: attempt number as a String => text digest).
    # @param attempt [Integer] the attempt in the delivered item id.
    # @return [Boolean] whether the verdict may be taken.
    def self.verdict_for_entry?(entry, attempt)
      current = entry["attempt"].to_i
      return true if current.positive? && attempt == current
      return false unless attempt.is_a?(Integer) && attempt.positive? && attempt < current

      digests = entry["digests"]
      return false unless digests.is_a?(Hash)

      earlier = digests[attempt.to_s]
      earlier.is_a?(String) && !earlier.empty? && earlier == digests[current.to_s]
    end

    # The administrator's scope as stored, read: which new posts the plugin holds and
    # sends. An empty list is "every category" or "no group"; a value that cannot be read
    # is nil, which {in_scope?} ignores, so it never narrows the scope.
    #
    # @param categories [String, nil] `minos_categories`: category ids joined by "|".
    # @param exempt_groups [String, nil] `minos_exempt_groups`: group ids joined by "|".
    # @param max_trust_level [Integer, String, nil] `minos_max_trust_level`.
    # @return [Hash{String => Object}] `categories` and `exempt_groups` (Array<Integer> or
    #   nil), `max_trust_level` (Integer or nil).
    def self.scope_settings(categories:, exempt_groups:, max_trust_level:)
      level = Integer(max_trust_level.to_s, 10, exception: false)
      {
        "categories" => id_list(categories),
        "exempt_groups" => id_list(exempt_groups),
        "max_trust_level" => TRUST_LEVELS.cover?(level) ? level : nil,
      }
    end

    # Whether a new post is in the administrator's scope, so that the plugin holds it and
    # sends it. A post out of scope is not the plugin's at all: Discourse publishes or holds
    # it by its own rules, nothing is sent and no verdict is ever guessed for it. Whatever
    # cannot be told fails toward moderation: an unknown category, author's groups or trust
    # level, or a setting that cannot be read, never takes a post out of scope.
    #
    # @param category_ids [Array<Integer>, nil] the post's category and the categories
    #   above it (a subcategory of a chosen category is in scope); nil when unknown.
    # @param group_ids [Array<Integer>, nil] the author's groups; nil when unknown.
    # @param trust_level [Integer, nil] the author's trust level; nil when unknown.
    # @param scope [Hash{String => Object}] {scope_settings}, its `categories` narrowed to
    #   the categories that still exist.
    # @return [Boolean] false only when a readable setting puts the post out: the author's
    #   trust level is above `max_trust_level`, the author is in an exempt group, or the
    #   post's category (and every one above it) is outside a non-empty `categories`.
    def self.in_scope?(category_ids:, group_ids:, trust_level:, scope:)
      scope = {} unless scope.is_a?(Hash)
      highest = scope["max_trust_level"]
      if highest.is_a?(Integer) && trust_level.is_a?(Integer) && trust_level > highest
        return false
      end

      exempt = scope["exempt_groups"]
      return false if exempt.is_a?(Array) && group_ids.is_a?(Array) && (exempt & group_ids).any?

      chosen = scope["categories"]
      return true unless chosen.is_a?(Array) && !chosen.empty?
      return true unless category_ids.is_a?(Array) && !category_ids.empty?

      (chosen & category_ids).any?
    end

    # Whether a pending entry is due to be sent: waiting and its retry time has come, or
    # marked as being sent for longer than {STALE_SENDING_S} (that send was lost).
    #
    # @param entry [Hash{String => Object}] the entry as `Store` keeps it.
    # @param now [Integer] the clock, in seconds.
    # @return [Boolean]
    def self.due?(entry, now:)
      case entry["status"]
      when "queued"
        entry["retry_at"].to_i <= now
      when "sending"
        now - entry["sending_at"].to_i > STALE_SENDING_S
      else
        false
      end
    end

    # Until when no post is sent after a refusal (shared plugin rule F5a): a `429` (the
    # key's limits, the shared ceiling, a full queue), a `5xx`, a network failure or a
    # `2xx` that accepted nothing closes the gateway for every post, not only for the one
    # refused, so the next posts wait without a request that could only be refused too.
    #
    # @param now [Integer] the clock, in seconds.
    # @param retry_in [Integer, nil] the refusal's `ponow_za_s`, as the gateway gave it.
    # @param delay [Integer] the plugin's own pause for the refused post, used without a
    #   `ponow_za_s` (`Scores.backoff`).
    # @return [Integer] epoch seconds: now plus `ponow_za_s` (or `delay`), at least one
    #   second and at most {MAX_PAUSE_S} away.
    def self.pause_until(now:, retry_in:, delay:)
      wait = retry_in.is_a?(Integer) && retry_in.positive? ? retry_in : delay.to_i
      now + wait.clamp(1, MAX_PAUSE_S)
    end

    # @param pause [Hash{String => Object}, nil] the shared pause as `Store` keeps it
    #   (`until`, epoch seconds).
    # @param now [Integer] the clock, in seconds.
    # @return [Integer, nil] when sending may resume, while the pause is in force; nil
    #   when there is none, it is over or it cannot be read (an unreadable pause never
    #   stops the plugin).
    def self.paused_until(pause, now:)
      return nil unless pause.is_a?(Hash)

      resume = pause["until"]
      resume.is_a?(Integer) && resume > now && resume <= now + MAX_PAUSE_S ? resume : nil
    end

    # Whether an entry is a post the failure mode held after its time-out, so that a
    # verdict delivered late still applies to it (shared plugin rule A6): finished as
    # `leave` with the reason `timeout`. A post the failure mode published is
    # `auto_published` instead; one Discourse held itself, one a moderator edited, a
    # refusal, a configuration error or `nieocenione` finished with another reason, and no
    # verdict is taken for those. Whether the review item is still undecided is the
    # caller's to check.
    #
    # @param entry [Hash{String => Object}, nil] the entry as `Store` keeps it.
    # @return [Boolean]
    def self.held_after_timeout?(entry)
      entry.is_a?(Hash) && entry["status"] == "done" && entry["outcome"] == "leave" &&
        entry["reason"] == "timeout"
    end

    # Whether a refusal keeps the gateway closed past the post's time-out, so that the
    # failure mode applies at once instead of a retry that could only come too late
    # (shared plugin rule 3(a)). The gateway's `ponow_za_s` is compared as it was given,
    # before the cap on the plugin's own retry pause (`Scores::MAX_BACKOFF_S`): a daily
    # limit's 36000 s would otherwise read as a retry in 15 minutes.
    #
    # @param entry [Hash{String => Object}] the entry as `Store` keeps it (`queued_at`).
    # @param now [Integer] the clock, in seconds.
    # @param timeout_s [Integer] `Settings.timeout_s`.
    # @param retry_in [Integer, nil] the refusal's `ponow_za_s`, uncapped.
    # @return [Boolean] true when the gateway refuses until after the post's time-out.
    def self.refusal_outlasts_timeout?(entry, now:, timeout_s:, retry_in:)
      return false unless retry_in.is_a?(Integer) && retry_in.positive?

      now + retry_in > entry["queued_at"].to_i + timeout_s
    end

    # What a pending entry needs now; the sweeper's rules.
    #
    # @param entry [Hash{String => Object}] the entry as `Store` keeps it.
    # @param now [Integer] the clock, in seconds.
    # @param timeout_s [Integer] `Settings.timeout_s`.
    # @return [Symbol, nil] `:resubmit` (a retry is due, or a send was lost), `:timeout`
    #   (no verdict in time: the failure mode), `:reapply` (a received verdict was not
    #   applied), `:abandon` (a received verdict could not be applied for a day: leave the
    #   post to the moderators), `:purge` (a finished entry is old) or nil (nothing yet).
    def self.for_entry(entry, now:, timeout_s:)
      age = ->(field) { now - entry[field].to_i }
      case entry["status"]
      when "done", "auto_published"
        :purge if age.call("handled_at") > PURGE_AFTER_S
      when "received"
        return :abandon if age.call("received_at") > MAX_REAPPLY_S

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

    # @param value [String, nil] ids joined by "|", as Discourse stores a list setting.
    # @return [Array<Integer>, nil] the ids (empty for an empty value), or nil when a part
    #   is not a whole number of zero or more (the group "everyone" is 0).
    def self.id_list(value)
      parts = value.to_s.split("|").map(&:strip).reject(&:empty?)
      ids = parts.map { |part| Integer(part, 10, exception: false) }
      ids.all? { |id| id.is_a?(Integer) && id >= 0 } ? ids.uniq : nil
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
      # Under both modes: the masks cover only the beginning, and a beginning that needed
      # masking says little good about the unassessed rest.
      return leave(:truncated, support) if truncated

      result(:approve_masked, :verdict, support)
    end

    # @return [Result] a `:leave` decision.
    def self.leave(reason, support, unassessed: false)
      result(:leave, reason, support, unassessed: unassessed)
    end

    # @return [Result] a decision.
    def self.result(action, reason, support, unassessed: false)
      Result.new(action: action, reason: reason, unassessed: unassessed, support: support)
    end

    private_class_method :censored, :late, :leave, :result, :id_list
  end
end
