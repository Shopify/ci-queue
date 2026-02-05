# frozen_string_literal: true
require 'test_helper'

module CI::Queue
  # This test reproduces the REAL ToggleHelper FLAGS issue
  # The difference: instance variables are NOT reset by load() because they're not in the file
  class ForkToggleHelperRealisticTest < Minitest::Test
    def test_toggle_helper_with_inherited_instance_variables
      # Skip if we can't fork (Windows)
      skip "Fork not available" unless Process.respond_to?(:fork)

      # Create a test file WITHOUT the instance variable initialization
      # This matches Shopify's actual test files
      test_file = Tempfile.new(['realistic_toggle_test_', '.rb'])
      test_file.write(<<~RUBY)
        class RealisticToggleTest < Minitest::Test
          # NOTE: Unlike the previous test, we do NOT initialize these here
          # They will be set at runtime by process_flags

          class << self
            def flags_to_test
              @flags_to_test ||= [{ name: 'test_flag', state: :both }]
            end

            # Override runnable_methods like ToggleHelper does
            def runnable_methods
              process_flags
              super
            end

            def process_flags
              current_pid = Process.pid

              # Check if instance variable exists, not just its value
              last_processed_pid = if instance_variable_defined?(:@toggle_helper_processed_pid)
                instance_variable_get(:@toggle_helper_processed_pid)
              else
                nil
              end

              has_processed_flag = instance_variable_defined?(:@toggle_helper_processed)

              puts "[RealisticTest] process_flags called: PID=\#{current_pid}"
              puts "[RealisticTest] last_processed_pid=\#{last_processed_pid.inspect} (defined? \#{instance_variable_defined?(:@toggle_helper_processed_pid)})"
              puts "[RealisticTest] @toggle_helper_processed defined? \#{has_processed_flag}"

              if has_processed_flag
                puts "[RealisticTest] @toggle_helper_processed=\#{instance_variable_get(:@toggle_helper_processed)}"
              end

              # Skip if already processed in this process
              if has_processed_flag &&
                 instance_variable_get(:@toggle_helper_processed) &&
                 last_processed_pid == current_pid
                puts "[RealisticTest] SKIPPING - already processed in this PID"
                return
              end

              puts "[RealisticTest] PROCESSING - will generate FLAGS methods"
              instance_variable_set(:@toggle_helper_processed, true)
              instance_variable_set(:@toggle_helper_processed_pid, current_pid)

              # Get base methods, exclude FLAGS
              base_methods = instance_methods(false).grep(/^test_/).reject { |m| m.to_s.include?('_FLAGS:') }
              puts "[RealisticTest] Found \#{base_methods.size} base methods"

              # Generate FLAGS variants
              base_methods.each do |method|
                define_method("\#{method}_FLAGS:test_flag:ON") { send(method) }
                define_method("\#{method}_FLAGS:test_flag:OFF") { send(method) }
              end

              generated = instance_methods(false).grep(/^test_/).select { |m| m.to_s.include?('_FLAGS:') }
              puts "[RealisticTest] Generated \#{generated.size} FLAGS methods"
            end
          end

          def test_example
            assert true
          end
        end
      RUBY
      test_file.close

      begin
        # Parent: load with require() and call runnable_methods
        puts "\n=== PARENT PROCESS (PID #{Process.pid}) ==="
        require(test_file.path)

        parent_klass = Object.const_get('RealisticToggleTest')
        parent_methods = parent_klass.runnable_methods
        parent_flags = parent_methods.select { |m| m.to_s.include?('_FLAGS:') }

        puts "Parent: #{parent_methods.size} total, #{parent_flags.size} FLAGS methods"

        assert parent_flags.size > 0, "Parent should have FLAGS methods"

        # Fork a child
        read_pipe, write_pipe = IO.pipe

        child_pid = fork do
          read_pipe.close

          puts "\n=== CHILD PROCESS (PID #{Process.pid}) ==="
          puts "Child: About to call load()"

          # Key: load() re-executes the file but does NOT reset instance variables
          # that were set at runtime!
          load(test_file.path)

          child_klass = Object.const_get('RealisticToggleTest')

          # Check what instance variables the class has
          ivars = child_klass.instance_variables
          puts "Child: Class instance variables after load(): #{ivars.inspect}"

          child_methods = child_klass.runnable_methods
          child_flags = child_methods.select { |m| m.to_s.include?('_FLAGS:') }

          puts "Child: #{child_methods.size} total, #{child_flags.size} FLAGS methods"

          write_pipe.write("#{child_flags.size}\n")
          write_pipe.close
          exit(0)
        end

        write_pipe.close
        child_flags_count = read_pipe.readline.chomp.to_i
        read_pipe.close
        Process.wait(child_pid)

        puts "\n=== RESULT ==="
        puts "Child FLAGS count: #{child_flags_count}"

        assert child_flags_count > 0,
               "REPRODUCED THE BUG! Child has #{child_flags_count} FLAGS methods (expected > 0). " \
               "The child inherited @toggle_helper_processed_pid from parent via fork, " \
               "and load() did NOT reset it because it's not in the file. " \
               "When the child called runnable_methods with a different PID, " \
               "it should have regenerated, but it didn't!"

      ensure
        Object.send(:remove_const, 'RealisticToggleTest') if defined?(RealisticToggleTest)
        test_file.unlink
      end
    end
  end
end
