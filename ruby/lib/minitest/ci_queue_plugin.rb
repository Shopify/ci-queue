# frozen_string_literal: true

module Minitest
  class << self
    def plugin_ci_queue_init(_options)
      if Minitest.queue_reporters
        reporter.reporters.delete_if { |reporter| reporter.is_a?(SummaryReporter) }
        reporter.reporters.delete_if { |reporter| reporter.is_a?(ProgressReporter) }
        Minitest.queue_reporters.each do |queue_reporter|
          reporter << queue_reporter
        end
      end

      if Minitest.backtrace_filter.respond_to?(:add_silencer)
        # Backtrace filter installed by Rails
        Minitest.backtrace_filter.add_filter { |line| line =~ %r{exe/minitest-queue|lib/ci/queue} }
      elsif Minitest.backtrace_filter.respond_to?(:add_filter)
        # Backtrace filter installed by minitest-reporters
        Minitest.backtrace_filter.add_filter(%r{exe/minitest-queue|lib/ci/queue})
      else
        # Replace the backtrace filter
        # TODO: do we want to replace the standard filter that minitest ships with?
      end
    end
  end
end
