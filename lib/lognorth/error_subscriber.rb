# frozen_string_literal: true

module LogNorth
  class ErrorSubscriber
    def report(error, handled:, severity:, context: {}, source: nil)
      # Rails answers these with a 4xx (not found, bad CSRF token). The
      # middleware logs the request with that status; it is not an error.
      return if LogNorth.client_error?(error)

      ctx = context.dup
      ctx[:handled] = handled
      ctx[:severity] = severity
      ctx[:source] = source if source

      LogNorth.error(error.message, error, ctx)
    end
  end
end
