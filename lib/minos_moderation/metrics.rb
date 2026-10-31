# frozen_string_literal: true

module MinosModeration
  # How fast the gateway answers and what it answers, for the administrator: the time from
  # the gateway's acceptance of a post (its `202`) to the delivery of the verdict, as its
  # median (P50) and 95th percentile (P95) over the last seven days, and how many posts
  # got each verdict in that time.
  #
  # Computed from the timestamps the plugin's entries already keep (`submitted_at`,
  # `received_at`) and the verdict each entry stores without its masked text: nothing new
  # is stored, no request is made, and no text, key or secret is read. Entries are kept 30
  # days (`Decision::PURGE_AFTER_S`), so seven days are always there.
  #
  # Plain Ruby: no Rails, so the standalone tier runs it without Discourse.
  module Metrics
    # The window the numbers cover, in seconds.
    WINDOW_S = 7 * 24 * 3600

    # The verdict values counted, as the contract spells them.
    VERDICTS = %w[bezpieczne ocenzurowane zablokowane nieocenione].freeze

    # The rows shown, in order, each with what its value is: a duration in seconds (nil
    # without a measured post) or a count.
    ROWS = [
      %w[p50 duration],
      %w[p95 duration],
      %w[timed count],
      *VERDICTS.map { |verdict| [verdict, "count"] },
      %w[no_verdict count],
    ].freeze

    # Entry states after which a post will get nothing more from the gateway.
    FINISHED = %w[done auto_published].freeze

    # The numbers for the last {WINDOW_S} seconds.
    #
    # - `p50`, `p95`: seconds from the gateway's `202` to the verdict's delivery (nearest
    #   rank), nil when no post was measured; a verdict delivered before the plugin noted
    #   the `202` counts as 0;
    # - `timed`: how many posts were measured;
    # - one count per {VERDICTS} value, by the time the verdict was delivered (a value the
    #   contract does not know counts as `nieocenione`, as the payload reader reads it);
    # - `no_verdict`: posts finished in the window without any verdict (the failure mode
    #   after a time-out, a refusal or a configuration error), not those a person handled
    #   before a verdict came.
    #
    # @param entries [Enumerable<Hash{String => Object}>] the entries as `Store` keeps them.
    # @param now [Integer] the clock, in seconds.
    # @return [Hash{String => Integer, nil}] the value of each {ROWS} key.
    def self.summary(entries, now:)
      since = now - WINDOW_S
      within = ->(time) { time.is_a?(Integer) && time > since && time <= now }
      counts = (VERDICTS + %w[no_verdict]).to_h { |key| [key, 0] }
      durations = []
      entries.each do |entry|
        next unless entry.is_a?(Hash)

        verdict = entry["verdict"]
        if verdict.is_a?(Hash)
          received = entry["received_at"]
          next unless within.call(received)

          counts[value_of(verdict)] += 1
          submitted = entry["submitted_at"]
          durations << [received - submitted, 0].max if submitted.is_a?(Integer)
        elsif FINISHED.include?(entry["status"]) && entry["outcome"] != "resolved_elsewhere" &&
              within.call(entry["handled_at"])
          counts["no_verdict"] += 1
        end
      end
      sorted = durations.sort
      counts.merge(
        "p50" => percentile(sorted, 50),
        "p95" => percentile(sorted, 95),
        "timed" => sorted.size,
      )
    end

    # The nearest-rank percentile: the smallest value at least `percent` per cent of the
    # values do not exceed.
    #
    # @param sorted [Array<Integer>] the values, ascending.
    # @param percent [Integer] 1 to 100.
    # @return [Integer, nil] the value, or nil without values.
    def self.percentile(sorted, percent)
      return nil if sorted.empty?

      rank = (percent * sorted.size + 99) / 100
      sorted[rank.clamp(1, sorted.size) - 1]
    end

    # @param seconds [Integer] a duration.
    # @return [Array(Integer, Integer)] whole minutes and the seconds left.
    def self.minutes_and_seconds(seconds)
      seconds.to_i.divmod(60)
    end

    # @param verdict [Hash{String => Object}] a verdict as an entry stores it.
    # @return [String] the {VERDICTS} value it counts as.
    def self.value_of(verdict)
      return "nieocenione" unless verdict["status"] == "ocenione"

      value = verdict["kwalifikacja"]
      %w[bezpieczne ocenzurowane zablokowane].include?(value) ? value : "nieocenione"
    end

    private_class_method :value_of
  end
end
