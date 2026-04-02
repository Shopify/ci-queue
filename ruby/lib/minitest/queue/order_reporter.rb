# frozen_string_literal: true
require 'minitest/reporters'

class Minitest::Queue::OrderReporter < Minitest::Reporters::BaseReporter
  # Hook prepended onto Minitest::Test to capture test order from within the
  # test process. In DRb parallel mode, reporters only receive prerecord/record
  # in the parent, but before_setup runs inside the forked worker where we can
  # identify the process and write to a per-worker file.
  #
  # All file management lives here (class-level) so forked workers are
  # self-contained and don't depend on a reporter instance crossing the fork.
  module TestOrderTracking
    def before_setup
      TestOrderTracking.record(self.class.name, self.name)
      super
    end

    @mutex = Mutex.new
    @files = {}
    @dir = nil
    @basename = nil
    @ext = nil

    class << self
      def configure(dir:, basename:, ext:)
        @dir = dir
        @basename = basename
        @ext = ext
      end

      def reset
        @dir = nil
        @files.each_value do |f|
          f.flush
          f.close
        end
        @files.clear
      end

      def record(klass_name, test_name)
        return unless @dir

        file.puts("#{klass_name}##{test_name}")
      end

      private

      def file
        pid = Process.pid
        @mutex.synchronize do
          @files[pid] ||= File.open(
            File.join(@dir, "#{@basename}.worker-#{pid}#{@ext}"),
            'a+',
          ).tap { |f| f.sync = true }
        end
      end
    end
  end

  def initialize(options = {})
    @path = options.delete(:path)
    @dir = File.dirname(@path)
    @basename = File.basename(@path, File.extname(@path))
    @ext = File.extname(@path)
    super
  end

  def start
    super
    TestOrderTracking.configure(dir: @dir, basename: @basename, ext: @ext)

    # Clean stale worker files from previous runs
    Dir.glob(File.join(@dir, "#{@basename}.worker-*#{@ext}")).each do |f|
      File.delete(f)
    end
  end

  def report
    TestOrderTracking.reset
  end
end

Minitest::Test.prepend(Minitest::Queue::OrderReporter::TestOrderTracking)
