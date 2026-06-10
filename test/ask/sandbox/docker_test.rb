# frozen_string_literal: true

require "test_helper"

class Ask::Sandbox::DockerTest < Minitest::Test
  def setup
    skip("Docker not available") unless docker_available?
    # Use an image that we already have cached or pull it first
    @image = pull_cached_image
    @sandbox = Ask::Sandbox::Docker.new(
      image: @image,
      memory: "128m",
      cpus: 0.5,
      timeout: 10
    )
  end

  def docker_available?
    system("docker info", out: File::NULL, err: File::NULL)
  rescue SystemCallError
    false
  end

  def pull_cached_image
    # Use alpine which is typically cached or small to pull
    system("docker image inspect alpine:3.20 > /dev/null 2>&1 || docker pull alpine:3.20 > /dev/null 2>&1")
    "alpine:3.20"
  end

  def test_executes_command_in_container
    result = @sandbox.call(["echo", "hello from docker"])
    assert_equal "hello from docker\n", result.stdout
    assert_equal 0, result.exit_code
    refute result.timed_out
  end

  def test_executes_string_command_via_shell
    result = @sandbox.call("echo hello shell")
    assert_equal "hello shell\n", result.stdout
    assert_equal 0, result.exit_code
  end

  def test_non_zero_exit
    result = @sandbox.call(["sh", "-c", "exit 7"])
    assert_equal 7, result.exit_code
  end

  def test_captures_stderr
    result = @sandbox.call(["sh", "-c", "echo error >&2"])
    assert_includes result.stderr, "error"
    refute result.timed_out
  end

  def test_read_only_rootfs
    result = @sandbox.call(["touch", "/should-fail"])
    refute_equal 0, result.exit_code
    assert_includes(result.stderr + result.stdout, "Read-only file system")
  end

  def test_stdin_piping
    result = @sandbox.call(["cat"], stdin: "piped data")
    assert_equal "piped data", result.stdout
  end

  def test_timeout_handling
    result = @sandbox.call(["sleep", "30"], timeout: 1)
    assert result.timed_out
  end

  def test_nil_command_raises
    assert_raises(ArgumentError) { @sandbox.call(nil) }
  end

  def test_empty_command_raises
    assert_raises(ArgumentError) { @sandbox.call("") }
  end

  def test_env_vars_forwarded
    result = @sandbox.call(["sh", "-c", "echo $MY_VAR"], env: { "MY_VAR" => "docker_env" })
    assert_equal "docker_env\n", result.stdout
  end
end
