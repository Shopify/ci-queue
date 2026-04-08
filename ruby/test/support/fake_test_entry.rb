# frozen_string_literal: true
module Minitest
  module Queue
    # Lightweight stand-in for a test object in unit tests that don't run real tests.
    # Holds test_id and file_path directly so no source_location lookup is needed.
    FakeEntry = Struct.new(:id, :queue_entry, :method_name)

    def self.fake_entry(method_name)
      test_id = "Minitest::Test##{method_name}"
      # Use the same file_path as ReporterTestHelper#result so entries match across reserve/record calls
      file_path = "#{Minitest::Queue.project_root}/test/my_test.rb"
      FakeEntry.new(test_id, CI::Queue::QueueEntry.format(test_id, file_path), method_name)
    end
  end
end
