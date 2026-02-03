# frozen_string_literal: true
require 'ci/queue/output_helpers'
require 'minitest/reporters'

module Minitest
  module Queue
    class LocalRequeueReporter < Minitest::Reporters::DefaultReporter
      include ::CI::Queue::OutputHelpers
      attr_accessor :requeues

      def initialize(*)
        self.requeues = 0
        super
      end

      def report
        self.requeues = results.count(&:requeued?)
        super
        print_report
      end

      private

      def print_report
        reopen_previous_step if failures > 0 || errors > 0
        success = failures.zero? && errors.zero?
        failures_count = "#{failures} failures, #{errors} errors,"
        step [
          'Ran %d tests, %d assertions,' % [count, assertions],
          success ? green(failures_count) : red(failures_count),
          yellow("#{skips} skips, #{requeues} requeues"),
          'in %.2fs' % total_time,
        ].join(' ')

        print_worker_stats
      end

      def print_worker_stats
        queue = Minitest.queue
        return unless queue.respond_to?(:lazy_load?)

        role = queue.master? ? "leader" : "consumer"
        files_loaded = queue.files_loaded_count
        peak_memory = peak_memory_mb
        lazy_status = queue.lazy_load? ? "lazy loading enabled" : "lazy loading disabled"

        puts
        puts "Worker stats: #{role}, #{files_loaded} files loaded, #{peak_memory} MB peak memory, #{lazy_status}"
      end

      def peak_memory_mb
        if File.exist?("/proc/self/status")
          status = File.read("/proc/self/status")
          if (match = status.match(/VmHWM:\s*(\d+)\s*kB/))
            return match[1].to_i / 1024
          end
        end

        rusage = Process.getrusage
        max_rss = rusage.maxrss
        # maxrss is bytes on macOS, KB on Linux
        RUBY_PLATFORM.include?("darwin") ? max_rss / (1024 * 1024) : max_rss / 1024
      rescue StandardError
        0
      end

      def message_for(test)
        e = test.failure

        if test.requeued?
          "Requeued:\n#{test.klass}##{test.name} [#{location(e)}]:\n#{e.message}"
        else
          super
        end
      end

      def result_line
        "#{super}, #{requeues} requeues"
      end
    end
  end
end
