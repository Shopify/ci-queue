# frozen_string_literal: true
require 'openssl'
require 'socket'
require 'timeout'

# Minimal TLS endpoint that speaks just enough RESP to observe whether a
# client completed the handshake and what commands it sent. It presents a
# self-signed certificate, so a verifying client must reject it.
class TLSRedisStub
  def self.ssl_context
    @ssl_context ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=127.0.0.1')
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      cert.sign(key, OpenSSL::Digest::SHA256.new)

      context = OpenSSL::SSL::SSLContext.new
      context.cert = cert
      context.key = key
      context
    end
  end

  def initialize
    @tcp_server = TCPServer.new('127.0.0.1', 0)
    @server = OpenSSL::SSL::SSLServer.new(@tcp_server, self.class.ssl_context)
    @server.start_immediately = false
    @events = Thread::Queue.new
    @thread = Thread.new { accept_loop }
  end

  def url
    "rediss://127.0.0.1:#{@tcp_server.addr[1]}/0"
  end

  # Returns the next event: :handshake_failed, or an Array with a command's arguments.
  def next_event(timeout: 10)
    Timeout.timeout(timeout) { @events.pop }
  end

  def wait_for_command(name, timeout: 10)
    Timeout.timeout(timeout) do
      loop do
        event = @events.pop
        return event if event.is_a?(Array) && event.first.casecmp?(name)
      end
    end
  end

  def close
    @thread.kill
    @server.close
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      Thread.new { serve(socket) }
    end
  end

  def serve(socket)
    socket.accept
    while (command = read_command(socket))
      @events << command
      socket.write("+OK\r\n")
    end
  rescue OpenSSL::SSL::SSLError
    @events << :handshake_failed
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close rescue nil
  end

  def read_command(socket)
    header = socket.gets("\r\n") or return
    Array.new(header[1..].to_i) do
      length = socket.gets("\r\n")[1..].to_i
      socket.read(length + 2)[0, length]
    end
  end
end
