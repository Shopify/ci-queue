# frozen_string_literal: true
module ReporterTestHelper
  private

  def result(name, **kwargs)
    result = Minitest::Result.from(runnable(name, **kwargs))
    result.source_location = ["#{Minitest::Queue.project_root}/test/my_test.rb", 12]
    result
  end

  def runnable(name, failure: nil, requeued: false, skipped: false, unexpected_error: false)
    runnable = Minitest::Test.new(name)
    runnable.failures << generate_assertion(failure) if failure
    runnable.failures << Minitest::Skip.new if skipped
    runnable.failures << generate_unexpected_error if unexpected_error
    runnable.failures << Minitest::Requeue.new(generate_assertion("Failed")) if requeued
    runnable.assertions += 1
    runnable.time = 0.12
    runnable
  end

  def generate_unexpected_error
    error = StandardError.new
    error.set_backtrace([
      "#{Minitest::Queue.project_root}/test/support/reporter_test_helper.rb:15:in `runnable'",
      "#{Minitest::Queue.project_root}/test/support/reporter_test_helper.rb:6:in `result'",
      "#{Minitest::Queue.project_root}/app/components/app/test/junit_reporter_test.rb:65:in `test_generate_junitxml_for_errored_test'",
    ])
    Minitest::UnexpectedError.new(error)
  end

  def generate_assertion(message)
    return message if message.is_a?(Minitest::Assertion)

    error = Minitest::Assertion.new(message)
    error.set_backtrace([
      "#{Minitest::Queue.project_root}/test/support/reporter_test_helper.rb:15:in `runnable'",
      "#{Minitest::Queue.project_root}/test/support/reporter_test_helper.rb:6:in `result'",
      "#{Minitest::Queue.project_root}/test/minitest/reporters/junit_reporter_test.rb:65:in `test_generate_junitxml_for_errored_test'",
    ])
    error
  end
end
