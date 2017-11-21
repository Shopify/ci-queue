require 'test_helper'

module CI::Queue
  class ConfigurationTest < Minitest::Test
    def test_cirleci_defaults
      config = Configuration.from_env(
        'CIRCLE_BUILD_URL' => 'https://circleci.com/gh/circleci/frontend/933',
        'CIRCLE_NODE_INDEX' => '12',
      )
      assert_equal 'https://circleci.com/gh/circleci/frontend/933', config.build_id
      assert_equal '12', config.worker_id
    end

    def test_buildkite_defaults
      config = Configuration.from_env(
        'BUILDKITE_BUILD_ID' => '9e08ef3c-d6e6-4a86-91dd-577ce5205b8e',
        'BUILDKITE_PARALLEL_JOB' => '12',
      )
      assert_equal '9e08ef3c-d6e6-4a86-91dd-577ce5205b8e', config.build_id
      assert_equal '12', config.worker_id
    end

    def test_travis_defaults
      config = Configuration.from_env(
        'TRAVIS_BUILD_ID' => '324325435435',
      )
      assert_equal '324325435435', config.build_id
    end

    def test_prefix
      config = Configuration.new(build_id: '9e08ef3c-d6e6-4a86-91dd-577ce5205b8e')
      assert_equal '9e08ef3c-d6e6-4a86-91dd-577ce5205b8e', config.build_id
      config.prefix = 'browser'
      assert_equal 'browser:9e08ef3c-d6e6-4a86-91dd-577ce5205b8e', config.build_id
    end
  end
end
