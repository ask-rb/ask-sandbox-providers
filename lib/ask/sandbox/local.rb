# frozen_string_literal: true

require "tmpdir"
require "fileutils"

module Ask
  module Sandbox
    # Executes commands in a local subprocess with resource limits.
    # Available on all platforms (macOS, Linux). Uses stdlib only.
    class Local < Base
      MAX_OUTPUT_SIZE = 102_400

      STRIP_ENV_PREFIXES = %w[BUNDLE_ GEM_].freeze
      STRIP_ENV_VARS = %w[RUBYOPT RUBYLIB BASH_ENV GEM_PATH GEM_HOME
                          BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH
                          BUNDLE_SETUP BUNDLE_WITHOUT BUNDLE_FROZEN].freeze

      RLIMITS = {
        rlimit_cpu: [10, 30],
        # nproc limits the *user's* total process count, not the sandbox's.
        # 200 is easily exceeded on a busy dev machine, which makes every
        # fork in the sandboxed command fail with EAGAIN. 1024 still guards
        # against fork bombs without breaking normal use.
        rlimit_nproc: [1024, 1024],
        rlimit_fsize: [10_485_760, 10_485_760],
        rlimit_nofile: [200, 200],
        rlimit_as: [2_147_483_648, 2_147_483_648]
      }.freeze

      POLL_INTERVAL = 0.05

      def initialize(timeout: 30, max_output: MAX_OUTPUT_SIZE)
        @default_timeout = timeout
        @max_output = max_output
      end

      def call(command, timeout: @default_timeout, workdir: nil, env: {}, stdin: nil)
        raise ArgumentError, "command must not be nil" if command.nil?
        raise ArgumentError, "command must not be empty" if command.respond_to?(:empty?) && command.empty?

        argv = build_argv(command)
        child_env = build_environment(env)

        if workdir
          execute_in_dir(argv, child_env, workdir, timeout, stdin)
        else
          Dir.mktmpdir("ask_sandbox") do |dir|
            execute_in_dir(argv, child_env, dir, timeout, stdin)
          end
        end
      end

      private

      def build_argv(command)
        case command
        when String then ["bash", "-c", command]
        when Array then command.map(&:to_s)
        else raise ArgumentError, "command must be a String or Array of Strings"
        end
      end

      def build_environment(extra_env)
        env = {}
        STRIP_ENV_VARS.each { |v| env[v] = nil }
        ENV.each_key do |key|
          next if key.start_with?("ASK_")
          STRIP_ENV_PREFIXES.each { |p| env[key] = nil if key.start_with?(p) }
        end
        extra_env.each { |k, v| env[k.to_s] = v.to_s }
        env
      end

      def self.supported_rlimits
        @supported_rlimits ||= {}.tap do |opts|
          RLIMITS.each do |option, (soft, hard)|
            begin
              pid = Process.spawn({}, "true", {option => [soft, hard]})
              Process.waitpid(pid)
              opts[option] = [soft, hard]
            rescue ArgumentError, Errno::EINVAL, NotImplementedError
            end
          end
        end
      end

      def execute_in_dir(argv, env, dir, timeout, stdin_data)
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe
        stdin_r, stdin_w = IO.pipe

        spawn_opts = {
          pgroup: true,
          chdir: dir,
          in: stdin_r,
          out: stdout_w,
          err: stderr_w
        }.merge!(self.class.supported_rlimits)

        pid = Process.spawn(env, *argv, **spawn_opts)

        stdin_r.close
        stdout_w.close
        stderr_w.close

        stdin_thread = Thread.new do
          if stdin_data && !stdin_data.empty?
            begin
              stdin_w.write(stdin_data)
            rescue Errno::EPIPE
            end
          end
          stdin_w.close
        rescue IOError
        end

        stdout_chunks = []
        stderr_chunks = []
        stdout_thread = Thread.new { read_stream(stdout_r, stdout_chunks) }
        stderr_thread = Thread.new { read_stream(stderr_r, stderr_chunks) }

        exit_status, timed_out = wait_for_process(pid, timeout)

        stdin_thread.join
        stdout_thread.join
        stderr_thread.join

        [stdout_r, stderr_r, stdin_w].each { |io| io.close rescue nil }

        begin
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
        end

        stdout_str = truncate_output(stdout_chunks.join)
        stderr_str = truncate_output(stderr_chunks.join)

        Result.new(
          stdout: stdout_str,
          stderr: stderr_str,
          exit_code: exit_status&.exitstatus,
          timed_out: timed_out
        )
      end

      def wait_for_process(pid, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return [status, false] if status

          sleep POLL_INTERVAL
        end

        kill_process_group(pid)
        [nil, true]
      rescue Errno::ECHILD
        [nil, false]
      end

      def kill_process_group(pid)
        begin
          Process.kill(:TERM, -pid)
          _, status = Process.waitpid2(pid, 1)
          return if status
        rescue Errno::ESRCH, Errno::ECHILD
          return
        end

        begin
          Process.kill(:KILL, -pid)
          Process.waitpid(pid, 1)
        rescue Errno::ESRCH, Errno::ECHILD
        end
      end

      def read_stream(io, chunks)
        buffer = String.new(capacity: @max_output + 4096)
        while (data = io.read(8192))
          buffer << data
          break if buffer.bytesize > @max_output
        end
        chunks << buffer
      rescue IOError
      ensure
        io.close rescue nil
      end

      def truncate_output(str)
        if str.bytesize > @max_output
          str.byteslice(0, @max_output) << "\n[Truncated — output exceeds #{@max_output} bytes]\n"
        else
          str
        end
      end
    end
  end
end
