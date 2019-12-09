# frozen_string_literal: true
require 'minitest/reporters'

class Minitest::Queue::OrderReporter < Minitest::Reporters::BaseReporter
  def initialize(options = {})
    @path = options.delete(:path)
    super
  end

  def start
    @file = File.open(@path, 'w+')
    super
  end

  def before_test(test)
    super
    @file.puts("#{test.class.name}##{test.name}")
    @file.flush
  end

  def report
    @file.close
  end
end
