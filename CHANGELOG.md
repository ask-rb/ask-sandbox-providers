## [0.1.2] - 2026-06-25

### Changed
- Infrastructure: rubocop, overcommit, bin/setup, CI matrix, gemspec test.
# Changelog

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
