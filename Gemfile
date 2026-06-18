source "https://rubygems.org"

ruby ">= 3.2"

# ask-rb ecosystem — all gems live under ASK_RB_ROOT (default: parent directory)
ask_rb = ENV.fetch("ASK_RB_ROOT") { File.expand_path("..", __dir__) }
gem "ask-core", path: "#{ask_rb}/ask-core"
gem "ask-llm-providers", path: "#{ask_rb}/ask-llm-providers"
gem "ask-agent", path: "#{ask_rb}/ask-agent"
gem "ask-tools", path: "#{ask_rb}/ask-tools"
gem "ask-schema", path: "#{ask_rb}/ask-schema"

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
