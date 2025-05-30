require_relative '../../../spec_helper'

describe "SortedSet" do
  ruby_version_is ""..."3.5" do
    it "raises error including message that it has been extracted from the set stdlib" do
      -> {
        SortedSet
      }.should raise_error(RuntimeError) { |e|
        e.message.should.include?("The `SortedSet` class has been extracted from the `set` library")
      }
    end
  end
end
