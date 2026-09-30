# frozen_string_literal: true

module MinosModeration
  # The sweeper's pass over every entry (`Jobs::MinosSweeper`, every five minutes).
  #
  # What an entry needs is decided by `Decision.for_entry`; this module only does it:
  # resubmit a due retry or a lost send, apply the failure mode to a post that got no
  # verdict within `minos_timeout_minutes` (contract: "Treat an item without an answer
  # after the TTL plus a few minutes as `nieocenione`"), apply again a verdict whose job was
  # lost, give up on one that could not be applied for a day (the post stays with the
  # moderators), and forget finished entries after thirty days. One broken entry never
  # stops the pass.
  module Sweep
    # @param now [Integer] the clock, in seconds.
    # @return [void]
    def self.run(now = Time.now.to_i)
      timeout_s = Settings.timeout_s
      Store.each_entry do |id, entry|
        case Decision.for_entry(entry, now: now, timeout_s: timeout_s)
        when :resubmit
          ::Jobs.enqueue(:minos_submit, reviewable_id: id)
        when :timeout
          VerdictApplier.new(id).apply_failure(:timeout)
        when :reapply
          ::Jobs.enqueue(:minos_apply_verdict, reviewable_id: id)
        when :abandon
          VerdictApplier.new(id).abandon
        when :purge
          purge(id, now, timeout_s)
        end
      rescue StandardError => e
        ::Rails.logger.warn("[#{PLUGIN_NAME}] sweeping reviewable #{id} failed (#{e.class.name})")
      end
    end

    # Forgets a finished entry, if it is still one to forget.
    #
    # @return [void]
    def self.purge(id, now, timeout_s)
      Store.lock(id) do
        entry = Store.get(id)
        next unless entry

        Store.remove(id) if Decision.for_entry(entry, now: now, timeout_s: timeout_s) == :purge
      end
    end

    private_class_method :purge
  end
end
