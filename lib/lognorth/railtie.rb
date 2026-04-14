# frozen_string_literal: true

module LogNorth
  class Railtie < Rails::Railtie
    config.lognorth = ActiveSupport::OrderedOptions.new
    # nil = auto (production only). Set true/false to override.
    config.lognorth.enabled = nil
    config.lognorth.middleware = true
    config.lognorth.error_subscriber = true
    config.lognorth.active_job = true
    # Rails 7.1+ auto-generates /up as a health-check endpoint; kamal-proxy
    # and most load balancers hit it constantly and it would otherwise swamp
    # the log feed. Set to [] to disable or pass your own list to replace.
    config.lognorth.ignored_paths = ["/up"]

    initializer "lognorth.middleware" do |app|
      if LogNorth::Railtie.lognorth_enabled?(app) && app.config.lognorth.middleware
        app.middleware.use LogNorth::Middleware
      end
    end

    config.after_initialize do |app|
      next unless LogNorth::Railtie.lognorth_enabled?(app)

      url = app.config.lognorth.url || LogNorth::Railtie.dig_credential(app, :url)
      key = app.config.lognorth.api_key || LogNorth::Railtie.dig_credential(app, :api_key)

      unless url && key
        Rails.logger.warn("[LogNorth] enabled but credentials missing — set Rails credentials lognorth.url/api_key or config.lognorth.{url,api_key}")
        next
      end

      LogNorth.config(url, key, environment: Rails.env.to_s)
      LogNorth::Client.debug = false # Rails.env.local? made tests/dev noisy

      if app.config.lognorth.error_subscriber && Rails.version >= "7.0"
        Rails.error.subscribe(LogNorth::ErrorSubscriber.new)
      end

      if app.config.lognorth.active_job && defined?(ActiveJob)
        require "lognorth/active_job_subscriber"
        LogNorth::ActiveJobSubscriber.attach
      end
    end

    class << self
      # Default off in development and test only. Production, staging, preview,
      # qa, and any other custom env opt in automatically. Set
      # config.lognorth.enabled = true/false to override.
      def lognorth_enabled?(app)
        explicit = app.config.lognorth.enabled
        return explicit unless explicit.nil?

        !(Rails.env.development? || Rails.env.test?)
      end

      def dig_credential(app, key)
        app.credentials.dig(:lognorth, key)
      rescue StandardError
        nil
      end
    end
  end
end
