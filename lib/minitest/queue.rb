require 'minitest'

module Minitest
  module Queue
    attr_accessor :queue

    SuiteNotFound = Class.new(StandardError)

    def loaded_tests
      MiniTest::Test.runnables.flat_map do |suite|
        suite.runnable_methods.map do |method|
          "#{suite}##{method}"
        end
      end
    end

    def __run(*args)
      if queue
        run_from_queue(*args)
      else
        super
      end
    end

    def run_from_queue(reporter, *)
      runnable_classes = Minitest::Runnable.runnables.map { |s| [s.name, s] }.to_h

      queue.poll do |msg|
        class_name, method = msg.split("#".freeze, 2)

        if suite = runnable_classes[class_name]
          Minitest::Runnable.run_one_method(suite, method, reporter)
        else
          raise SuiteNotFound, "Couldn't find suite matching: #{msg.inspect}"
        end
      end
    end
  end
end

MiniTest.singleton_class.prepend(MiniTest::Queue)
