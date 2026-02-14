# frozen_string_literal: true

require_relative "test_helper"

class ErrorSubscriberTest < Minitest::Test
  def setup
    LogNorth.config("https://lognorth.test", "test-key")
    stub_request(:post, "https://lognorth.test/api/v1/events/batch")
      .to_return(status: 200)
  end

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

    sleep 0.1 # wait for thread

    assert_requested(:post, "https://lognorth.test/api/v1/events/batch")
  end
end
