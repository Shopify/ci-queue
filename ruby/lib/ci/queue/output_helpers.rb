# frozen_string_literal: true
require 'ansi'

module CI
  module Queue
    module OutputHelpers
      include ANSI::Code

      private

      def step(*args)
        ci_provider.step(*args)
      end

      def reopen_previous_step
        ci_provider.reopen_previous_step
      end

      def close_previous_step
        ci_provider.close_previous_step
      end

      def ci_provider
        @ci_provider ||= if ENV['BUILDKITE']
          BuildkiteOutput
        else
          DefaultOutput
        end
      end

      module DefaultOutput
        extend self

        def step(title, collapsed: true)
          puts title
        end

        def reopen_previous_step
          # noop
        end

        def close_previous_step
          # noop
        end
      end

      module BuildkiteOutput
        extend self

        def step(title, collapsed: true)
          prefix = collapsed ? '---' : '+++'
          puts "#{prefix} #{title}"
        end

        def reopen_previous_step
          puts '^^^ +++'
        end

        def close_previous_step
          puts '^^^ ---'
        end
      end
    end
  end
end
