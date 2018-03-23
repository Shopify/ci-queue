module ReporterTestHelper
  private

  def result(*args)
    result = runnable(*args)
    if defined? Minitest::Result
      result = Minitest::Result.from(result)
    end
    result
  end

  def runnable(name, failure: nil, requeued: false, skipped: false, unexpected_error: false)
    runnable = defined?(MiniTest::Result) ? MiniTest::Result.new(name) : Minitest::Test.new(name)
    runnable.failures << failure if failure
    runnable.failures << MiniTest::Skip.new if skipped
    runnable.failures << Minitest::UnexpectedError.new(StandardError.new) if unexpected_error
    if requeued
      runnable.failures << 'Failed'
      runnable.requeue!
    end
    runnable.assertions += 1
    runnable
  end
end
