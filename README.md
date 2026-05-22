# llm-proxy

A Ruby HTTP proxy that exposes any LLM provider (OpenAI, Anthropic, Google, OpenRouter, OpenCode Go/Zen, etc.) through multiple wire protocols simultaneously. Lets you use the same models in **Codex Desktop**, **Claude Code**, **Cursor**, and any other client, without changing provider configs per tool.

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

# Set your API keys
export OPENCODE_API_KEY="your-key-from-https://opencode.ai/zen"
export OPENROUTER_API_KEY="your-key-from-https://openrouter.ai/keys"

# Start the proxy
ruby bin/llm-proxy
```

The server starts on `http://127.0.0.1:8765` with 20+ models ready to use.

## Usage with different clients

### Codex Desktop

```bash
codex -c model_providers.llm-proxy.name="LLM Proxy" \
      -c model_providers.llm-proxy.base_url="http://127.0.0.1:8765/v1" \
      -c model_providers.llm-proxy.wire_api="responses" \
      -c model_providers.llm-proxy.experimental_bearer_token="dummy" \
      -c model="kimi-k2.6"
```

Or use the generated catalog at `file:///Users/kaka/Code/Cowork/codex-shim/.codex-shim/custom_model_catalog.json` and point Codex at the proxy.

### Claude Code

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
    "ANTHROPIC_AUTH_TOKEN": "ignore",
    "ANTHROPIC_MODEL": "claude-sonnet-4-6"
  }
}
```

### Cursor / Aider / open-interpreter

Point to the OpenAI-compatible endpoint:
```bash
# Cursor: Settings → Models → OpenAI Base URL
http://127.0.0.1:8765/v1

# Aider:
aider --openai-api-base http://127.0.0.1:8765/v1 --model kimi-k2.6
```

## Wire protocols

| Endpoint | Format | Client |
|----------|--------|--------|
| `POST /v1/chat/completions` | OpenAI chat completions | Cursor, Aider, open-interpreter, most tools |
| `POST /v1/responses` | OpenAI Responses API | Codex Desktop |
| `POST /v1/messages` | Anthropic Messages API | Claude Code CLI |

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

Supported providers (via RubyLLM): `openai`, `anthropic`, `google`, `openrouter`, `deepseek`, `xai`, `mistral`, `groq`, `bedrock`, `ollama`, `perplexity`, `azure`, `vertexai`, `gpustack`, plus `opencode` and `opencode_go` (registered by this project).

## Architecture

```
Client request ──▶ Sinatra route ──▶ Protocol.normalize() ──▶ RubyLLM.chat()
                    │                                              │
                    │    Protocol.chunk_events() ◀── streaming ◀───┘
                    │
                    ▼
            SSE stream back to client
```

- **Protocols** translate wire format ↔ unified format
- **RubyLLM** routes to providers and handles streaming
- **Config** defines which models to expose
- Adding a new protocol = subclass `Protocols::Base` + register in server

## Custom providers

RubyLLM supports custom OpenAI-compatible providers:

```ruby
# lib/llm_proxy/providers/my_provider.rb
class RubyLLM::Providers::MyProvider < RubyLLM::Providers::OpenAI
  def api_base; "https://my-provider.com/v1"; end
  def headers; { "Authorization" => "Bearer #{@config.my_provider_api_key}" }; end
end
RubyLLM::Provider.register :my_provider, RubyLLM::Providers::MyProvider
```

Then reference it in `config.yml` with `provider: my_provider`.
