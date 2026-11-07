# frozen_string_literal: true

module ::Jobs
  # Every five minutes: timeouts, lost retries, lost verdict jobs and old entries
  # (`MinosModeration::Sweep`). While the plugin is disabled only the plugin's own
  # retention runs (`Sweep.retain`: the 30-day deletion and the masked text of a verdict
  # that waited over a day); the posts it held stay in the review queue for the
  # moderators, and nothing is sent, applied or timed out.
  class MinosSweeper < ::Jobs::Scheduled
    every 5.minutes

    # @param _args [Hash] unused.
    # @return [void]
    def execute(_args)
      now = Time.now.to_i
      return ::MinosModeration::Sweep.retain(now) unless ::MinosModeration::Settings.enabled?

      ::MinosModeration::Sweep.run(now)
    end
  end
end
