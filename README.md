# ask-sandbox-providers

[![Gem Version](https://badge.fury.io/rb/ask-sandbox-providers.svg)](https://badge.fury.io/rb/ask-sandbox-providers)

Sandbox providers for the ask-rb ecosystem. Isolated code execution via four backends:

| Provider | Isolation | Speed | Requirement |
|---|---|---|---|
| `Local` | Process + rlimits (CPU, memory, processes, file size) | Instant | None (stdlib) |
| `Docker` | Full container (read-only rootfs, no network, no capabilities) | ~1s | Docker daemon |
| `Daytona` | Remote container via Daytona API | ~2-5s | `daytona` gem, API key |
| `Cloudflare` | Cloudflare Workers sandbox via proxy Worker | ~1-3s | Proxy Worker URL |

## Installation

```ruby
gem "ask-sandbox-providers"
```

## Quick Start

```ruby
require "ask-sandbox-providers"

# Default: Local (subprocess + rlimits on macOS/Linux)
result = Ask::Sandbox.provider.call(["ruby", "-e", "puts 1+1"])
puts result.stdout  # => "1\n"
puts result.exit_code  # => 0
puts result.timed_out  # => false
```

### Configure a different provider

```ruby
# Docker (requires Docker daemon)
Ask::Sandbox.provider = Ask::Sandbox::Docker.new(
  image: "ruby:3.4-alpine",
  memory: "256m",
  network: false
)

# Daytona (requires `daytona` gem + API key)
Ask::Sandbox.provider = Ask::Sandbox::Daytona.new(
  api_key: Ask::Auth.lookup("DAYTONA_API_KEY"),
  server_url: "https://api.daytona.io"
)

# Cloudflare (requires a deployed proxy Worker)
Ask::Sandbox.provider = Ask::Sandbox::Cloudflare.new(
  worker_url: "https://sandbox-proxy.my-worker.workers.dev",
  auth_token: ENV["CLOUDFLARE_SANDBOX_TOKEN"]
)
```

### String vs Array commands

```ruby
# String → executed via shell (bash -c)
Ask::Sandbox.provider.call("ls -la | head -5")

# Array → executed directly, no shell (safer for untrusted input)
Ask::Sandbox.provider.call(["ruby", "-e", "puts ENV['HOME']"])
```

### Return value

All providers return an `Ask::Sandbox::Result`:

```ruby
Result = Data.define(:stdout, :stderr, :exit_code, :timed_out)
```

## Provider Details

### Local

The default provider. Runs commands in a temp directory with:

- **Process group isolation** — all child processes are killed on timeout
- **`Process.setrlimit`** — CPU (10s), address space (2GB), processes (50), file size (10MB), FDs (200)
- **Temp directory** — execution sandbox is auto-cleaned
- **Environment sanitization** — Bundler/Ruby env vars stripped

Available on every platform where Ruby runs (macOS, Linux). Zero external dependencies.

### Docker

Runs commands in a Docker container with security hardening:

- `--read-only` — read-only root filesystem
- `--cap-drop ALL` — no Linux capabilities
- `--security-opt no-new-privileges` — no privilege escalation
- `--network none` — no network egress (configurable)
- `--memory`, `--cpus`, `--pids-limit` — resource limits
- `--rm` — auto-cleanup on exit

### Daytona

Runs commands in a Daytona sandbox via the official `daytona` gem. Daytona provides secure, elastic sandboxes with full isolation, dedicated kernel, filesystem, and network stack. See [daytona.io/docs](https://www.daytona.io/docs).

### Cloudflare

Runs commands in a Cloudflare Workers sandbox. Requires deploying a proxy Worker that wraps `@cloudflare/sandbox`. See the [Cloudflare Sandbox SDK docs](https://developers.cloudflare.com/sandbox/) for setup.

## Migration from Direct Open3 Usage

If you're upgrading from `ask-tools-shell` v0.1.0 where `Code` and `Bash` tools called
`Open3.popen3` directly — no action needed. The default `Ask::Sandbox::Local` provider
behaves identically. To enable stronger isolation, switch the provider:

```ruby
# Before: direct Open3 (implicit Local)
Ask::Tools::Code.new.call(code: "puts 1")

# After: configure Docker for stronger isolation
Ask::Sandbox.provider = Ask::Sandbox::Docker.new
# The Code tool now runs code inside a Docker container automatically
```

## Development

```bash
git clone https://github.com/ask-rb/ask-sandbox-providers.git
cd ask-sandbox-providers
bundle install
bundle exec rake test
```

## License

MIT
