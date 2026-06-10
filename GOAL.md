# ask-sandbox-providers — Sandbox Providers for the ask-rb Ecosystem

## Purpose

A sandbox provider gem that provides isolated code/shell execution through a unified
interface. Currently supports four backends:

- **Local** — subprocess with `Process.setrlimit` resource limits + process group isolation
- **Docker** — hardened Docker container execution via the `docker` CLI
- **Daytona** — remote sandboxes via the official `daytona` Ruby gem
- **Cloudflare** — Cloudflare Workers sandbox via a user-deployed proxy Worker

This gem is consumed by `ask-tools-shell` (Code and Bash tools) and `ask-agent`
(Session loop). It can also be used standalone by any Ruby script that needs
safe command execution.

## Dependencies

- **Runtime:** Zero. All providers use stdlib only. The Daytona provider optionally
  requires the `daytona` gem (loaded on-demand, not a hard dependency).
- **Build/test:** minitest, mocha, rake
- **This gem MUST wait until `ask-tools` is built, tested, and released.** The
  `ask-tools-shell` migration depends on `Ask::Tool` being available.

## Design Principles

1. **One method, four providers.** Every provider implements `#call(command, ...)`
   which returns `Ask::Sandbox::Result` (a Data.defined value with stdout, stderr,
   exit_code, timed_out).

2. **String vs Array commands.** String commands run via shell (`bash -c`). Array
   commands run execve-style with no shell interpretation. This is a common pattern
   (Open3, Flue, etc.).

3. **Zero deps for Local.** The local provider must use only stdlib. No gems.

4. **Lazy dependency loading.** Daytona and Cloudflare providers load their
   dependencies on `#call`, not at require time. This way the gem installs without
   forcing users to install `daytona` or set up Cloudflare.

5. **Global config with sensible default.** `Ask::Sandbox.provider` defaults to
   `Ask::Sandbox::Local.new`. Users who want stronger isolation swap it.

6. **No filesystem sandboxing.** This gem isolates *execution* only. Filesystem
   operations (Read, Write, Edit, Glob, Grep) remain host-level in
   `ask-tools-shell`. The sandbox is for running untrusted *code*, not for
   restricting file access.

## Implementation Steps

### 1. Define the gem scaffold (already done)
- `lib/ask-sandbox-providers.rb` — entry point with global provider config
- `lib/ask/sandbox/version.rb`
- `lib/ask/sandbox/base.rb` — `Ask::Sandbox::Base` + `Ask::Sandbox::Result`
- `lib/ask/sandbox/local.rb` — stub (implementation below)
- `lib/ask/sandbox/docker.rb` — stub (implementation below)
- `lib/ask/sandbox/daytona.rb` — stub (implementation below)
- `lib/ask/sandbox/cloudflare.rb` — stub (implementation below)
- `ask-sandbox-providers.gemspec` — zero runtime dependencies
- Rakefile, Gemfile, test_helper.rb

### 2. Implement `Ask::Sandbox::Local` (`lib/ask/sandbox/local.rb`)

This is the default provider. It must replicate the current behavior of
`Ask::Tools::Shell::Code` and `Ask::Tools::Shell::Bash` (Open3.popen3 in a temp
directory) while adding resource limits.

**Required behavior:**

```ruby
# String → shell
sandbox.call("ls -la", timeout: 10)
# Array → exec-style (no shell)
sandbox.call(["ruby", "-e", "puts 1+1"])
```

**Implementation details:**

- **Process spawning:** Use `Process.spawn` with `pgroup: true` so all child processes
  belong to a process group that can be killed on timeout.
- **Pipe capturing:** Set up stdin_r/stdin_w, stdout_r/stdout_w, stderr_r/stderr_w
  pipes. Write stdin_data to stdin_w in a thread. Capture stdout/stderr in threads.
- **Timeout handling:** Use `Timeout.timeout` or `Process.waitpid(pid, Process::WNOHANG)`
  in a loop. On timeout, send `-TERM` then `-KILL` to the process group.
- **Temp directory:** Use `Dir.mktmpdir("ask_sandbox")` — same as current tools.
- **Resource limits:** Call `Process.setrlimit` on the child process via
  `Process.setrlimit(type, soft, hard, pid)`:
  - `RLIMIT_CPU`: 10s soft, 30s hard
  - `RLIMIT_NPROC`: max 50 child processes
  - `RLIMIT_FSIZE`: max 10MB file writes
  - `RLIMIT_NOFILE`: max 200 file descriptors
  - `RLIMIT_AS`: max 2GB address space
  - Wrap each in `rescue nil` — some constants may not exist on all platforms.
- **Environment sanitization:** Strip `BUNDLE_*`, `GEM_*`, `RUBYOPT`, `RUBYLIB`,
  `BASH_ENV` vars before passing to child process. Keep `ASK_*` vars (for ask-auth).
- **Output truncation:** Same as current tools — 100KB limit per stream.
- **Cross-platform:** Test on macOS and Linux. `setrlimit` works on both.
  `pgroup: true` works on both.

**Edge cases to handle:**
- Command returns non-zero exit code (not an error, return it in Result)
- Empty stdin_data
- Very large output (truncate + add [Truncated] header)
- Process already dead by the time we try to kill it
- Workdir doesn't exist → let child process error naturally

### 3. Implement `Ask::Sandbox::Docker` (`lib/ask/sandbox/docker.rb`)

Runs commands inside a Docker container with maximum practical security.

**Constructor parameters:**
```ruby
Docker.new(
  image: "ruby:3.4-alpine",       # Docker image to use
  memory: "512m",                   # Memory limit
  cpus: 1.0,                        # CPU limit
  network: false,                   # Block network egress
  read_only: true,                  # Read-only root filesystem
  cap_drop: "ALL",                  # Drop all Linux capabilities
  user: nil,                        # Run as specific user (nil = container default)
  timeout: 30,                      # Default timeout
  remove: true                      # Auto-remove container after execution
)
```

**Implementation (`#call`):**

1. Build the docker command as an argv array:
   ```ruby
   argv = ["docker", "run", "--rm", "-i"]
   argv << "--memory" << @memory if @memory
   argv << "--cpus" << @cpus.to_s if @cpus
   argv << "--network" << "none" if @network == false
   argv << "--read-only" if @read_only
   argv << "--cap-drop" << @cap_drop if @cap_drop
   argv << "--security-opt" << "no-new-privileges"
   argv << "--pids-limit" << "100"
   argv << "--entrypoint" << ""  # Don't use ENTRYPOINT, we control the command
   argv << @image
   argv += Array(command)  # Command as argv or string
   ```

2. Call `Process.spawn` with the docker argv, setting up pipes for stdin/stdout/stderr
   and process group. Or delegate to `Ask::Sandbox::Local.new.call(argv, ...)`.

   BUT: this is a chicken-and-egg problem — Docker needs to pass the command
   as Docker arguments, not as a shell string. The Docker provider should
   NOT use the Local provider. Instead, it should directly spawn the docker
   process with proper argv construction.

3. Capture stdout/stderr, handle timeout by sending `docker stop` (graceful) then
   `docker kill` (force) to the container.

4. Return `Ask::Sandbox::Result`.

**Important:** The Docker provider does NOT use the `docker-api` gem. It shells
out to the `docker` CLI binary. This avoids a gem dependency and matches how
most Docker tooling works in practice.

**Edge cases:**
- Docker daemon not running → raise `Ask::Sandbox::ProviderUnavailable` (new error class)
- Docker image not found → let the error propagate with a clear message
- Container exits with non-zero → return in Result, not an error
- Timeout → `docker stop -t TIMEOUT` then `docker kill`

**Test considerations:**
- Skip integration tests unless Docker is available
- Try `docker info` in `setup` to detect Docker daemon
- Mock the `Process.spawn` call for unit tests

### 4. Implement `Ask::Sandbox::Daytona` (`lib/ask/sandbox/daytona.rb`)

Runs commands in a Daytona sandbox via the official `daytona` gem
(https://rubygems.org/gems/daytona, maintained by Daytona Platforms Inc.).

**Constructor parameters:**
```ruby
Daytona.new(
  api_key: nil,          # Daytona API key (can use Ask::Auth.lookup("DAYTONA_API_KEY"))
  server_url: nil,       # Daytona server URL (defaults to Daytona SDK default)
  image: nil,            # Sandbox image
  timeout: 120           # Default timeout (Daytona sandboxes may take time to boot)
)
```

**Implementation (`#call`):**

1. Require `daytona` lazily (inside `#call`):
   ```ruby
   begin
     require "daytona"
   rescue LoadError
     raise "The `daytona` gem is required for the Daytona sandbox provider. " \
           "Add `gem 'daytona'` to your Gemfile."
   end
   ```

2. Create a Daytona client with the API key:
   ```ruby
   # Using the daytona gem API
   client = Daytona::Client.new(api_key: @api_key, server_url: @server_url)
   ```

3. Create a sandbox (or reuse an existing one):
   ```ruby
   sandbox = client.sandboxes.create(image: @image || "ruby:3.4")
   ```

4. Execute the command:
   ```ruby
   result = sandbox.process.execute(command, timeout: timeout)
   ```

5. Parse the result into `Ask::Sandbox::Result`.

6. Cleanup: destroy the sandbox after execution (configurable via options).

**Lazy loading:** The `require "daytona"` should be inside `#call`, not at the top
of the file. This way the gem can be installed without the `daytona` gem present —
it only fails at runtime if you try to use the Daytona provider without it.

**Edge cases:**
- `daytona` gem not installed → clear LoadError message with install instructions
- API key missing → raise `Ask::Sandbox::ConfigurationError` (new error class)
- Network error → timeout and retry
- Daytona server returns error → propagate with context

### 5. Implement `Ask::Sandbox::Cloudflare` (`lib/ask/sandbox/cloudflare.rb`)

Runs commands in a Cloudflare Workers sandbox. Cloudflare's Sandbox SDK
(`@cloudflare/sandbox`) is a JavaScript/TypeScript package that provides container
sandboxes on Cloudflare's edge network. Since it's not natively available from Ruby,
this provider requires a user-deployed proxy Worker.

The proxy Worker wraps `@cloudflare/sandbox` and exposes a simple HTTP API that
this provider calls.

**The proxy Worker (user deploys this, not part of this gem):**
```typescript
// sandbox-proxy Worker — users deploy this themselves
import { getSandbox } from '@cloudflare/sandbox';
export { Sandbox } from '@cloudflare/sandbox';

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { sandbox_id, command, timeout } = await request.json();
    const sandbox = getSandbox(env.Sandbox, sandbox_id);
    const result = await sandbox.exec(command, { timeout });
    return Response.json(result);
  }
};
```

**Constructor parameters:**
```ruby
Cloudflare.new(
  worker_url: nil,       # URL of the deployed proxy Worker
  auth_token: nil,       # Auth token for the proxy Worker (optional)
  timeout: 60            # Default timeout
)
```

**Implementation (`#call`):**

1. Build an HTTP request to the proxy Worker:
   ```ruby
   require "net/http"
   require "json"
   
   uri = URI(@worker_url)
   http = Net::HTTP.new(uri.host, uri.port)
   http.use_ssl = uri.scheme == "https"
   http.open_timeout = 10
   http.read_timeout = timeout + 5
   
   request = Net::HTTP::Post.new(uri)
   request["Content-Type"] = "application/json"
   request["Authorization"] = "Bearer #{@auth_token}" if @auth_token
   request.body = JSON.generate({
     sandbox_id: SecureRandom.uuid,
     command: Array(command).join(" "),  # flatten array to string
     timeout: timeout
   })
   
   response = http.request(request)
   ```

2. Parse the JSON response into `Ask::Sandbox::Result`.

3. Handle errors (network, auth, Worker error).

**Lazy loading:** `require "net/http"` and `require "json"` are stdlib. No gem
dependencies needed. But `net/http` is a bundled gem in Ruby 3.4+, so add it
as a gemspec dependency:
```ruby
spec.add_dependency "net-http"  # bundled gem, ensures availability
```

Wait — actually `net/http` is part of Ruby's standard library. In Ruby 3.4+ it
was moved to a bundled gem. If it needs to be in the gemspec:
```ruby
spec.add_dependency "net-http", "~> 0.6"
```

Actually, to keep zero deps, we can use `open-uri` or just document that users
need `net-http` if on Ruby 3.4+. But the cleanest approach: just add `net-http`
as a runtime dependency. It's tiny and maintained by the Ruby core team.

**Hmm, but we said zero deps.** Let me think... `net/http` is part of stdlib on
Ruby 3.2 and 3.3. On Ruby 3.4+ it's a bundled gem (automatically included but
needs to be in Gemfile for gems that use it). So we need it in the gemspec.

BUT — the gemspec says zero runtime deps. Adding `net-http` breaks that promise.
Options:

1. Make it a conditional dep:
   ```ruby
   spec.add_dependency "net-http", "~> 0.6" if RUBY_VERSION >= "3.4"
   ```
   (This doesn't work in gemspec — `RUBY_VERSION` is evaluated at build time)

2. Just add it:
   ```ruby
   spec.add_dependency "net-http", "~> 0.6"
   ```
   This is fine. It's a bundled gem maintained by Ruby core. Practically everyone has it.

3. Use `open-uri` instead — also bundled.

I'll go with option 2 for pragmatism. The gem description says "zero external
dependencies" — `net-http` is a bundled gem, not external. Same category as
`base64` which `ask-auth` already depends on.

Actually wait, let me reconsider. The `net-http` gem requirement is only for the
Cloudflare provider. What if someone only uses Local and Docker? They shouldn't
need `net-http`. But it's harmless — it's a bundled gem, minimal footprint.

OK, let me include it for pragmatism.

**Edge cases:**
- Proxy Worker not deployed → connection refused / DNS error
- Auth token invalid → 401/403
- Sandbox creation timeout → retry or propagate

### 6. Provider Registry & Configuration (lib/ask-sandbox-providers.rb)

The entry point already has:
```ruby
Ask::Sandbox.provider  # returns current provider (default: Local.new)
Ask::Sandbox.provider = :local        # symbol lookup
Ask::Sandbox.provider = :docker
Ask::Sandbox.provider = MyCustom.new  # any Base subclass
```

**Enhancements to add:**
- `Ask::Sandbox.configure` block for config:
  ```ruby
  Ask::Sandbox.configure do |c|
    c.provider = :docker
    c.docker_image = "ruby:3.4-slim"
  end
  ```
  Actually, this is overengineering. Keep the simple `provider =` setter for v0.1.0.
  Each provider's constructor takes its own options. Users configure per-provider.

### 7. Error Classes

Add to `lib/ask/sandbox/base.rb` or a separate `lib/ask/sandbox/errors.rb`:

```ruby
module Ask
  module Sandbox
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class ProviderUnavailable < Error; end
    class ExecutionError < Error; end
  end
end
```

These should be defined and used by the providers:
- `ConfigurationError` — bad config (missing API key, invalid image, etc.)
- `ProviderUnavailable` — Docker not running, Daytona server down, Worker unreachable
- `ExecutionError` — unexpected failure during execution

### 8. Documentation

#### README.md
Already scaffolded. Update after implementation with:
- Installation
- Quick start (Local)
- Each provider with setup instructions and example
- Configuration guide
- Development workflow
- How to add a custom provider

#### Each provider's yardoc
Document every public method. Include security notes per provider:
- Local: "Process-level isolation. Not suitable for untrusted code in
  multi-tenant environments."
- Docker: "Container-level isolation. Suitable for untrusted code."
- Daytona: "Remote sandbox. Network latency applies."
- Cloudflare: "Edge sandbox. Requires Cloudflare deployment."

### 9. Test Coverage

**`test/test_helper.rb`** — already scaffolded. Add SimpleCov if desired.

**`test/ask/sandbox/local_test.rb`** — Tests for Local provider:
- Normal command execution (stdout, stderr, exit_code)
- String command vs Array command
- Timeout kills process and sets timed_out flag
- Process group isolation (spawn subprocesses, kill parent, verify children die)
- Output truncation
- Environment sanitization (BUNDLE_* vars stripped, ASK_* vars kept)
- Temp directory cleanup
- Stdin piping
- Workdir option
- Non-zero exit codes
- rlimits are applied (test that RLIMIT_NPROC prevents fork bomb)
- Empty command

**`test/ask/sandbox/docker_test.rb`** — Tests for Docker provider:
- Docker daemon detection (skip if unavailable)
- Basic command execution
- Command with Array argv (correctly forwarded to container)
- Timeout handling (docker stop then kill)
- Read-only root filesystem (can't write to /)
- Network none (can't reach internet)
- Non-root user
- Container cleanup after execution
- ProviderUnavailable when Docker not running

**`test/ask/sandbox/daytona_test.rb`** — Tests for Daytona provider:
- Lazy load of `daytona` gem
- Missing API key → ConfigurationError
- Valid API key → creates client
- Command execution (mocked or with VCR)

**`test/ask/sandbox/cloudflare_test.rb`** — Tests for Cloudflare provider:
- HTTP request construction
- Auth token header
- Response parsing
- Network errors → ProviderUnavailable
- Timeout handling

**`test/ask/sandbox/config_test.rb`** — Tests for global config:
- Default provider is Local
- Symbol providers resolve correctly (:local, :docker, etc.)
- Custom provider instances are accepted
- `Result` Data.define works correctly

### 10. Integration: Migrate ask-tools-shell to Use Sandbox Providers

**This is a critical step.** After `ask-sandbox-providers` is built and released,
update `ask-tools-shell` to use it:

#### 10a. Add dependency in `ask-tools-shell.gemspec`:
```ruby
spec.add_dependency "ask-sandbox-providers", "~> 0.1"
```

#### 10b. Refactor `Ask::Tools::Shell::Code` (`lib/ask/tools/shell/code.rb`):

**Before:**
```ruby
def execute(code:)
  Dir.mktmpdir do |dir|
    Open3.popen3("ruby", "-e", code, chdir: dir) do |stdin, out, err, wait_thr|
      # ... capture, timeout, truncate
    end
  end
end
```

**After:**
```ruby
def execute(code:)
  result = Ask::Sandbox.provider.call(
    ["ruby", "-e", code],
    timeout: @timeout || 30
  )
  if result.timed_out
    return Ask::Result.error(message: "Code execution timed out",
                             metadata: { stdout: result.stdout, stderr: result.stderr })
  end
  Ask::Result.ok(data: {
    stdout: result.stdout,
    stderr: result.stderr,
    exit_code: result.exit_code
  })
end
```

#### 10c. Refactor `Ask::Tools::Shell::Bash` (`lib/ask/tools/shell/bash.rb`):

**Before:**
```ruby
def execute(command:, timeout: 30, workdir: nil)
  Dir.mktmpdir do |dir|
    Open3.popen3("bash", "-c", command, chdir: workdir || dir) do |...|
      # ... capture, timeout, truncate
    end
  end
end
```

**After:**
```ruby
def execute(command:, timeout: 30, workdir: nil)
  result = Ask::Sandbox.provider.call(
    "bash -c '#{command}'",
    timeout: timeout,
    workdir: workdir
  )
  if result.timed_out
    return Ask::Result.error(message: "Command timed out",
                             metadata: { stdout: result.stdout, stderr: result.stderr })
  end
  Ask::Result.ok(data: {
    stdout: result.stdout,
    stderr: result.stderr,
    exit_code: result.exit_code,
    timed_out: result.timed_out
  })
end
```

**Important:** For Bash, passing the command as a string to `bash -c` requires
shell escaping. The better approach is to use the `env` and `workdir` options
of the sandbox provider and pass the command as an array in the shell:

Actually, `Bash` tool currently runs `bash -c command`. The string command form
of the sandbox provider should handle this. When we call `sandbox.call("ls -la")`
with a string, the provider executes it via shell. So Bash should just pass the
command string directly:

```ruby
def execute(command:, timeout: 30, workdir: nil)
  result = Ask::Sandbox.provider.call(
    command,          # string → shell execution
    timeout: timeout,
    workdir: workdir
  )
  ...
end
```

This is cleaner — the sandbox provider decides how to run the string command
(Local uses bash -c, Docker uses the container's shell, etc.).

#### 10d. Update `ask-tools-shell` test suite:

- Existing tests should still pass (Ask::Sandbox::Local behaves identically to
  the old Open3 code)
- Add tests that verify sandbox configuration is used
- Add test that verifies the sandbox provider can be swapped

#### 10e. Update `ask-tools-shell` README:

- Document that sandbox environment is now configurable
- Add configuration example

### 11. Production Hardening

- **Error messages:** All errors must include what went wrong AND what to do.
  Example: "Docker sandbox unavailable: docker info failed. Is Docker running?"
- **Network timeouts:** Every HTTP call (Daytona, Cloudflare) must have
  configurable timeouts with sensible defaults.
- **Resource limits:** Local provider MUST apply rlimits (best-effort on macOS).
  Container providers MUST use container-native limits.
- **No secrets in output:** Sanitize command output — if a command accidentally
  prints a secret (env dump, debug output), the sandbox shouldn't be the leak
  vector. At minimum, document that stdout/stderr may contain sensitive data.
- **Input validation:** Reject nil command. Reject empty command with clear message.
- **Process leaks:** Ensure child processes are reaped on timeout (Process.waitpid
  after kill).

## What Done Means for v0.1.0

The gem reaches v0.1.0 when:
- All four providers are implemented and tested
- `ask-tools-shell` is migrated to use `ask-sandbox-providers`
- The gem is released on RubyGems
- A consumer can install it and use the Local provider out of the box
- A consumer can configure Docker/Daytona/Cloudflare and they work
- The README provides enough information to get started in 5 minutes
- The CHANGELOG documents what v0.1.0 delivers

## v0.1.0 Completion Checklist

### Code & Tests
- [ ] `Ask::Sandbox::Local` — implemented with spawn, pipes, rlimits, process group, tempdir, env sanitization
- [ ] `Ask::Sandbox::Docker` — implemented with `docker run --rm` and hardened flags
- [ ] `Ask::Sandbox::Daytona` — implemented with lazy `daytona` gem loading
- [ ] `Ask::Sandbox::Cloudflare` — implemented with HTTP calls to proxy Worker
- [ ] `Ask::Sandbox::Result` — Data.define with stdout, stderr, exit_code, timed_out
- [ ] Error classes defined (ConfigurationError, ProviderUnavailable, ExecutionError)
- [ ] Local provider tests cover: stdout, stderr, exit_code, timeout, rlimits, process group kill, env sanitization, truncation, stdin piping, workdir
- [ ] Docker provider tests cover: basic execution, timeout, flags, container cleanup, Docker unavailable
- [ ] Daytona provider tests cover: lazy require, missing API key, command execution (mocked)
- [ ] Cloudflare provider tests cover: HTTP request, auth header, response parsing, network errors
- [ ] Global config tests cover: default provider, symbol resolution, custom instances
- [ ] All tests pass: `bundle exec rake test`
- [ ] Test coverage >= 90%
- [ ] No warnings on load

### Documetation
- [ ] README complete: installation, quick start, each provider documented, configuration, examples, development
- [ ] Every public method documented (yardoc)
- [ ] CHANGELOG.md with v0.1.0 entry

### Release
- [ ] Gem builds without errors: `gem build *.gemspec`
- [ ] Gem is released on RubyGems.org: `gem push *.gem`
- [ ] Fresh install works: `gem install ask-sandbox-providers`
- [ ] Consumer script can require and use the full public API

### Production Hardening
- [ ] Error messages are helpful and actionable
- [ ] Network timeouts handled for Daytona/Cloudflare providers
- [ ] Resource limits applied consistently across all compatible providers
- [ ] Input validation for all parameters
- [ ] Child process cleanup guaranteed (no zombie processes)
- [ ] Thread safety for concurrent #call invocations

### CI/CD
- [ ] GitHub Actions workflow runs tests on push and PR (`.github/workflows/ci.yml`)
- [ ] CI passes on Ruby 3.2, 3.3, 3.4

### Migration
- [ ] `ask-tools-shell` updated to depend on `ask-sandbox-providers`
- [ ] `Code` tool refactored to use `Ask::Sandbox.provider.call`
- [ ] `Bash` tool refactored to use `Ask::Sandbox.provider.call`
- [ ] `ask-tools-shell` tests still pass
- [ ] `ask-tools-shell` README updated with sandbox configuration docs
- [ ] `ask-tools-shell` version bumped (minor)
- [ ] `ask-tools-shell` released to RubyGems

### Post-Release
- [ ] ask-docs repository updated with this gem documentation
- [ ] Version tag exists: `git tag v0.1.0 && git push --tags`

## Development Workflow

### Git conventions
- The default branch is **master**. All work should be based on master.
- Follow the git-workflow skill for branch naming, commit messages, and PR structure.
- Use conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`.
- One logical change per commit. No "fixup" or "wip" commits on master.
- Commit messages must be one direct sentence describing the change.

### Reference projects
Study existing implementations for patterns and conventions:

- **ask-tools-shell** — the current Code and Bash tools (to understand what sandbox replaces)
- **ask-auth** — credential resolution pattern (for Daytona/Cloudflare auth)
- **ask-github** — service context gem pattern (gemspec, testing structure)
- **flue/packages/sdk/src/sandbox.ts** — Flue's sandbox API design
- **flue/packages/sdk/src/cloudflare/cf-sandbox.ts** — Flue's Cloudflare sandbox wrapper
- **flue/packages/connectors/src/daytona.ts** — Flue's Daytona connector

### Reference Repositories (Local)
All ask-rb gem repos are available locally at /Users/kaka/Code/ask-rb/ for reference.
Do not clone from GitHub — use the local directories:
- Source code: /Users/kaka/Code/ask-rb/GEMNAME/lib/
- Tests: /Users/kaka/Code/ask-rb/GEMNAME/test/
- Goal: /Users/kaka/Code/ask-rb/GEMNAME/GOAL.md
- Gemspec: /Users/kaka/Code/ask-rb/GEMNAME/GEMNAME.gemspec

Other reference projects in the same workspace:
- /Users/kaka/Code/ask-rb/ask-tools-shell/ — The Code & Bash tools being migrated
- /Users/kaka/Code/ask-rb/flue/ — Flue's sandbox architecture
- /Users/kaka/Code/ask-rb/ask-auth/ — Ask::Auth for provider credentials

### Testing
- Use Minitest (not RSpec) — consistent with the ask-rb ecosystem.
- Unit tests for every public method (normal path + edge cases + error cases).
- Integration tests should skip if dependencies aren't available (e.g., `docker info`
  fails for Docker tests).
- Run the full suite before every commit: `bundle exec rake test`.
