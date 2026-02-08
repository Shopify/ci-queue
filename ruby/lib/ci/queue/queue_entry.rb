# frozen_string_literal: true

require 'base64'
require 'json'

module CI
  module Queue
    module QueueEntry
      DELIMITER = '|'
      LOAD_ERROR_PREFIX = '__ciq_load_error__:'.freeze

      def self.parse(entry)
        return { test_id: entry, file_path: nil } unless entry.include?(DELIMITER)

        test_id, file_path = entry.split(DELIMITER, 2)
        file_path = nil if file_path == ""
        { test_id: test_id, file_path: file_path }
      end

      def self.format(test_id, file_path)
        return test_id if file_path.nil? || file_path == ""

        "#{test_id}#{DELIMITER}#{file_path}"
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
