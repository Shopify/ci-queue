module CI
  module Queue
    module Redis
      class Supervisor < Base
        def master?
          false
        end

        def wait_for_workers
          return false unless wait_for_master

          sleep 0.1 until exhausted?
          true
        end
      end
    end
  end
end