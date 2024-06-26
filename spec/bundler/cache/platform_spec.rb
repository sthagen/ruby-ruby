# frozen_string_literal: true

RSpec.describe "bundle cache with multiple platforms" do
  before :each do
    gemfile <<-G
      source "https://gem.repo1"

      platforms :mri, :rbx do
        gem "myrack", "1.0.0"
      end

      platforms :jruby do
        gem "activesupport", "2.3.5"
      end
    G

    lockfile <<-G
      GEM
        remote: https://gem.repo1/
        specs:
          myrack (1.0.0)
          activesupport (2.3.5)

      PLATFORMS
        ruby
        java

      DEPENDENCIES
        myrack (1.0.0)
        activesupport (2.3.5)
    G

    cache_gems "myrack-1.0.0", "activesupport-2.3.5"
  end

  it "ensures that a successful bundle install does not delete gems for other platforms" do
    bundle "install"

    expect(bundled_app("vendor/cache/myrack-1.0.0.gem")).to exist
    expect(bundled_app("vendor/cache/activesupport-2.3.5.gem")).to exist
  end

  it "ensures that a successful bundle update does not delete gems for other platforms" do
    bundle "update", all: true

    expect(bundled_app("vendor/cache/myrack-1.0.0.gem")).to exist
    expect(bundled_app("vendor/cache/activesupport-2.3.5.gem")).to exist
  end
end
