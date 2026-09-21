# frozen_string_literal: true

require "test_helper"

class Ask::Sandbox::DaytonaTest < Minitest::Test
  def setup
    @sandbox = Ask::Sandbox::Daytona.new(
      api_key: "dta_test-key",
      server_url: "https://api.daytona.io"
    )
  end

  def test_raises_configuration_error_without_api_key
    orig_key = ENV.delete("DAYTONA_API_KEY")
    sandbox = Ask::Sandbox::Daytona.new(api_key: nil)
    assert_raises(Ask::Sandbox::ConfigurationError) do
      sandbox.call("echo hello")
    end
  ensure
    ENV["DAYTONA_API_KEY"] = orig_key if orig_key
  end

  def test_nil_command_raises
    assert_raises(ArgumentError) { @sandbox.call(nil) }
  end

  def test_empty_command_raises
    assert_raises(ArgumentError) { @sandbox.call("") }
  end

  def test_raises_load_error_without_daytona_gem
    sandbox = Ask::Sandbox::Daytona.new(api_key: "dta_xxx")
    # Simulate LoadError by raising from the require call
    sandbox.define_singleton_method(:ensure_daytona_gem!) do
      raise LoadError, "The `daytona` gem is required for the Daytona sandbox provider."
    end
    assert_raises(LoadError) { sandbox.call("echo hello") }
  end

  def test_converts_array_command_to_string
    sandbox = Ask::Sandbox::Daytona.new(api_key: "dta_xxx")
    sandbox.define_singleton_method(:ensure_daytona_gem!) { true }
    sandbox.define_singleton_method(:execute_on_daytona) do |command, _, _|
      Ask::Sandbox::Result.new(stdout: "2\n", stderr: "", exit_code: 0, timed_out: false)
    end
    result = sandbox.call(["ruby", "-e", "puts 1+1"])
    assert_equal "2\n", result.stdout
  end

  def test_executes_command_with_string
    sandbox = Ask::Sandbox::Daytona.new(api_key: "dta_xxx")
    sandbox.define_singleton_method(:ensure_daytona_gem!) { true }
    sandbox.define_singleton_method(:execute_on_daytona) do |command, _, _|
      Ask::Sandbox::Result.new(stdout: "total 0\n", stderr: "", exit_code: 0, timed_out: false)
    end
    result = sandbox.call("ls -la")
    assert_equal "total 0\n", result.stdout
  end

  def test_resolves_api_key_from_env
    orig_key = ENV.delete("DAYTONA_API_KEY")
    ENV["DAYTONA_API_KEY"] = "dta_env-key"
    sandbox = Ask::Sandbox::Daytona.new(api_key: nil)
    assert_equal "dta_env-key", sandbox.send(:resolve_api_key)
  ensure
    ENV["DAYTONA_API_KEY"] = orig_key if orig_key
  end
end
