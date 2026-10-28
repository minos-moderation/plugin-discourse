# frozen_string_literal: true

module MinosModeration
  # The `NewPostManager` handler: holds a new post in the review queue and hands it to the
  # gateway.
  #
  # A post is held as a `ReviewableQueuedPost`, the way Discourse itself holds a post
  # before it exists, so a moderator can always act on it in the review queue and the
  # author sees the usual "awaiting approval" notice. When Discourse would hold the post
  # anyway (a new user, a watched word, a category that needs approval), its own handler
  # queues it and the gateway's verdict only annotates it: the forum's rules stay in
  # force.
  #
  # Not handled, so published or held as Discourse decides: the plugin is disabled; the
  # author is staff (with `minos_skip_staff`), a bot or the system user; the post is a
  # personal message (Discourse never queues those, and their content is private); the
  # post is outside the administrator's scope (`minos_categories`, `minos_exempt_groups`,
  # `minos_max_trust_level`; `Decision.in_scope?`). Nothing about the scope is sent.
  module NewPostHandler
    # Runs after the handlers of other plugins (they are 0 and up) that may still change
    # the post's arguments or refuse it.
    PRIORITY = -100

    # The score reason moderators see (`reviewables.reasons.minos_pending`).
    REASON = :minos_pending

    # The groups every author of a new post belongs to without a membership row:
    # "everyone" and, where Discourse has it, "logged in users".
    PSEUDO_GROUPS = [
      ::Group::AUTO_GROUPS[:everyone],
      ::Group::AUTO_GROUPS[:logged_in_users],
    ].compact.freeze

    # How many categories up a subcategory is looked through (Discourse nests three deep).
    MAX_CATEGORY_DEPTH = 3

    # @param manager [NewPostManager] the post being created.
    # @return [NewPostResult, nil] the queued result, or nil to let the next handler and
    #   Discourse decide.
    def self.call(manager)
      return nil unless applies_to?(manager)

      core_reason = ::NewPostManager.post_needs_approval?(manager)
      result =
        if core_reason == :skip
          manager.enqueue(REASON)
        else
          ::NewPostManager.default_handler(manager)
        end
      reviewable = result&.reviewable
      if result&.success? && reviewable.is_a?(::ReviewableQueuedPost) && reviewable.persisted?
        Submission.enqueue(reviewable, core_hold: core_reason == :skip ? nil : core_reason.to_s)
      end
      result
    end

    # @param manager [NewPostManager] the post being created.
    # @return [Boolean] whether the plugin holds this post.
    def self.applies_to?(manager)
      return false unless Settings.enabled?

      user = manager.user
      return false if user.nil? || user.bot? || user.id.to_i <= 0
      return false if Settings.skip_staff? && user.staff?
      return false if private_message?(manager.args)

      in_scope?(manager)
    end

    # @param manager [NewPostManager] the post being created.
    # @return [Boolean] whether the post is in the administrator's scope; true whenever
    #   something cannot be told (`Decision.in_scope?`).
    def self.in_scope?(manager)
      scope = Settings.scope
      chosen = scope["categories"]
      if chosen.is_a?(Array) && !chosen.empty?
        # A deleted category's id can never match: the list is the categories that exist,
        # and a list of none of them moderates every category.
        scope = scope.merge("categories" => ::Category.where(id: chosen).pluck(:id))
      end
      user = manager.user
      Decision.in_scope?(
        category_ids: category_ids(manager.args),
        group_ids: user.group_ids | PSEUDO_GROUPS,
        trust_level: user.trust_level,
        scope: scope,
      )
    end

    # @param args [Hash] the post's arguments: `topic_id` for a reply, `category` for a new
    #   topic.
    # @return [Array<Integer>, nil] the post's category and the ones above it, or nil when
    #   the category cannot be found.
    def self.category_ids(args)
      category =
        if args[:topic_id].present?
          ::Topic.find_by(id: args[:topic_id])&.category
        elsif args[:category].present?
          ::Category.find_by(id: args[:category])
        end
      ids = []
      while category && ids.size < MAX_CATEGORY_DEPTH
        ids << category.id
        category = category.parent_category
      end
      ids.empty? ? nil : ids
    end

    # @param args [Hash] the post's arguments.
    # @return [Boolean] whether the post is, or replies within, a personal message.
    def self.private_message?(args)
      return true if args[:archetype] == ::Archetype.private_message

      topic_id = args[:topic_id]
      topic_id.present? &&
        ::Topic.where(id: topic_id, archetype: ::Archetype.private_message).exists?
    end

    private_class_method :applies_to?, :private_message?, :in_scope?, :category_ids
  end
end
