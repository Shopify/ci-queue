require 'test_helper'

module CI::Queue
  class FileFlakySupplierTest < Minitest::Test
    include SharedTestCases

    def test_parses_file_correctly
      Tempfile.open('flaky_test_file') do |file|
        file.write(TEST_NAMES.join("\n") + "\n")
        file.close
        supplier = FileFlakySupplier.new(file.path)
        supplier.include?(TEST_LIST.first)
      end
    end

    def test_raises_when_file_is_missing
      assert_raises(SystemCallError) do
        FileFlakySupplier.new('nonexistent_file')
      end
    end
  end
end
