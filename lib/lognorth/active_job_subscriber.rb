# frozen_string_literal: true

require "securerandom"

module LogNorth
  module ActiveJobSubscriber
    # Carries the trace ID from enqueue time (e.g. during a request)
    # through to job execution, so the job shares the request's trace.
    module TraceCarrier
      def serialize
        super.merge("lognorth_trace_id" => LogNorth::Client.current_trace_id)
      end

      def deserialize(job_data)
        super
        @lognorth_trace_id = job_data["lognorth_trace_id"]
      end
    end

    def self.attach
      ActiveJob::Base.prepend(TraceCarrier)

      ActiveJob::Base.around_perform do |job, block|
        trace_id = job.instance_variable_get(:@lognorth_trace_id) || SecureRandom.hex(8)
        LogNorth::Client.current_trace_id = trace_id
        started_at = Time.now
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        block.call

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
        LogNorth::Client.send_event(
          "#{job.class.name} completed",
          { job: job.class.name, queue: job.queue_name, job_id: job.job_id },
          trace_id: trace_id,
          duration_ms: duration_ms,
          timestamp: started_at
        )
        LogNorth.flush
        LogNorth::Client.current_trace_id = nil
      rescue StandardError => e
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
        LogNorth::Client.send_error_event(
          "#{job.class.name} failed", e,
          { job: job.class.name, queue: job.queue_name, job_id: job.job_id },
          trace_id: trace_id,
          duration_ms: duration_ms,
          timestamp: started_at
        )
        LogNorth.flush
        LogNorth::Client.current_trace_id = nil
        raise
      end
    end
  end
end
