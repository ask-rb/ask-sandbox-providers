# frozen_string_literal: true

require "test_helper"

class Ask::Sandbox::LocalTest < Minitest::Test
  def setup
    @sandbox = Ask::Sandbox::Local.new(timeout: 10, max_output: 102_400)
  end

  def test_executes_string_command_via_shell
    result = @sandbox.call("echo hello world")
    assert_equal "hello world\n", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_code
    refute result.timed_out
  end

  def test_executes_array_command_no_shell
    result = @sandbox.call(["ruby", "-e", "puts 1+1"])
    assert_equal "2\n", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_code
    refute result.timed_out
  end

  def test_captures_stderr
    result = @sandbox.call(["ruby", "-e", "$stderr.puts 'error msg'"])
    assert_equal "", result.stdout
    assert_equal "error msg\n", result.stderr
    assert_equal 0, result.exit_code
  end

  def test_non_zero_exit_code
    result = @sandbox.call(["ruby", "-e", "exit 42"])
    assert_equal 42, result.exit_code
    refute result.timed_out
  end

  def test_timeout_kills_process
    result = @sandbox.call(["ruby", "-e", "sleep 60"], timeout: 1)
    assert result.timed_out, "expected process to be timed out"
  end

  def test_stdin_piping
    result = @sandbox.call(["ruby", "-e", "puts STDIN.read"], stdin: "hello from stdin")
    assert_includes result.stdout, "hello from stdin"
  end

  def test_empty_stdin_is_ok
    result = @sandbox.call(["ruby", "-e", "puts 'no input'"], stdin: "")
    assert_equal "no input\n", result.stdout
  end

  def test_nil_command_raises
    assert_raises(ArgumentError) { @sandbox.call(nil) }
  end

  def test_empty_string_command_raises
    assert_raises(ArgumentError) { @sandbox.call("") }
  end

  def test_empty_array_command_raises
    assert_raises(ArgumentError) { @sandbox.call([]) }
  end

  def test_working_directory
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "test.txt"), "present")
      result = @sandbox.call(["cat", "test.txt"], workdir: dir)
      assert_equal "present", result.stdout.strip
    end
  end

  def test_env_vars_are_passed
    result = @sandbox.call(["ruby", "-e", "puts ENV['MY_VAR']"], env: { "MY_VAR" => "custom_value" })
    assert_equal "custom_value\n", result.stdout
  end

  def test_ask_env_vars_are_preserved
    original = ENV["ASK_TEST_VAR"]
    ENV["ASK_TEST_VAR"] = "preserved"
    begin
      result = @sandbox.call(["ruby", "-e", "puts ENV['ASK_TEST_VAR']"])
      assert_equal "preserved\n", result.stdout
    ensure
      ENV["ASK_TEST_VAR"] = original
    end
  end

  def test_bundle_env_vars_are_stripped
    original = ENV["BUNDLE_GEMFILE"]
    ENV["BUNDLE_GEMFILE"] = "/should/not/exist"
    begin
      # Run in a Gemfile-less dir: from a project dir Ruby auto-detects the
      # local Gemfile and re-injects BUNDLE_GEMFILE itself (like a real
      # terminal), which would mask the inherited-env stripping we test here.
      Dir.mktmpdir do |dir|
        result = @sandbox.call(["ruby", "-e", "puts ENV['BUNDLE_GEMFILE'].inspect"], workdir: dir)
        assert_equal "nil\n", result.stdout
      end
    ensure
      ENV["BUNDLE_GEMFILE"] = original
    end
  end

  def test_output_truncation
    small_sandbox = Ask::Sandbox::Local.new(max_output: 100)
    # Generate output larger than 100 bytes
    result = small_sandbox.call(["ruby", "-e", "puts 'a' * 200"])
    assert result.stdout.bytesize <= 150 # 100 + truncation header
    assert_includes result.stdout, "[Truncated"
  end

  def test_runs_in_caller_working_directory_by_default
    result = @sandbox.call(["ruby", "-e", "puts Dir.pwd"])
    assert_equal Dir.pwd, result.stdout.strip
  end

  def test_explicit_workdir_wins
    Dir.mktmpdir do |dir|
      result = @sandbox.call(["ruby", "-e", "puts Dir.pwd"], workdir: dir)
      assert_equal File.realpath(dir), result.stdout.strip
    end
  end

  def test_process_group_isolation
    # Spawn a process that creates a child, then kill the parent
    # The grandchild should also be killed when parent times out
    result = @sandbox.call(
      ["ruby", "-e", "Process.spawn('sleep 30', pgroup: true); sleep 30"],
      timeout: 2
    )
    assert result.timed_out
  end

  def test_rejects_invalid_command_type
    assert_raises(ArgumentError) { @sandbox.call(42) }
  end

  def test_result_success_method
    result = @sandbox.call("true")
    assert result.success?

    result = @sandbox.call("false")
    refute result.success?
  end

  def test_concurrent_execution
    threads = 4.times.map do
      Thread.new do
        @sandbox.call(["ruby", "-e", "puts 'concurrent'"])
      end
    end
    results = threads.map(&:value)
    results.each do |result|
      assert_equal "concurrent\n", result.stdout
      assert_equal 0, result.exit_code
    end
  end
end
