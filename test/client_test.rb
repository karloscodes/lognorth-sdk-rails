# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  def test_config_sets_endpoint_and_key
    LogNorth.config("https://example.com/", "my-key")

    assert_equal "https://example.com", LogNorth::Client.instance_variable_get(:@endpoint)
    assert_equal "my-key", LogNorth::Client.instance_variable_get(:@api_key)
  end

  def test_log_adds_event_to_buffer
    LogNorth.log("test message", { user_id: 1 })

    assert_equal 1, buffer.size
    assert_equal "test message", buffer.first[:message]
    assert_equal({ user_id: 1 }, buffer.first[:context])
    assert buffer.first[:timestamp]
  end

  def test_flush_sends_batch_request
    LogNorth.log("message 1")
    LogNorth.log("message 2")

    LogNorth.flush

    request = @server.requests.first
    assert_equal %w[message\ 1 message\ 2], @server.messages
    assert_equal "Bearer test-key", request[:headers]["authorization"]
    assert_equal "application/json", request[:headers]["content-type"]
    assert_empty buffer
  end

  def test_log_events_are_sent_after_the_flush_interval
    LogNorth.log("later")

    wait_until { @server.events.any? }

    assert_equal ["later"], @server.messages
  end

  def test_ten_events_are_sent_without_waiting_for_the_timer
    set_client(:flush_interval, 60)

    10.times { |i| LogNorth.log("event #{i}") }
    wait_until { @server.events.size == 10 }

    assert_equal 10, @server.events.size
  end

  def test_error_is_sent_at_once_through_the_queue
    set_client(:flush_interval, 60)
    LogNorth.log("before")

    LogNorth.error("failure", error_with_backtrace("something broke"), { request_id: "abc" })
    wait_until { @server.events.size == 2 }

    assert_equal %w[before failure], @server.messages
    context = @server.events.last["context"]
    assert_equal "something broke", context["error"]
    assert_equal "order.rb", context["error_file"]
    assert_equal "abc", context["request_id"]
  end

  def test_environment_is_stamped_on_log_events
    LogNorth.config(@server.url, "test-key", environment: "staging")

    LogNorth.log("hello", { user_id: 1 })

    assert_equal "staging", buffer.first[:context][:environment]
    assert_equal 1, buffer.first[:context][:user_id]
  end

  def test_environment_is_stamped_on_error_events
    LogNorth.config(@server.url, "test-key", environment: "staging")

    LogNorth.error("crash", error_with_backtrace("boom"))
    wait_until { @server.events.any? }

    assert_equal "staging", @server.events.first.dig("context", "environment")
  end

  def test_calls_are_no_op_when_not_configured
    set_client(:endpoint, nil)
    set_client(:api_key, nil)

    LogNorth.log("dropped")

    assert_empty buffer
  end
end
