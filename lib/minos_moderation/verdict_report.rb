# frozen_string_literal: true

module MinosModeration
  # The administrator's report "Minos — czas do werdyktu i werdykty" (Admin → Reports),
  # registered by `plugin.rb` with `add_report`: the numbers of `Metrics` as a table, in
  # the forum's language files. Shown to staff only, like every report, and only while
  # the plugin is enabled. No text of a post, no key and no secret is in it.
  module VerdictReport
    # The report's type (`/admin/reports/minos_moderation`): Discourse allows `[a-z0-9_]`.
    NAME = "minos_moderation"

    # Fills a Discourse report with the last seven days' numbers.
    #
    # @param report [Report] the report Discourse is building.
    # @param now [Integer] the clock, in seconds.
    # @return [void]
    def self.fill(report, now: Time.now.to_i)
      entries = []
      Store.each_entry { |_id, entry| entries << entry }
      summary = Metrics.summary(entries, now: now)
      report.modes = [::Report::MODES[:table]]
      report.dates_filtering = false
      report.labels = [
        { property: :x, title: text("labels.measure") },
        { property: :y, title: text("labels.value") },
      ]
      report.data =
        Metrics::ROWS.map do |key, kind|
          { key: key, x: text("rows.#{key}"), y: value_text(summary[key], kind) }
        end
    end

    # @return [String] a value as the table shows it.
    def self.value_text(value, kind)
      return value.to_i.to_s if kind == "count"
      return text("no_data") if value.nil?

      minutes, seconds = Metrics.minutes_and_seconds(value)
      return text("seconds", sekundy: seconds) if minutes.zero?

      text("minutes", minuty: minutes, sekundy: seconds)
    end

    def self.text(key, **args)
      ::I18n.t("reports.#{NAME}.#{key}", **args)
    end

    private_class_method :value_text, :text
  end
end
