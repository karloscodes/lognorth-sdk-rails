# frozen_string_literal: true

require_relative "test_helper"

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
end
