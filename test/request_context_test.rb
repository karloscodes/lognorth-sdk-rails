# frozen_string_literal: true

require_relative "test_helper"

class RequestContextTest < Minitest::Test
  def teardown
    LogNorth::Client.end_request
    Object.send(:remove_const, :Current) if defined?(::Current)
  end

  def request(status: 200, agent: "Mozilla/5.0", &handler)
    app = lambda do |env|
      handler&.call
      env["action_controller.instance"] = Object.new
      [status, {}, ["OK"]]
    end
    LogNorth::Middleware.new(app).call(
      { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/account", "HTTP_USER_AGENT" => agent }
    )
  end

  def test_the_request_event_and_its_errors_carry_the_user
    request(status: 500) do
      LogNorth.user = 42
      LogNorth.error("charge failed", StandardError.new("card declined"))
    end

    wait_until { @server.events.size == 2 }
    assert_equal %w[42 42], @server.events.map { |e| e["context"]["user"] }
  end

  def test_the_user_comes_from_current_when_the_app_defines_it
    user = Struct.new(:id).new(7)
    Object.const_set(:Current, Class.new { define_singleton_method(:user) { user } })

    request

    assert_equal "7", buffer.first[:context][:user]
  end

  def test_the_user_is_forgotten_after_the_request
    request { LogNorth.user = 42 }

    LogNorth.log("background work")

    assert_nil buffer.last[:context][:user]
  end

  def test_only_a_failed_request_carries_the_user_agent
    request(status: 200)
    request(status: 500)

    LogNorth.flush
    ok, broken = @server.events.sort_by { |e| e["context"]["status"] }
    assert_nil ok["context"]["user_agent"]
    assert_equal "Mozilla/5.0", broken["context"]["user_agent"]
  end

  def test_errors_carry_the_release_and_logs_do_not
    LogNorth.config(@server.url, "test-key", release: "a1b2c3d")

    LogNorth.log("signed up")
    LogNorth.error("charge failed", StandardError.new("card declined"))

    LogNorth.flush
    start, log, error = @server.events
    assert_equal "Release a1b2c3d started", start["message"]
    assert_nil log["context"]["release"]
    assert_equal "a1b2c3d", error["context"]["release"]
  end

  def test_the_release_comes_from_the_environment
    ENV["KAMAL_VERSION"] = "f00ba44"
    LogNorth.config(@server.url, "test-key")

    LogNorth.error("charge failed", StandardError.new("card declined"))

    wait_until { @server.events.size == 2 }
    assert_equal "f00ba44", @server.events.last["context"]["release"]
  ensure
    ENV.delete("KAMAL_VERSION")
  end

  def test_the_client_says_once_that_the_release_started
    LogNorth.config(@server.url, "test-key", release: "c0ffee1")
    LogNorth.config(@server.url, "test-key", release: "c0ffee1")

    LogNorth.flush

    assert_equal ["Release c0ffee1 started"], @server.messages
  end
end
