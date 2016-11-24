module ReporterTestHelper
  private

  def runnable(name, failure = nil)
    runnable = Minitest::Test.new(name)
    runnable.failures << failure if failure
    runnable.assertions += 1
    runnable
  end
end
