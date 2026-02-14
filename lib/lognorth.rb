# frozen_string_literal: true

require_relative "lognorth/client"
require_relative "lognorth/middleware"
require_relative "lognorth/error_subscriber"
require_relative "lognorth/railtie" if defined?(Rails::Railtie)

module LogNorth
  class << self
    def config(url, key)
      Client.config(url, key)
    end

    def log(message, context = {})
      Client.log(message, context)
    end

    def error(message, exception, context = {})
      Client.error(message, exception, context)
    end

    def flush
      Client.flush
    end
  end
end

at_exit { LogNorth.flush }
