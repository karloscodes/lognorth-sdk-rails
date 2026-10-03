# frozen_string_literal: true

require_relative "test_helper"

class ErrorSubscriberTest < Minitest::Test
  def test_report_sends_error
    subscriber = LogNorth::ErrorSubscriber.new
    error = RuntimeError.new("test error")
    error.set_backtrace(["app/models/user.rb:10"])

    subscriber.report(
      error,
      handled: false,
      severity: :error,
      context: { controller: "UsersController" },
      source: "application"
    )

    wait_until { @server.events.any? }

    assert_equal "UsersController", @server.events.first.dig("context", "controller")
  end
end
