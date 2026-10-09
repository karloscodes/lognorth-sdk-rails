# frozen_string_literal: true

require "net/http"
require "json"
require "time"
require "uri"

module LogNorth
  MAX_BUFFER = 10_000                 # events in the queue
  MAX_BUFFER_BYTES = 10 * 1024 * 1024 # JSON bytes in the queue
  MAX_BATCH = 500                     # events in one request
  MAX_BATCH_BYTES = 1024 * 1024       # JSON bytes in one request
  MAX_EVENT_BYTES = 64 * 1024
  MAX_MESSAGE_CHARS = 1000
  MAX_STACK_TRACE_BYTES = 16 * 1024
  MAX_STRING_BYTES = 8 * 1024
  # The context keys an event keeps when it is still too big after trimming.
  ESSENTIAL_KEYS = %w[error error_class error_file error_line method path status environment release user].freeze
  # Where deploy tools put the version that runs. The first one set wins.
  RELEASE_ENV = %w[
    LOGNORTH_RELEASE GIT_SHA GIT_COMMIT SOURCE_COMMIT KAMAL_VERSION
    RENDER_GIT_COMMIT HEROKU_SLUG_COMMIT SOURCE_VERSION RAILWAY_GIT_COMMIT_SHA VERCEL_GIT_COMMIT_SHA
  ].freeze

  module Client
    # An event in the queue, with its JSON size and whether it is an error.
    Entry = Struct.new(:event, :bytes, :error)

    @mutex = Mutex.new
    @wakeup = ConditionVariable.new
    # Held for the whole of a send, so only one request is in flight.
    # Lock order: @send_lock first, then @mutex.
    @send_lock = Mutex.new
    @sender = nil
    @buffer = []      # Entry objects, oldest first
    @bytes = 0        # sum of the bytes of the entries in @buffer
    @batch_sizes = [] # sizes of the batches put back at the front
    @dropped = 0
    @dropped_errors = 0
    @first_at = nil   # when the first event entered an empty queue
    @urgent = false   # send without waiting for the 5-second timer
    @retry_at = nil   # never send before this time
    @failing = nil    # nil, :retrying or :config: the state last written to stderr
    @endpoint = nil
    @api_key = nil
    @environment = nil
    @release = nil
    @announced = nil # the release this process last said it started

    # Wait times in seconds. Tests set them lower.
    @flush_interval = 5
    @first_backoff = 1
    @max_backoff = 60
    @first_config_backoff = 60
    @max_config_backoff = 300
    @shutdown_timeout = 5
    @backoff = @first_backoff
    @config_backoff = @first_config_backoff

    class << self
      attr_accessor :debug

      def config(url, key, environment: nil, release: nil)
        @mutex.synchronize do
          @endpoint = url.chomp("/")
          @api_key = key
          @environment = environment
          @release = release || release_from_env
        end
        log_debug("configured with url=#{url} env=#{environment.inspect}")
        announce_release
      end

      def configured?
        @mutex.synchronize { !@endpoint.nil? && !@api_key.nil? }
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

      # The user of the request on this thread: the one set with LogNorth.user=,
      # or else Current.user, which the Rails authentication generator defines.
      def current_user
        Thread.current[:lognorth_user] || user_from_current_attributes
      end

      def current_user=(id)
        Thread.current[:lognorth_user] = id&.to_s
      end

      # Forgets the trace ID and the user when a request ends.
      def end_request
        Thread.current[:lognorth_trace_id] = nil
        Thread.current[:lognorth_user] = nil
      end

      def send_event(message, context = {}, trace_id: nil, duration_ms: nil, timestamp: nil)
        return unless configured?

        trace_id ||= current_trace_id
        event = {
          message: message,
          timestamp: (timestamp || Time.now).utc.iso8601(3),
          context: stamp_user(stamp_environment(context))
        }
        event[:trace_id] = trace_id if trace_id
        event[:duration_ms] = duration_ms if duration_ms

        enqueue(event)
      end

      def send_error_event(message, exception, context = {}, trace_id: nil, duration_ms: nil, timestamp: nil)
        return unless configured?

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
          context: stamp_user(stamp_environment(context.merge(
            error: exception.message,
            error_class: exception.class.name,
            error_file: error_file,
            error_line: error_line,
            error_caller: error_caller,
            stack_trace: exception.backtrace&.first(20)&.join("\n")
          )))
        }
        event[:trace_id] = trace_id if trace_id
        event[:duration_ms] = duration_ms if duration_ms

        enqueue(event, urgent: true)
      end

      # Sends what is in the queue now, ignoring any backoff. Each batch gets
      # one attempt, all within the shutdown timeout. Events that could not
      # be sent stay in the queue. Returns how many events are left.
      def flush
        deadline = monotonic + @shutdown_timeout
        @send_lock.synchronize do
          loop do
            left = deadline - monotonic
            break if left <= 0

            batch = @mutex.synchronize { take_batch }
            break unless batch
            break unless deliver(batch, timeout: left)
          end
        end
        @mutex.synchronize { @buffer.size }
      rescue StandardError => e
        log_debug("flush failed: #{e.class}: #{e.message}")
        @mutex.synchronize { @buffer.size }
      end

      # Called at process exit. Events still queued after the flush are lost.
      def shutdown
        left = flush
        warn("[LogNorth] exiting with #{left} unsent event(s); they are lost") if left.positive?
      end

      private

      # Adds context.environment when the client was configured with one.
      # The server displays this on every event/issue/trace so users can tell
      # which deployment a log came from.
      def stamp_environment(context)
        env = @mutex.synchronize { @environment }
        return context unless env

        context.merge(environment: env)
      end

      # Logs "Release <version> started" once per release, when the client is
      # configured. LogNorth takes the first start of a release as its deploy
      # time and marks it on its charts.
      def announce_release
        release = @mutex.synchronize do
          next if @release.nil? || @release == @announced

          @announced = @release
        end
        send_event("Release #{release} started", { release: release }) if release
      end

      def stamp_user(context)
        user = current_user
        return context if user.nil? || fetch(context, :user)

        context.merge(user: user)
      end

      def user_from_current_attributes
        return unless defined?(::Current) && ::Current.respond_to?(:user)

        ::Current.user&.id&.to_s
      rescue StandardError
        nil
      end

      # Errors carry the release: that is where it answers which deploy broke
      # something. Other events stay small.
      def stamp_release(event)
        release = @mutex.synchronize { @release }
        return event if release.nil? || !error_event?(event[:context]) || fetch(event[:context], :release)

        event.merge(context: event[:context].merge(release: release))
      end

      def release_from_env
        RELEASE_ENV.lazy.map { |k| ENV[k].to_s.strip }.find { |v| !v.empty? }
      end

      def enqueue(event, urgent: false)
        entry = new_entry(trim(stamp_release(event)))
        @mutex.synchronize do
          push(entry)
          @urgent = true if urgent
          start_sender
          @wakeup.signal
        end
      rescue StandardError => e
        log_debug("could not queue event: #{e.class}: #{e.message}")
      end

      def new_entry(event)
        Entry.new(event, JSON.generate(event).bytesize, error_event?(event[:context]))
      end

      def error_event?(context)
        return false unless context.is_a?(Hash)

        status = fetch(context, :status)
        !fetch(context, :error).nil? || !fetch(context, :error_class).nil? ||
          (status.is_a?(Integer) && status >= 500)
      end

      def fetch(hash, key)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      # Cuts an event down to at most MAX_EVENT_BYTES of JSON, so one huge
      # event cannot fill the queue.
      def trim(event)
        trimmed = false
        if event[:message].is_a?(String) && event[:message].length > MAX_MESSAGE_CHARS
          event[:message] = event[:message][0, MAX_MESSAGE_CHARS]
          trimmed = true
        end

        context = event[:context]
        if context.is_a?(Hash)
          context = context.to_h do |key, value|
            limit = key.to_s == "stack_trace" ? MAX_STACK_TRACE_BYTES : MAX_STRING_BYTES
            if value.is_a?(String) && value.bytesize > limit
              trimmed = true
              [key, value.byteslice(0, limit).scrub("")]
            else
              [key, value]
            end
          end
          event[:context] = context
        end

        if JSON.generate(event).bytesize > MAX_EVENT_BYTES && context.is_a?(Hash)
          event[:context] = context.select { |key, _| ESSENTIAL_KEYS.include?(key.to_s) }
          trimmed = true
        end

        event[:context] = event[:context].merge(truncated: true) if trimmed
        event
      end

      # Call with @mutex held. Adds an entry at the back.
      def push(entry)
        @first_at ||= monotonic
        @buffer << entry
        @bytes += entry.bytes
        drop_oldest while over_limit?
      end

      # Call with @mutex held.
      def over_limit?
        @buffer.size > MAX_BUFFER || @bytes > MAX_BUFFER_BYTES
      end

      # Call with @mutex held. Drops the oldest event that is not an error,
      # or the oldest error when the queue holds nothing else.
      def drop_oldest
        index = @buffer.index { |entry| !entry.error } || 0
        entry = @buffer.delete_at(index)
        @bytes -= entry.bytes
        count_drop(entry, "queue full, dropping the oldest events")
      end

      # Call with @mutex held.
      def count_drop(entry, reason)
        warn("[LogNorth] #{reason}") if @dropped.zero?
        @dropped += 1
        @dropped_errors += 1 if entry.error
      end

      # Call with @mutex held. A forked child has no sender thread; this
      # starts a new one there.
      def start_sender
        return if @sender&.alive?

        @sender = Thread.new { run_sender }
      end

      def run_sender
        loop do
          @mutex.synchronize { @wakeup.wait(@mutex, seconds_until_due) until seconds_until_due&.zero? }
          @send_lock.synchronize do
            batch = @mutex.synchronize { take_batch if seconds_until_due&.zero? }
            deliver(batch) if batch
          end
        end
      rescue StandardError => e
        log_debug("sender stopped: #{e.class}: #{e.message}")
      end

      # Call with @mutex held. 0 when the queue should be sent now, nil to
      # wait for a new event, else the seconds left to wait.
      def seconds_until_due
        return nil if @buffer.empty?

        now = monotonic
        return @retry_at - now if @retry_at && now < @retry_at
        return 0 if @urgent || @buffer.size >= 10 || @bytes > MAX_BUFFER_BYTES / 2

        [@first_at + @flush_interval - now, 0].max
      end

      # Call with @mutex held. Takes entries from the front, up to MAX_BATCH
      # events and MAX_BATCH_BYTES of JSON, and always at least one.
      def take_batch
        return nil if @buffer.empty?

        max = [@batch_sizes.shift || MAX_BATCH, MAX_BATCH].min
        count = 0
        bytes = 12 # {"events":[]}
        while count < @buffer.size && count < max
          bytes += @buffer[count].bytes + 1
          break if bytes > MAX_BATCH_BYTES && count.positive?

          count += 1
        end
        batch = @buffer.shift(count)
        @bytes -= batch.sum(&:bytes)
        if @buffer.empty?
          @first_at = nil
          @urgent = false
          @batch_sizes.clear
        end
        batch
      end

      # Call with @mutex held. Puts events back at the front, in order. The
      # next send takes the same events again.
      def put_back(batch, sizes = [batch.size])
        @batch_sizes.unshift(*sizes)
        @buffer = batch + @buffer
        @bytes += batch.sum(&:bytes)
        @first_at ||= monotonic
        @urgent = true
        drop_oldest while over_limit?
      end

      # Sends one batch and acts on the answer. Returns true when the next
      # batch can go out at once.
      def deliver(batch, timeout: nil)
        code, retry_after = post(batch, timeout)
        log_debug("response: #{code}")
        @mutex.synchronize { handle_answer(batch, code, retry_after) }
      rescue StandardError => e
        log_debug("send failed: #{e.class}: #{e.message}")
        @mutex.synchronize { retry_later(batch, "network error (#{e.class})", wait_with_jitter) }
      end

      # Call with @mutex held.
      def handle_answer(batch, code, retry_after)
        case code
        when 200..299
          succeeded
          true
        when 429, 503
          # The server said when; the backoff stays for failures that do not say.
          retry_later(batch, "server answered #{code}", retry_after || next_backoff)
        when 408, 500..599
          retry_later(batch, "server answered #{code}", wait_with_jitter)
        when 401, 403, 404
          misconfigured(batch, code)
        when 400..499
          reject(batch)
          true
        else # a redirect or an unknown answer: most likely a wrong url
          misconfigured(batch, code)
        end
      end

      # Call with @mutex held.
      def misconfigured(batch, code)
        retry_later(batch, "server answered #{code}, check the LogNorth url and api key",
                    next_config_backoff, state: :config)
      end

      # Call with @mutex held.
      def succeeded
        warn("[LogNorth] delivery recovered") if @failing
        @failing = nil
        @retry_at = nil
        @backoff = @first_backoff
        @config_backoff = @first_config_backoff
        return if @dropped.zero?

        report = {
          message: "LogNorth client dropped #{@dropped} events",
          timestamp: Time.now.utc.iso8601(3),
          context: stamped({ dropped: @dropped, dropped_errors: @dropped_errors })
        }
        @dropped = 0
        @dropped_errors = 0
        push(new_entry(report))
        @urgent = true
      end

      # Call with @mutex held. The server can never accept this batch as it
      # is: split it, or drop it when it is a single event.
      def reject(batch)
        if batch.size > 1
          half = (batch.size + 1) / 2
          put_back(batch, [half, batch.size - half])
        else
          count_drop(batch.first, "server rejected an event, dropping it")
        end
      end

      # Call with @mutex held. Returns false: the next send must wait.
      def retry_later(batch, reason, wait, state: :retrying)
        # The next send takes a full batch again; a refused batch splits again.
        @batch_sizes.clear
        put_back(batch, [])
        @retry_at = monotonic + wait
        warn("[LogNorth] #{reason}; keeping #{@buffer.size} event(s) and retrying") if @failing != state
        @failing = state
        false
      end

      # Call with @mutex held.
      def stamped(context)
        @environment ? context.merge(environment: @environment) : context
      end

      def next_backoff
        wait = @backoff
        @backoff = [@backoff * 2, @max_backoff].min
        wait
      end

      def wait_with_jitter
        next_backoff * rand(0.8..1.2)
      end

      def next_config_backoff
        wait = @config_backoff
        @config_backoff = [@config_backoff * 2, @max_config_backoff].min
        wait
      end

      # Returns the status code and the Retry-After seconds (nil when the
      # header is missing or not an integer).
      def post(batch, timeout)
        endpoint, api_key = @mutex.synchronize { [@endpoint, @api_key] }
        uri = URI("#{endpoint}/api/v1/events/batch")
        log_debug("sending #{batch.size} event(s) to #{uri}")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = [5, timeout].compact.min
        http.read_timeout = [10, timeout].compact.min
        http.write_timeout = [10, timeout].compact.min

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{api_key}"
        request.body = JSON.generate(events: batch.map(&:event))

        response = http.request(request)
        header = response["Retry-After"]&.strip
        retry_after = header.to_i.clamp(1, 300) if header&.match?(/\A\d+\z/)
        [response.code.to_i, retry_after]
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def warn(msg)
        $stderr.puts msg
      end

      def log_debug(msg)
        return unless @debug

        $stdout.puts "[LogNorth] #{msg}"
      end
    end
  end
end
