module RedisHelpers
  def get_redis_instance(redis_url)
    if redis_url.start_with? "rediss://"
      Redis.new(
        url: redis_url,
        ssl_params: {
          ca_file: "#{test_certificate_path}/ca.crt",
          cert: OpenSSL::X509::Certificate.new(File.read("#{test_certificate_path}/client.crt")),
          key: OpenSSL::PKey::RSA.new(File.read("#{test_certificate_path}/client.key")),
          verify_mode: OpenSSL::SSL::VERIFY_NONE
        }
      )
    else
      Redis.new(url: redis_url)
    end
  end

  def amend_ci_queue_configuration(redis_url, config)
    if redis_url.start_with? "rediss://"
      {
        redis_ca_file_path: "#{test_certificate_path}/ca.crt",
        redis_client_certificate_path: "#{test_certificate_path}/client.crt",
        redis_client_certificate_key_path: "#{test_certificate_path}/client.key",
        redis_disable_certificate_verification: true
      }.merge(config)
    else
      config
    end
  end

  def amend_system_command_for_ssl(redis_url)
    if redis_url.start_with? "rediss://"
      [
        "--redis-ca-file-path", "#{test_certificate_path}/ca.crt",
        "--redis-client-certificate_path", "#{test_certificate_path}/client.crt",
        "--redis-client-certificate-key-path", "#{test_certificate_path}/client.key",
        "--redis-disable-certificate-verification"
      ]
    else
      []
    end
  end

  def test_certificate_path
    @test_certificate_path ||= File.expand_path("../tests/tls", Dir.getwd)
  end
end
