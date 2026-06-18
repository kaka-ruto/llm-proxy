source "https://rubygems.org"

ruby ">= 3.2"

# ask-rb ecosystem (replaces ruby_llm)
#
# When developing / testing local changes: uncomment the `path:` lines
# and comment out the rubygems lines above them.
#
gem "ask-core", "~> 0.1"
gem "ask-llm-providers", "~> 0.1"
gem "ask-agent", "~> 0.1"
gem "ask-tools", "~> 0.1"
gem "ask-schema", "~> 0.1"
  # gem "ask-core", path: "../ask-core"
  # gem "ask-llm-providers", path: "../ask-llm-providers"
  # gem "ask-agent", path: "../ask-agent"
  # gem "ask-tools", path: "../ask-tools"
  # gem "ask-schema", path: "../ask-schema"

gem "sinatra", "~> 4.0"
gem "sqlite3", "~> 2.0"
gem "puma", "~> 6.0"
gem "rackup", "~> 2.0"

group :development, :test do
  gem "ostruct"
  gem "minitest", "~> 5.0"
  gem "rack-test", "~> 2.0"
  gem "mocha", "~> 3.0"
  gem "vcr", "~> 6.0"
  gem "webmock", "~> 3.26"
  gem "debug"
  gem "rake", "~> 13.0"
end
