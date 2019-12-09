# frozen_string_literal: true
require 'test_helper'

module CI::Queue
  class ConfigurationTest < Minitest::Test
    def test_cirleci_defaults
      config = Configuration.from_env(
        'CIRCLE_BUILD_URL' => 'https://circleci.com/gh/circleci/frontend/933',
        'CIRCLE_NODE_INDEX' => '12',
        'CIRCLE_SHA1' => 'faa647bbb8168a77cf338e7488c3f8445c3e6554',
      )
      assert_equal 'https://circleci.com/gh/circleci/frontend/933', config.build_id
      assert_equal '12', config.worker_id
      assert_equal 'faa647bbb8168a77cf338e7488c3f8445c3e6554', config.seed
    end

    def test_heroku_ci_defaults
      config = Configuration.from_env(
        'HEROKU_TEST_RUN_ID' => 'YouAreAnAmazingPersonAndIBelieveYouCanDoIt',
        'CI_NODE_INDEX' => '12',
        'HEROKU_TEST_RUN_COMMIT_VERSION' => 'zaa647bbb8168a77cf338e7488c3f8445c3e6554',
      )
      assert_equal 'YouAreAnAmazingPersonAndIBelieveYouCanDoIt', config.build_id
      assert_equal '12', config.worker_id
      assert_equal 'zaa647bbb8168a77cf338e7488c3f8445c3e6554', config.seed
    end

    def test_buildkite_defaults
      config = Configuration.from_env(
        'BUILDKITE_BUILD_ID' => '9e08ef3c-d6e6-4a86-91dd-577ce5205b8e',
        'BUILDKITE_PARALLEL_JOB' => '12',
        'BUILDKITE_COMMIT' => 'faa647bbb8168a77cf338e7488c3f8445c3e6554',
      )
      assert_equal '9e08ef3c-d6e6-4a86-91dd-577ce5205b8e', config.build_id
      assert_equal '12', config.worker_id
      assert_equal 'faa647bbb8168a77cf338e7488c3f8445c3e6554', config.seed
    end

    def test_travis_defaults
      config = Configuration.from_env(
        'TRAVIS_BUILD_ID' => '324325435435',
        'TRAVIS_COMMIT' => 'faa647bbb8168a77cf338e7488c3f8445c3e6554',
      )
      assert_equal '324325435435', config.build_id
      assert_equal 'faa647bbb8168a77cf338e7488c3f8445c3e6554', config.seed
    end


    def test_semaphore2_defaults
      config = Configuration.from_env(
        'SEMAPHORE_PIPELINE_ID' => 'a47d9178-a94e-435a-9bbd-a095aee1e41c',
        'SEMAPHORE_JOB_ID' => '04f953b6-493c-424e-a9a4-e8a0c28f4bc2',
        'SEMAPHORE_GIT_SHA' => 'faa647bbb8168a77cf338e7488c3f8445c3e6554',
      )

      assert_equal 'a47d9178-a94e-435a-9bbd-a095aee1e41c', config.build_id
      assert_equal '04f953b6-493c-424e-a9a4-e8a0c28f4bc2', config.worker_id
      assert_equal 'faa647bbb8168a77cf338e7488c3f8445c3e6554', config.seed
    end

    def test_namespace
      config = Configuration.new(build_id: '9e08ef3c-d6e6-4a86-91dd-577ce5205b8e')
      assert_equal '9e08ef3c-d6e6-4a86-91dd-577ce5205b8e', config.build_id
      config.namespace = 'browser'
      assert_equal 'browser:9e08ef3c-d6e6-4a86-91dd-577ce5205b8e', config.build_id
    end

    def test_parses_file_correctly
      Tempfile.open('flaky_test_file') do |file|
        file.write(SharedTestCases::TEST_NAMES.join("\n") + "\n")
        file.close

        flaky_tests = Configuration.load_flaky_tests(file.path)
        SharedTestCases::TEST_NAMES.each do |test|
          assert_includes flaky_tests, test
        end
      end

      flaky_tests = Configuration.load_flaky_tests('/tmp/does-not-exist')
      assert_empty flaky_tests
    end
  end
end
