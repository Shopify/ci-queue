# frozen_string_literal: true

require 'uri'
require 'cgi'

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
require 'logger'
require 'fileutils'

module CI
  module Queue
    extend self

    attr_accessor :shuffler, :requeueable

    module Warnings
      RESERVED_LOST_TEST = :RESERVED_LOST_TEST
    end

    def requeueable?(test_result)
      result = requeueable.nil? || requeueable.call(test_result)

      test_result.failures.each do |failure|
        CI::Queue.logger.info("requeueable failure: #{failure} - #{failure.error} - #{failure.class}}")
      end

      CI::Queue.logger.info("requeueable?(#{test_result.inspect}) => #{result}")
      CI::Queue.logger.info("requeueable: #{requeueable&.source_location}}")

      result
    end

    def logger
      @logger ||= begin
        FileUtils.mkdir_p("log")
        Logger.new('log/ci-queue.log')
      end
    end

    def with_instrumentation(msg)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      result = yield
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start
      CI::Queue.logger.info("#{msg} #{duration}ms")
      result
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
      when 'redis'
        require 'ci/queue/redis'
        Redis
      else
        raise ArgumentError, "Don't know how to handle #{uri.scheme} URLs"
      end
      implementation.from_uri(uri, config)
    end
  end
end
