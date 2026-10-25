# frozen_string_literal: true

require_relative "test_helper"
require "action_dispatch"

class MiddlewareTest < Minitest::Test
  def test_logs_successful_request
    app = ->(env) { [200, {}, ["OK"]] }
    middleware = LogNorth::Middleware.new(app)

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/users"
    }

    status, _headers, _body = middleware.call(env)

    assert_equal 200, status

    assert_equal 1, buffer.size
    assert_equal "GET /users → 200", buffer.first[:message]
    assert_equal "GET", buffer.first[:context][:method]
    assert_equal "/users", buffer.first[:context][:path]
    assert_equal 200, buffer.first[:context][:status]
    assert buffer.first[:duration_ms]
    assert buffer.first[:trace_id]
    refute buffer.first[:context][:duration_ms]
  end

  def test_skips_route_miss_404
    app = ->(env) { [404, {}, ["Not Found"]] }
    middleware = LogNorth::Middleware.new(app)

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/.env"
    }

    status, _headers, _body = middleware.call(env)

    assert_equal 404, status

    assert_equal 0, buffer.size
  end

  def test_tracks_controller_404
    app = ->(env) {
      env["action_controller.instance"] = Object.new
      [404, {}, ["Not Found"]]
    }
    middleware = LogNorth::Middleware.new(app)

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/users/999"
    }

    status, _headers, _body = middleware.call(env)

    assert_equal 404, status

    assert_equal 1, buffer.size
    assert_equal "GET /users/999 → 404", buffer.first[:message]
  end

  def test_logs_error_and_reraises
    app = ->(_env) { raise StandardError, "boom" }
    middleware = LogNorth::Middleware.new(app)

    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/orders"
    }

    assert_raises(StandardError) { middleware.call(env) }

    wait_until { @server.events.any? }

    assert_equal "Request failed: POST /orders", @server.messages.first
  end

  def test_populates_controller_and_action_from_action_controller_instance
    fake_controller = Class.new do
      def self.name; "ConversationsController"; end
      def action_name; "index"; end
    end.new

    app = ->(env) {
      env["action_controller.instance"] = fake_controller
      [200, {}, ["OK"]]
    }
    middleware = LogNorth::Middleware.new(app)

    middleware.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/conversations" })

    ctx = buffer.first[:context]
    assert_equal "ConversationsController", ctx[:controller]
    assert_equal "index", ctx[:action]
  end

  def test_omits_route_fields_when_not_a_rails_controller
    app = ->(_env) { [200, {}, ["OK"]] }
    middleware = LogNorth::Middleware.new(app)

    middleware.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/" })

    ctx = buffer.first[:context]
    refute ctx.key?(:controller)
    refute ctx.key?(:action)
  end

  def test_sends_the_route_rails_matched
    app = routes { get "/users/:id", to: CONTROLLER }

    LogNorth::Middleware.new(app).call(Rack::MockRequest.env_for("/users/42"))

    ctx = buffer.first[:context]
    assert_equal "/users/42", ctx[:path]
    assert_equal "/users/:id", ctx[:route]
  end

  def test_sends_the_full_path_and_route_of_a_mounted_engine
    engine = routes { get "/posts/:id", to: CONTROLLER }
    app = routes { mount engine => "/admin" }

    LogNorth::Middleware.new(app).call(Rack::MockRequest.env_for("/admin/posts/7"))

    ctx = buffer.first[:context]
    assert_equal "GET /admin/posts/7 → 200", buffer.first[:message]
    assert_equal "/admin/posts/7", ctx[:path]
    assert_equal "/admin/posts/:id", ctx[:route]
  end

  def test_names_the_full_path_when_a_mounted_engine_fails
    failing = ->(env) { env["action_controller.instance"] = Object.new; raise StandardError, "boom" }
    engine = routes { get "/posts/:id", to: failing }
    app = routes { mount engine => "/admin" }

    assert_raises(StandardError) { LogNorth::Middleware.new(app).call(Rack::MockRequest.env_for("/admin/posts/7")) }

    wait_until { @server.events.any? }
    assert_equal "Request failed: GET /admin/posts/7", @server.messages.first
  end

  def test_sends_no_route_for_a_mounted_rack_app
    rack_app = ->(_env) { [200, {}, ["OK"]] }
    app = routes { mount rack_app => "/jobs" }

    LogNorth::Middleware.new(app).call(Rack::MockRequest.env_for("/jobs/queues"))

    ctx = buffer.first[:context]
    assert_equal "/jobs/queues", ctx[:path]
    refute ctx.key?(:route)
  end

  private

  # A Rails controller sets action_controller.instance when it runs.
  CONTROLLER = ->(env) { env["action_controller.instance"] = Object.new; [200, {}, ["OK"]] }

  def routes(&draw)
    ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw(&draw) }
  end
end
