# frozen_string_literal: true

# name: minos-moderation
# about: Minos — moderacja postów: nowe posty czekają na werdykt bramy Wergiliusz, który wraca podpisanym webhookiem.
# version: 0.1.0
# authors: INPERITIA
# url: https://github.com/minos-moderation/plugin-discourse

enabled_site_setting :minos_enabled

module ::MinosModeration
  PLUGIN_NAME = "minos-moderation"
end

require_relative "lib/minos_moderation/engine"

after_initialize do
  NewPostManager.add_handler(MinosModeration::NewPostHandler::PRIORITY) do |manager|
    MinosModeration::NewPostHandler.call(manager)
  end

  # The gateway's pause and limit belong to the key and the address they came for: a new
  # key or gateway address may send at once.
  on(:site_setting_changed) do |name, _old_value, _new_value|
    if %w[minos_api_key minos_gateway_url].include?(name.to_s)
      MinosModeration::Store.forget_refusals
    end
  end

  if respond_to?(:register_problem_check)
    register_problem_check(MinosModeration::MinosGatewayProblem)
  end
end
