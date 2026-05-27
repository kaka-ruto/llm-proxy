# llm-proxy

> **For Research Purposes Only**

A Ruby HTTP proxy that exposes any LLM provider through multiple wire protocols simultaneously. Lets you use the same models in **Codex Desktop**, **Claude Code**, **Cursor**, and any other client, without changing provider configs per tool.

Built on [RubyLLM](https://rubyllm.com) — one API for 15+ providers.

```
                    ┌─────────────────────┐
 Codex Desktop ────▶│  POST /v1/responses │
 Claude Code ──────▶│  POST /v1/messages  │── RubyLLM ──▶ OpenAI / Anthropic / Google
 Cursor / Aider ───▶│  POST /v1/chat/comp │              OpenRouter / OpenCode / ...
                    └─────────────────────┘
```

## Quick start

```bash
cd ~/Code/Anywaye/llm-proxy
bundle install
cp .env.example .env   # add your API keys

# Start the proxy
ruby bin/llm-proxy server
```

The server starts on `http://127.0.0.1:8765` with models ready to use.

## Models included (22 via config.yml)

| Provider | Models | Source |
|----------|--------|--------|
| **Mimo Direct** | MIMO V2.5 Pro (free) | `token-plan-sgp.xiaomimimo.com/v1` |
| **OpenCode Go** | Kimi K2.5/2.6, DeepSeek V4 Flash/Pro, Qwen 3.5+/3.6+, GLM-5, MIMO V2.5, MiniMax M2.7 | `opencode.ai/zen/go/v1` |
| **OpenCode Zen** | Claude Sonnet 4/4.6, Opus 4.5/4.7, Haiku 4.5, Gemini 3 Flash, DeepSeek V4 Flash Free | `opencode.ai/zen/v1` |
| **OpenRouter** | GPT-4o, Claude Sonnet 4.6/Opus 4.7, DeepSeek V4 Flash, Gemini 3 Flash | `openrouter.ai/api/v1` |

## CLI commands

```bash
llm-proxy server            # Start the HTTP proxy (keep running)

llm-proxy enable            # Install proxy provider into Codex config
llm-proxy disable           # Restore Codex to native (ChatGPT)
llm-proxy toggle            # Switch between proxy and native

llm-proxy codex launch      # Quit Codex, enable proxy, relaunch
llm-proxy codex patch       # Patch Codex ASAR for custom model picker

llm-proxy re-patch          # Restore latest backup then re-patch (after Codex update)
llm-proxy restore           # Restore latest backup (from backups/<build>/)
llm-proxy restore latest    # Same as above (explicit)
llm-proxy restore oldest    # Factory reset — restore first-ever pre-patch original
llm-proxy restore <build>   # Restore a specific backup by Codex build number

llm-proxy backup            # Save current Codex app.asar (for rollback)
llm-proxy backups           # List saved backups
llm-proxy delete-backup <build>  # Remove a backup
llm-proxy delete-backup --all    # Remove all backups

llm-proxy catalog           # Generate the Codex model catalog JSON

llm-proxy login             # ChatGPT OAuth login (opens browser)
llm-proxy logout            # Clear ChatGPT OAuth token
llm-proxy status            # Show ChatGPT login status
```

## Backup & rollback workflow

```bash
# Before updating Codex — save the working state
llm-proxy backup

# After Codex update — patch and enable the new version
llm-proxy patch
llm-proxy enable

# If the new Codex breaks custom models — roll back
llm-proxy restore           # restores latest backup (auto-saved before each patch)

# If latest backup is also broken — restore an older specific build
llm-proxy backups           # list available builds
llm-proxy restore 3044      # restore a known-good build

# If you want to start completely fresh — factory reset
llm-proxy restore oldest    # back to the very first original ASAR
```

## Usage with Codex Desktop

The proxy integrates with Codex as a custom model provider. Enable it:

```bash
llm-proxy enable
```

This adds the `[model_providers.llm_proxy]` section to `~/.codex/config.toml` and generates a model catalog with 21 proxy models.

**If the Codex model picker only shows "Custom"**, the ASAR patch is needed:

```bash
llm-proxy codex patch
```

This patches Codex's bundled JS to allow custom models in the picker. Re-apply after each Codex update.

****If a Codex update breaks custom models**, roll back with `re-patch`:

```bash
llm-proxy re-patch          # restore latest backup and re-patch
llm-proxy enable            # regenerate model catalog
```

This restores from the last auto-backup (taken before `patch` modified the ASAR)
and re-applies the patches. If the new Codex version itself is incompatible,
you can restore a specific older build:

```bash
llm-proxy backups           # list available
llm-proxy restore 3044      # restore a known working build
```


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
| `POST /v1/messages` | Anthropic Messages API | Claude Code CLI |
| `GET /v1/models` | OpenAI models list | Model discovery |
| `GET /health` | Health check | Monitoring |

## Architecture

```
Client request ──▶ Sinatra route ──▶ Protocol.normalize() ──▶ RubyLLM.chat()
                    │                                              │
                    │    Protocol.chunk_events() ◀── streaming ◀───┘
                    │
                    ▼
            SSE stream back to client
```

- **Protocols** (`lib/llm_proxy/protocols/`) translate wire format ↔ unified format
- **RubyLLM** routes to providers and handles streaming
- **Config** (`config.yml`) defines which models to expose
- **OpenCode Go/Zen providers** registered automatically at startup

## Adding models

Edit `config.yml`:

```yaml
models:
  - id: my-model
    provider: openai              # any RubyLLM provider key
    display_name: "My Model"
    context_window: 128000
    max_tokens: 4096
    capabilities: [tools, streaming, reasoning, vision]
```

Supported providers (via RubyLLM): `openai`, `anthropic`, `google`, `openrouter`, `deepseek`, `xai`, `mistral`, `groq`, `bedrock`, `ollama`, `perplexity`, `azure`, `vertexai`, `gpustack`, plus `opencode` and `opencode_go`.

## Adding a custom provider

```ruby
# lib/llm_proxy/providers/my_provider.rb
class RubyLLM::Providers::MyProvider < RubyLLM::Providers::OpenAI
  def api_base; "https://my-provider.com/v1"; end
  def headers; { "Authorization" => "Bearer #{@config.my_provider_api_key}" }; end
end
RubyLLM::Provider.register :my_provider, RubyLLM::Providers::MyProvider
```

Then reference it in `config.yml` with `provider: my_provider`.

## API keys

Keys go in `.env` (gitignored):

```bash
OPENCODE_API_KEY=sk-...    # https://opencode.ai/zen
OPENROUTER_API_KEY=sk-...  # https://openrouter.ai/keys
ANTHROPIC_API_KEY=sk-...   # direct Anthropic access
OPENAI_API_KEY=sk-...      # direct OpenAI access
```

```bash
MIMO_API_KEY=tp-...              # XiaomiMiMo free key (mimo-v2.5-pro)
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
  complete_events count=6
  response.completed output items=2
  => 200 (5621.9ms)
```

## Project layout

```
llm-proxy/
├── bin/llm-proxy              # CLI entry point
├── config.yml                 # Model definitions
├── .env                       # API keys (gitignored)
├── logs/development.log       # Request log
├── .codex-shim/               # Generated catalog, ASAR backups
└── lib/
    ├── llm_proxy.rb           # Entry point
    └── llm_proxy/
        ├── server.rb          # Sinatra HTTP server
        ├── cli.rb             # CLI command dispatch
        ├── codex.rb           # Codex integration (catalog, patch, backup, enable)
        ├── config.rb          # YAML config loader
        ├── model_catalog.rb   # Model lookup
        ├── auth.rb            # ChatGPT OAuth login (PKCE)
        ├── providers/
        │   ├── opencode.rb    # OpenCode Zen provider for RubyLLM
        │   └── opencode_go.rb # OpenCode Go provider for RubyLLM
        └── protocols/
            ├── base.rb                  # Protocol base class
            ├── openai_completions.rb     # POST /v1/chat/completions
            ├── openai_responses.rb       # POST /v1/responses (Codex)
            └── anthropic_messages.rb     # POST /v1/messages (Claude Code)
```

## Dependencies

- Ruby 3.2+
- RubyLLM ~> 1.14
- Sinatra ~> 4.0
- Puma ~> 6.0

## License

MIT
