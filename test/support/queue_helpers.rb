module QueueHelper
  private

  def poll(queue, success = true)
    test_order = []
    queue.poll do |test|
      yield test if block_given?
      test_order << test
      queue.acknowledge(test, success.respond_to?(:call) ? success.call(test) : success)
    end
    test_order
  end
end
