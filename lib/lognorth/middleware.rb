# frozen_string_literal: true

require "securerandom"

module LogNorth
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      path = env["PATH_INFO"]

      # Skip ignored paths (health checks, metrics, etc.)
      if ignored_path?(path)
        return @app.call(env)
      end

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      start_time = Time.now
      trace_id = env["HTTP_X_TRACE_ID"].to_s.strip
      trace_id = SecureRandom.hex(8) if trace_id.empty?
      LogNorth::Client.current_trace_id = trace_id

      status, headers, response = @app.call(env)

      # Don't track requests that didn't match any route (scanner noise)
      if status == 404 && !env["action_controller.instance"]
        LogNorth::Client.current_trace_id = nil
        return [status, headers, response]
      end

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
      headers["X-Trace-ID"] = trace_id

      context = { method: env["REQUEST_METHOD"], path: env["PATH_INFO"], status: status }
      merge_route_info!(context, env)

      LogNorth::Client.send_event(
        "#{env['REQUEST_METHOD']} #{env['PATH_INFO']} → #{status}",
        context,
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

    private

    def ignored_path?(path)
      ignored_paths = Rails.application.config.lognorth.ignored_paths rescue []
      return false if ignored_paths.nil? || ignored_paths.empty?

      ignored_paths.any? { |p| path == p || path.start_with?("#{p}/") }
    end

    # Rails populates action_controller.instance after dispatch so the
    # controller/action names — and the named route when available —
    # can be pulled straight off the env.
    def merge_route_info!(context, env)
      controller = env["action_controller.instance"]
      return unless controller

      klass = controller.class.name
      action = controller.respond_to?(:action_name) ? controller.action_name : nil
      context[:controller] = klass if klass
      context[:action] = action if action
    end
  end
end
