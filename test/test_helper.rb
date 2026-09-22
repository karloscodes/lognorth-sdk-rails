# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"
require_relative "../lib/lognorth"

WebMock.disable_net_connect!

class Minitest::Test
  # The client is global state. Reset it before every test, so a test that
  # triggers a rate-limit backoff cannot drop the requests of the next one.
  def before_setup
    super
    LogNorth::Client.instance_variable_set(:@buffer, [])
    LogNorth::Client.instance_variable_set(:@backoff_until, nil)
  end

  # Error events go out on a background thread. Wait for the request
  # instead of sleeping a fixed time.
  def wait_for_request(method, url, timeout: 2)
    pattern = WebMock::RequestPattern.new(method, url)
    deadline = Time.now + timeout
    sleep 0.01 until WebMock::RequestRegistry.instance.times_executed(pattern).positive? || Time.now > deadline
  end
end
