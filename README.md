# ask-sandbox-providers

[![Gem Version](https://badge.fury.io/rb/ask-sandbox-providers.svg)](https://badge.fury.io/rb/ask-sandbox-providers)

Sandbox providers for the ask-rb ecosystem: isolated code execution with a single interface and four backends. The default Local provider needs nothing; Docker, Daytona, and Cloudflare add stronger or remote isolation.

## Installation

```ruby
gem "ask-sandbox-providers"
```

## Quick Start

```ruby
require "ask-sandbox-providers"

result = Ask::Sandbox.provider.call(["ruby", "-e", "puts 1 + 1"])
result.stdout     # => "1\n"
result.exit_code  # => 0
result.success?   # => true
```

Commands can be an Array (executed directly, no shell) or a String (executed via `bash -c`). All providers accept `call(command, timeout: 30, workdir: nil, env: {}, stdin: nil)`.

## Choosing a provider

```ruby
Ask::Sandbox.provider = :docker   # symbol shortcuts: :local, :docker, :daytona, :cloudflare

Ask::Sandbox.provider = Ask::Sandbox::Docker.new(image: "ruby:3.4-alpine", memory: "256m", network: false)
```

| Provider | Isolation | Requirement |
|---|---|---|
| `Ask::Sandbox::Local` (default) | Subprocess with rlimits (CPU, memory, processes, file size), caller's working directory (or `workdir:`), sanitized environment | None, stdlib only |
| `Ask::Sandbox::Docker` | Container with read-only rootfs, no capabilities, no network | Docker daemon |
| `Ask::Sandbox::Daytona` | Remote sandbox via the Daytona API | `daytona` gem, API key |
| `Ask::Sandbox::Cloudflare` | Cloudflare Workers sandbox via a proxy Worker | Deployed proxy Worker URL |

Daytona resolves its API key from `Ask::Auth.lookup("DAYTONA_API_KEY")` or `ENV["DAYTONA_API_KEY"]` when `api_key:` is not given. Cloudflare falls back to the `CLOUDFLARE_SANDBOX_WORKER_URL` and `CLOUDFLARE_SANDBOX_AUTH_TOKEN` env vars.

## Result

Every provider returns `Ask::Sandbox::Result`, a `Data` object with `stdout`, `stderr`, `exit_code`, and `timed_out` fields, plus `#success?` (true when `exit_code == 0`).

## Full documentation

The full ask-rb documentation lives at https://ask-rb.github.io/ask-docs. [ask-sandbox-providers in depth](https://ask-rb.github.io/ask-docs/core/sandbox) covers each provider and the hardening details. API reference: https://ask-rb.github.io/ask-docs/reference/api.

## Development

```
bundle install
bundle exec rake test
```

## License

MIT
