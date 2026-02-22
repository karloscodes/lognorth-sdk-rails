# frozen_string_literal: true

require_relative "test_helper"

class MiddlewareTest < Minitest::Test
  def setup
    LogNorth.config("https://lognorth.test", "test-key")
    LogNorth::Client.instance_variable_set(:@buffer, [])
  end

  def test_logs_successful_request
    app = ->(env) { [200, {}, ["OK"]] }
    middleware = LogNorth::Middleware.new(app)

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/users"
    }

    status, _headers, _body = middleware.call(env)

    assert_equal 200, status

    buffer = LogNorth::Client.instance_variable_get(:@buffer)

    assert_equal 1, buffer.size
    assert_equal "GET /users → 200", buffer.first[:message]
    assert_equal "GET", buffer.first[:context][:method]
    assert_equal "/users", buffer.first[:context][:path]
    assert_equal 200, buffer.first[:context][:status]
    assert buffer.first[:duration_ms]
    assert buffer.first[:trace_id]
    refute buffer.first[:context][:duration_ms]
  end

  def test_logs_error_and_reraises
    app = ->(_env) { raise StandardError, "boom" }
    middleware = LogNorth::Middleware.new(app)

    stub_request(:post, "https://lognorth.test/api/v1/events/batch")
      .to_return(status: 200)

    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/orders"
    }

    assert_raises(StandardError) { middleware.call(env) }

    sleep 0.1 # wait for error thread
  end
end
