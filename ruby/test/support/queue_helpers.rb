# frozen_string_literal: true
module QueueHelper
  private

  def poll(queue, success = true)
    test_order = []
    queue.poll do |test|
      yield test if block_given?
      test_order << test
      failed = !(success.respond_to?(:call) ? success.call(test) : success)
      if failed
        if queue.requeue(test)
          # Requeued — don't report to circuit breaker
        else
          queue.report_failure!
          queue.acknowledge(test.id)
        end
      else
        queue.report_success!
        queue.acknowledge(test.id)
      end
    end
    test_order
  end
end
