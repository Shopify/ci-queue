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
