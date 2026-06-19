require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.pattern = "test/**/{test_*.*,*.rb}"
  t.warning = false
  t.ruby_opts = ["-Itest"]
end

desc "Run all tests via bin/test"
task :all do
  exec "bin/test"
end

task default: :test
