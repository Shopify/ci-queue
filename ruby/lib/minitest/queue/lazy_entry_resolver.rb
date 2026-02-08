# frozen_string_literal: true

module Minitest
  module Queue
    class LazyEntryResolver
      def initialize(loader:, resolver:)
        @loader = loader
        @resolver = resolver
      end

      def call(entry)
        parsed = CI::Queue::QueueEntry.parse(entry)
        class_name, method_name = parsed.fetch(:test_id).split('#', 2)
        if CI::Queue::QueueEntry.load_error_payload?(parsed[:file_path])
          payload = CI::Queue::QueueEntry.decode_load_error(parsed[:file_path])
          if payload
            error = StandardError.new("#{payload['error_class']}: #{payload['error_message']}")
            error.set_backtrace(payload['backtrace']) if payload['backtrace']
            load_error = CI::Queue::FileLoadError.new(payload['file_path'], error)
            return Minitest::Queue::LazySingleExample.new(
              class_name,
              method_name,
              payload['file_path'],
              loader: @loader,
              resolver: @resolver,
              load_error: load_error,
              queue_entry: entry,
            )
          end
        end

        Minitest::Queue::LazySingleExample.new(
          class_name,
          method_name,
          parsed[:file_path],
          loader: @loader,
          resolver: @resolver,
          queue_entry: entry,
        )
      end
    end
  end
end
