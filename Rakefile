require "rake/testtask"

# All test files, regardless of naming convention. This codebase uses BOTH
# `foo_test.rb` (suffix) and `test_foo.rb` (prefix); match them all so nothing
# is silently skipped. `test/test_helper.rb` is excluded (it's the helper, not
# a test file).
TEST_FILES = Rake::FileList.new do |fl|
  fl.add("test/**/*_test.rb", "test/**/test_*.rb")
  fl.exclude("test/test_helper.rb")
  fl.exclude(FileList["test/manual/**"]) # opt-in only (require live API keys)
end

# Default `rake test`: one aggregated minitest run across every test file,
# the same way `bin/rails test` works.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = TEST_FILES
  t.verbose = true
end

desc "Run tests (single file or name): bin/test test/test_zcode.rb | bin/test zcode"
task :test_files do |_, args|
  exec("ruby", "bin/test", *args.to_a)
end

desc "Run all tests via bin/test (one process per file)"
task :all do
  exec "bin/test"
end

task default: :test
