require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.pattern = "test/**/*_test.rb"
  t.ruby_opts = ["-Itest"]
end

desc "Run all tests via bin/test"
task :all do
  exec "bin/test"
end

task default: :test
