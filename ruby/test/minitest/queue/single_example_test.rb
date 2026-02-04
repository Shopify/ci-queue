# frozen_string_literal: true
require 'test_helper'
require 'drb'

module Minitest
  module Queue
    class SingleExampleTest < Minitest::Test
      class ExampleTest < Minitest::Test
        def test_example
          assert true
        end
      end

      def setup
        @example_class = ExampleTest
      end

      def test_stores_class_name_as_string
        example = SingleExample.new(@example_class, 'test_example')

        # Verify that internally it stores a string, not a class
        assert_kind_of String, example.instance_variable_get(:@runnable_name)
        assert_equal 'Minitest::Queue::SingleExampleTest::ExampleTest',
                     example.instance_variable_get(:@runnable_name)
      end

      def test_runnable_returns_class_proxy
        example = SingleExample.new(@example_class, 'test_example')

        # External interface: .runnable returns a ClassProxy that behaves like a Class
        runnable = example.runnable

        # Acts like a Class
        assert_kind_of Class, runnable

        # Equals the actual class
        assert runnable == @example_class, "ClassProxy should equal the actual class"

        # Can call class methods
        assert_equal 'Minitest::Queue::SingleExampleTest::ExampleTest', runnable.name
        assert_respond_to runnable, :instance_method
      end

      def test_accepts_string_class_name
        example = SingleExample.new('ExampleTest', 'test_example')

        # Should accept string and store it
        assert_equal 'ExampleTest', example.instance_variable_get(:@runnable_name)
      end

      def test_drb_serialization_with_marshal
        example = SingleExample.new(@example_class, 'test_example')

        # Verify the example itself can be marshaled (contains only strings internally)
        marshaled = Marshal.dump(example)
        unmarshaled = Marshal.load(marshaled)

        assert_equal example.id, unmarshaled.id
        assert_equal example.method_name, unmarshaled.method_name
        assert_equal example.instance_variable_get(:@runnable_name),
                     unmarshaled.instance_variable_get(:@runnable_name)
      end

      def test_drb_serialization_simulated
        skip "DRb test requires actual DRb server" unless ENV['RUN_DRB_TESTS']

        # Start a DRb server in a separate thread
        server_ready = false
        queue = Thread::Queue.new

        server_thread = Thread.new do
          DRb.start_service('druby://localhost:9999', queue)
          server_ready = true
          DRb.thread.join
        end

        sleep 0.1 until server_ready

        begin
          # Connect as client
          DRb.start_service
          remote_queue = DRbObject.new_from_uri('druby://localhost:9999')

          # Create example and try to send it over DRb
          example = SingleExample.new(@example_class, 'test_example')

          # This simulates what the integration layer does:
          # Calling .runnable returns a Class, which should serialize
          data = [example.runnable, example.method_name]

          # Try to push to remote queue (this will marshal the data)
          remote_queue.push(data)

          # Try to retrieve it
          received = queue.pop

          # Verify we can access the data
          assert_kind_of Array, received
          assert_equal 2, received.length

          # The class should be accessible (not DRb::DRbUnknown)
          klass, method = received
          refute_kind_of DRb::DRbUnknown, klass
          assert_equal 'test_example', method
        ensure
          DRb.stop_service
          server_thread.kill
        end
      end

      def test_integration_layer_problem
        # This tests the pattern used by the Shopify integration layer:
        # example.runnable and example.method_name are sent over DRb

        example = SingleExample.new(@example_class, 'test_example')

        # Current problematic pattern: calling .runnable returns a Class
        runnable = example.runnable
        method_name = example.method_name

        # These would be sent over DRb. Runnable is a Class object.
        assert_kind_of Class, runnable
        assert_kind_of String, method_name

        # Problem: Class objects can't always be marshaled over DRb in lazy loading
        # They become DRb::DRbUnknown, causing: undefined method '[]' for DRb::DRbUnknown
      end

      def test_provides_class_name_accessor
        # Solution: SingleExample should provide access to the class NAME (string)
        # so integration layer can send strings instead of Class objects

        example = SingleExample.new(@example_class, 'test_example')

        # SingleExample should expose the class name as a string
        # This allows integration layer to do:
        #   [example.runnable_class_name, example.method_name, reporter]
        # instead of:
        #   [example.runnable, example.method_name, reporter]

        # Verify runnable_class_name exists and returns a string
        assert_respond_to example, :runnable_class_name,
                         "SingleExample should provide runnable_class_name accessor"

        class_name = example.runnable_class_name
        assert_kind_of String, class_name
        assert_equal 'Minitest::Queue::SingleExampleTest::ExampleTest', class_name

        # The string can be marshaled safely over DRb
        marshaled = Marshal.dump(class_name)
        unmarshaled = Marshal.load(marshaled)
        assert_equal class_name, unmarshaled
      end
    end
  end
end
