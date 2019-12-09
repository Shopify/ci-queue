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

module CI
  module Queue
    extend self

    attr_accessor :shuffler

    module Warnings
      RESERVED_LOST_TEST = :RESERVED_LOST_TEST
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
