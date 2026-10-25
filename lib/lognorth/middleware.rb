# frozen_string_literal: true

require "securerandom"

module LogNorth
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      # A mounted engine or Rack app leaves PATH_INFO and SCRIPT_NAME as it
      # saw them, so read both before the call.
      path = env["PATH_INFO"]
      script_name = env["SCRIPT_NAME"].to_s

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
        LogNorth::Client.end_request
        return [status, headers, response]
      end

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
      headers["X-Trace-ID"] = trace_id

      context = { method: env["REQUEST_METHOD"], path: path, status: status }
      merge_route_info!(context, env, script_name)
      merge_user_agent!(context, env, status)

      LogNorth::Client.send_event(
        "#{env['REQUEST_METHOD']} #{path} → #{status}",
        context,
        trace_id: trace_id,
        duration_ms: duration_ms,
        timestamp: start_time
      )

      LogNorth.flush if status >= 500

      LogNorth::Client.end_request
      [status, headers, response]
    rescue StandardError => e
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
      if LogNorth.client_error?(e)
        # Rails turns this into a 4xx further out. Log the request with that
        # status, like any other request, instead of an error.
        status = LogNorth.response_status_for(e)
        context = { method: env["REQUEST_METHOD"], path: path, status: status }
        merge_route_info!(context, env, script_name)
        LogNorth::Client.send_event(
          "#{env['REQUEST_METHOD']} #{path} → #{status}", context,
          trace_id: trace_id, duration_ms: duration_ms, timestamp: start_time
        )
        LogNorth::Client.end_request
        raise
      end
      LogNorth::Client.send_error_event(
        "Request failed: #{env['REQUEST_METHOD']} #{path}", e,
        merge_user_agent!({ method: env["REQUEST_METHOD"], path: path }, env, 500),
        trace_id: trace_id,
        duration_ms: duration_ms,
        timestamp: start_time
      )
      LogNorth::Client.end_request
      raise
    end

    private

    def ignored_path?(path)
      ignored_paths = Rails.application.config.lognorth.ignored_paths rescue []
      return false if ignored_paths.nil? || ignored_paths.empty?

      ignored_paths.any? { |p| path == p || path.start_with?("#{p}/") }
    end

    # The user agent tells a bot from a browser on a failed request. Only
    # failed ones carry it, to keep every other event small.
    def merge_user_agent!(context, env, status)
      agent = env["HTTP_USER_AGENT"].to_s
      context[:user_agent] = agent if status.to_i >= 500 && !agent.empty?
      context
    end

    # Rails populates action_controller.instance after dispatch so the
    # controller/action names — and the route — can be pulled straight off
    # the env.
    def merge_route_info!(context, env, script_name)
      controller = env["action_controller.instance"]
      return unless controller

      klass = controller.class.name
      action = controller.respond_to?(:action_name) ? controller.action_name : nil
      context[:controller] = klass if klass
      context[:action] = action if action
      route = route_of(env, script_name)
      context[:route] = route if route
    end

    # The route as `bin/rails routes` prints it (Rails 7.1+), without the
    # optional format: "/users/:id". An engine's route is relative to its
    # mount point, which Rails added to SCRIPT_NAME.
    def route_of(env, script_name)
      return unless defined?(ActionDispatch::Request) && ActionDispatch::Request.method_defined?(:route_uri_pattern)

      pattern = ActionDispatch::Request.new(env).route_uri_pattern
      return unless pattern

      mount = env["SCRIPT_NAME"].to_s.delete_prefix(script_name)
      mount + pattern.delete_suffix("(.:format)")
    end
  end
end
