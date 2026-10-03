# frozen_string_literal: true

require_relative "test_helper"
require "action_dispatch"
require "action_controller"
require "action_controller/metal/request_forgery_protection"

# Registered the way ActiveRecord's railtie registers RecordNotFound.
class WidgetNotFound < StandardError; end
ActionDispatch::ExceptionWrapper.rescue_responses["WidgetNotFound"] = :not_found

class ClientErrorsTest < Minitest::Test
  def test_rails_decides_what_is_a_client_error
    assert LogNorth.client_error?(ActionController::InvalidAuthenticityToken.new)
    assert LogNorth.client_error?(WidgetNotFound.new)
    refute LogNorth.client_error?(RuntimeError.new("boom"))
  end

  def test_error_subscriber_skips_a_404
    LogNorth::ErrorSubscriber.new.report(WidgetNotFound.new("no widget 19"), handled: false, severity: :error)
    sleep 0.2 # an error would be sent at once

    assert_empty @server.requests
    assert_empty buffer
  end

  def test_error_subscriber_skips_a_422
    LogNorth::ErrorSubscriber.new.report(ActionController::InvalidAuthenticityToken.new, handled: false, severity: :error)
    sleep 0.2

    assert_empty @server.requests
    assert_empty buffer
  end

  def test_error_subscriber_reports_a_500
    error = RuntimeError.new("boom")
    error.set_backtrace(["app/models/order.rb:10:in `charge'"])

    LogNorth::ErrorSubscriber.new.report(error, handled: false, severity: :error)
    wait_until { @server.events.any? }

    assert_equal 1, @server.events.size
  end

  def test_middleware_logs_a_client_error_as_a_request_with_its_status
    app = ->(_env) { raise ActionController::InvalidAuthenticityToken }
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/orders" }

    assert_raises(ActionController::InvalidAuthenticityToken) { LogNorth::Middleware.new(app).call(env) }
    assert_equal 1, buffer.size
    assert_equal "POST /orders → 422", buffer.first[:message]
    assert_equal 422, buffer.first[:context][:status]
    refute buffer.first[:context].key?(:error)
  end

  def test_middleware_still_reports_a_500_as_an_error
    app = ->(_env) { raise "boom" }
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/orders" }

    assert_raises(RuntimeError) { LogNorth::Middleware.new(app).call(env) }
    wait_until { @server.events.any? }

    assert_equal 1, @server.events.size
  end
end
