# frozen_string_literal: true
# Implements a small and limited StatsD implementation to reduce importing unnecessary dependencies because
# we don't want to require on the bundle which would slow down a CI Queue run

require 'socket'

module Minitest
  module Queue
    class Statsd
      attr_reader :addr, :namespace, :default_tags

      def initialize(addr: nil, default_tags: [], namespace: nil)
        @default_tags = default_tags
        @namespace = namespace
        @addr = addr

        if addr
          host, port = addr.split(':', 2)
          @socket = UDPSocket.new
          @socket.connect(host, Integer(port))
        end
      rescue SocketError => e
        # No-op, we shouldn't fail CI because of statsd
      end

      def increment(metric, tags: [], value: 1)
        send_metric(type: 'c', value: value, metric: metric, tags: default_tags + tags)
      end

      def measure(metric, duration = nil, tags: [], &block)
        if block_given?
          return_value, duration = Minitest::Queue::Statsd.measure_duration(&block)
        elsif duration.nil?
          raise ArgumentError, "You need to pass a block or pass a float as second argument."
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
        return unless @socket 
        metric_snippet = namespace.nil? ? metric : "#{namespace}.#{metric}"
        tags_snippet = tags.empty? ? '' : "|##{tags.join(',')}"
        payload = "#{metric_snippet}:#{value}|#{type}#{tags_snippet}"
        @socket.send(payload, 0)
      rescue SystemCallError
        # No-op, we shouldn't fail or spam output due to statsd issues
      end
    end
  end
end
