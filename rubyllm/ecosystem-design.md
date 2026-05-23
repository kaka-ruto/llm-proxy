# LLM Ruby Ecosystem — Design

## Guiding Principles

1. **Provider owns its protocol** — OpenAI knows how to talk OpenAI. Anthropic knows Anthropic. The provider gem handles its own wire format, not a shared protocol layer.
2. **Conversation + Tools + Streaming are one concept** — A conversation contains tool calls. Streaming delivers conversations. They ship together in `llm-core`.
3. **Auth is part of the provider** — Each provider knows how to authenticate. API keys, OAuth, token refresh — provider-specific.
4. **Schema is the only true shared primitive** — JSON Schema is used by tools AND structured output. It has zero LLM dependencies and stands alone.
5. **Built-in tools separate from agent loop** — bash, read, write, edit, glob, grep are useful with or without an LLM involved. The tool implementations live in `llm-tools`. The agent loop that orchestrates think → call → execute → feed-back lives in `llm-conductor`. They can be used together or independently.
6. **Agent loop stays in one gem** — Think → act → observe → repeat is a single coherent concept. Splitting the loop, tool executor, hooks, and compaction across gems loses the integration value.
7. **No required database** — In-memory persistence is the default. ActiveRecord is an optional adapter. The core conductor works without any database.

## Gem Map

```
                           Application
                    (Codex, Claude Code, Pi, web apps)
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                    │
          ▼                    ▼                    ▼
    ┌──────────┐        ┌──────────┐         ┌──────────┐
    │ llm-core  │        │ llm-tools │         │ llm-conductor │
    │           │        │           │         │              │
    │ Provider  │        │ bash      │         │ Agent loop   │
    │ interface │        │ read      │         │ Tool executor│
    │           │        │ write     │         │ Compaction   │
    │ Conver-   │        │ edit      │         │ Hooks        │
    │ sation    │        │ glob      │         │ Session mgmt │
    │           │        │ grep      │         │ Telemetry    │
    │ Streaming │        │           │         │ Persistence  │
    │           │        │ (No agent │         │ (in-memory + │
    │ Auth      │        │  concepts)│         │  AR optional)│
    │ (API key, │        │           │         │              │
    │  OAuth)   │        │ Depends   │         │ Depends on:  │
    │           │        │ on:       │         │ llm-core     │
    │ (Zero     │        │ llm-core  │         │ llm-tools    │
    │  deps)    │        │           │         │ llm-* providers│
    └──────────┘        └──────────┘         └──────────────┘
            │                │                       │
            └────────────────┴───────────────────────┘
                              │
                     ┌────────▼────────┐
                     │   llm-schema     │
                     │  JSON Schema DSL │
                     │  (zero deps)     │
                     └─────────────────┘
                              │
                     ┌────────▼────────┐
                     │  llm-test        │
                     │  VCR matchers,   │
                     │  eval helpers    │
                     └─────────────────┘
```

## `llm-core` — Foundation (zero dependencies)

The only gem every LLM app must depend on.

```ruby
# Conversation — message history with role mapping and tool call support
LLM::Conversation.new
  .add_message(:user, "hello")
  .add_message(:assistant, tool_calls: [{ id: "call_1", name: "get_weather", arguments: {} }])
  .to_a  # [{role: "user", content: "hello"}, {role: "assistant", tool_calls: [...]}]

# ToolDefinition — full JSON Schema for tools
LLM::ToolDefinition.new(
  name: "get_weather",
  description: "Get weather for a city",
  schema: { type: "object", properties: { city: { type: "string" } }, required: ["city"] }
)

# Provider interface — each provider implements this
class MyProvider < LLM::Provider
  def chat(conversation, tools: [], model: nil, stream: nil)
    # Returns LLM::Stream
  end
end

# Streaming — parse and generate SSE
LLM::Stream.from_enumerator(enumerator)
stream.each { |event| ... }

# Auth — API key and OAuth helpers
LLM::Auth::ApiKey.new("sk-...", env: "OPENAI_API_KEY")
LLM::Auth::OAuth.new(client_id: "...", token_url: "...")
```

## Provider gems — one per provider

### `llm-provider-openai`

```ruby
provider = LLM::Provider::OpenAI.new(api_key: "sk-...")

# Chat completions (Cursor, Aider)
provider.chat(conversation, tools:, model: "gpt-4o")

# Responses API (Codex Desktop)
provider.responses(conversation, tools:, model: "gpt-5.5")

# Custom base URL for OpenRouter, LiteLLM, etc.
LLM::Provider::OpenAI.new(api_key: "...", base_url: "https://openrouter.ai/api/v1")
```

OpenCode Go/Zen are lightweight subclasses with different base URLs.
ChatGPT OAuth is a specialized subclass handling PKCE + chatgpt.com transport.

### `llm-provider-anthropic`

```ruby
provider = LLM::Provider::Anthropic.new(api_key: "sk-ant-...")
provider.chat(conversation, tools:, thinking: { effort: :high })
```

## `llm-schema` — JSON Schema DSL (zero dependencies)

```ruby
schema = LLM::Schema.define do
  string :name, desc: "Name"
  number :price
  any_of :contact do
    string :email
    string :phone
  end
end
```

## `llm-tools` — Built-in coding tools (no agent concepts)

Tool definitions + implementations. Useful with or without an LLM.

```ruby
# Standalone use — no LLM, no agent loop
tool = LLM::Tools::Bash.new
result = tool.call(cmd: "ls -la")

# As tool definitions for an LLM provider
provider.chat(conversation, tools: LLM::Tools.all)

# As tools for conductor's agent loop
LLM::Conductor::Session.new(tools: LLM::Tools.all)
```

## `llm-conductor` — Agent loop + session management

Kept as ONE gem because the agent loop, tool execution, context compaction, and hooks are tightly integrated. Splitting them would create cross-gem coupling that's harder to maintain than one coherent gem.

```ruby
agent = LLM::Conductor::Session.new(
  model: "deepseek-v4-flash",
  provider: :opencode_go,
  tools: LLM::Tools.all
)

agent.run("List files in /tmp") do |event|
  case event
  in LLM::Conductor::Events::ToolCalled(name:, arguments:)
    # Tool was called
  in LLM::Conductor::Events::Chunk(content:)
    out << content
  end
end
```

| Component | Lives in | Why |
|-----------|----------|-----|
| Tool DEFINITIONS (bash, read, etc.) | `llm-tools` | Useful without LLM |
| Tool EXECUTORS (bash, read, etc.) | `llm-tools` | Useful without LLM |
| Agent loop | `llm-conductor` | Core orchestration |
| Tool executor (parallel/sequential) | `llm-conductor` | Coupled to loop |
| Hooks (before/after tool) | `llm-conductor` | Loop lifecycle |
| Compactor (context management) | `llm-conductor` | Conductor-specific |
| Session + telemetry | `llm-conductor` | Public API |
| Persistence (in-memory + AR optional) | `llm-conductor` | Session lifecycle |
| Provider interface + Conversation | `llm-core` | Foundation |
| Provider implementations | Provider gems | One per provider |

## When you use each combination

| Use case | Gems needed | Agent loop? | DB? |
|----------|------------|-------------|-----|
| Simple chatbot (no tools) | `llm-core` + provider | No | No |
| One-shot LLM with tools | `llm-core` + `llm-tools` + provider | No | No |
| Batch script (tools, no LLM) | `llm-tools` only | No | No |
| Coding assistant (web or terminal) | `llm-core` + `llm-tools` + conductor + provider | Yes | Optional |
| Long-running agent with persistence | `llm-core` + `llm-tools` + conductor + provider | Yes | Optional (AR adapter) |
| Rails app with chat history | `llm-core` + conductor + Rails AR adapter | Optional | Yes (via Rails) |

## How llm-proxy would look with this

```ruby
post "/v1/responses" do
  request = LLM::Provider::OpenAI::Responses.parse(http_request.body)
  conversation = request.to_conversation

  stream = if request.model.start_with?("gpt-")
    chatgpt_provider.chat(conversation, tools: request.tools, model: request.model)
  else
    opencode_provider.chat(conversation, tools: request.tools, model: request.model)
  end

  LLM::Provider::OpenAI::Responses.serialize(stream)
end
```

## Migration path

1. Extract `lib/llm_proxy/protocols/` types → `llm-core`
2. Extract `lib/llm_proxy/providers/` → `llm-provider-opencode`
3. Extract `lib/llm_proxy/auth.rb` → `llm-core` OAuth
4. `ruby_llm-conductor` tools → `llm-tools`
5. `ruby_llm-conductor` agent loop stays in conductor, depends on `llm-core` + `llm-tools` + providers
