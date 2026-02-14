# frozen_string_literal: true

module LogNorth
  class Railtie < Rails::Railtie
    config.lognorth = ActiveSupport::OrderedOptions.new
    config.lognorth.enabled = true
    config.lognorth.middleware = true
    config.lognorth.error_subscriber = true

    initializer "lognorth.configure" do |app|
      next unless app.config.lognorth.enabled

      url = app.config.lognorth.url || credentials_url(app)
      key = app.config.lognorth.api_key || credentials_api_key(app)

      if url && key
        LogNorth.config(url, key)

        if app.config.lognorth.middleware
          app.middleware.use LogNorth::Middleware
        end

        if app.config.lognorth.error_subscriber && Rails.version >= "7.0"
          Rails.error.subscribe(LogNorth::ErrorSubscriber.new)
        end
      end
    end

    private

    def credentials_url(app)
      app.credentials.dig(:lognorth, :url)
    rescue StandardError
      nil
    end

    def credentials_api_key(app)
      app.credentials.dig(:lognorth, :api_key)
    rescue StandardError
      nil
    end
  end
end
