# frozen_string_literal: true
require 'digest/md5'

module CI
  module Queue
    module Redis
      module KeyShortener
        # Suffix mapping for common key patterns
        SUFFIX_ALIASES = {
          'running' => 'r',
          'processed' => 'p',
          'queue' => 'q',
          'owners' => 'o',
          'error-reports' => 'e',
          'requeues-count' => 'rc',
          'assertions' => 'a',
          'errors' => 'er',
          'failures' => 'f',
          'skips' => 's',
          'requeues' => 'rq',
          'total_time' => 't',
          'test_failed_count' => 'fc',
          'completed' => 'c',
          'master-status' => 'm',
          'created-at' => 'ca',
          'workers' => 'w',
          'worker' => 'w',
          'warnings' => 'wn',
          'worker-errors' => 'we',
          'flaky-reports' => 'fl',
        }.freeze

        # We're transforming the key to a shorter format to minimize network traffic.
        #
        # Strategy:
        # - Shorten prefix: 'b' instead of 'build'
        # - Hash UUID: 8-char MD5 instead of 36-char UUID
        # - Alias suffixes: single letters instead of full words
        #
        # Example:
        #   build:unit:019aef0e-c010-433e-b706-c658d3c16372:running (55 bytes)
        #   -> b:f03d3bef:r (13 bytes, 76% reduction)

        def self.key(build_id, *args)
          digest = Digest::MD5.hexdigest(build_id)[0..7]
          shortened_args = args.map { |arg| SUFFIX_ALIASES[arg] || arg }

          ['b', digest, *shortened_args].join(':')
        end
      end
    end
  end
end
