# frozen_string_literal: true
module SharedTestCases
  class TestCase
    attr_reader :name

    def initialize(name)
      @name = name
    end

    def inspect
      "#<TestCase #{name}>"
    end

    def id
      name
    end

    def to_s
      inspect
    end

    def <=>(other)
      self.name <=> other
    end
  end


  TEST_NAMES = %w(
    ATest#test_foo
    ATest#test_bar
    BTest#test_foo
    BTest#test_bar
  ).freeze
  TEST_LIST = TEST_NAMES.map { |n| TestCase.new(n).freeze }.freeze
end
