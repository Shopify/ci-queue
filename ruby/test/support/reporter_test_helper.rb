module ReporterTestHelper
  private

  def result(*args)
    result = runnable(*args)
    if defined? Minitest::Result
      result = Minitest::Result.from(result)
    end
    result
  end

  def runnable(name, failure = nil)
    runnable = Minitest::Test.new(name)
    runnable.failures << failure if failure
    runnable.assertions += 1
    runnable
  end
end
