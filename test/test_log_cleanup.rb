require_relative "test_helper"

describe "Log cleanup" do
  let(:log_dir) { Dir.mktmpdir("llm_proxy_logs_test") }

  after do
    FileUtils.remove_entry(log_dir)
  end

  it "deletes rotated log files but not the current log" do
    File.write(File.join(log_dir, "development.log"), "today's log")
    File.write(File.join(log_dir, "development.log.20260526"), "yesterday's log")
    File.write(File.join(log_dir, "development.log.20260525"), "day before's log")

    Dir[File.join(log_dir, "development.log.*")].each { |f| File.delete(f) }

    assert File.exist?(File.join(log_dir, "development.log")),
           "current development.log should not be deleted"
    refute File.exist?(File.join(log_dir, "development.log.20260526")),
           "rotated log should be deleted"
    refute File.exist?(File.join(log_dir, "development.log.20260525")),
           "older rotated log should be deleted"
  end

  it "handles a directory with only the current log" do
    File.write(File.join(log_dir, "development.log"), "today's log")
    Dir[File.join(log_dir, "development.log.*")].each { |f| File.delete(f) }
    assert File.exist?(File.join(log_dir, "development.log")),
           "current development.log should still exist"
  end

  it "handles a directory with no files at all" do
    Dir[File.join(log_dir, "development.log.*")].each { |f| File.delete(f) }
    pass "cleanup should not raise when there are no files"
  end

  it "only targets development.log.*, not unrelated files" do
    File.write(File.join(log_dir, "development.log"), "current")
    File.write(File.join(log_dir, "development.log.20260526"), "rotated")
    File.write(File.join(log_dir, "other_file.log"), "unrelated")
    File.write(File.join(log_dir, "server.log"), "also unrelated")

    Dir[File.join(log_dir, "development.log.*")].each { |f| File.delete(f) }

    assert File.exist?(File.join(log_dir, "development.log")),
           "current log should survive"
    assert File.exist?(File.join(log_dir, "other_file.log")),
           "other_file.log should not be touched"
    assert File.exist?(File.join(log_dir, "server.log")),
           "server.log should not be touched"
  end

  it "deletes multiple rotated files at once" do
    File.write(File.join(log_dir, "development.log"), "today")
    File.write(File.join(log_dir, "development.log.20260523"), "day1")
    File.write(File.join(log_dir, "development.log.20260524"), "day2")
    File.write(File.join(log_dir, "development.log.20260525"), "day3")

    Dir[File.join(log_dir, "development.log.*")].each { |f| File.delete(f) }

    assert File.exist?(File.join(log_dir, "development.log")),
           "current log should survive"
    assert_empty Dir[File.join(log_dir, "development.log.*")],
                 "all rotated files should be deleted"
  end

  it "mirrors the exact code from server.rb" do
    Dir[File.join(log_dir, "development.log.*")].each { |f| File.delete(f) }

    # Confirm the exact line exists in the server source
    server_source = File.read(File.expand_path("../../lib/llm_proxy/server.rb", __FILE__))
    assert_includes server_source,
      %{Dir[File.join(LOG_DIR, "development.log.*")].each { |f| File.delete(f) }},
      "server.rb must contain the cleanup line"
  end
end
