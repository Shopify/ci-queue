# frozen_string_literal: true
require 'minitest/reporters'

class Minitest::Queue::OrderReporter < Minitest::Reporters::BaseReporter
  def initialize(options = {})
    @path = options.delete(:path)
    @file = nil
    @flush_every = Integer(ENV.fetch('CI_QUEUE_ORDER_FLUSH_EVERY', '50'))
    @flush_every = 1 if @flush_every < 1
    @pending = 0
    super
  end

  def start
    super
    file.truncate(0)
  end

  def before_test(test)
    super
    file.puts("#{test.class.name}##{test.name}")
    @pending += 1
    if @pending >= @flush_every
      file.flush
      @pending = 0
    end
  end

  def report
    file.flush
    file.close
  end

  private

  def file
    @file ||= File.open(@path, 'a+')
  end
end
