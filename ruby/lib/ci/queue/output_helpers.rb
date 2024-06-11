# frozen_string_literal: true
module CI
  module Queue
    module OutputHelpers
      private

      def step(*args, **kwargs)
        ci_provider.step(*args, **kwargs)
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

      def red(text)
        colorize(text, 31)
      end

      def green(text)
        colorize(text, 32)
      end

      def yellow(text)
        colorize(text, 33)
      end

      def colorize(text, color_code)
        "\e[#{color_code}m#{text}\e[0m"
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
          puts '\n^^^ +++'
        end

        def close_previous_step
          puts '\n^^^ ---'
        end
      end
    end
  end
end
