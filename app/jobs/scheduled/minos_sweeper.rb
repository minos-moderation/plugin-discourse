# frozen_string_literal: true

module ::Jobs
  # Every five minutes: timeouts, lost retries, lost verdict jobs and old entries
  # (`MinosModeration::Sweep`). Nothing runs while the plugin is disabled; the posts it
  # held stay in the review queue for the moderators.
  class MinosSweeper < ::Jobs::Scheduled
    every 5.minutes

    # @param _args [Hash] unused.
    # @return [void]
    def execute(_args)
      return unless ::MinosModeration::Settings.enabled?

      ::MinosModeration::Sweep.run(Time.now.to_i)
    end
  end
end
