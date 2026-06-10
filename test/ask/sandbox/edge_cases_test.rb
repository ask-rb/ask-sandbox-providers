# frozen_string_literal: true

require "test_helper"

class Ask::Sandbox::EdgeCasesTest < Minitest::Test
  def setup
    @sandbox = Ask::Sandbox::Local.new(timeout: 10)
  end

  def test_provider_unavailable_raised_when_docker_missing
    sandbox = Ask::Sandbox::Docker.new
    sandbox.define_singleton_method(:check_docker_available!) do
      raise Ask::Sandbox::ProviderUnavailable,
            "Docker sandbox unavailable: `docker info` failed."
    end
    assert_raises(Ask::Sandbox::ProviderUnavailable) { sandbox.call("echo test") }
  end

  def test_local_rejects_invalid_command_type
    assert_raises(ArgumentError) { @sandbox.call(42) }
  end

  def test_result_timed_out
    result = Ask::Sandbox::Result.new(stdout: "", stderr: "", exit_code: nil, timed_out: true)
    assert result.timed_out
    refute result.success?
  end

  def test_result_exit_code_nil
    result = Ask::Sandbox::Result.new(stdout: "", stderr: "", exit_code: nil, timed_out: false)
    assert_nil result.exit_code
  end

  def test_result_various_combinations
    ok = Ask::Sandbox::Result.new(stdout: "a", stderr: "b", exit_code: 0, timed_out: false)
    assert ok.success?
    fail = Ask::Sandbox::Result.new(stdout: "a", stderr: "b", exit_code: 1, timed_out: false)
    refute fail.success?
  end

  def test_local_caches_rlimits
    Ask::Sandbox::Local.supported_rlimits
    cached = Ask::Sandbox::Local.supported_rlimits
    assert_kind_of Hash, cached
  end

  def test_cloudflare_env_fallbacks
    orig_url = ENV.delete("CLOUDFLARE_SANDBOX_WORKER_URL")
    orig_token = ENV.delete("CLOUDFLARE_SANDBOX_AUTH_TOKEN")
    ENV["CLOUDFLARE_SANDBOX_WORKER_URL"] = "https://fallback.workers.dev"
    ENV["CLOUDFLARE_SANDBOX_AUTH_TOKEN"] = "fallback-token"
    sandbox = Ask::Sandbox::Cloudflare.new
    assert_equal "https://fallback.workers.dev", sandbox.instance_variable_get(:@worker_url)
    assert_equal "fallback-token", sandbox.instance_variable_get(:@auth_token)
  ensure
    ENV["CLOUDFLARE_SANDBOX_WORKER_URL"] = orig_url if orig_url
    ENV["CLOUDFLARE_SANDBOX_AUTH_TOKEN"] = orig_token if orig_token
  end

  def test_daytona_env_fallback
    orig_key = ENV.delete("DAYTONA_API_KEY")
    ENV["DAYTONA_API_KEY"] = "dta_env_fallback"
    sandbox = Ask::Sandbox::Daytona.new
    assert_equal "dta_env_fallback", sandbox.send(:resolve_api_key)
  ensure
    ENV["DAYTONA_API_KEY"] = orig_key if orig_key
  end

  def test_daytona_missing_gem_raises_clear_error
    sandbox = Ask::Sandbox::Daytona.new(api_key: "dta_xxx")
    sandbox.define_singleton_method(:ensure_daytona_gem!) do
      raise LoadError, "The `daytona` gem is required for the Daytona sandbox provider."
    end
    ex = assert_raises(LoadError) { sandbox.call("echo hello") }
    assert_includes ex.message, "daytona"
  end

  def test_cloudflare_missing_worker_url_raises
    orig = ENV.delete("CLOUDFLARE_SANDBOX_WORKER_URL")
    sandbox = Ask::Sandbox::Cloudflare.new
    assert_raises(Ask::Sandbox::ConfigurationError) { sandbox.call("echo hi") }
  ensure
    ENV["CLOUDFLARE_SANDBOX_WORKER_URL"] = orig if orig
  end

  def test_cloudflare_converts_array
    sandbox = Ask::Sandbox::Cloudflare.new(worker_url: "https://test.workers.dev", auth_token: "tok")
    sandbox.define_singleton_method(:make_request) do |cmd, _timeout|
      Ask::Sandbox::Result.new(stdout: "3\n", stderr: "", exit_code: 0, timed_out: false)
    end
    result = sandbox.call(["ruby", "-e", "puts 3"])
    assert_equal "3\n", result.stdout
  end

  def test_local_preserves_ask_env_vars
    orig = ENV["ASK_KEEP_ME"]
    ENV["ASK_KEEP_ME"] = "preserved"
    result = @sandbox.call(["ruby", "-e", "puts ENV['ASK_KEEP_ME']"])
    assert_equal "preserved\n", result.stdout
  ensure
    ENV["ASK_KEEP_ME"] = orig if orig
  end

  def test_string_command_uses_shell
    result = @sandbox.call("echo hello from shell")
    assert_includes result.stdout, "hello from shell"
  end
end
