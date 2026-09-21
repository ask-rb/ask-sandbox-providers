## [0.1.4] — 2026-08-03

### Changed

- **Commands run in the caller's working directory by default** (was: a
  fresh temp dir). The shell tools (Write, Edit, ...) operate relative to
  the process CWD, so a sandboxed command that couldn't see a file the file
  tools had just created — `ruby hello.rb` after writing it with Write
  failed with `LoadError` — now works like a real terminal. Pass `workdir:`
  to pin a specific directory (e.g. an empty temp dir for hermetic runs).

## [0.1.3] — 2026-08-03

### Fixed

- **`rlimit_nproc` default raised from 200 to 1024.** nproc limits the
  *user's* total process count, not the sandbox's — 200 is easily exceeded
  on a busy dev machine, which made every fork inside a sandboxed command
  fail with `Resource temporarily unavailable` (EAGAIN). 1024 still guards
  against fork bombs without breaking normal use.

## [0.1.2] - 2026-06-25

### Changed
- Infrastructure: rubocop, overcommit, bin/setup, CI matrix, gemspec test.
# Changelog

## Unreleased

### Added

- `Ask::Sandbox::RuntimeExecutor` bridges sandbox providers to the
  `ask-runtime` tool executor contract.

## [0.1.1] - 2026-06-18

### Fixed
- Bumped `rlimit_nproc` from 50 to 200 in `Ask::Sandbox::Local` to prevent `fork: Resource temporarily unavailable` when subprocesses create nested shells (e.g., heredocs)

## [0.1.0] - 2026-06-18

### Added
- Initial release
- `Ask::Sandbox::Local` — subprocess execution with resource limits (rlimits, process group, tempdir)
- `Ask::Sandbox::Docker` — Docker container execution with hardened security flags
- `Ask::Sandbox::Daytona` — remote sandbox via the official Daytona SDK
- `Ask::Sandbox::Cloudflare` — Cloudflare Workers sandbox via a proxy Worker
- `Ask::Sandbox::Base` — abstract base class with unified `#call` interface
- Global provider configuration via `Ask::Sandbox.provider`
- Migration of `ask-tools-shell` Code and Bash tools to use sandbox providers
