# frozen_string_literal: true

# Discourse tier: needs the plugin harness (`bin/rspec plugins/minos-moderation/spec`).
# Which new posts the plugin holds, and how. Every text is invented.
RSpec.describe MinosModeration::NewPostHandler do
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic)

  let(:raw) { "To jest zupełnie zwyczajna odpowiedź w tym temacie." }

  before do
    SiteSetting.minos_enabled = true
    SiteSetting.minos_api_key = "wgb2b_klucz_testowy_0000000000000000"
    SiteSetting.minos_webhook_secret = "sekret-testowy"
  end

  def create(author, args = {})
    NewPostManager.new(author, { raw: raw, topic_id: topic.id }.merge(args)).perform
  end

  it "holds a new reply as a queued post and schedules its submission" do
    result = nil
    expect_enqueued_with(job: :minos_submit) { result = create(user) }

    expect(result.action).to eq(:enqueued)
    reviewable = result.reviewable
    expect(reviewable).to be_a(ReviewableQueuedPost)
    expect(reviewable.payload["raw"]).to eq(raw)
    expect(reviewable.reviewable_scores.map(&:reason)).to include("minos_pending")
    expect(Post.where(raw: raw)).to be_empty

    entry = MinosModeration::Store.get(reviewable.id)
    expect(entry["status"]).to eq("queued")
    expect(entry["core_hold"]).to be_nil
  end

  it "holds a new topic too" do
    result =
      create(
        user,
        topic_id: nil,
        title: "Zupełnie nowy temat do dyskusji",
        category: topic.category_id,
      )
    expect(result.action).to eq(:enqueued)
    expect(MinosModeration::Store.get(result.reviewable.id)).to be_present
  end

  it "does nothing while the plugin is disabled" do
    SiteSetting.minos_enabled = false
    result = create(user)
    expect(result.action).to eq(:create_post)
    expect(result.post.raw).to eq(raw)
  end

  it "publishes staff posts at once by default, and holds them when told to" do
    moderator = Fabricate(:moderator)
    expect(create(moderator).action).to eq(:create_post)

    SiteSetting.minos_skip_staff = false
    expect(create(moderator, raw: "#{raw} Drugi raz.").action).to eq(:enqueued)
  end

  it "never holds a personal message" do
    other = Fabricate(:user)
    result =
      create(
        user,
        topic_id: nil,
        title: "Prywatna wiadomość testowa",
        archetype: Archetype.private_message,
        target_usernames: other.username,
      )
    expect(result.action).to eq(:create_post)
    expect(PluginStoreRow.where(plugin_name: MinosModeration::PLUGIN_NAME)).to be_empty
  end

  it "lets Discourse hold a post it holds itself, and marks the verdict as advice only" do
    SiteSetting.approve_post_count = 5
    newcomer = Fabricate(:user, trust_level: TrustLevel[0])
    result = create(newcomer)

    expect(result.action).to eq(:enqueued)
    expect(result.reason).to eq(:post_count)
    entry = MinosModeration::Store.get(result.reviewable.id)
    expect(entry["core_hold"]).to eq("post_count")
  end

  describe "the administrator's scope" do
    fab!(:chosen) { Fabricate(:category) }
    fab!(:sub) { Fabricate(:category, parent_category: chosen) }
    fab!(:elsewhere) { Fabricate(:category) }
    fab!(:chosen_topic) { Fabricate(:topic, category: sub) }
    fab!(:other_topic) { Fabricate(:topic, category: elsewhere) }

    let(:endpoint) { "https://gateway.wergiliusz.app/api/v1/b2b/oceny" }

    def stored?
      PluginStoreRow.where(plugin_name: MinosModeration::PLUGIN_NAME).exists?
    end

    it "sends nothing, stores nothing and holds nothing for a post outside it" do
      Jobs.run_immediately!
      gateway = stub_request(:post, endpoint).to_return(status: 202, body: "{}")
      SiteSetting.minos_categories = chosen.id.to_s

      result = create(user, topic_id: other_topic.id)

      expect(result.action).to eq(:create_post)
      expect(gateway).not_to have_been_requested
      expect(stored?).to be(false)
    end

    it "holds and sends a post inside it as before, also in a subcategory" do
      Jobs.run_immediately!
      gateway = stub_request(:post, endpoint).to_return(status: 202, body: "{}")
      SiteSetting.minos_categories = chosen.id.to_s

      result = create(user, topic_id: chosen_topic.id)

      expect(result.action).to eq(:enqueued)
      expect(gateway).to have_been_requested.once
      expect(MinosModeration::Store.get(result.reviewable.id)["status"]).to eq("submitted")
    end

    it "holds a new topic in a chosen category and lets one elsewhere through" do
      SiteSetting.minos_categories = chosen.id.to_s
      inside = { topic_id: nil, title: "Zupełnie nowy temat do dyskusji", category: chosen.id }
      outside = {
        topic_id: nil,
        title: "Drugi, całkiem inny temat do rozmowy",
        category: elsewhere.id,
        raw: "#{raw} Inny.",
      }
      expect(create(user, inside).action).to eq(:enqueued)
      expect(create(user, outside).action).to eq(:create_post)
    end

    it "leaves the members of an exempt group to Discourse" do
      group = Fabricate(:group)
      group.add(user)
      SiteSetting.minos_exempt_groups = group.id.to_s
      expect(create(user).action).to eq(:create_post)
      expect(stored?).to be(false)
    end

    it "holds authors up to the trust level chosen, and leaves those above it" do
      SiteSetting.minos_max_trust_level = 1
      expect(create(user).action).to eq(:create_post)
      basic = Fabricate(:user, trust_level: TrustLevel[1])
      expect(create(basic, raw: "#{raw} Od nowego.").action).to eq(:enqueued)
    end

    it "moderates every category when none of the chosen ones exists any more" do
      SiteSetting.minos_categories = (Category.maximum(:id) + 1000).to_s
      expect(create(user, topic_id: other_topic.id).action).to eq(:enqueued)
    end

    it "still lets Discourse hold a post outside it by its own rules, with no verdict" do
      SiteSetting.minos_categories = chosen.id.to_s
      SiteSetting.approve_post_count = 5
      newcomer = Fabricate(:user, trust_level: TrustLevel[0])

      result = create(newcomer, topic_id: other_topic.id)

      expect(result.action).to eq(:enqueued)
      expect(result.reason).to eq(:post_count)
      expect(stored?).to be(false)
    end
  end

  it "does not hold a post Discourse refuses" do
    result = create(user, topic_id: -1)
    expect(result.success?).to be(false)
    expect(PluginStoreRow.where(plugin_name: MinosModeration::PLUGIN_NAME)).to be_empty
  end
end
