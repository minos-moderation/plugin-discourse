# frozen_string_literal: true

module MinosModeration
  # Takes a verified, parsed delivery and hands it to `Jobs::MinosApplyVerdict`.
  #
  # Only the first delivery for the latest attempt of a post that still waits is taken; a
  # repeat, a verdict for an earlier attempt, or one for an id that is not this plugin's is
  # dropped silently, and the gateway still gets its 200 (contract: "Use `id` to drop a
  # repeat"). A post the failure mode already published still waits: its verdict is
  # carried out on the published post. The verdict is stored with the entry, so the job
  # reads it from there and not from its arguments.
  module Receiver
    # Entry states that accept a verdict. `queued` included: a request whose `202` was lost
    # on the way back is still assessed by the gateway. `auto_published`: the failure mode
    # published the post, and the verdict still counts.
    WAITING = %w[queued sending submitted auto_published].freeze

    # @param payload [Hash{String => Object}] from `WebhookPayload.parse`.
    # @return [Symbol] `:accepted` or `:ignored`.
    def self.accept(payload)
      id, attempt = Scores.parse_item_id(payload["id"])
      return :ignored unless id

      taken =
        Store.lock(id) do
          entry = Store.get(id)
          next false unless entry && WAITING.include?(entry["status"])
          next false unless entry["attempt"].to_i == attempt

          received = { "status" => "received", "received_at" => Time.now.to_i }
          Store.set(id, entry.merge(received).merge("verdict" => payload))
          true
        end
      return :ignored unless taken

      ::Jobs.enqueue(:minos_apply_verdict, reviewable_id: id)
      :accepted
    end
  end
end
