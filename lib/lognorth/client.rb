# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module LogNorth
  MAX_BUFFER = 1000

  module Client
    @mutex = Mutex.new
    @buffer = []
    @timer = nil
    @backoff_until = nil
    @endpoint = nil
    @api_key = nil

    class << self
      attr_accessor :debug

      def config(url, key)
        @mutex.synchronize do
          @endpoint = url.chomp("/")
          @api_key = key
        end
        log_debug("configured with url=#{url}")
      end

      def log(message, context = {})
        send_event(message, context)
      end

      def error(message, exception, context = {})
        send_error_event(message, exception, context)
      end

      def current_trace_id
        Thread.current[:lognorth_trace_id]
      end

      def current_trace_id=(id)
        Thread.current[:lognorth_trace_id] = id
      end

      def send_event(message, context = {}, trace_id: nil, duration_ms: nil, timestamp: nil)
        trace_id ||= current_trace_id
        event = {
          message: message,
          timestamp: (timestamp || Time.now).utc.iso8601(3),
          context: context
        }
        event[:trace_id] = trace_id if trace_id
        event[:duration_ms] = duration_ms if duration_ms

        should_flush = false
        @mutex.synchronize do
          @buffer << event
          @buffer = @buffer.last(MAX_BUFFER) if @buffer.size > MAX_BUFFER
          schedule_flush
          should_flush = @buffer.size >= 10
        end

        flush if should_flush
      end

      def send_error_event(message, exception, context = {}, trace_id: nil, duration_ms: nil, timestamp: nil)
        trace_id ||= current_trace_id
        error_file = ""
        error_line = 0
        error_caller = ""
        if exception.backtrace&.first
          if (match = exception.backtrace.first.match(/(.+):(\d+):in [`'](.+)'/))
            error_file = File.basename(match[1])
            error_line = match[2].to_i
            error_caller = match[3]
          end
        end

        event = {
          message: message,
          timestamp: (timestamp || Time.now).utc.iso8601(3),
          context: context.merge(
            error: exception.message,
            error_class: exception.class.name,
            error_file: error_file,
            error_line: error_line,
            error_caller: error_caller,
            stack_trace: exception.backtrace&.first(20)&.join("\n")
          )
        }
        event[:trace_id] = trace_id if trace_id
        event[:duration_ms] = duration_ms if duration_ms

        Thread.new { send_events([event], is_error: true) }
      end

      def flush
        events = nil
        @mutex.synchronize do
          cancel_timer
          return if @buffer.empty?

          events = @buffer
          @buffer = []
        end

        send_events(events, is_error: false)
      end

      private

      def schedule_flush
        return if @timer

        @timer = Thread.new do
          sleep 5
          @mutex.synchronize { @timer = nil }
          flush
        end
      end

      def cancel_timer
        if @timer
          @timer = nil
        end
      end

      def send_events(events, is_error:)
        return if events.empty?

        endpoint, api_key = @mutex.synchronize { [@endpoint, @api_key] }
        unless endpoint
          log_debug("skipping send: no endpoint configured")
          return
        end

        if @backoff_until && Time.now < @backoff_until
          log_debug("skipping send: backing off until #{@backoff_until}")
          requeue(events)
          return
        end

        uri = URI("#{endpoint}/api/v1/events/batch")
        log_debug("sending #{events.size} event(s) to #{uri}")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{api_key}"
        request.body = JSON.generate(events: events)

        response = http.request(request)
        log_debug("response: #{response.code} #{response.body}")

        if response.code == "429"
          @mutex.synchronize { @backoff_until = Time.now + 5 }
          requeue(events)
        end
      rescue StandardError => e
        log_debug("send failed: #{e.class}: #{e.message}")
        requeue(events) if is_error
      end

      def requeue(events)
        @mutex.synchronize do
          @buffer = events + @buffer
          @buffer = @buffer.first(MAX_BUFFER) if @buffer.size > MAX_BUFFER
        end
      end

      def log_debug(msg)
        return unless @debug

        $stdout.puts "[LogNorth] #{msg}"
      end
    end
  end
end
