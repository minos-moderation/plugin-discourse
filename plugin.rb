# frozen_string_literal: true

# name: minos-moderation
# about: Minos — moderacja postów: nowe posty czekają na werdykt bramy Wergiliusz, który wraca podpisanym webhookiem.
# version: 0.1.0
# authors: Minos
# url: https://github.com/minos-moderation/plugin-discourse

enabled_site_setting :minos_enabled

module ::MinosModeration
  PLUGIN_NAME = "minos-moderation"
end

require_relative "lib/minos_moderation/engine"

after_initialize do
end
