require 'redis'
require 'ci/queue/redis/base'
require 'ci/queue/redis/worker'
require 'ci/queue/redis/retry'
require 'ci/queue/redis/supervisor'

module CI
  module Queue
    module Redis
      Error = Class.new(StandardError)
      LostMaster = Class.new(Error)

      class << self

        def new(*args)
          Worker.new(*args)
        end

        def from_uri(uri)
          options = parse_query(uri.query)
          redis_uri = uri.dup
          redis_uri.query = nil
          options[:redis] = ::Redis.new(url: redis_uri.to_s)
          new(**options)
        end

        private

        def parse_query(query)
          CGI.parse(query.to_s).map { |k, v| [k.to_sym, v.size > 1 ? v : v.first] }.to_h
        end
      end
    end
  end
end
