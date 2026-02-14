# frozen_string_literal: true

module LogNorth
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      status, headers, response = @app.call(env)

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

      LogNorth.log(
        "#{env['REQUEST_METHOD']} #{env['PATH_INFO']} → #{status}",
        {
          method: env["REQUEST_METHOD"],
          path: env["PATH_INFO"],
          status: status,
          duration_ms: duration_ms
        }
      )

      [status, headers, response]
    rescue StandardError => e
      LogNorth.error("Request failed: #{env['REQUEST_METHOD']} #{env['PATH_INFO']}", e, {
        method: env["REQUEST_METHOD"],
        path: env["PATH_INFO"]
      })
      raise
    end
  end
end
