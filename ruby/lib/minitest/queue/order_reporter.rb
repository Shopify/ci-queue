# frozen_string_literal: true
require 'minitest/reporters'

class Minitest::Queue::OrderReporter < Minitest::Reporters::BaseReporter
  def initialize(options = {})
    @path = options.delete(:path)
    super
  end

  def start
    open_file
    super
  end

  def before_test(test)
    super
    open_file if @file.closed?
    @file.puts("#{test.class.name}##{test.name}")
  end

  def report
    @file.close
  end

  private

  def open_file
    @file = File.open(@path, 'a+')
    @file.sync = true
  end
end
