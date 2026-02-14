# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module LogNorth
  module Client
    @mutex = Mutex.new
    @buffer = []
    @timer = nil
    @backoff_until = nil
    @endpoint = nil
    @api_key = nil

    class << self
      def config(url, key)
        @mutex.synchronize do
          @endpoint = url.chomp("/")
          @api_key = key
        end
      end

      def log(message, context = {})
        event = {
          message: message,
          timestamp: Time.now.utc.iso8601,
          context: context
        }

        should_flush = false
        @mutex.synchronize do
          @buffer << event
          schedule_flush
          should_flush = @buffer.size >= 10
        end

        flush if should_flush
      end

      def error(message, exception, context = {})
        event = {
          message: message,
          timestamp: Time.now.utc.iso8601,
          error_type: exception.class.name,
          context: context.merge(
            error: exception.message,
            backtrace: exception.backtrace&.first(20)
          )
        }

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
          flush
        end
      end

      def cancel_timer
        @timer&.kill
        @timer = nil
      end

      def send_events(events, is_error:)
        return if events.empty?

        endpoint, api_key = @mutex.synchronize { [@endpoint, @api_key] }
        return unless endpoint

        if @backoff_until && Time.now < @backoff_until
          requeue(events) unless is_error
          return
        end

        uri = URI("#{endpoint}/api/v1/events/batch")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{api_key}"
        request.body = JSON.generate(events: events)

        response = http.request(request)

        if response.code == "429"
          @mutex.synchronize { @backoff_until = Time.now + 5 }
          requeue(events) unless is_error
        end
      rescue StandardError
        requeue(events) if is_error
      end

      def requeue(events)
        @mutex.synchronize { @buffer = events + @buffer }
      end
    end
  end
end
