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
        queue.report_failure!
        queue.requeue(test) || queue.acknowledge(test)
      else
        queue.report_success!
        queue.acknowledge(test)
      end
    end
    test_order
  end
end
