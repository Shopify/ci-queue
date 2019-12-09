# frozen_string_literal: true
module Minitest
  module Queue
    class ErrorReport
      class << self
        attr_accessor :coder

        def load(payload)
          new(coder.load(payload))
        end
      end

      self.coder = Marshal

      begin
        require 'snappy'
        require 'msgpack'
        require 'stringio'

        module SnappyPack
          extend self

          MSGPACK = MessagePack::Factory.new
          MSGPACK.register_type(0x00, Symbol)

          def load(payload)
            io = StringIO.new(Snappy.inflate(payload))
            MSGPACK.unpacker(io).unpack
          end

          def dump(object)
            io = StringIO.new
            packer = MSGPACK.packer(io)
            packer.pack(object)
            packer.flush
            io.rewind
            Snappy.deflate(io.string).force_encoding(Encoding::UTF_8)
          end
        end

        self.coder = SnappyPack
      rescue LoadError
      end

      def initialize(data)
        @data = data
      end

      def dump
        self.class.coder.dump(@data)
      end

      def test_name
        @data[:test_name]
      end

      def test_and_module_name
        @data[:test_and_module_name]
      end

      def test_file
        @data[:test_file]
      end

      def test_line
        @data[:test_line]
      end

      def to_h
        @data
      end

      def to_s
        output
      end

      def output
        @data[:output]
      end
    end
  end
end
