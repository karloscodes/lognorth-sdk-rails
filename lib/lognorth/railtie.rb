# frozen_string_literal: true

module LogNorth
  class Railtie < Rails::Railtie
    config.lognorth = ActiveSupport::OrderedOptions.new
    config.lognorth.enabled = true
    config.lognorth.middleware = true
    config.lognorth.error_subscriber = true
    config.lognorth.active_job = true
    config.lognorth.ignored_paths = []  # Paths to skip logging (e.g., ["/healthz", "/_health"])

    initializer "lognorth.middleware" do |app|
      if app.config.lognorth.enabled && app.config.lognorth.middleware
        app.middleware.use LogNorth::Middleware
      end
    end

    config.after_initialize do |app|
      $stdout.puts "[LogNorth] after_initialize running"
      next unless app.config.lognorth.enabled

      url = app.config.lognorth.url
      key = app.config.lognorth.api_key

      unless url
        begin
          url = app.credentials.dig(:lognorth, :url)
        rescue StandardError
          nil
        end
      end

      unless key
        begin
          key = app.credentials.dig(:lognorth, :api_key)
        rescue StandardError
          nil
        end
      end

      if url && key
        LogNorth.config(url, key)
        LogNorth::Client.debug = Rails.env.local?

        if app.config.lognorth.error_subscriber && Rails.version >= "7.0"
          Rails.error.subscribe(LogNorth::ErrorSubscriber.new)
        end

        if app.config.lognorth.active_job && defined?(ActiveJob)
          require "lognorth/active_job_subscriber"
          LogNorth::ActiveJobSubscriber.attach
        end
      else
        $stdout.puts "[LogNorth] not configured: url=#{url.inspect} api_key=#{key ? '[set]' : 'nil'}"
      end
    end
  end
end
