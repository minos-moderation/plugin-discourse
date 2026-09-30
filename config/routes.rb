# frozen_string_literal: true

# The gateway delivers every verdict to POST /minos/webhook on the forum's own domain.
MinosModeration::Engine.routes.draw { post "/webhook" => "webhooks#receive" }

Discourse::Application.routes.draw { mount ::MinosModeration::Engine, at: "minos" }
