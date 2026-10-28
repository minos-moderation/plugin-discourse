# frozen_string_literal: true

module MinosModeration
  # Takes a verified, parsed delivery and hands it to `Jobs::MinosApplyVerdict`.
  #
  # Only the first delivery for a post that still waits is taken, and only for the latest
  # attempt or an earlier attempt that sent the same text (`Decision.verdict_for_entry?`);
  # a repeat, any later verdict for the same post, a verdict for an earlier attempt with
  # another text, or one for an id that is not this plugin's is dropped silently, and the
  # gateway still gets its 200 (contract: "Use `id` to drop a repeat"). A post the failure
  # mode already published still waits: its verdict is carried out on the published post.
  # So does a post the failure mode held after its time-out, while its review item is
  # still undecided (shared plugin rule A6, `Decision.held_after_timeout?`): the verdict
  # is applied as if it had come in time. Once a moderator approved or rejected it, the
  # verdict is dropped and the entry stays as it was.
  # The verdict is stored with the entry, so the job reads it from there and not from its
  # arguments.
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
          next false unless entry
          unless WAITING.include?(entry["status"]) ||
                   (Decision.held_after_timeout?(entry) && undecided?(id))
            next false
          end
          next false unless Decision.verdict_for_entry?(entry, attempt)

          received = { "status" => "received", "received_at" => Time.now.to_i }
          Store.set(id, entry.merge(received).merge("verdict" => payload))
          true
        end
      return :ignored unless taken

      ::Jobs.enqueue(:minos_apply_verdict, reviewable_id: id)
      :accepted
    end

    # @param id [Integer] a reviewable's id.
    # @return [Boolean] whether no one has approved or rejected the held post yet.
    def self.undecided?(id)
      ::ReviewableQueuedPost.find_by(id: id)&.pending? == true
    end

    private_class_method :undecided?
  end
end
