# frozen_string_literal: true

module ::MinosModeration
  # The plugin's Rails engine: it mounts the webhook route (`config/routes.rb`) and makes
  # `lib/` and `app/` autoloadable. The shape is the one of `discourse-plugin-skeleton`.
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace MinosModeration
    config.autoload_paths << File.join(config.root, "lib")
    scheduled_job_dir = "#{config.root}/app/jobs/scheduled"
    config.to_prepare do
      Rails.autoloaders.main.eager_load_dir(scheduled_job_dir) if Dir.exist?(scheduled_job_dir)
    end
  end
end
