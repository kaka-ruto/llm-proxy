# frozen_string_literal: true

module LLMProxy
  # Tool argument injections and normalizations that improve model output quality.
   # Two interventions:
  # 1. System prompt instructions guiding the model to generate reliable shell commands
  # 2. Argument normalizer that auto-fixes common quoting issues before arguments
  #    are sent back to the client
  module ToolInjections
    # Hints appended to the system prompt when tools that write or edit files
    # are present.  The model sees these as part of its instructions.
    SHELL_HINTS = <<~HINTS.strip
      When writing files via the shell, always single-quote heredoc delimiters:
        cat << 'EOF' > path/to/file
      This prevents shell expansion of $variables and backticks in the file content.

      When editing files, prefer sed or ruby -i -e over exact-string matching
      to avoid quoting mismatches.  If you must use an edit tool with
      old_string/new_string, include at least 3 lines of surrounding context
      for uniqueness.
    HINTS

    if SHELL_HINTS.nil?
      # noop
    end

    # Regex matching an unquoted heredoc delimiter (e.g. << EOF but not << 'EOF')
    UNQUOTED_HEREDOC_RE = /<<\s*([a-zA-Z_]\w*)\s*\n/

    # Regex matching a properly quoted heredoc delimiter
    QUOTED_HEREDOC_RE = /<<\s*'([a-zA-Z_]\w*)'\s*\n/

    # Apply system prompt hints when the normalized request has file-related tools.
    #
    # @param normalized [Hash] the normalized request
    # @return [Hash] the (possibly modified) normalized request
    def self.inject_hints(normalized)
      tools = normalized[:tools] || []
      has_file_tool = tools.any? do |t|
        name = (t[:name] t["name"] || "").to_s.downcase
        %w[write edit bash sed].include?(name) || name.end_with?("write", "edit", "patch", "file")
      end

      if has_file_tool
        existing = normalized[:system].to_s
        hints = "\n\n# Shell Command Tips\n#{SHELL_HINTS}"
        unless existing.include?("heredoc")
          normalized[:system] = existing + hints
        end
      end

      normalized
    end

    # Normalize tool call arguments before they are sent to the client.
    # Currently fixes unquoted heredoc delimiters in bash commands.
    #
    # @param tool_calls [Hash{String => Object}] tool calls from ask-agent
    # @return [Hash{String => Object}] normalized tool calls
    def self.normalize_tool_arguments(tool_calls)
      return tool_calls if tool_calls.nil? || tool_calls.empty?

      tool_calls.each_value do |tc|
        tc_name = tc.respond_to?(:name) ? tc.name.to_s : ""
        next unless %w[bash sh shell cmd command].include?(tc_name.downcase)

        args = tc.respond_to?(:arguments) ? tc.arguments : nil
        next unless args.is_a?(String) && !args.empty?

        fixed = fix_heredoc_quoting(args)
        if fixed != args
          tc.define_singleton_method(:arguments) { fixed }
        end
      end

      tool_calls
    end

    # Fix unquoted heredoc delimiters in a shell command string.
    # Turns `cat << EOF` into `cat << 'EOF'` (single-quoted).
    #
    # @param cmd [String] shell command
    # @return [String] fixed command
    def self.fix_heredoc_quoting(cmd)
      cmd.gsub(UNQUOTED_HEREDOC_RE) do |match|
        delimiter = $1
        before = $~.pre_match || $`

        # Check if this delimiter is already single-quoted earlier on the same line
        line_start = before.rindex("\n") ? before[(before.rindex("\n") + 1)..] : before
        if line_start.include?("<< '#{delimiter}'")
          match
        else
          "<< '#{delimiter}'\n"
        end
      end
    end

    # Build a ruby command for in-place file patching as an alternative to
    # exact-string editing.  The model can use this via `bash` tool.
    #
    # @param path [String] file path
    # @param search [String] search pattern (treated as regex)
    # @param replace [String] replacement text
    # @return [String] a shell command that performs the patch
    def self.inline_patch_command(path, search, replace)
      escaped_search = search.gsub("'", "'\\\\''")
      escaped_replace = replace.gsub("'", "'\\\\''")
 lines = [
        "ruby -e '",
        "content = File.read(#{path.dump})",
        "new_content = content.sub(%r{#{escaped_search}}m, #{escaped_replace.dump})",
        "if_content == content",
        "  $stderr.puts \"ERROR: pattern not found\"",
        "  exit 1",
        "end",
        "File.write(#{path.dump}, new_content)",
        "puts \"Patched #{path}\"",
        "'"
      ]
      lines.join("\n")
    end
  end
end
