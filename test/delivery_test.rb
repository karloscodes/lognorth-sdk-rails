# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

# How the client keeps events when the server is down, slow, or says no.
class DeliveryTest < Minitest::Test
  def log_events(count, prefix = "event")
    count.times { |i| LogNorth.log("#{prefix} #{i}") }
  end

  def drop_report
    @server.events.find { |e| e["message"].start_with?("LogNorth client dropped") }
  end

  def test_503_with_retry_after_sends_the_batch_again_after_the_wait
    @server.answer(503, { "Retry-After" => "1" })

    log_events(10)
    sleep 0.6

    assert_equal 1, @server.requests.size

    wait_until { @server.events.size == 10 }

    assert_equal 2, @server.requests.size
    assert_equal (0..9).map { |i| "event #{i}" }, @server.messages
  end

  def test_429_with_retry_after_keeps_the_events_and_sends_them_after_the_wait
    @server.answer(429, { "Retry-After" => "1" })

    LogNorth.error("boom", error_with_backtrace("boom"))
    sleep 0.6

    assert_empty @server.events
    assert_equal 1, buffer.size

    wait_until { @server.events.any? }

    assert_equal ["boom"], @server.messages
  end

  def test_retry_after_does_not_grow_the_backoff_and_the_retry_takes_a_full_batch
    answers = [[503, { "Retry-After" => "1" }], [503, { "Retry-After" => "1" }], [500, {}]]
    @server.handler = ->(_events) { answers.shift || [201, {}] }

    log_events(10)
    wait_until { @server.requests.size == 1 }
    log_events(30, "later")
    wait_until(timeout: 5) { @server.events.size == 40 }

    requests = @server.requests
    assert_equal [10, 40, 40, 40], requests.map { |r| r[:events].size }
    gap = requests[3][:at] - requests[2][:at]
    assert_operator gap, :<, 0.12, "the wait after the 500 is the first backoff, not one grown by Retry-After"
  end

  def test_500_is_retried_with_backoff
    @server.answer(500, times: 3)

    log_events(10)
    # The server records a batch before it answers, so wait for the client to read the 201 too.
    wait_until { @server.events.size == 10 && @stderr.string.include?("delivery recovered") }

    assert_equal [500, 500, 500, 201], @server.requests.map { |r| r[:status] }
    assert_equal 10, @server.events.size
    assert_includes @stderr.string, "server answered 500"
    assert_includes @stderr.string, "delivery recovered"
  end

  def test_network_failure_keeps_normal_log_events
    @server.stop

    log_events(10)
    sleep 0.3
    @server.start
    wait_until { @server.events.size == 10 }

    assert_equal (0..9).map { |i| "event #{i}" }, @server.messages
    assert_equal 1, @stderr.string.scan("network error").size
  end

  def test_413_splits_the_batch
    @server.answer(413)

    log_events(10)
    wait_until { @server.events.size == 10 }

    assert_equal [10, 5, 5], @server.requests.map { |r| r[:events].size }
    assert_equal (0..9).map { |i| "event #{i}" }, @server.messages
  end

  def test_413_drops_and_counts_a_single_event_it_cannot_send
    @server.handler = lambda do |events|
      events.any? { |e| e["message"] == "too big" } ? [413, {}] : [201, {}]
    end

    LogNorth.log("first")
    LogNorth.log("too big")
    LogNorth.log("last")
    LogNorth.flush
    LogNorth.flush # sends the drop report

    assert_equal ["first", "last", "LogNorth client dropped 1 events"], @server.messages
    assert_equal({ "dropped" => 1, "dropped_errors" => 0 }, drop_report["context"])
  end

  def test_401_keeps_the_events_until_the_server_accepts
    @server.answer(401, times: 3)

    log_events(10)
    wait_until { @server.events.size == 10 }

    assert_equal 10, @server.events.size
    assert_equal 1, @stderr.string.scan("check the LogNorth url and api key").size
    assert_nil drop_report
  end

  def test_event_limit_drops_the_oldest_normal_events_and_keeps_errors
    @server.stop

    LogNorth.error("oldest error", error_with_backtrace("boom"))
    log_events(10_050)
    @server.start
    wait_until(timeout: 10) { drop_report }

    normal = @server.messages.grep(/\Aevent /)
    assert_includes @server.messages, "oldest error"
    assert_includes normal, "event 10049"
    refute_includes normal, "event 0"
    assert_equal normal, normal.sort_by { |m| m.split.last.to_i }
    assert_equal 10_050, normal.size + drop_report.dig("context", "dropped")
    assert_equal 0, drop_report.dig("context", "dropped_errors")
    assert_equal 1, @stderr.string.scan("queue full").size
  end

  def test_byte_limit_drops_the_oldest_normal_events_and_keeps_errors
    @server.stop
    padding = (1..7).to_h { |i| [:"field#{i}", "x" * 8000] } # about 56 KB of JSON

    LogNorth.error("oldest error", error_with_backtrace("boom"))
    200.times { |i| LogNorth.log("big #{i}", padding) } # about 11 MB
    @server.start
    wait_until(timeout: 10) { drop_report }

    big = @server.messages.grep(/\Abig /)
    dropped = drop_report.dig("context", "dropped")
    assert_includes @server.messages, "oldest error"
    assert_includes big, "big 199"
    refute_includes big, "big 0"
    assert_operator dropped, :>, 0
    assert_equal 200, big.size + dropped
  end

  def test_errors_are_dropped_only_when_the_queue_holds_nothing_else
    @server.stop

    10_001.times { |i| LogNorth.error("error #{i}", error_with_backtrace("boom")) }
    @server.start
    wait_until(timeout: 10) { drop_report }

    assert_equal 1, drop_report.dig("context", "dropped_errors")
    refute_includes @server.messages, "error 0"
    assert_includes @server.messages, "error 10000"
  end

  def test_big_events_are_trimmed_before_they_enter_the_queue
    backtrace = (1..20).map { |i| "app/line#{i}.rb:#{i}:in `m#{i}' #{'y' * 2500}" } # about 50 KB

    LogNorth.error("big", error_with_backtrace("boom", backtrace), { blob: "x" * 100_000 })
    wait_until { @server.events.any? }

    context = @server.events.first["context"]
    assert_equal true, context["truncated"]
    assert_equal 8 * 1024, context["blob"].bytesize
    assert_equal 16 * 1024, context["stack_trace"].bytesize
    assert context["stack_trace"].start_with?("app/line1.rb:1")
    assert_equal "boom", context["error"]
  end

  def test_an_event_still_too_big_keeps_only_the_essential_context
    padding = (1..10).to_h { |i| [:"field#{i}", "x" * 8000] } # about 80 KB

    LogNorth.log("x" * 5000, padding.merge(path: "/orders", status: 200))
    LogNorth.flush

    event = @server.events.first
    assert_equal 1000, event["message"].length
    assert_equal({ "path" => "/orders", "status" => 200, "truncated" => true }, event["context"])
  end

  def test_a_batch_holds_at_most_500_events
    set_client(:flush_interval, 60)

    log_events(1200)
    wait_until { @server.events.size == 1200 }

    assert_equal 1200, @server.events.size
    assert(@server.requests.all? { |r| r[:events].size <= 500 })
  end

  def test_a_batch_holds_at_most_1_mb_of_json
    padding = (1..7).to_h { |i| [:"field#{i}", "x" * 8000] }

    40.times { |i| LogNorth.log("big #{i}", padding) } # about 2.2 MB
    wait_until { @server.events.size == 40 }

    assert_operator @server.requests.size, :>=, 3
    assert(@server.requests.all? { |r| r[:bytes] <= 1024 * 1024 })
  end

  def test_events_arrive_in_order_across_retries
    @server.answer(503, times: 2)

    log_events(10, "first")
    sleep 0.05
    log_events(25, "second")
    wait_until { @server.events.size == 35 }

    expected = (0..9).map { |i| "first #{i}" } + (0..24).map { |i| "second #{i}" }
    assert_equal expected, @server.messages
  end

  def test_events_logged_during_a_backoff_are_kept
    @server.answer(503, { "Retry-After" => "1" })

    log_events(10, "before")
    sleep 0.2
    log_events(3, "during")
    LogNorth.error("during error", error_with_backtrace("boom"))
    wait_until { @server.events.size == 14 }

    assert_equal 14, @server.events.size
    assert_equal "before 0", @server.messages.first
    assert_equal "during error", @server.messages.last
  end

  def test_flush_sends_buffered_events_ignoring_the_backoff
    set_client(:flush_interval, 60)
    set_client(:retry_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60)
    log_events(3)

    LogNorth.flush

    assert_equal ["event 0", "event 1", "event 2"], @server.messages
  end

  def test_shutdown_reports_events_it_could_not_send
    @server.stop
    log_events(3)

    LogNorth::Client.shutdown

    assert_includes @stderr.string, "exiting with 3 unsent event(s)"
    @server.start
  end

  def test_buffered_events_are_sent_at_process_exit
    lib = File.expand_path("../lib", __dir__)
    script = "LogNorth.config('#{@server.url}', 'key'); LogNorth.log('bye')"

    system(RbConfig.ruby, "-I", lib, "-rlognorth", "-e", script, exception: true)

    assert_equal ["bye"], @server.messages
  end
end
