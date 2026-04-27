# frozen_string_literal: true

require 'base64'
require 'json'

module CI
  module Queue
    module QueueEntry
      LOAD_ERROR_PREFIX = '__ciq_load_error__:'.freeze

      def self.test_id(entry)
        JSON.parse(entry, symbolize_names: true)[:test_id]
      end

      def self.parse(entry)
        JSON.parse(entry, symbolize_names: true)
      end

      def self.format(test_id, file_path)
        raise ArgumentError, "file_path is required for '#{test_id}' — the test file path must be resolvable" if file_path.nil? || file_path.empty?
        canonical = load_error_payload?(file_path) ? file_path : ::File.expand_path(file_path)
        JSON.dump({ test_id: test_id, file_path: canonical })
      end

      # Format a file-affinity work-unit entry. The reserving worker discovers
      # tests inside the file lazily and runs them all under the file's lease.
      #
      # Note: do NOT add a "type" field to test entries (format above) —
      # changing their byte representation would break Redis hash/set keys
      # such as `requeues-count`, `error-reports`, `processed`, and
      # `requeued-by` across rolling deploys and mixed-version builds.
      def self.format_file(file_path)
        raise ArgumentError, 'file_path is required for a file entry' if file_path.nil? || file_path.empty?
        JSON.dump({ type: 'file', file_path: ::File.expand_path(file_path) })
      end

      FILE_ENTRY_PREFIX = '{"type":"file"'.freeze
      private_constant :FILE_ENTRY_PREFIX

      # Hot-path predicate: avoid JSON.parse on every reserve call.
      def self.file_entry?(entry)
        return false unless entry.is_a?(String)
        entry.start_with?(FILE_ENTRY_PREFIX)
      end

      def self.entry_type(entry)
        file_entry?(entry) ? :file : :test
      end

      def self.test_entry?(entry)
        entry_type(entry) == :test
      end

      def self.file_path(entry)
        parse(entry)[:file_path]
      rescue JSON::ParserError
        nil
      end

      # Canonical key for reservation bookkeeping.
      #
      # `worker.rb` keys `reserved_tests`, `reserved_entries`, `reserved_entry_ids`,
      # and `@reserved_leases` by reservation key. For test entries this is the
      # test_id (as today). For file entries `test_id` is nil — multiple files
      # would collide on nil — so we use a `file:<path>` key derived from the
      # entry's file_path.
      def self.reservation_key(entry)
        return "file:#{file_path(entry)}" if file_entry?(entry)
        test_id(entry) || entry
      rescue JSON::ParserError
        entry
      end

      def self.load_error_payload?(file_path)
        file_path&.start_with?(LOAD_ERROR_PREFIX)
      end

      def self.encode_load_error(file_path, error)
        original = error.respond_to?(:original_error) ? error.original_error : error
        payload = {
          'file_path' => file_path,
          'error_class' => original.class.name,
          'error_message' => original.message,
          'backtrace' => original.backtrace,
        }
        "#{LOAD_ERROR_PREFIX}#{Base64.strict_encode64(JSON.dump(payload))}"
      end

      def self.decode_load_error(file_path)
        return nil unless load_error_payload?(file_path)

        encoded = file_path.sub(LOAD_ERROR_PREFIX, '')
        JSON.parse(Base64.strict_decode64(encoded))
      rescue ArgumentError, JSON::ParserError
        nil
      end
    end
  end
end
