require 'minitest/reporters'

class Minitest::Reporters::OrderReporter < Minitest::Reporters::BaseReporter
  def initialize(options = {})
    @path = options.delete(:path)
    super
  end

  def start
    @file = File.open(@path, 'w+')
    super
  end

  def record(test)
    @file.puts("#{test.class}##{test.name}")
  end

  def report
    @file.close
  end
end
