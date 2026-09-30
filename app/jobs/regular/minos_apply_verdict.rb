# frozen_string_literal: true

module ::Jobs
  # Applies a received verdict to its post (`MinosModeration::VerdictApplier`). Sidekiq
  # never retries it: the sweeper applies a verdict again when its job was lost.
  class MinosApplyVerdict < ::Jobs::Base
    sidekiq_options retry: false

    # @param args [Hash] `reviewable_id`: the held post's reviewable.
    # @return [void]
    def execute(args)
      return unless ::MinosModeration::Settings.enabled?

      ::MinosModeration::VerdictApplier.new(args[:reviewable_id]).apply_verdict
    end
  end
end
