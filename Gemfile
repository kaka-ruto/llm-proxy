source "https://rubygems.org"

ruby ">= 3.2"

# ask-rb ecosystem
#
# When developing / testing local changes: uncomment the `path:` lines
# and comment out the rubygems lines above them.
#
gem "ask-core"
gem "ask-llm-providers"
gem "ask-agent"
gem "ask-tools"
gem "ask-schema"
gem "ask-web-search"
gem "ask-tools-shell"
gem "ask-mcp", "~> 0.4"
# Local development overrides (uncomment to use local copies):
# gem "ask-core", path: "../ask-core"

gem "sinatra", "~> 4.0"
gem "sqlite3", "~> 2.0"
gem "puma", "~> 8.0"
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
