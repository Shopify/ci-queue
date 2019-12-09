# frozen_string_literal: true
module CI
  module Queue
    module Redis
      class Grind < Worker

        def build
          @build ||= GrindRecord.new(self, redis, config)
        end

        def supervisor
          GrindSupervisor.new(redis_url, config)
        end
      end
    end
  end
end
