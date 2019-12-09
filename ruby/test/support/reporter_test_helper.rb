# frozen_string_literal: true
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
    runnable = Minitest::Test.new(name)
    runnable.failures << failure if failure
    runnable.failures << MiniTest::Skip.new if skipped
    runnable.failures << Minitest::UnexpectedError.new(StandardError.new) if unexpected_error
    runnable.failures << MiniTest::Requeue.new('Failed') if requeued
    runnable.assertions += 1
    runnable
  end
end
