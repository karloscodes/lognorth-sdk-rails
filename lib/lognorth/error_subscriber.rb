# frozen_string_literal: true

module LogNorth
  class ErrorSubscriber
    def report(error, handled:, severity:, context: {}, source: nil)
      ctx = context.dup
      ctx[:handled] = handled
      ctx[:severity] = severity
      ctx[:source] = source if source

      LogNorth.error(error.message, error, ctx)
    end
  end
end
