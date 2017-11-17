module CI
  module Queue
    class Configuration
      attr_accessor :timeout, :build_id, :worker_id, :max_requeues, :requeue_tolerance

      def initialize(timeout: 10, build_id: nil, worker_id: nil, max_requeues: 0, requeue_tolerance: 0)
        @timeout = timeout
        @build_id = build_id
        @worker_id = worker_id
        @max_requeues = max_requeues
        @requeue_tolerance = requeue_tolerance
      end

      def global_max_requeues(tests_count)
        (tests_count * Float(requeue_tolerance)).ceil
      end
    end
  end
end
