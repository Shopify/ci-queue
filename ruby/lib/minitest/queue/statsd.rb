# Implements a small and limited StatsD implementation to reduce importing unnecessary dependencies because
# we don't want to require on the bundle which would slow down a CI Queue run

require 'socket'

module Minitest
  module Queue
    class Statsd
      DEFAULT_ADDR = ENV.fetch('STATSD_ADDR', '127.0.0.1:8125')

      attr_reader :addr, :namespace, :default_tags

      def initialize(addr: DEFAULT_ADDR, default_tags: [], namespace: nil)
        @default_tags = default_tags
        @namespace = namespace
        @addr = addr

        host, port = addr.split(':', 2)
        @socket = UDPSocket.new
        @socket.connect(host, Integer(port))
      rescue SocketError => e
        # This can only reasonably be a DNS failure, use localhost to prevent the build failing
        $stderr.puts "[Minitest::Queue::Statsd] Error connecting to #{addr}: #{e}"
        @socket = UDPSocket.new
        @socket.connect('127.0.0.1', 8125)
      end

      def increment(metric, tags: [], value: 1)
        send_metric(type: 'c', value: value, metric: metric, tags: default_tags + tags)
      end

      def measure(metric, duration = nil, tags: [], &block)
        if block_given?
          return_value, duration = Minitest::Queue::Statsd.measure_duration(&block)
        elsif duration.nil?
          raise ArgumentError, "You need to pass a block or to pass a float as second argument."
        end
        send_metric(type: 'ms', value: duration, metric: metric, tags: default_tags + tags)
        return_value
      end

      def self.measure_duration
        before = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
        return_value = yield
        after = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)

        [return_value, after - before]
      end

      private

      def send_metric(type:, metric:, value:, tags:)
        metric_snippet = namespace.nil? ? metric : "#{namespace}.#{metric}"
        tags_snippet = tags.empty? ? '' : "|##{tags.join(',')}"
        payload = "#{metric_snippet}:#{value}|#{type}#{tags_snippet}"
        @socket.send(payload, 0)
      rescue SystemCallError
        $stderr.puts "[Minitest::Queue::Statsd] Failed to send StatsD packet to #{addr}!"
      end
    end
  end
end
