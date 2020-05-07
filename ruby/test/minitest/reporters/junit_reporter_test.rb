# frozen_string_literal: true
require 'test_helper'
require 'minitest/reporters/junit_reporter'

module Minitest::Reporters
  class JUnitReporterTest < Minitest::Test
    include ReporterTestHelper

    def setup
      @reporter = Minitest::Queue::JUnitReporter.new
    end

    def test_generate_junitxml_for_passing_tests
      @reporter.record(result('test_foo'))
      @reporter.record(result('test_bar'))

      assert_equal <<~XML, generate_xml(@reporter)
        <?xml version='1.0' encoding='UTF-8'?>
        <testsuites>
          <testsuite name='Minitest::Test' filepath='test/my_test.rb' skipped='0' failures='0' errors='0' tests='2' assertions='2' time='0.24'>
            <testcase name='test_foo' classname='Minitest::Test' assertions='1' time='0.12' flaky_test='false' lineno='12'/>
            <testcase name='test_bar' classname='Minitest::Test' assertions='1' time='0.12' flaky_test='false' lineno='12'/>
          </testsuite>
        </testsuites>
      XML
    end

    def test_generate_junitxml_for_failing_test
      @reporter.record(result('test_foo', failure: 'Assertion failed'))

      assert_equal <<~XML, generate_xml(@reporter)
        <?xml version='1.0' encoding='UTF-8'?>
        <testsuites>
          <testsuite name='Minitest::Test' filepath='test/my_test.rb' skipped='0' failures='1' errors='0' tests='1' assertions='1' time='0.12'>
            <testcase name='test_foo' classname='Minitest::Test' assertions='1' time='0.12' flaky_test='false' lineno='12'>
              <failure type='Minitest::Assertion' message='Assertion failed'>
                <![CDATA[
        Failure:
        test_foo(Minitest::Test) [#{Dir.pwd}/test/support/reporter_test_helper.rb:15]:
        Assertion failed
        ]]>
              </failure>
            </testcase>
          </testsuite>
        </testsuites>
      XML
    end

    def test_generate_junitxml_with_ansi_codes_in_message
      @reporter.record(result('test_foo', failure: "\e[31mAssertion failed\e[0m"))

      assert_equal <<~XML, generate_xml(@reporter)
        <?xml version='1.0' encoding='UTF-8'?>
        <testsuites>
          <testsuite name='Minitest::Test' filepath='test/my_test.rb' skipped='0' failures='1' errors='0' tests='1' assertions='1' time='0.12'>
            <testcase name='test_foo' classname='Minitest::Test' assertions='1' time='0.12' flaky_test='false' lineno='12'>
              <failure type='Minitest::Assertion' message='Assertion failed'>
                <![CDATA[
        Failure:
        test_foo(Minitest::Test) [#{Dir.pwd}/test/support/reporter_test_helper.rb:15]:
        \e[31mAssertion failed\e[0m
        ]]>
              </failure>
            </testcase>
          </testsuite>
        </testsuites>
      XML
    end

    def test_generate_junitxml_for_skipped_test
      @reporter.record(result('test_foo', skipped: true))

      assert_equal <<~XML, generate_xml(@reporter)
        <?xml version='1.0' encoding='UTF-8'?>
        <testsuites>
          <testsuite name='Minitest::Test' filepath='test/my_test.rb' skipped='1' failures='0' errors='0' tests='1' assertions='1' time='0.12'>
            <testcase name='test_foo' classname='Minitest::Test' assertions='1' time='0.12' flaky_test='false' lineno='12'>
              <skipped type='Minitest::Skip'/>
            </testcase>
          </testsuite>
        </testsuites>
      XML
    end

    def test_generate_junitxml_for_errored_test
      @reporter.record(result('test_foo', unexpected_error: true))

      assert_equal <<~XML, generate_xml(@reporter)
        <?xml version='1.0' encoding='UTF-8'?>
        <testsuites>
          <testsuite name='Minitest::Test' filepath='test/my_test.rb' skipped='0' failures='0' errors='1' tests='1' assertions='1' time='0.12'>
            <testcase name='test_foo' classname='Minitest::Test' assertions='1' time='0.12' flaky_test='false' lineno='12'>
              <error type='StandardError' message='StandardError: StandardError'>
                <![CDATA[
        Failure:
        test_foo(Minitest::Test) [#{Dir.pwd}/test/support/reporter_test_helper.rb:15]:
        StandardError: StandardError
            #{Dir.pwd}/test/support/reporter_test_helper.rb:15:in `runnable'
            #{Dir.pwd}/test/support/reporter_test_helper.rb:6:in `result'
            #{Dir.pwd}/test/minitest/reporters/junit_reporter_test.rb:65:in `test_generate_junitxml_for_errored_test'
        ]]>
              </error>
            </testcase>
          </testsuite>
        </testsuites>
      XML
    end

    def test_generate_junitxml_for_requeued_test
      @reporter.record(result('test_foo', requeued: true))

      assert_equal <<~XML, generate_xml(@reporter)
        <?xml version='1.0' encoding='UTF-8'?>
        <testsuites>
          <testsuite name='Minitest::Test' filepath='test/my_test.rb' skipped='1' failures='0' errors='0' tests='1' assertions='1' time='0.12'>
            <testcase name='test_foo' classname='Minitest::Test' assertions='1' time='0.12' flaky_test='false' lineno='12'>
              <skipped type='Minitest::Assertion'/>
            </testcase>
          </testsuite>
        </testsuites>
      XML
    end

    private

    def generate_xml(junitxml)
      io = StringIO.new
      junitxml.format_document(junitxml.generate_document, io)
      io.string
    end
  end
end
