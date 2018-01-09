module ReporterTestHelper
  private

  def runnable(name, failure = nil)
    runnable = Minitest::Test.new(name)
    if defined? Minitest::Result
      runnable = Minitest::Result.from(runnable)
    end
    runnable.failures << failure if failure
    runnable.assertions += 1
    runnable
  end
end
