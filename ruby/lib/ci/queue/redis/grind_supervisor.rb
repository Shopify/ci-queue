# frozen_string_literal: true
module CI
  module Queue
    module Redis
      class GrindSupervisor < Supervisor

        def build
          @build ||= GrindRecord.new(self, redis, config)
        end
      end
    end
  end
end
