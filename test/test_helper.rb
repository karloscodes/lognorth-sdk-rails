# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "stringio"
require_relative "../lib/lognorth"

# A real HTTP server on 127.0.0.1 that records every batch it receives.
# The handler decides the answer from the events of the request.
class TestServer
  attr_reader :port, :requests
  attr_accessor :handler

  def initialize
    @requests = []
    @lock = Mutex.new
    @handler = ->(_events) { [201, {}] }
    start
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  # Answers the next `times` requests with this status, then 201 again.
  def answer(status, headers = {}, times: 1)
    left = times
    @handler = lambda do |_events|
      left -= 1
      left >= 0 ? [status, headers] : [201, {}]
    end
  end

  def start
    @server = TCPServer.new("127.0.0.1", @port || 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop { serve(@server.accept) }
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def stop
    @server.close
    @thread.join
  end

  # Requests the server answered with a 2xx.
  def accepted
    @lock.synchronize { @requests.select { |r| r[:status].between?(200, 299) } }
  end

  # Events the server accepted, in the order it accepted them.
  def events
    accepted.flat_map { |r| r[:events] }
  end

  def messages
    events.map { |e| e["message"] }
  end

  private

  def serve(socket)
    headers = {}
    socket.gets # request line
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(headers["content-length"].to_i)
    events = JSON.parse(body)["events"]
    status, extra = @handler.call(events)
    @lock.synchronize do
      @requests << { status: status, events: events, bytes: body.bytesize, headers: headers, at: Time.now }
    end

    reply = +"HTTP/1.1 #{status} X\r\nContent-Length: 2\r\nConnection: close\r\n"
    extra.each { |k, v| reply << "#{k}: #{v}\r\n" }
    socket.write(reply << "\r\n{}")
  rescue StandardError
    nil
  ensure
    socket.close
  end
end

class Minitest::Test
  # Short wait times so retries take milliseconds.
  FAST = {
    flush_interval: 0.3,
    first_backoff: 0.05,
    max_backoff: 0.2,
    first_config_backoff: 0.1,
    max_config_backoff: 0.4,
    shutdown_timeout: 2
  }.freeze

  # The client is global state. Wait for any send in flight, then reset it
  # before every test.
  def before_setup
    super
    reset_client
    @stderr = StringIO.new
    $stderr = @stderr
    @server = TestServer.new
    LogNorth.config(@server.url, "test-key")
  end

  def after_teardown
    reset_client
    $stderr = STDERR
    @server.stop
    super
  end

  def reset_client
    client = LogNorth::Client
    client.instance_variable_get(:@send_lock).synchronize do
      client.instance_variable_get(:@mutex).synchronize do
        {
          buffer: [], bytes: 0, batch_sizes: [], dropped: 0, dropped_errors: 0, first_at: nil, urgent: false,
          retry_at: nil, failing: nil, environment: nil,
          backoff: FAST[:first_backoff], config_backoff: FAST[:first_config_backoff]
        }.merge(FAST).each { |name, value| client.instance_variable_set(:"@#{name}", value) }
      end
    end
  end

  def set_client(name, value)
    LogNorth::Client.instance_variable_set(:"@#{name}", value)
  end

  # The events waiting in the client queue.
  def buffer
    LogNorth::Client.instance_variable_get(:@buffer).map(&:event)
  end

  def wait_until(timeout: 3)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
  end

  def error_with_backtrace(message, backtrace = ["app/models/order.rb:10:in `charge'"])
    error = RuntimeError.new(message)
    error.set_backtrace(backtrace)
    error
  end
end
