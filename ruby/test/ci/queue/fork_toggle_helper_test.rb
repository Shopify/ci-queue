# frozen_string_literal: true
require 'test_helper'

module CI::Queue
  # This test reproduces the ToggleHelper FLAGS issue with forked workers
  class ForkToggleHelperTest < Minitest::Test
    def test_toggle_helper_regenerates_after_fork
      # Skip if we can't fork (Windows)
      skip "Fork not available" unless Process.respond_to?(:fork)

      # Create a temporary file with a test class that uses ToggleHelper pattern
      test_file = Tempfile.new(['fork_toggle_test_', '.rb'])
      test_file.write(<<~RUBY)
        class ForkToggleTest < Minitest::Test
          # Simulate ToggleHelper pattern
          @toggle_helper_processed = false
          @toggle_helper_processed_pid = nil
          @flags_to_test = [{ name: 'test_flag', state: :both }]

          class << self
            attr_accessor :toggle_helper_processed, :toggle_helper_processed_pid, :flags_to_test

            # Override runnable_methods like ToggleHelper does
            def runnable_methods
              process_flags
              super
            end

            def process_flags
              current_pid = Process.pid
              last_processed_pid = @toggle_helper_processed_pid

              puts "[ForkToggleTest] process_flags called: current_pid=\#{current_pid}, last_processed_pid=\#{last_processed_pid.inspect}"
              puts "[ForkToggleTest] @toggle_helper_processed=\#{@toggle_helper_processed.inspect}"
              puts "[ForkToggleTest] Will skip? \#{@toggle_helper_processed && last_processed_pid == current_pid}"

              # Skip if already processed in this process
              if @toggle_helper_processed && last_processed_pid == current_pid
                puts "[ForkToggleTest] SKIPPING - already processed in this PID"
                return
              end

              puts "[ForkToggleTest] PROCESSING - generating FLAGS methods"
              @toggle_helper_processed = true
              @toggle_helper_processed_pid = current_pid

              # Get base test methods - EXCLUDE already-generated FLAGS methods (idempotent fix)
              base_methods = instance_methods(false).grep(/^test_/).reject { |m| m.to_s.include?('_FLAGS:') }
              puts "[ForkToggleTest] Found \#{base_methods.size} base methods: \#{base_methods.join(', ')}"

              # Generate ON and OFF variants like ToggleHelper does
              base_methods.each do |method|
                define_method("\#{method}_FLAGS:test_flag:ON") do
                  send(method)
                end

                define_method("\#{method}_FLAGS:test_flag:OFF") do
                  send(method)
                end
              end

              generated = instance_methods(false).grep(/^test_/).select { |m| m.to_s.include?('_FLAGS:') }
              puts "[ForkToggleTest] Generated \#{generated.size} FLAGS methods"
            end
          end

          def test_example
            assert true
          end

          def test_another
            assert true
          end
        end
      RUBY
      test_file.close

      begin
        # Parent process: load file and call runnable_methods
        puts "\n=== PARENT PROCESS (PID #{Process.pid}) ==="
        require(test_file.path)

        parent_klass = Object.const_get('ForkToggleTest')
        parent_methods = parent_klass.runnable_methods

        puts "Parent generated #{parent_methods.size} methods"
        parent_flags_methods = parent_methods.select { |m| m.to_s.include?('_FLAGS:') }
        puts "Parent FLAGS methods: #{parent_flags_methods.size}"
        puts "Sample: #{parent_flags_methods.first(3).join(', ')}"

        # Verify parent generated FLAGS methods
        assert parent_flags_methods.size > 0, "Parent should generate FLAGS methods"
        assert parent_flags_methods.map(&:to_s).include?("test_example_FLAGS:test_flag:ON"), "Parent should have ON variant"
        assert parent_flags_methods.map(&:to_s).include?("test_example_FLAGS:test_flag:OFF"), "Parent should have OFF variant"

        # Fork a child process
        read_pipe, write_pipe = IO.pipe

        child_pid = fork do
          read_pipe.close

          puts "\n=== CHILD PROCESS (PID #{Process.pid}) ==="

          # Child inherits the class object from parent via CoW
          # The class still has @toggle_helper_processed_pid = parent_pid

          # Simulate what ci-queue does: call load() then runnable_methods
          load(test_file.path)

          child_klass = Object.const_get('ForkToggleTest')
          child_methods = child_klass.runnable_methods

          puts "Child generated #{child_methods.size} methods"
          child_flags_methods = child_methods.select { |m| m.to_s.include?('_FLAGS:') }
          puts "Child FLAGS methods: #{child_flags_methods.size}"
          puts "Sample: #{child_flags_methods.first(3).join(', ')}"

          # Send result to parent
          write_pipe.write("#{child_flags_methods.size}\n")
          write_pipe.write("#{child_methods.map(&:to_s).include?("test_example_FLAGS:test_flag:ON") ? 'YES' : 'NO'}\n")
          write_pipe.close

          exit(0)
        end

        write_pipe.close
        child_flags_count = read_pipe.readline.chomp.to_i
        child_has_on_variant = read_pipe.readline.chomp
        read_pipe.close

        Process.wait(child_pid)

        # Verify child also generated FLAGS methods
        puts "\nChild result: #{child_flags_count} FLAGS methods, has ON variant: #{child_has_on_variant}"

        assert child_flags_count > 0,
               "Child should generate FLAGS methods after fork! " \
               "Got #{child_flags_count}, expected > 0. " \
               "This indicates the PID-based fork detection is not working."

        assert_equal 'YES', child_has_on_variant,
                     "Child should have the ON variant method"

      ensure
        Object.send(:remove_const, 'ForkToggleTest') if defined?(ForkToggleTest)
        test_file.unlink
      end
    end
  end
end
