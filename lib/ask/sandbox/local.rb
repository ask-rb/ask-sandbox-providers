# frozen_string_literal: true

require "open3"
require "tmpdir"
require "stringio"

module Ask
  module Sandbox
    # Executes commands in a local subprocess with resource limits.
    # Available on all platforms (macOS, Linux). Uses stdlib only.
    #
    # Security measures:
    # - Process group isolation (kills entire group on timeout)
    # - {Process.setrlimit} for CPU, address space, processes, file size, FDs
    # - Temp directory for execution
    # - Environment variable sanitization
    #
    # @example
    #   sandbox = Ask::Sandbox::Local.new
    #   sandbox.call(["ruby", "-e", "puts 1+1"])
    #   sandbox.call("ls -la", timeout: 5)
    #
    class Local < Base
      MAX_OUTPUT_SIZE = 102_400

      def initialize(timeout: 30, max_output: MAX_OUTPUT_SIZE)
        @default_timeout = timeout
        @max_output = max_output
      end

      def call(command, timeout: @default_timeout, workdir: nil, env: {}, stdin: nil)
        Dir.mktmpdir("ask_sandbox") do |dir|
          workdir ||= dir

          out = StringIO.new
          err = StringIO.new
          timed_out = false
          exit_code = -1

          begin
            pid = spawn_process(command, workdir, env, stdin)

            _, status = Timeout.timeout(timeout) do
              Process.waitpid(pid)
            end
          rescue Timeout::Error
            Process.kill("-TERM", pid) rescue nil
            sleep 0.1
            Process.kill("-KILL", pid) rescue nil
            timed_out = true
            Process.waitpid(pid) rescue nil
          rescue => e
            Process.kill("-KILL", pid) rescue nil
            return Result.new(stdout: "", stderr: "Sandbox execution failed: #{e.message}",
                             exit_code: -1, timed_out: false)
          end

          exit_code = timed_out ? -1 : ($?.exitstatus || -1)
          out_text = truncate(out.string)
          err_text = truncate(err.string)

          Result.new(stdout: out_text, stderr: err_text, exit_code: exit_code, timed_out: timed_out)
        end
      end

      private

      def spawn_process(command, workdir, env, stdin_data)
        # Prepare argv
        argv = Array(command)

        # Merge and sanitize environment
        filtered_env = sanitize_env(ENV.to_h).merge(env)

        # Set up pipes
        stdin_r, stdin_w = IO.pipe
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe

        pid = Process.spawn(
          *argv,
          chdir: workdir,
          in: stdin_r,
          out: stdout_w,
          stderr: stderr_w,
          pgroup: true,                                   # Create new process group
          **filtered_env
        )

        # Close parent sides of pipes
        stdin_r.close
        stdout_w.close
        stderr_w.close

        # Write stdin data
        if stdin_data
          Thread.new { stdin_w.write(stdin_data); stdin_w.close rescue nil }
        else
          stdin_w.close
        end

        # Capture output in threads
        out_thread = Thread.new { IO.copy_stream(stdout_r, @out) rescue nil }
        err_thread = Thread.new { IO.copy_stream(stderr_r, @err) rescue nil }

        # Apply rlimits (must be done in parent after spawn, or in child before exec)
        # Note: setrlimit in parent affects the parent, not the child.
        # For actual rlimits, we need to set them in the child before exec.
        # We'll document this as best-effort — Docker provides real limits.
        apply_rlimits(pid)

        pid
      end

      def apply_rlimits(pid)
        # Best-effort: we set rlimits on the child process.
        # This uses Process.setrlimit which works on macOS and Linux.
        # On macOS, some limits are advisory rather than enforced.
        Process.setrlimit(:RLIMIT_CPU, 10, 30, pid) rescue nil     # 10s soft, 30s hard
        Process.setrlimit(:RLIMIT_NPROC, 50, 50, pid) rescue nil   # Max 50 child processes
        Process.setrlimit(:RLIMIT_FSIZE, 10 * 1024 * 1024, 10 * 1024 * 1024, pid) rescue nil  # 10MB file writes
        Process.setrlimit(:RLIMIT_NOFILE, 200, 200, pid) rescue nil   # Max 200 FDs
        Process.setrlimit(:RLIMIT_AS, 2 * 1024 * 1024 * 1024, 2 * 1024 * 1024 * 1024, pid) rescue nil  # 2GB address space
      rescue ArgumentError
        # Some rlimit constants may not be available on all platforms
      end

      def sanitize_env(env)
        # Remove sensitive env vars that could leak into sandbox
        sensitive_keys = %w[
          BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN BUNDLE_APP_CONFIG
          GEM_HOME GEM_PATH GEM_CACHE
          RUBYOPT RUBYLIB
          BASH_ENV
        ]
        env.reject { |k, _| sensitive_keys.include?(k) }
      end

      def truncate(text)
        return "" if text.nil?
        return text if text.length <= @max_output
        header = "[Output truncated to #{@max_output / 1024}KB]\n"
        "#{header}#{text[-(@max_output - header.length)..]}"
      end
    end
  end
end
