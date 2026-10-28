# frozen_string_literal: true

require "digest"

module MinosModeration
  # Carries out a `Decision` on a held post, through the reviewable, and records it.
  #
  # Publishing is `perform(system user, :approve_post)`, rejecting `:reject_post`; a masked
  # publication first edits the queued `raw` (and `title`) with `update_fields`, which
  # Discourse records in the reviewable's history, and approves only once the reviewable,
  # read back from the database, carries exactly the masks. Every outcome leaves a note
  # for the moderators on the review item (a `ReviewableNote` by the system user). When an
  # action cannot be carried out — the topic was closed meanwhile, the masks do not map
  # onto the Markdown, the reviewable refuses or does not keep the masks — the post is left
  # to the moderators, never published instead.
  #
  # A post the failure mode published (fail-open) keeps its entry as `auto_published`, so a
  # verdict that still arrives is carried out on the published post (`apply_late`).
  #
  # `wsparcie` (shared plugin rule A7) is an active signal for the moderators whatever the
  # verdict: a post still held is in their review queue already, with the note; a post
  # that is published gets a `notify_moderators` flag from the system user, a new item in
  # the same queue. Nothing about it ever goes to the author, and such a post is never
  # rejected or hidden automatically (`Decision`).
  #
  # The unmasked text is never copied into the plugin's store: the reviewable's history has
  # it, and for a `dane_osobowe` mask it is exactly the personal data the mask removed. The
  # entry keeps its digest only.
  #
  # Callers must not hold `Store.lock` for the same post: every public method takes it.
  class VerdictApplier
    # Entry states the failure mode no longer applies to: a verdict arrived, or it is over.
    CLOSED = %w[received done auto_published].freeze

    # Errors of the reviewable's and the post's own actions that leave the post as it was.
    ACTION_ERRORS = [
      ::Reviewable::InvalidAction,
      ::Reviewable::UpdateConflict,
      ::ActiveRecord::ActiveRecordError,
      ::Discourse::InvalidAccess,
    ].freeze

    # @param reviewable_id [Integer] the held post's reviewable.
    def initialize(reviewable_id)
      @id = Integer(reviewable_id)
    end

    # Applies a received verdict (`Receiver`), once.
    #
    # A post whose text changed in the queue since it was sent, or that Discourse holds
    # for its own reasons, only gets the verdict as a note; see `Decision.for_verdict`. A
    # post the failure mode already published gets `Decision.for_late_verdict`.
    #
    # @return [void]
    def apply_verdict
      Store.lock(@id) do
        entry = Store.get(@id)
        next unless entry && entry["status"] == "received"

        verdict = entry["verdict"].to_h
        next apply_late(entry, verdict) if entry["auto_published"]

        reviewable = pending_reviewable
        unless reviewable
          next close(entry.merge("verdict" => stored(verdict)), "resolved_elsewhere")
        end

        decision =
          Decision.for_verdict(
            verdict,
            Settings.decision,
            truncated: entry["truncated"] == true,
            core_hold: entry["core_hold"].present?,
            edited: changed_since_sent?(reviewable, entry, missing_digest: true),
          )
        execute(reviewable, entry, decision, verdict)
      end
    end

    # Applies the failure mode to a post that will get no verdict.
    #
    # @param reason [Symbol] `:timeout`, `:limit`, `:config` or `:no_text`.
    # @return [void]
    def apply_failure(reason)
      Store.lock(@id) do
        entry = Store.get(@id)
        # Any state but a received verdict or a finished entry: an entry the plugin does not
        # understand gets the failure mode rather than waiting forever.
        next if entry.nil? || CLOSED.include?(entry["status"])

        reviewable = pending_reviewable
        next close(entry, "resolved_elsewhere") unless reviewable

        decision =
          Decision.for_failure(
            Settings.decision,
            reason.to_sym,
            core_hold: entry["core_hold"].present?,
            edited: changed_since_sent?(reviewable, entry, missing_digest: false),
          )
        execute(reviewable, entry, decision, nil)
      end
    end

    # Gives up on a received verdict that could not be applied for a day
    # (`Decision::MAX_REAPPLY_S`): the post stays as it is, with a note, and the sweeper
    # stops trying.
    #
    # @return [void]
    def abandon
      Store.lock(@id) do
        entry = Store.get(@id)
        next unless entry && entry["status"] == "received"

        verdict = entry["verdict"].to_h
        done =
          Decision::Result.new(
            action: entry["auto_published"] ? :keep : :leave,
            reason: :apply_stuck,
            unassessed: false,
            support: verdict["wsparcie"] == true,
          )
        reviewable = ::ReviewableQueuedPost.find_by(id: @id)
        record(reviewable, done, verdict) if reviewable
        signal_support(published_post(entry["post_id"])) if done.support && done.action == :keep
        finished = entry.merge("verdict" => stored(verdict), "reason" => "apply_stuck")
        close(finished, done.action.to_s)
      end
    end

    # Marks a post's entry as finished without acting on the post.
    #
    # @param outcome [String] what happened instead.
    # @return [void]
    def finish(outcome)
      Store.lock(@id) do
        entry = Store.get(@id)
        close(entry, outcome) if entry && !%w[done auto_published].include?(entry["status"])
      end
    end

    private

    # @param missing_digest [Boolean] what an entry without a digest counts as: a verdict
    #   always has one (the text was sent), a failure may come before anything was sent.
    # @return [Boolean] whether the post no longer reads as the text that was assessed.
    def changed_since_sent?(reviewable, entry, missing_digest:)
      digest = entry["text_digest"]
      return missing_digest if digest.nil?

      payload = reviewable.payload
      Text.for_submission(payload["raw"].to_s, payload["title"])[:digest] != digest
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
      record(reviewable, done, verdict)
      if done.support && %i[approve approve_masked].include?(done.action)
        signal_support(published_post(reviewable.target_id))
      end
      finished =
        entry.merge(extra).merge(
          "verdict" => verdict && stored(verdict),
          "reason" => done.reason.to_s,
        )
      if verdict.nil? && done.action == :approve && reviewable.target_id
        # Published without a verdict: one may still arrive and is then carried out on the
        # published post (`Receiver`, `apply_late`).
        auto = { "auto_published" => true, "post_id" => reviewable.target_id }
        close(finished.merge(auto), "approve", status: "auto_published")
      else
        close(finished, done.action.to_s)
      end
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

    # Publishes the masked text (and title, for a new topic).
    #
    # @return [Array(Decision::Result, Hash)] what was done, and fields for the entry.
    def approve_masked(reviewable, decision, verdict)
      return [instead(decision, :topic_closed), {}] if reviewable.topic&.closed?

      raw = reviewable.payload["raw"].to_s
      title = reviewable.payload["title"]
      masked = masks_for(raw, title, verdict)
      return [instead(decision, :mask_unmappable), {}] unless masked

      # String keys: the payload is a JSON column, and a symbol key would add a second
      # "raw" to it.
      changes = { "raw" => masked[:raw] }
      changes["title"] = masked[:title] if title
      edited =
        begin
          reviewable.update_fields({ payload: changes }, ::Discourse.system_user)
        rescue *ACTION_ERRORS => e
          log("update_fields raised #{e.class.name}")
          false
        end
      return [instead(decision, :action_failed), {}] unless edited && stored?(reviewable, changes)

      [act(reviewable, :approve_post, decision), originals(raw, title)]
    end

    # Whether the queued text Discourse would publish is the masked one. `approve_post`
    # publishes the reviewable's payload as the object holds it, so the object is read back
    # from the database first: a save that reported success but did not keep the masks
    # must never publish the original instead.
    #
    # @param reviewable [ReviewableQueuedPost] the pending post, reloaded here.
    # @param changes [Hash{String => String}] the masked `raw` (and `title`).
    # @return [Boolean] whether every masked field is stored exactly.
    def stored?(reviewable, changes)
      reviewable.reload
      payload = reviewable.payload || {}
      return true if changes.all? { |field, value| payload[field] == value }

      log("the masked text did not persist")
      false
    rescue ::ActiveRecord::ActiveRecordError => e
      log("reading the masked post back raised #{e.class.name}")
      false
    end

    # A verdict for a post the failure mode already published. A person's decision since
    # then stays final; otherwise the published post is kept, masked or hidden.
    #
    # @return [void]
    def apply_late(entry, verdict)
      reviewable = ::ReviewableQueuedPost.find_by(id: @id)
      post = entry["post_id"] && ::Post.with_deleted.find_by(id: entry["post_id"])
      decision =
        Decision.for_late_verdict(
          verdict,
          Settings.decision,
          truncated: entry["truncated"] == true,
          acted: post.nil? || acted_on?(post, reviewable),
        )
      done, extra =
        case decision.action
        when :hide
          [hide(post, decision), {}]
        when :mask
          mask(post, reviewable, decision, verdict)
        else
          [decision, {}]
        end
      record(reviewable, done, verdict) if reviewable
      signal_support(post) if done.support
      close(
        entry.merge(extra).merge("verdict" => stored(verdict), "reason" => done.reason.to_s),
        done.action.to_s,
      )
    end

    # @param post_id [Integer, nil] a post the plugin published.
    # @return [Post, nil] it, while it exists.
    def published_post(post_id)
      post_id && ::Post.find_by(id: post_id)
    end

    # Puts the support signal in the moderators' own queue (shared plugin rule A7): a
    # `notify_moderators` flag by the system user on a published post, with a Polish
    # message that names no content. Discourse sends that message to the moderators'
    # group, never to the author. A post already deleted or hidden is a person's decision
    # and gets none; a flag Discourse refuses leaves the note alone.
    #
    # @param post [Post, nil] the published post.
    # @return [void]
    def signal_support(post)
      return if post.nil? || post.deleted_at || post.hidden?

      result =
        ::PostActionCreator.create(
          ::Discourse.system_user,
          post,
          :notify_moderators,
          message: translate("minos_moderation.flags.support"),
        )
      log("the support flag was not raised") unless result.success?
    rescue *ACTION_ERRORS, ::RateLimiter::LimitExceeded => e
      log("raising the support flag raised #{e.class.name}")
    end

    # @param post [Post] a post the failure mode published.
    # @param reviewable [ReviewableQueuedPost, nil] the review item it was published from.
    # @return [Boolean] whether a person acted on it since: deleted it, hid it, edited it
    #   (a new version, or a text that no longer reads as the one published — an author's
    #   edit within the grace period makes no new version), or reviewed a flag on it.
    def acted_on?(post, reviewable)
      return true if post.deleted_at || post.hidden? || post.version.to_i > 1
      return true if reviewable.nil?

      published = Text.plain(published_form(post.raw))
      return true if published != Text.plain(published_form(reviewable.payload["raw"]))

      ::ReviewableFlaggedPost.where(target: post).where.not(status: :pending).exists?
    end

    # A queued text as Discourse publishes it: `PostCreator#setup_post` replaces the
    # Unicode spaces of `TextCleaner.normalize_whitespaces` (no-break, en/em, ideographic
    # and the like) with plain spaces and strips the end. Comparing the published post with
    # its queued text without this would read every such post as edited by a person.
    #
    # @param raw [String, nil] a post's raw Markdown.
    # @return [String] the same text after Discourse's normalisation.
    def published_form(raw)
      ::TextCleaner.normalize_whitespaces(raw.to_s).rstrip
    end

    # Takes a published post out of view; a moderator can show it again.
    #
    # @return [Decision::Result] what was done.
    def hide(post, decision)
      post.hide!(::PostActionType.types[:inappropriate])
      decision
    rescue *ACTION_ERRORS => e
      log("hiding the published post raised #{e.class.name}")
      instead(decision, :action_failed, action: :keep)
    end

    # Edits the masks into a published post; hides it when that cannot be done exactly.
    #
    # @return [Array(Decision::Result, Hash)] what was done, and fields for the entry.
    def mask(post, reviewable, decision, verdict)
      payload = reviewable ? reviewable.payload : {}
      raw = payload["raw"].to_s
      title = payload["title"]
      masked = reviewable && masks_for(raw, title, verdict)
      return [unmasked(post, decision, :mask_unmappable), {}] unless masked

      fields = {
        raw: published_form(masked[:raw]),
        edit_reason: translate("minos_moderation.edit_reason"),
      }
      fields[:title] = masked[:title] if title && post.is_first_post?
      revised =
        begin
          ::PostRevisor.new(post).revise!(
            ::Discourse.system_user,
            fields,
            skip_validations: true,
            bypass_bump: true,
            bypass_rate_limiter: true,
          )
        rescue *ACTION_ERRORS => e
          log("masking the published post raised #{e.class.name}")
          false
        end
      return [unmasked(post, decision, :action_failed), {}] unless revised

      [decision, originals(raw, title)]
    end

    # A published post whose masks could not be edited in: hidden, unless it carries
    # `wsparcie`, which is never hidden automatically (`Decision.for_late_verdict`).
    #
    # @return [Decision::Result] what was done.
    def unmasked(post, decision, reason)
      return instead(decision, reason, action: :keep) if decision.support

      hide(post, instead(decision, reason, action: :hide))
    end

    # @return [Hash{Symbol => String}, nil] the masked raw and title, or nil when the masks
    #   do not map onto the text that was sent.
    def masks_for(raw, title, verdict)
      sent = Text.for_submission(raw, title)[:text]
      Text.apply_masks(raw, sent, verdict && verdict["ocenzurowany"], title: title)
    end

    # @return [Hash{String => String}] digests of the unmasked text, never the text.
    def originals(raw, title)
      digests = { "original_digest" => ::Digest::SHA256.hexdigest(raw) }
      digests["original_title_digest"] = ::Digest::SHA256.hexdigest(title) if title
      digests
    end

    # @return [Hash] a verdict as the entry keeps it: without the masked text.
    def stored(verdict)
      verdict.except("ocenzurowany")
    end

    # @return [Decision::Result] the decision, or a `:leave` when the action failed.
    def act(reviewable, action_id, decision)
      result = reviewable.perform(::Discourse.system_user, action_id)
      return decision if result.success?

      log("#{action_id} did not succeed")
      instead(decision, :action_failed)
    rescue *ACTION_ERRORS => e
      log("#{action_id} raised #{e.class.name}")
      instead(decision, :action_failed)
    end

    # @return [Decision::Result] `action` (a `:leave` by default) in place of a decision
    #   that could not be done.
    def instead(decision, reason, action: :leave)
      Decision::Result.new(
        action: action,
        reason: reason,
        unassessed: decision.unassessed,
        support: decision.support,
      )
    end

    # @param entry [Hash{String => Object}] the entry.
    # @param outcome [String] what was done.
    # @param status [String] `done`, or `auto_published` for a post a late verdict may
    #   still reach.
    # @return [void]
    def close(entry, outcome, status: "done")
      finished = { "status" => status, "outcome" => outcome, "handled_at" => Time.now.to_i }
      Store.set(@id, entry.merge(finished))
    end

    # Notes what was done on the review item, and the support signal.
    #
    # @return [void]
    def record(reviewable, done, verdict)
      note(reviewable, note_text(done, verdict))
      note(reviewable, translate("minos_moderation.notes.support")) if done.support
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
      parts = [header, translate("minos_moderation.actions.#{action_key(done)}")]
      if done.reason != :verdict
        reason = translate("minos_moderation.reasons.#{done.reason}")
        parts << translate("minos_moderation.notes.reason", powod: reason)
      end
      parts.join(" ")
    end

    # @return [String] the action's text key; a publication by the failure mode says so.
    def action_key(done)
      publication = %i[approve approve_masked].include?(done.action)
      done.unassessed && publication ? "#{done.action}_unassessed" : done.action.to_s
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
