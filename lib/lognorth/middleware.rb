# frozen_string_literal: true

require "securerandom"

module LogNorth
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      start_time = Time.now
      trace_id = env["HTTP_X_TRACE_ID"].to_s.strip
      trace_id = SecureRandom.hex(8) if trace_id.empty?
      LogNorth::Client.current_trace_id = trace_id

      status, headers, response = @app.call(env)

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
      headers["X-Trace-ID"] = trace_id

      LogNorth::Client.send_event(
        "#{env['REQUEST_METHOD']} #{env['PATH_INFO']} → #{status}",
        { method: env["REQUEST_METHOD"], path: env["PATH_INFO"], status: status },
        trace_id: trace_id,
        duration_ms: duration_ms,
        timestamp: start_time
      )

      LogNorth.flush if status >= 500

      LogNorth::Client.current_trace_id = nil
      [status, headers, response]
    rescue StandardError => e
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
      LogNorth::Client.send_error_event(
        "Request failed: #{env['REQUEST_METHOD']} #{env['PATH_INFO']}", e,
        { method: env["REQUEST_METHOD"], path: env["PATH_INFO"] },
        trace_id: trace_id,
        duration_ms: duration_ms,
        timestamp: start_time
      )
      LogNorth::Client.current_trace_id = nil
      raise
    end
  end
end
