# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  def setup
    LogNorth.config("https://lognorth.test", "test-key")
    LogNorth::Client.instance_variable_set(:@buffer, [])
    LogNorth::Client.instance_variable_set(:@backoff_until, nil)
  end

  def test_config_sets_endpoint_and_key
    LogNorth.config("https://example.com", "my-key")

    assert_equal "https://example.com", LogNorth::Client.instance_variable_get(:@endpoint)
    assert_equal "my-key", LogNorth::Client.instance_variable_get(:@api_key)
  end

  def test_log_adds_event_to_buffer
    LogNorth.log("test message", { user_id: 1 })

    buffer = LogNorth::Client.instance_variable_get(:@buffer)

    assert_equal 1, buffer.size
    assert_equal "test message", buffer.first[:message]
    assert_equal({ user_id: 1 }, buffer.first[:context])
    assert buffer.first[:timestamp]
  end

  def test_flush_sends_batch_request
    stub = stub_request(:post, "https://lognorth.test/api/v1/events/batch")
      .with(
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer test-key"
        }
      )
      .to_return(status: 200)

    LogNorth.log("message 1")
    LogNorth.log("message 2")
    LogNorth.flush

    assert_requested(stub)
    assert_empty LogNorth::Client.instance_variable_get(:@buffer)
  end

  def test_error_sends_immediately
    stub_request(:post, "https://lognorth.test/api/v1/events/batch")
      .to_return(status: 200)

    error = StandardError.new("something broke")
    error.set_backtrace(["line1", "line2"])

    LogNorth.error("failure", error, { request_id: "abc" })
    sleep 0.1 # wait for thread

    assert_requested(:post, "https://lognorth.test/api/v1/events/batch")
  end

  def test_flush_clears_buffer
    LogNorth.log("test")

    refute_empty LogNorth::Client.instance_variable_get(:@buffer)

    stub_request(:post, "https://lognorth.test/api/v1/events/batch")
      .to_return(status: 200)

    LogNorth.flush

    assert_empty LogNorth::Client.instance_variable_get(:@buffer)
  end

  def test_rate_limit_triggers_backoff
    stub_request(:post, "https://lognorth.test/api/v1/events/batch")
      .to_return(status: 429)

    LogNorth.log("test")
    LogNorth.flush

    backoff = LogNorth::Client.instance_variable_get(:@backoff_until)

    assert backoff
    assert backoff > Time.now
  end
end
