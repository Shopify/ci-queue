#!/usr/bin/env -S ruby --disable-gems
# typed: false
# frozen_string_literal: true

require 'logger'
require 'redis'
require 'json'

module CI
  module Queue
    module Redis
      class Monitor
        DEV_SCRIPTS_ROOT = ::File.expand_path('../../../../../../redis', __FILE__)
        RELEASE_SCRIPTS_ROOT = ::File.expand_path('../../redis', __FILE__)

        def initialize(pipe, logger, redis_url, zset_key, processed_key, owners_key, worker_queue_key, entry_delimiter)
          @zset_key = zset_key
          @processed_key = processed_key
          @owners_key = owners_key
          @worker_queue_key = worker_queue_key
          @entry_delimiter = entry_delimiter
          @logger = logger
          @redis = ::Redis.new(url: redis_url, reconnect_attempts: [0, 0, 0.1, 0.5, 1, 3, 5])
          @shutdown = false
          @pipe = pipe
          @self_pipe_reader, @self_pipe_writer = IO.pipe
          @self_pipe_writer.sync = true
          @queue = []
          @deadlines = {}
          %i[TERM INT USR1].each do |sig|
            Signal.trap(sig) { soft_signal(sig) }
          end
        end

        def soft_signal(sig)
          @queue << sig
          @self_pipe_writer << '.'
        end

        def process_tick!(id:)
          eval_script(
            :heartbeat,
            keys: [@zset_key, @processed_key, @owners_key, @worker_queue_key],
            argv: [Time.now.to_f, id, @entry_delimiter]
          )
        rescue => error
          @logger.info(error)
        end

        def eval_script(script, *args)
          @redis.evalsha(load_script(script), *args)
        end

        def load_script(script)
          @scripts_cache ||= {}
          @scripts_cache[script] ||= @redis.script(:load, read_script(script))
        end

        def read_script(name)
          resolve_lua_includes(
            ::File.read(::File.join(DEV_SCRIPTS_ROOT, "#{name}.lua")),
            DEV_SCRIPTS_ROOT,
          )
        rescue SystemCallError
          resolve_lua_includes(
            ::File.read(::File.join(RELEASE_SCRIPTS_ROOT, "#{name}.lua")),
            RELEASE_SCRIPTS_ROOT,
          )
        end

        def resolve_lua_includes(script, root)
          script.gsub(/^-- @include (\S+)$/) do
            ::File.read(::File.join(root, "#{$1}.lua"))
          end
        end

        HEADER = 'L'
        HEADER_SIZE = [0].pack(HEADER).bytesize
        def read_message(io)
          case header = io.read_nonblock(HEADER_SIZE, exception: false)
          when :wait_readable
            nil
          when nil
            @logger.debug('Broken pipe, exiting')
            @shutdown = 0
            false
          else
            JSON.parse(io.read(header.unpack1(HEADER)))
          end
        end

        def process_messages(io)
          while (message = read_message(io))
            type, kwargs = message
            kwargs.transform_keys!(&:to_sym)
            public_send("process_#{type}", **kwargs)
          end
        end

        def wait_for_events(ios)
          return if @shutdown

          return unless (ready = IO.select(ios, nil, nil, 10))

          ready[0].each do |io|
            case io
            when @self_pipe_reader
              io.read_nonblock(512, exception: false) # Just flush the pipe, the information is in the @queue
            when @pipe
              process_messages(@pipe)
            else
              @logger.debug("Unknown reader: #{io.inspect}")
              raise "Unknown reader: #{io.inspect}"
            end
          end
        end

        def monitor
          @logger.debug("Starting monitor")
          ios = [@self_pipe_reader, @pipe]

          until @shutdown
            while (sig = @queue.shift)
              case sig
              when :INT, :TERM
                @logger.debug("Received #{sig}, exiting")
                @shutdown = 0
                break
              else
                raise "Unknown signal: #{sig.inspect}"
              end
            end

            wait_for_events(ios)
          end

          @logger.debug('Done')
          @shutdown
        end
      end
    end
  end
end

logger = Logger.new($stderr)
if ARGV.include?('-v')
  logger.level = Logger::DEBUG
else
  logger.level = Logger::INFO
  logger.formatter = ->(_severity, _timestamp, _progname, msg) { "[CI Queue Monitor] #{msg}\n" }
end

redis_url = ARGV[0]
zset_key = ARGV[1]
processed_key = ARGV[2]
owners_key = ARGV[3]
worker_queue_key = ARGV[4]
entry_delimiter = ARGV[5]

logger.debug("Starting monitor: #{redis_url} #{zset_key} #{processed_key}")
manager = CI::Queue::Redis::Monitor.new($stdin, logger, redis_url, zset_key, processed_key, owners_key, worker_queue_key, entry_delimiter)

# Notify the parent we're ready
$stdout.puts(".")
$stdout.close

exit(manager.monitor)
