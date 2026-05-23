# RubyLLM Issues Found During llm-proxy Development

This document catalogs issues discovered in [RubyLLM](https://rubyllm.com) v1.15.0 while building `llm-proxy`, a universal LLM proxy that forwards tool calls between coding agents (Codex Desktop, Claude Code, Cursor) and upstream providers via RubyLLM.

---

## 1. `Tool#name` returns empty string for anonymous classes

**File:** `lib/ruby_llm/tool.rb:68-77`

```ruby
def name
  klass_name = self.class.name
  normalized = klass_name.to_s.dup.force_encoding('UTF-8').unicode_normalize(:nfkd)
  # ...
end
```

When a tool is created with `Class.new(RubyLLM::Tool)`, `self.class.name` returns `nil` because the class is anonymous. Calling `.to_s` on `nil` gives `""`, so the tool name sent to providers is an empty string. Providers like DeepSeek reject empty tool names with `Invalid 'tools[0].function.name': empty string`.

**Workaround:** Override `name` on each instance:

```ruby
klass = Class.new(RubyLLM::Tool) { ... }
klass.define_method(:name) { "my_tool" }
```

**Suggested fix:** Allow setting a tool name via a class-level DSL:

```ruby
class MyTool < RubyLLM::Tool
  tool_name "my_tool"
  # ...
end
```

Or fall back to a configured name when `self.class.name` is nil:

```ruby
def name
  @tool_name || begin
    klass_name = self.class.name
    # ... existing logic
  end
end
```

---

## 2. `params(schema:)` wraps hash schema in a `"schema"` key

**File:** `lib/ruby_llm/tool.rb:226-268`

When using `params(schema: { type: "object", properties: {...} })`, the `SchemaDefinition` stores the schema hash in `@schema`. When `json_schema` resolves it via `resolve_direct_schema`, the code path for a plain `Hash` does:

```ruby
return RubyLLM::Utils.deep_dup(schema) if schema.is_a?(Hash)
```

However, `deep_stringify_keys` in `json_schema` produces `{"schema" => {actual_schema}}` instead of `{actual_schema}`. The resulting `params_schema` returned by the tool wraps the real schema in a `"schema"` key.

The OpenAI provider then sends to the API:

```json
{
  "parameters": {
    "schema": {
      "type": "object",
      "properties": {}
    }
  }
}
```

The API rejects this with `schema must be a JSON Schema of 'type: "object"', got 'type: null'` because it reads `"schema"` as a property name, not the schema itself.

**Workaround:** Bypass the `params` class method entirely and set `@params_schema_definition` directly:

```ruby
klass = Class.new(RubyLLM::Tool) { ... }
sd = RubyLLM::Tool::SchemaDefinition.new(schema: my_schema)
klass.instance_variable_set(:@params_schema_definition, sd)
```

**Suggested fix:** In `SchemaDefinition#resolve_direct_schema`, the `extract_schema` method handles the `"schema"` key unwrapping but is only called from the `to_json_schema` path, not the plain Hash path. The Hash path should also unwrap:

```ruby
def resolve_direct_schema(schema)
  return extract_schema(schema.to_json_schema) if schema.respond_to?(:to_json_schema)
  return RubyLLM::Utils.deep_dup(schema) if schema.is_a?(Hash)
  # ...
end
```

should become:

```ruby
def resolve_direct_schema(schema)
  return extract_schema(schema.to_json_schema) if schema.respond_to?(:to_json_schema)
  return extract_schema(schema) if schema.is_a?(Hash)
  # ...
end
```

---

## 3. `param` DSL can't represent complex JSON Schema features

**File:** `lib/ruby_llm/tool.rb:45-51`

The `param` class method only supports simple types:

```ruby
def param(name, type: 'string', desc: nil, description: nil, required: true)
  @parameters[name] = Parameter.new(name, type:, description: desc || description, required:)
end
```

This can't represent:
- `anyOf`, `oneOf`, `allOf` (union types)
- `$ref` (schema references)
- Nested objects with `properties`
- Arrays with specific `items` schemas
- `additionalProperties`
- `enum` values
- `minimum`/`maximum` constraints
- `pattern` validation
- `default` values

Coding agents like Codex Desktop send tool definitions with these complex schemas. When flattened through `param`, the definitions become incorrect and the model produces malformed tool calls (e.g., passing `cMs -ls` as a key name instead of `cmd`).

**Workaround:** Use `params(schema:)` via the direct `instance_variable_set` approach (see Issue #2), which preserves the full JSON Schema.

**Suggested fix:** Add a class-level `schema` DSL that accepts a full JSON Schema hash:

```ruby
class MyTool < RubyLLM::Tool
  description "Does a thing"
  schema({
    type: "object",
    properties: {
      cmd: { type: "string", description: "Command to run" },
      workdir: { anyOf: [{ type: "string" }, { type: "null" }] }
    },
    required: ["cmd"]
  })
end
```

Or ensure `params(schema:)` works correctly (fix Issue #2) so users can pass full schemas.

---

## 4. `ToolCall#arguments` can be a raw JSON string (not a Hash)

**File:** `lib/ruby_llm/providers/openai/tools.rb:83-101`

When `parse_arguments: false` (used during streaming), `ToolCall#arguments` is a raw JSON string:

```ruby
ToolCall.new(
  id: tc['id'],
  name: tc.dig('function', 'name'),
  arguments: if parse_arguments
               parse_tool_call_arguments(tc)  # Returns a Hash
             else
               tc.dig('function', 'arguments')  # Returns a String
             end,
)
```

This is non-obvious from the public API. Code that accesses `tool_call.arguments` must handle both cases:

```ruby
arg_text = tc.arguments.is_a?(String) ? tc.arguments : JSON.generate(tc.arguments)
```

**Suggested fix:** Normalize `arguments` to always return a Hash, or provide a consistent accessor:

```ruby
class ToolCall
  def arguments
    @arguments.is_a?(String) ? (JSON.parse(@arguments) rescue @arguments) : @arguments
  end

  def arguments_raw
    @arguments
  end
end
```

---

## 5. No API to replay conversation history with tool_calls

When building conversation history (e.g., forwarding a conversation between clients), there's no easy way to add an assistant message that contains `tool_calls`. The `chat.add_message` method accepts arbitrary attributes, but tool_calls need to be in the correct RubyLLM internal format.

The `Message` constructor accepts `tool_calls` as an option:

```ruby
# message.rb
@tool_calls = options[:tool_calls]
```

But the provider serialization code expects `tool_calls` to be a Hash of `ToolCall` objects (keyed by ID), not an Array or other format. This is undocumented.

**Workaround:** Skip tool_calls in conversation replay and convert them to text descriptions:

```ruby
if msg[:tool_calls] && !msg[:content]
  tool_text = msg[:tool_calls].map { |tc|
    fn = tc[:function] || tc
    "[Called tool: #{fn[:name] || tc[:name]} with args: #{fn[:arguments] || tc[:arguments]}]"
  }.join("\n")
  chat.add_message(role: :assistant, content: tool_text)
elsif role == :tool
  chat.add_message(role: :user, content: "[Tool result: #{msg[:content]}]")
elsif msg[:content]
  chat.add_message(role: role, content: msg[:content])
end
```

**Suggested fix:** Provide a documented API for constructing tool call messages:

```ruby
chat.add_message(
  role: :assistant,
  content: nil,
  tool_calls: {
    "call_1" => RubyLLM::ToolCall.new(id: "call_1", name: "get_weather", arguments: { city: "Paris" })
  }
)
```

---

## 6. Empty parameter schemas lack `type: "object"`

**File:** `lib/ruby_llm/providers/openai/tools.rb:13-16`

```ruby
EMPTY_PARAMETERS_SCHEMA = {
  'type' => 'object',
  'properties' => {},
  'additionalProperties' => false,
  'strict' => true
}.freeze
```

This fallback is used when a tool has no parameters. However, when a tool HAS parameters but they're defined through the `param` DSL with zero parameters, `schema_from_parameters` produces `{}` (empty hash) because `from_parameters` returns `nil` when parameters are empty and `allow_empty` is false. This empty hash is then passed directly to the API, which rejects it.

**Suggested fix:** Always use `EMPTY_PARAMETERS_SCHEMA` or a fallback with `type: "object"` when the resolved schema is empty or lacks `type`.

---

## Summary

| # | Issue | Severity | Fix Difficulty |
|---|-------|----------|----------------|
| 1 | `Tool#name` empty for anonymous classes | **High** | Easy |
| 2 | `params(schema:)` wraps in `"schema"` key | **High** | Medium |
| 3 | `param` DSL can't represent complex schemas | **Medium** | Hard (needs new DSL) |
| 4 | `ToolCall#arguments` type inconsistency | **Medium** | Easy |
| 5 | No documented API for tool_call message replay | **Medium** | Medium |
| 6 | Empty parameter schemas may lack `type` | **Low** | Easy |
