# frozen_string_literal: true

require_relative "../../lib/minos_moderation/store" unless defined?(MinosModeration::Store)

# Shared plugin rule F10, without Discourse: `Store.set` never goes on after a write that
# `PluginStore.set` reports as not saved (`false`, its `row.save`), so the receiver cannot
# answer the gateway 2xx for a verdict it did not store. `PluginStore` is a stand-in here;
# spec/requests/webhooks_controller_spec.rb runs the same through Discourse's own.
RSpec.describe "MinosModeration::Store" do
  subject(:store) { MinosModeration::Store }

  # Discourse's `PluginStore.set` signature: plugin name, key, value.
  let(:plugin_store) do
    Class.new do
      def self.set(_plugin_name, _key, _value)
        true
      end
    end
  end

  before do
    stub_const("MinosModeration::PLUGIN_NAME", "minos-moderation")
    stub_const("PluginStore", plugin_store)
  end

  it "raises when PluginStore did not save the entry" do
    allow(plugin_store).to receive(:set).and_return(false)
    expect { store.set(7, { "status" => "received" }) }.to raise_error(
      RuntimeError,
      /reviewable 7 was not saved/,
    )
    # The write it refused is the entry's own.
    expect(plugin_store).to have_received(:set).with(
      "minos-moderation",
      "pending:7",
      { "status" => "received" },
    )
  end

  it "returns once PluginStore saved the entry" do
    expect { store.set(7, { "status" => "received" }) }.not_to raise_error
  end
end
