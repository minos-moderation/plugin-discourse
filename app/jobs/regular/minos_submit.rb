# frozen_string_literal: true

module ::Jobs
  # Sends one held post to the gateway (`MinosModeration::Submission`). Sidekiq never
  # retries it: the submission schedules its own retry after `ponow_za_s` or a backoff,
  # and the sweeper picks up an attempt that died half-way.
  class MinosSubmit < ::Jobs::Base
    sidekiq_options retry: false

    # @param args [Hash] `reviewable_id`: the held post's reviewable.
    # @return [void]
    def execute(args)
      ::MinosModeration::Submission.new(args[:reviewable_id]).run
    end
  end
end
