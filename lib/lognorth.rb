# frozen_string_literal: true

require_relative "lognorth/client"
require_relative "lognorth/middleware"
require_relative "lognorth/error_subscriber"
require_relative "lognorth/railtie" if defined?(Rails::Railtie)

module LogNorth
  class << self
    def config(url, key, environment: nil)
      Client.config(url, key, environment: environment)
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

    # The HTTP status Rails answers this exception with, from
    # config.action_dispatch.rescue_responses. RecordNotFound is a 404,
    # InvalidAuthenticityToken a 422, anything unmapped a 500. Nil outside Rails.
    def response_status_for(exception)
      return nil unless defined?(ActionDispatch::ExceptionWrapper)

      ActionDispatch::ExceptionWrapper.status_code_for_exception(exception.class.name)
    end

    # A client error is an exception Rails answers with a 4xx: the request
    # was wrong, the app is fine. It is not reported as an error.
    def client_error?(exception)
      status = response_status_for(exception)
      !status.nil? && status < 500
    end
  end
end

at_exit { LogNorth.flush }
