# Changelog

## [0.1.0] - Unreleased

### Added
- Initial release
- `Ask::Sandbox::Local` — subprocess execution with resource limits (rlimits, process group, tempdir)
- `Ask::Sandbox::Docker` — Docker container execution with hardened security flags
- `Ask::Sandbox::Daytona` — remote sandbox via the official Daytona SDK
- `Ask::Sandbox::Cloudflare` — Cloudflare Workers sandbox via a proxy Worker
- `Ask::Sandbox::Base` — abstract base class with unified `#call` interface
- Global provider configuration via `Ask::Sandbox.provider`
- Migration of `ask-tools-shell` Code and Bash tools to use sandbox providers
