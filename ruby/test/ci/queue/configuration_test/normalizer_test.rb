module CI
  module Queue
    class ConfigurationTest < Minitest::Test
      class NormalizerTest < Minitest::Test
        module ExampleHelper
          extend self

          def normalize(id)
            id.sub(%r{^\./}, "")
          end

          def strip(id)
            id.strip
          end
        end

        def test_flaky_without_normalizer
          config = Configuration.new(flaky_tests: Set["ATest#test_foo", "BTest#test_bar"])

          test = Struct.new(:id).new("ATest#test_foo")
          assert config.flaky?(test)

          test = Struct.new(:id).new("CTest#test_baz")
          refute config.flaky?(test)
        end

        def test_flaky_with_instance_method_normalizer
          config = Configuration.new(flaky_tests: Set["./test/my_test.rb:ATest#test_foo", "./test/my_test.rb:BTest#test_bar"])
          config.test_id_normalizer = ExampleHelper.instance_method(:normalize)

          test = Struct.new(:id).new("test/my_test.rb:ATest#test_foo")
          assert config.flaky?(test)

          test = Struct.new(:id).new("test/my_test.rb:CTest#test_baz")
          refute config.flaky?(test)
        end

        def test_flaky_with_method_normalizer
          config = Configuration.new(flaky_tests: Set["./test/my_test.rb:ATest#test_foo", "./test/my_test.rb:BTest#test_bar"])
          config.test_id_normalizer = ExampleHelper.method(:normalize)

          test = Struct.new(:id).new("test/my_test.rb:ATest#test_foo")
          assert config.flaky?(test)

          test = Struct.new(:id).new("test/my_test.rb:CTest#test_baz")
          refute config.flaky?(test)
        end

        def test_flakey_with_proc
          config = Configuration.new(flaky_tests: Set["./test/my_test.rb:ATest#test_foo", "./test/my_test.rb:BTest#test_bar"])
          config.test_id_normalizer = proc { |id| id.sub(%r{^\./}, "") }

          test = Struct.new(:id).new("test/my_test.rb:ATest#test_foo")
          assert config.flaky?(test)

          test = Struct.new(:id).new("test/my_test.rb:CTest#test_baz")
          refute config.flaky?(test)
        end

        def test_flaky_normalizer_applied_to_both_sides
          config = Configuration.new(flaky_tests: Set["  ATest#test_foo  ", "BTest#test_bar"])
          config.test_id_normalizer = ExampleHelper.instance_method(:strip)

          test = Struct.new(:id).new("ATest#test_foo")
          assert config.flaky?(test)

          test = Struct.new(:id).new("  ATest#test_foo  ")
          assert config.flaky?(test)
        end

        def test_flaky_normalizer_invalidates_cache
          config = Configuration.new(flaky_tests: Set["./test/my_test.rb:ATest#test_foo"])
          test = Struct.new(:id).new("test/my_test.rb:ATest#test_foo")

          refute config.flaky?(test)

          config.test_id_normalizer = ExampleHelper.instance_method(:normalize)

          assert config.flaky?(test)
        end

        def test_flaky_normalized_lookup_uses_set
          config = Configuration.new(flaky_tests: Set["ATest#test_foo"])
          assert_kind_of Set, config.lazy_normalized_flaky_tests
        end
      end
    end
  end
end
