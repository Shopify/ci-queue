require 'test_helper'

module CI::Queue
  class FileFlakySupplierTest < Minitest::Test
    include SharedTestCases

    def test_parses_file_correctly
      Tempfile.open('flaky_test_file') do |file|
        file.write(TEST_NAMES.to_json)
        file.close
        supplier = FileFlakySupplier.new(file.path)
        supplier.include?(TEST_LIST.first)
      end
    end

    def test_raises_when_file_is_missing
      assert_raises(SystemCallError) do
        FileFlakySupplier.new('non_existant_file')
      end
    end

    def test_raises_when_file_in_incorrect_format
      Tempfile.open('flaky_test_file') do |file|
        file.write({flaky_tests: TEST_LIST}.to_json)
        file.close
        assert_raises(CI::Queue::FileFlakySupplier::FileParseError) do
          FileFlakySupplier.new(file.path)
        end
      end
    end

    def test_raises_when_invalid_json
      Tempfile.open('flaky_test_file') do |file|
        file.write('TestA#test_thing, TestB#test_thing')
        file.close
        assert_raises(JSON::ParserError) do
          FileFlakySupplier.new(file.path)
        end
      end
    end
  end
end
