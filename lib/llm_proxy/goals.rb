require "sqlite3"
require "securerandom"
require "fileutils"

module LLMProxy
  module Goals
    GOALS_DB = File.expand_path("~/.codex/goals_1.sqlite")

    class << self
      def set(thread_id:, objective: nil, status: nil)
        ensure_table

        if existing = find_by_thread(thread_id)
          now = current_time_ms
          db.execute(
            "UPDATE thread_goals SET objective = ?, status = ?, updated_at_ms = ? WHERE thread_id = ?",
            [objective || existing["objective"], status || existing["status"], now, thread_id]
          )
          find_by_thread(thread_id)
        else
          now = current_time_ms
          goal_id = SecureRandom.uuid
          status ||= "active"
          db.execute(
            "INSERT INTO thread_goals (thread_id, goal_id, objective, status, token_budget, tokens_used, time_used_seconds, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, NULL, 0, 0, ?, ?)",
            [thread_id, goal_id, objective || "", status, now, now]
          )
          find_by_thread(thread_id)
        end
      end

      def set_status(thread_id:, status:)
        ensure_table
        now = current_time_ms
        db.execute(
          "UPDATE thread_goals SET status = ?, updated_at_ms = ? WHERE thread_id = ?",
          [status, now, thread_id]
        )
        find_by_thread(thread_id)
      end

      def clear(thread_id)
        ensure_table
        db.execute("DELETE FROM thread_goals WHERE thread_id = ?", [thread_id])
      end

      def find_by_thread(thread_id)
        ensure_table
        row = db.get_first_row("SELECT * FROM thread_goals WHERE thread_id = ?", [thread_id])
        return nil unless row
        {
          id: row["goal_id"],
          goal_id: row["goal_id"],
          thread_id: row["thread_id"],
          objective: row["objective"],
          status: row["status"],
          token_budget: row["token_budget"],
          tokens_used: row["tokens_used"],
          time_used_seconds: row["time_used_seconds"],
          created_at_ms: row["created_at_ms"],
          updated_at_ms: row["updated_at_ms"],
        }
      end

      private

      def db
        @db ||= SQLite3::Database.new(GOALS_DB, results_as_hash: true)
      end

      def ensure_table
        db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS thread_goals (
            thread_id TEXT PRIMARY KEY NOT NULL,
            goal_id TEXT NOT NULL,
            objective TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN (
              'active', 'paused', 'blocked', 'usage_limited', 'budget_limited', 'complete'
            )),
            token_budget INTEGER,
            tokens_used INTEGER NOT NULL DEFAULT 0,
            time_used_seconds INTEGER NOT NULL DEFAULT 0,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          )
        SQL
      end

      def current_time_ms
        (Process.clock_gettime(Process::CLOCK_REALTIME) * 1000).to_i
      end
    end
  end
end
