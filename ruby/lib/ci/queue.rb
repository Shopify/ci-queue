require 'uri'
require 'cgi'

require 'ci/queue/version'
require 'ci/queue/output_helpers'
require 'ci/queue/index'
require 'ci/queue/configuration'
require 'ci/queue/static'
require 'ci/queue/file'
require 'ci/queue/bisect'

module CI
  module Queue
    extend self

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
