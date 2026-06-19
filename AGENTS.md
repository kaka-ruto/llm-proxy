# LLM Proxy - Agent Notes

## Response Logging

When debugging Codex session issues, the proxy logs outgoing SSE events at INFO level:

- `TOOL_ARGS_DONE` - final tool call arguments (truncated to 500 chars)
- `TOOL_ARGS_DELTA` - streaming delta of tool call arguments (DEBUG level, truncated)
- `RESPONSE_COMPLETED tool=<name> args=<truncated>` - tool calls in completed response
- `RESPONSE_COMPLETED text=<truncated>` - text content in completed response
- `TEXT_DONE` - final assistant text content
- `NONSTREAM tool=<name> args=<truncated>` - non-streaming tool call response
- `NONSTREAM text=<truncated>` - non-streaming text response
- `SSE_ERROR` - error events sent to client

Request bodies are logged at DEBUG level with API keys redacted.

## Codex Data Storage

Codex stores session data in `~/.codex/sqlite/`:
- `state_5.sqlite` - threads table (metadata only, no messages)
- `logs_2.sqlite` - application logs
- Conversation messages are NOT persisted - only available in memory during the session

Session window IDs from proxy `X-Codex-Window-Id` headers may differ from thread IDs in the database.

## Running

```bash
bundle exec ruby -e "require_relative 'lib/llm_proxy'; LLMProxy.run"
```

Listens on 127.0.0.1:8765 by default (configurable in config.yml).
