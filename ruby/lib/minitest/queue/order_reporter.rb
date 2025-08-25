# frozen_string_literal: true
require 'minitest/reporters'

class Minitest::Queue::OrderReporter < Minitest::Reporters::BaseReporter
  def initialize(options = {})
    @path = options.delete(:path)
    @file = File.open(@path, 'a+')
    super
  end

  def start
    super
    file.truncate(0)
  end

  def before_test(test)
    super
    file.puts("#{test.class.name}##{test.name}")
    file.flush
  end

  def report
    file.close
  end

  private

  attr_reader :file
end

