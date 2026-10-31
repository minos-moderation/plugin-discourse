# frozen_string_literal: true

module MinosModeration
  # The plugin's state, in `PluginStore` under the plugin's name.
  #
  # One entry per held post, `pending:<reviewable id>`, with string keys:
  #
  # - `status`: `queued` (waiting to be sent, or for a retry), `sending`, `submitted` (the
  #   gateway answered `202`), `received` (a verdict arrived and waits for its job),
  #   `auto_published` (the failure mode published the post; a late verdict is still
  #   taken) or `done`;
  # - times in epoch seconds: `queued_at`, `retry_at`, `sending_at`, `submitted_at`,
  #   `received_at`, `handled_at`;
  # - `attempts` and `attempt` (the current attempt, the suffix of the item id);
  #   `core_hold` (the reason Discourse itself held the post, if it did); `text_digest` and
  #   `truncated` (what the current attempt sent, without the text); `digests` (every
  #   attempt's text digest, by attempt number as a String); `verdict` (the parsed payload,
  #   minus `ocenzurowany` once applied); `original_digest` (never the unmasked text; an
  #   entry written before S8b may also have `original_title_digest`); `post_id` (of a post the failure mode published); `outcome` and
  #   `reason` (what was done, and why).
  #
  # Plus, for the admin dashboard, `problem` (the gateway's last refusal of the forum's
  # configuration) and `limit` (the gateway's last "not before T": a daily limit or an
  # overload). Kept apart, so that neither hides the other; the gateway's next `202`
  # clears both. And `pause`, the shared "send nothing before T" after any refusal to be
  # retried (`Decision.pause_until`), which the next `202` clears too. Every
  # read-modify-write of an entry happens under {lock}.
  module Store
    # The prefix of an entry's key.
    PREFIX = "pending:"

    # The key of the last configuration problem.
    PROBLEM = "problem"

    # The key of the last refusal for a while (`Scores::LIMITS`).
    LIMIT = "limit"

    # The key of the shared pause: no post is sent before its `until`.
    PAUSE = "pause"

    # @param id [Integer] a reviewable's id.
    # @return [Hash{String => Object}, nil] its entry.
    def self.get(id)
      value = ::PluginStore.get(PLUGIN_NAME, key(id))
      value.is_a?(Hash) ? value.to_h : nil
    end

    # @param id [Integer] a reviewable's id.
    # @param entry [Hash{String => Object}] its new entry.
    # @return [void]
    def self.set(id, entry)
      ::PluginStore.set(PLUGIN_NAME, key(id), entry)
    end

    # @param id [Integer] a reviewable's id.
    # @return [void]
    def self.remove(id)
      ::PluginStore.remove(PLUGIN_NAME, key(id))
    end

    # Runs a block while no other process works on the same post.
    #
    # @param id [Integer] a reviewable's id.
    # @yield the work on its entry. Never call {lock} for the same id inside it.
    # @return [Object] the block's value.
    def self.lock(id, &block)
      ::DistributedMutex.synchronize("#{PLUGIN_NAME}:#{Integer(id)}", &block)
    end

    # Changes an entry under the lock.
    #
    # @param id [Integer] a reviewable's id.
    # @yieldparam entry [Hash{String => Object}] a copy of the entry.
    # @yieldreturn [Hash, nil] the entry to store, or nil to leave it as it was.
    # @return [Hash{String => Object}, nil] the stored entry, or nil when there was none
    #   or the block kept it.
    def self.update(id)
      lock(id) do
        entry = get(id)
        next nil unless entry

        changed = yield(entry.dup)
        set(id, changed) if changed
        changed
      end
    end

    # Every entry, for the sweeper.
    #
    # @yieldparam id [Integer] the reviewable's id.
    # @yieldparam entry [Hash{String => Object}] its entry, as read (unlocked).
    # @return [void]
    def self.each_entry
      ::PluginStoreRow
        .where(plugin_name: PLUGIN_NAME)
        .where("key LIKE ?", "#{PREFIX}%")
        .find_each do |row|
          id = Integer(row.key.delete_prefix(PREFIX), 10, exception: false)
          value = ::PluginStore.cast_value(row.type_name, row.value)
          yield(id, value.to_h) if id && value.is_a?(Hash)
        end
    end

    # @return [Hash{String => Object}, nil] the last configuration problem: `reason`,
    #   `http`, `kod`, `at`.
    def self.problem
      value = ::PluginStore.get(PLUGIN_NAME, PROBLEM)
      value.is_a?(Hash) ? value.to_h : nil
    end

    # @param reason [String] `refused`, `unexpected` or `disallowed_address`.
    # @param http [Integer, nil] the gateway's status.
    # @param code [String, nil] the gateway's `blad.kod`, already checked for its shape.
    # @return [void]
    def self.record_problem(reason:, http:, code:)
      ::PluginStore.set(
        PLUGIN_NAME,
        PROBLEM,
        { "reason" => reason, "http" => http, "kod" => code, "at" => Time.now.to_i },
      )
    end

    # @return [Hash{String => Object}, nil] the gateway's last refusal for a while:
    #   `reason` (`daily_limit` or `overloaded`), `until` (epoch seconds), `http`, `kod`,
    #   `at`.
    def self.limit
      value = ::PluginStore.get(PLUGIN_NAME, LIMIT)
      value.is_a?(Hash) ? value.to_h : nil
    end

    # @param reason [String] `daily_limit` or `overloaded` (`Scores::LIMITS`).
    # @param until_at [Integer] epoch seconds before which the gateway accepts nothing: now
    #   plus `ponow_za_s` as the gateway gave it, never the plugin's capped pause.
    # @param http [Integer] the gateway's status.
    # @param code [String] the gateway's `blad.kod`, already checked for its shape.
    # @return [void]
    def self.record_limit(reason:, until_at:, http:, code:)
      ::PluginStore.set(
        PLUGIN_NAME,
        LIMIT,
        {
          "reason" => reason,
          "until" => Integer(until_at),
          "http" => http,
          "kod" => code,
          "at" => Time.now.to_i,
        },
      )
    end

    # @return [Hash{String => Object}, nil] the shared pause: `until` (epoch seconds before
    #   which no post is sent), `gateway` (whether `until` is the gateway's own
    #   `ponow_za_s`), `http`, `kod`, `at`.
    def self.pause
      value = ::PluginStore.get(PLUGIN_NAME, PAUSE)
      value.is_a?(Hash) ? value.to_h : nil
    end

    # Records the shared pause. A pause still in force is never shortened: a short refusal
    # of a request that was already on its way does not lift a daily limit.
    #
    # @param until_at [Integer] epoch seconds (`Decision.pause_until`).
    # @param gateway [Boolean] whether `until_at` comes from the gateway's `ponow_za_s`.
    # @param http [Integer, nil] the gateway's status (nil without an answer).
    # @param code [String, nil] the gateway's `blad.kod`, already checked for its shape.
    # @return [void]
    def self.record_pause(until_at:, gateway:, http:, code:)
      current = pause
      return if current && current["until"].is_a?(Integer) && current["until"] > until_at

      ::PluginStore.set(
        PLUGIN_NAME,
        PAUSE,
        {
          "until" => Integer(until_at),
          "gateway" => gateway == true,
          "http" => http,
          "kod" => code,
          "at" => Time.now.to_i,
        },
      )
    end

    # Forgets the shared pause and the last refusal for a while: they came for a key or a
    # gateway address the administrator has just changed (`plugin.rb`).
    #
    # @return [void]
    def self.forget_refusals
      ::PluginStore.remove(PLUGIN_NAME, PAUSE) if pause
      ::PluginStore.remove(PLUGIN_NAME, LIMIT) if limit
    end

    # Forgets the last configuration problem, the last refusal for a while and the shared
    # pause: the gateway accepted a request.
    #
    # @return [void]
    def self.clear_problem
      ::PluginStore.remove(PLUGIN_NAME, PROBLEM) if problem
      ::PluginStore.remove(PLUGIN_NAME, LIMIT) if limit
      ::PluginStore.remove(PLUGIN_NAME, PAUSE) if pause
    end

    # @param id [Integer] a reviewable's id.
    # @return [String] its entry's key.
    def self.key(id)
      "#{PREFIX}#{Integer(id)}"
    end

    private_class_method :key
  end
end
