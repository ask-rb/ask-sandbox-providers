# frozen_string_literal: true

require "test_helper"
require "net/http"
require "json"

class Ask::Sandbox::CloudflareTest < Minitest::Test
  def setup
    @sandbox = Ask::Sandbox::Cloudflare.new(
      worker_url: "https://sandbox-proxy.test.workers.dev",
      auth_token: "test-token",
      timeout: 5
    )
  end

  def test_nil_command_raises
    assert_raises(ArgumentError) { @sandbox.call(nil) }
  end

  def test_empty_command_raises
    assert_raises(ArgumentError) { @sandbox.call("") }
  end

  def test_raises_configuration_error_without_worker_url
    # Save and clear env var
    orig = ENV.delete("CLOUDFLARE_SANDBOX_WORKER_URL")
    sandbox = Ask::Sandbox::Cloudflare.new
    assert_raises(Ask::Sandbox::ConfigurationError) do
      sandbox.call("echo hello")
    end
  ensure
    ENV["CLOUDFLARE_SANDBOX_WORKER_URL"] = orig if orig
  end

  def test_resolves_worker_url_from_env
    orig = ENV.delete("CLOUDFLARE_SANDBOX_WORKER_URL")
    ENV["CLOUDFLARE_SANDBOX_WORKER_URL"] = "https://env.workers.dev"
    sandbox = Ask::Sandbox::Cloudflare.new
    assert_equal "https://env.workers.dev", sandbox.instance_variable_get(:@worker_url)
  ensure
    ENV["CLOUDFLARE_SANDBOX_WORKER_URL"] = orig if orig
  end

  def test_resolves_auth_token_from_env
    orig = ENV.delete("CLOUDFLARE_SANDBOX_AUTH_TOKEN")
    ENV["CLOUDFLARE_SANDBOX_AUTH_TOKEN"] = "env-token"
    sandbox = Ask::Sandbox::Cloudflare.new(worker_url: "https://test.workers.dev")
    assert_equal "env-token", sandbox.instance_variable_get(:@auth_token)
  ensure
    ENV["CLOUDFLARE_SANDBOX_AUTH_TOKEN"] = orig if orig
  end

  def test_uses_provided_worker_url_over_env
    orig = ENV.delete("CLOUDFLARE_SANDBOX_WORKER_URL")
    ENV["CLOUDFLARE_SANDBOX_WORKER_URL"] = "https://env.workers.dev"
    sandbox = Ask::Sandbox::Cloudflare.new(worker_url: "https://explicit.workers.dev")
    assert_equal "https://explicit.workers.dev", sandbox.instance_variable_get(:@worker_url)
  ensure
    ENV["CLOUDFLARE_SANDBOX_WORKER_URL"] = orig if orig
  end

  def test_converts_array_command_to_string
    sandbox = Ask::Sandbox::Cloudflare.new(
      worker_url: "https://test.workers.dev",
      auth_token: "tok"
    )
    # Stub the private make_request to capture the command
    sandbox.define_singleton_method(:make_request) do |cmd, _timeout|
      Ask::Sandbox::Result.new(stdout: "2\n", stderr: "", exit_code: 0, timed_out: false)
    end
    result = sandbox.call(["ruby", "-e", "puts 1+1"])
    assert_equal "2\n", result.stdout
  end

  def test_handles_configuration_error_on_401
    sandbox = Ask::Sandbox::Cloudflare.new(
      worker_url: "https://test.workers.dev",
      auth_token: "tok"
    )
    # Stub the private make_request to raise config error
    sandbox.define_singleton_method(:make_request) do |_cmd, _timeout|
      raise Ask::Sandbox::ConfigurationError,
            "Cloudflare sandbox authentication failed (401). Check your auth token."
    end
    assert_raises(Ask::Sandbox::ConfigurationError) do
      sandbox.call("echo hello")
    end
  end

  def test_handles_provider_unavailable
    sandbox = Ask::Sandbox::Cloudflare.new(
      worker_url: "https://test.workers.dev",
      auth_token: "tok"
    )
    sandbox.define_singleton_method(:make_request) do |_cmd, _timeout|
      raise Ask::Sandbox::ProviderUnavailable,
            "Cloudflare sandbox unavailable: Connection refused."
    end
    assert_raises(Ask::Sandbox::ProviderUnavailable) do
      sandbox.call("echo hello")
    end
  end
end
