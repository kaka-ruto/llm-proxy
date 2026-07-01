# llm-proxy

> **For Research Purposes Only**

A Ruby HTTP proxy that exposes any LLM provider through multiple wire protocols simultaneously. Lets you use the same models in **ZCode**, **Codex Desktop**, **Claude Code**, **Cursor**, and any other client, without changing provider configs per tool.

```
                    ┌─────────────────────┐
 ZCode ────────────▶│                     │
 Codex Desktop ────▶│  POST /v1/messages  │── ask-llm-providers ──▶ OpenAI / Anthropic / Google
 Claude Code ──────▶│  POST /v1/responses │                       OpenRouter / OpenCode / ...
 Cursor / Aider ───▶│  POST /v1/chat/comp │
                    └─────────────────────┘
```

## Quick start

```bash
cd ~/Code/ask-rb/llm-proxy
bundle install
cp .env.example .env   # add your API keys

# Start the proxy
ruby bin/llm-proxy server
```

The server starts on `http://127.0.0.1:8765` with models ready to use.

Test it:

```bash
curl http://127.0.0.1:8765/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"Say hello"}]}'
```

## CLI commands

```bash
llm-proxy server            # Start the HTTP proxy (default command)
llm-proxy enable codex      # Install proxy provider into Codex config
llm-proxy enable zcode      # Install proxy provider into ZCode config
llm-proxy enable zcode --model kimi-k2.6   # Use a specific model
llm-proxy disable codex     # Restore Codex to native (ChatGPT)
llm-proxy disable zcode     # Remove proxy provider from ZCode config
llm-proxy login             # ChatGPT OAuth login (opens browser)
llm-proxy -h, --help        # Show help
llm-proxy -v, --version     # Show version
```

## Usage with Codex Desktop

The proxy integrates with Codex as a custom model provider. Enable it:

```bash
llm-proxy enable codex
```

This adds the `[model_providers.llm_proxy]` section to `~/.codex/config.toml` with a bearer token, model, and wire protocol config. Models appear in Codex's model picker automatically.

To restore native ChatGPT:

```bash
llm-proxy disable codex
```

### After a Codex update

If models stop appearing in Codex after an update:

```bash
llm-proxy enable codex    # rewrites the proxy config
# then restart Codex
```

That's it — the proxy config lives in `~/.codex/config.toml` (your user config),
not in the Codex app bundle, so it usually survives updates. If Codex resets
the config.toml during an update, `enable codex` will restore it.

## Usage with Claude Code

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:8765 \
ANTHROPIC_AUTH_TOKEN=ignore \
ANTHROPIC_MODEL=claude-sonnet-4-6 \
CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=true \
claude
```

Or add to `~/.claude/settings.local.json`:
```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8765",
    "ANTHROPIC_AUTH_TOKEN": "ignore"
  }
}
```

## Usage with ZCode

ZCode speaks the Anthropic Messages protocol, which the proxy already serves at `POST /v1/messages`. Enable it:

```bash
llm-proxy enable zcode
```

This adds a custom `"LLM Proxy"` provider to `~/.zcode/v2/config.json` with all models from `config.yml` exposed in ZCode's model picker. The original config is backed up to `.zcode-shim/`.

To use a specific model instead of the default:

```bash
llm-proxy enable zcode --model kimi-k2.6
```

To remove the proxy provider and restore ZCode's original config:

```bash
llm-proxy disable zcode
```

Restart ZCode after enabling or disabling.

## Usage with Cursor / Aider

```bash
# Cursor: Settings → Models → OpenAI Base URL
http://127.0.0.1:8765/v1

# Aider:
aider --openai-api-base http://127.0.0.1:8765/v1 --model kimi-k2.6
```

## Wire protocols

| Endpoint | Format | Client |
|----------|--------|--------|
| `POST /v1/chat/completions` | OpenAI chat completions | Cursor, Aider, open-interpreter |
| `POST /v1/responses` | OpenAI Responses API | Codex Desktop |
| `POST /v1/messages` | Anthropic Messages API | Claude Code CLI, ZCode |
| `POST /api/goals` | Goal management | Codex /goal support |
| `GET /v1/models` | OpenAI models list | Model discovery |
| `GET /health` | Health check | Monitoring |

## Architecture

```
Client request ──▶ Sinatra route ──▶ Protocol.normalize() ──▶ Ask::Agent::Chat
                    │                                              │
                    │    Protocol.chunk_events() ◀── streaming ◀───┘
                    │
                    ▼
            SSE stream back to client
```

- **Protocols** (`lib/llm_proxy/protocols/`) translate wire format ↔ unified format
- **Ask::Agent::Chat** routes to providers and handles streaming
- **Config** (`config.yml`) defines which models to expose
- **ask-llm-providers** handles provider routing (OpenAI, Anthropic, DeepSeek, OpenRouter, OpenCode, etc.)

## Adding models

Edit `config.yml`:

```yaml
models:
  - id: my-model
    provider: openai              # any ask-llm-providers provider key
    display_name: "My Model"
    context_window: 128000
    max_tokens: 4096
    capabilities: [tools, streaming, reasoning, vision]
```

Supported providers: `openai`, `anthropic`, `deepseek`, `openrouter`, `opencode`, `opencode_go`, `gemini`, `xai`, `mistral`, `groq`, `ollama`, and more (via ask-llm-providers).

## API keys

Keys go in `.env` (gitignored). The proxy delegates credential resolution to `ask-auth` — it reads from `~/.config/ask-rb/auth.json`, `~/.auth.json`, or env vars automatically.

Common env vars:

```bash
OPENCODE_API_KEY=sk-...    # https://opencode.ai/zen
OPENROUTER_API_KEY=sk-...  # https://openrouter.ai/keys
DEEPSEEK_API_KEY=sk-...    # DeepSeek direct
ANTHROPIC_API_KEY=sk-...   # Anthropic direct
```

## Logging

All requests are logged to `logs/development.log` with full request/response details:

```
POST /v1/responses
  Headers: {...}
  Body: {"model":"deepseek-v4-flash",...}
  model=deepseek-v4-flash (opencode_go) msgs=1 tools=0
  Starting stream...
  Streamed 50 events...
  Streamed 433 events total
  Usage: {input: 84, output: 433}
  Finish reason: stop
  => 200 (5621.9ms)
```

## Project layout

```
llm-proxy/
├── bin/
│   ├── llm-proxy              # CLI entry point
│   ├── test                   # Rails-style test runner
│   ├── codex-with-proxy       # Launch llm-proxy + Codex
│   └── codex-without-proxy    # Launch Codex natively
├── config.yml                 # Model definitions
├── .env                       # API keys (gitignored)
├── logs/development.log       # Request log
├── .codex-shim/               # Codex config backup (gitignored)
├── .zcode-shim/               # ZCode config backup (gitignored)
└── lib/
    ├── llm_proxy.rb           # Entry point
    └── llm_proxy/
        ├── server.rb          # Sinatra HTTP server
        ├── cli.rb             # CLI command dispatch
        ├── codex.rb           # Codex config.toml integration
        ├── zcode.rb           # ZCode config.json integration
        ├── config.rb          # YAML config loader
        ├── model_catalog.rb   # Model lookup / OpenAPI format
        ├── goals.rb           # Codex /goal persistence
        ├── auth.rb            # ChatGPT OAuth login (PKCE)
        └── protocols/
            ├── base.rb                   # Protocol base class
            ├── openai_completions.rb     # POST /v1/chat/completions
            ├── openai_responses.rb       # POST /v1/responses (Codex)
            └── anthropic_messages.rb     # POST /v1/messages (Claude Code, ZCode)
```

## Dependencies

- Ruby 3.2+
- Ask ecosystem: `ask-core`, `ask-agent`, `ask-llm-providers`, `ask-tools`, `ask-schema`, `ask-auth`
- Sinatra ~> 4.0
- Puma ~> 6.0

## License

MIT
