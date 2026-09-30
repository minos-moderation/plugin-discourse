# frozen_string_literal: true

module MinosModeration
  # Carries out a `Decision` on a held post, through the reviewable, and records it.
  #
  # Publishing is `perform(system user, :approve_post)`, rejecting `:reject_post`; a masked
  # publication first edits the queued `raw` with `update_fields`, which Discourse records
  # in the reviewable's history. Every outcome leaves a note for the moderators on the
  # review item (a `ReviewableNote` by the system user). When an action cannot be carried
  # out — the topic was closed meanwhile, the masks do not map onto the Markdown, the
  # reviewable refuses — the post is left to the moderators, never published instead.
  #
  # Callers must not hold `Store.lock` for the same post: every public method takes it.
  class VerdictApplier
    # Entry states the failure mode no longer applies to: a verdict arrived, or it is over.
    CLOSED = %w[received done].freeze

    # @param reviewable_id [Integer] the held post's reviewable.
    def initialize(reviewable_id)
      @id = Integer(reviewable_id)
    end

    # Applies a received verdict (`Receiver`), once.
    #
    # A post whose text changed in the queue since it was sent, or that Discourse holds
    # for its own reasons, only gets the verdict as a note; see `Decision.for_verdict`.
    #
    # @return [void]
    def apply_verdict
      Store.lock(@id) do
        entry = Store.get(@id)
        next unless entry && entry["status"] == "received"

        verdict = entry["verdict"].to_h
        reviewable = pending_reviewable
        unless reviewable
          next close(entry.merge("verdict" => verdict.except("ocenzurowany")), "resolved_elsewhere")
        end

        decision =
          Decision.for_verdict(
            verdict,
            Settings.decision,
            truncated: entry["truncated"] == true,
            core_hold: entry["core_hold"].present?,
            edited: edited?(reviewable, entry),
          )
        execute(reviewable, entry, decision, verdict)
      end
    end

    # Applies the failure mode to a post that will get no verdict.
    #
    # @param reason [Symbol] `:timeout`, `:config` or `:no_text`.
    # @return [void]
    def apply_failure(reason)
      Store.lock(@id) do
        entry = Store.get(@id)
        # Any state but a received verdict or a finished entry: an entry the plugin does not
        # understand gets the failure mode rather than waiting forever.
        next if entry.nil? || CLOSED.include?(entry["status"])

        reviewable = pending_reviewable
        next close(entry, "resolved_elsewhere") unless reviewable

        execute(reviewable, entry, Decision.for_failure(Settings.decision, reason.to_sym), nil)
      end
    end

    # Marks a post's entry as finished without acting on the post.
    #
    # @param outcome [String] what happened instead.
    # @return [void]
    def finish(outcome)
      Store.lock(@id) do
        entry = Store.get(@id)
        close(entry, outcome) if entry && entry["status"] != "done"
      end
    end

    private

    # @return [Boolean] whether the post no longer reads as the text that was assessed.
    def edited?(reviewable, entry)
      digest = entry["text_digest"]
      digest.nil? || Text.for_submission(reviewable.payload["raw"].to_s)[:digest] != digest
    end

    # @return [ReviewableQueuedPost, nil] the post's reviewable, while it is still pending.
    def pending_reviewable
      reviewable = ::ReviewableQueuedPost.find_by(id: @id)
      reviewable&.pending? ? reviewable : nil
    end

    # Carries out a decision, notes it and finishes the entry. Runs under the lock.
    #
    # @param reviewable [ReviewableQueuedPost] the pending post.
    # @param entry [Hash{String => Object}] its entry.
    # @param decision [Decision::Result] what to do.
    # @param verdict [Hash{String => Object}, nil] the verdict, when there is one.
    # @return [void]
    def execute(reviewable, entry, decision, verdict)
      done, extra = carry_out(reviewable, decision, verdict)
      note(reviewable, note_text(done, verdict))
      note(reviewable, translate("minos_moderation.notes.support")) if done.support
      stored_verdict = verdict&.except("ocenzurowany")
      close(
        entry.merge(extra).merge("verdict" => stored_verdict, "reason" => done.reason.to_s),
        done.action.to_s,
      )
    end

    # @return [Array(Decision::Result, Hash)] what was done, and fields for the entry.
    def carry_out(reviewable, decision, verdict)
      case decision.action
      when :approve
        return [instead(decision, :topic_closed), {}] if reviewable.topic&.closed?

        [act(reviewable, :approve_post, decision), {}]
      when :approve_masked
        approve_masked(reviewable, decision, verdict)
      when :reject
        [act(reviewable, :reject_post, decision), {}]
      else
        [decision, {}]
      end
    end

    # Publishes the masked text, keeping the original in the entry.
    #
    # @return [Array(Decision::Result, Hash)] what was done, and fields for the entry.
    def approve_masked(reviewable, decision, verdict)
      return [instead(decision, :topic_closed), {}] if reviewable.topic&.closed?

      raw = reviewable.payload["raw"].to_s
      sent = Text.for_submission(raw)[:text]
      masked = Text.apply_masks(raw, sent, verdict && verdict["ocenzurowany"])
      return [instead(decision, :mask_unmappable), {}] unless masked

      # String keys: the payload is a JSON column, and a symbol key would add a second
      # "raw" to it.
      reviewable.update_fields({ payload: { "raw" => masked } }, ::Discourse.system_user)
      [act(reviewable, :approve_post, decision), { "original" => raw }]
    end

    # @return [Decision::Result] the decision, or a `:leave` when the action failed.
    def act(reviewable, action_id, decision)
      result = reviewable.perform(::Discourse.system_user, action_id)
      return decision if result.success?

      log("#{action_id} did not succeed")
      instead(decision, :action_failed)
    rescue ::Reviewable::InvalidAction, ::Reviewable::UpdateConflict,
           ::ActiveRecord::ActiveRecordError, ::Discourse::InvalidAccess => e
      log("#{action_id} raised #{e.class.name}")
      instead(decision, :action_failed)
    end

    # @return [Decision::Result] a `:leave` in place of a decision that could not be done.
    def instead(decision, reason)
      Decision::Result.new(
        action: :leave,
        reason: reason,
        unassessed: decision.unassessed,
        support: decision.support,
      )
    end

    # @param entry [Hash{String => Object}] the entry.
    # @param outcome [String] what was done.
    # @return [void]
    def close(entry, outcome)
      finished = { "status" => "done", "outcome" => outcome, "handled_at" => Time.now.to_i }
      Store.set(@id, entry.merge(finished))
    end

    # The moderators' note about what was done, in the forum's default language.
    #
    # @return [String] the note.
    def note_text(done, verdict)
      header =
        if verdict && verdict["status"] == "ocenione"
          categories = Array(verdict["kategorie"])
          listed =
            if categories.empty?
              translate("minos_moderation.notes.no_categories")
            else
              categories.join(", ")
            end
          translate(
            "minos_moderation.notes.verdict",
            werdykt: verdict["kwalifikacja"],
            kategorie: listed,
          )
        else
          translate("minos_moderation.notes.no_verdict")
        end
      action = done.unassessed && done.action != :leave ? "#{done.action}_unassessed" : done.action
      parts = [header, translate("minos_moderation.actions.#{action}")]
      if done.reason != :verdict
        reason = translate("minos_moderation.reasons.#{done.reason}")
        parts << translate("minos_moderation.notes.reason", powod: reason)
      end
      parts.join(" ")
    end

    # Adds a note to the review item, where the Discourse version has notes.
    #
    # @return [void]
    def note(reviewable, text)
      return unless defined?(::ReviewableNote) && reviewable.respond_to?(:reviewable_notes)

      limit = ::ReviewableNote::MAX_CONTENT_LENGTH
      reviewable.reviewable_notes.create!(user: ::Discourse.system_user, content: text[0, limit])
    rescue ::ActiveRecord::ActiveRecordError => e
      log("a note could not be added (#{e.class.name})")
    end

    def translate(key, **args)
      ::I18n.with_locale(::SiteSetting.default_locale) { ::I18n.t(key, **args) }
    end

    def log(what)
      ::Rails.logger.warn("[#{PLUGIN_NAME}] reviewable #{@id}: #{what}")
    end
  end
end
