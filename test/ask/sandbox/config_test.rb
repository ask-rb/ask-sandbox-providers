# frozen_string_literal: true

require "test_helper"

class Ask::Sandbox::ConfigTest < Minitest::Test
  def setup
    # Reset to default before each test
    Ask::Sandbox.instance_variable_set(:@provider, nil)
  end

  def teardown
    Ask::Sandbox.instance_variable_set(:@provider, nil)
  end

  def test_default_provider_is_local
    assert_instance_of Ask::Sandbox::Local, Ask::Sandbox.provider
  end

  def test_set_provider_by_symbol_local
    Ask::Sandbox.provider = :local
    assert_instance_of Ask::Sandbox::Local, Ask::Sandbox.provider
  end

  def test_set_provider_by_symbol_docker
    Ask::Sandbox.provider = :docker
    assert_instance_of Ask::Sandbox::Docker, Ask::Sandbox.provider
  end

  def test_set_provider_by_symbol_daytona
    Ask::Sandbox.provider = :daytona
    assert_instance_of Ask::Sandbox::Daytona, Ask::Sandbox.provider
  end

  def test_set_provider_by_symbol_cloudflare
    Ask::Sandbox.provider = :cloudflare
    assert_instance_of Ask::Sandbox::Cloudflare, Ask::Sandbox.provider
  end

  def test_set_provider_by_instance
    custom = Ask::Sandbox::Docker.new(image: "custom:latest")
    Ask::Sandbox.provider = custom
    assert_same custom, Ask::Sandbox.provider
  end

  def test_invalid_symbol_raises
    assert_raises(ArgumentError) { Ask::Sandbox.provider = :nonexistent }
  end

  def test_result_data_define
    result = Ask::Sandbox::Result.new(stdout: "out", stderr: "err", exit_code: 0, timed_out: false)
    assert_equal "out", result.stdout
    assert_equal "err", result.stderr
    assert_equal 0, result.exit_code
    refute result.timed_out
  end

  def test_result_success
    assert Ask::Sandbox::Result.new(stdout: "", stderr: "", exit_code: 0, timed_out: false).success?
    refute Ask::Sandbox::Result.new(stdout: "", stderr: "", exit_code: 1, timed_out: false).success?
  end

  def test_base_raises_not_implemented
    base = Ask::Sandbox::Base.new
    assert_raises(NotImplementedError) { base.call("ls") }
  end
end
