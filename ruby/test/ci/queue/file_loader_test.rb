# frozen_string_literal: true
require 'test_helper'

class CI::Queue::FileLoaderTest < Minitest::Test
  def test_load_file_records_stats
    loader = CI::Queue::FileLoader.new

    Dir.mktmpdir do |dir|
      path = File.join(dir, "sample_test.rb")
      File.write(path, "module FileLoaderSample; class Sample; end; end\n")

      loader.load_file(path)

      assert Object.const_defined?(:FileLoaderSample)
      assert FileLoaderSample.const_defined?(:Sample)
      assert_includes loader.load_stats.keys, path
      assert loader.load_stats[path] >= 0
    ensure
      if Object.const_defined?(:FileLoaderSample)
        FileLoaderSample.send(:remove_const, :Sample) if FileLoaderSample.const_defined?(:Sample)
        Object.send(:remove_const, :FileLoaderSample)
      end
    end
  end

  def test_load_file_raises_file_load_error
    loader = CI::Queue::FileLoader.new
    missing_path = File.join(Dir.tmpdir, "missing_test_#{Process.pid}.rb")

    error = assert_raises(CI::Queue::FileLoadError) do
      loader.load_file(missing_path)
    end

    assert_equal missing_path, error.file_path
    assert_includes loader.load_stats.keys, missing_path
  end

  # Verifies that non-StandardError exceptions (e.g., StrictWarning::Offense
  # which inherits from Exception) are caught and wrapped as FileLoadError
  # instead of crashing the worker process.
  def test_load_file_catches_non_standard_error_exceptions
    loader = CI::Queue::FileLoader.new

    Dir.mktmpdir do |dir|
      path = File.join(dir, "raises_exception_test.rb")
      File.write(path, "raise Class.new(Exception), 'non-standard exception'\n")

      error = assert_raises(CI::Queue::FileLoadError) do
        loader.load_file(path)
      end

      assert_equal path, error.file_path
      assert_includes error.message, "non-standard exception"
      assert_includes loader.load_stats.keys, path
    end
  end

  def test_load_file_does_not_catch_signal_exceptions
    loader = CI::Queue::FileLoader.new

    Dir.mktmpdir do |dir|
      path = File.join(dir, "raises_signal_test.rb")
      File.write(path, "raise SignalException, 'TERM'\n")

      assert_raises(SignalException) do
        loader.load_file(path)
      end
    end
  end
end
