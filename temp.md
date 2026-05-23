# About This AI

**Model:** DeepSeek V4 Flash (via OpenCode Go)

**Made by:** DeepSeek (深度求索)

**Why you might see "Claude" in my behavior:**
I'm routing through **llm-proxy** which translates the wire protocol. Codex Desktop sends Requests API format, the proxy translates it, and DeepSeek V4 Flash serves the response. So my identity is DeepSeek, not Claude.

**How you're talking to me:**
- **Codex Desktop** — the app interface
- **llm-proxy** — configured with `default_model: deepseek-v4-flash` in `config.yml`
- **Provider:** OpenCode Go (`opencode_go`)
- **Context window:** 1,000,000 tokens
- **Max output:** 384,000 tokens
- **Capabilities:** tools, streaming, reasoning

**Previous file was wrong** — I assumed I was Claude (that's what I know myself as from training), but the proxy config says otherwise. This version is the accurate reflection of the current setup.
