# frozen_string_literal: true

module MinosModeration
  # Takes a verified, parsed delivery and hands it to `Jobs::MinosApplyVerdict`.
  #
  # Only the first delivery for a post that still waits is taken; a repeat, a late one, or
  # one for an id that is not this plugin's is dropped silently, and the gateway still gets
  # its 200 (contract: "Use `id` to drop a repeat"). The verdict is stored with the entry,
  # so the job reads it from there and not from its arguments.
  module Receiver
    # Entry states that accept a verdict. `queued` included: a request whose `202` was lost
    # on the way back is still assessed by the gateway.
    WAITING = %w[queued sending submitted].freeze

    # @param payload [Hash{String => Object}] from `WebhookPayload.parse`.
    # @return [Symbol] `:accepted` or `:ignored`.
    def self.accept(payload)
      id = Scores.reviewable_id(payload["id"])
      return :ignored unless id

      taken =
        Store.lock(id) do
          entry = Store.get(id)
          next false unless entry && WAITING.include?(entry["status"])

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
