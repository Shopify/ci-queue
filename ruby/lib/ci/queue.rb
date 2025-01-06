# frozen_string_literal: true

require 'uri'
require 'cgi'
require 'json'

require 'ci/queue/version'
require 'ci/queue/output_helpers'
require 'ci/queue/circuit_breaker'
require 'ci/queue/configuration'
require 'ci/queue/common'
require 'ci/queue/build_record'
require 'ci/queue/static'
require 'ci/queue/file'
require 'ci/queue/grind'
require 'ci/queue/bisect'

module CI
  module Queue
    extend self

    attr_accessor :shuffler, :requeueable

    Error = Class.new(StandardError)

    module Warnings
      RESERVED_LOST_TEST = :RESERVED_LOST_TEST
    end

    GET_NOW = ::Time.method(:now)
    private_constant :GET_NOW
    def time_now
      # Mocks like freeze_time should be cleaned when ci-queue runs, however,
      # we experienced cases when tests were enqueued with wrong timestamps, so we
      # safeguard Time.now here.
      GET_NOW.call
    end

    def requeueable?(test_result)
      requeueable.nil? || requeueable.call(test_result)
    end

    def shuffle(tests, random)
      if shuffler
        shuffler.call(tests, random)
      else
        tests.sort.shuffle(random: random)
      end
    end

    def from_uri(url, config)
      uri = URI(url)
      implementation = case uri.scheme
      when 'list'
        Static
      when 'file', nil
        File
      when 'redis', 'rediss'
        require 'ci/queue/redis'
        Redis
      else
        raise ArgumentError, "Don't know how to handle #{uri.scheme} URLs"
      end
      implementation.from_uri(uri, config)
    end
  end
end
