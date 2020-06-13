# frozen_string_literal: true

class Minitest::Queue::OrderReporter < Minitest::Reporter
  include Minitest::Reporters::BaseReporterShim

  def initialize(options = {})
    @path = options.delete(:path)
    super
  end

  def start
    @file = File.open(@path, 'w+')
  end

  def prerecord(test_class, name)
    @file.puts("#{test_class.name}##{name}")
    @file.flush
  end

  def report
    @file.close
  end
end
