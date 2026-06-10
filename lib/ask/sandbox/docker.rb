# frozen_string_literal: true

module Ask
  module Sandbox
    # Executes commands in a Docker container with hardened security settings.
    #
    # Uses the +docker+ CLI binary directly (no gem dependencies). Requires
    # a running Docker daemon.
    #
    # Security measures:
    # - Read-only root filesystem (+--read-only+)
    # - All Linux capabilities dropped (+--cap-drop ALL+)
    # - No privilege escalation (+--security-opt no-new-privileges+)
    # - Network egress disabled by default (+--network none+)
    # - PIDs limit (+--pids-limit 100+)
    # - Memory and CPU limits
    # - Container auto-removal (+--rm+)
    #
    # @example
    #   sandbox = Ask::Sandbox::Docker.new(image: "ruby:3.4-alpine")
    #   sandbox.call(["ruby", "-e", "puts 1+1"])
    #
    class Docker < Base
      # @param image [String] Docker image to use (default: "ruby:3.4-alpine")
      # @param memory [String, nil] memory limit (e.g. "512m", "1g")
      # @param cpus [Float, nil] CPU limit (e.g. 1.0)
      # @param network [Boolean] allow network egress (default: false)
      # @param read_only [Boolean] read-only root filesystem (default: true)
      # @param cap_drop [String, nil] capabilities to drop (default: "ALL")
      # @param user [String, nil] run as specific user (default: nil = container default)
      # @param timeout [Integer] default timeout in seconds
      # @param remove [Boolean] auto-remove container after execution (default: true)
      def initialize(
        image: "ruby:3.4-alpine",
        memory: "512m",
        cpus: 1.0,
        network: false,
        read_only: true,
        cap_drop: "ALL",
        user: nil,
        timeout: 30,
        remove: true
      )
        @image = image
        @memory = memory
        @cpus = cpus
        @network = network
        @read_only = read_only
        @cap_drop = cap_drop
        @user = user
        @default_timeout = timeout
        @remove = remove
      end

      # (see Base#call)
      def call(command, timeout: @default_timeout, workdir: nil, env: {}, stdin: nil)
        raise ArgumentError, "command must not be nil" if command.nil?
        raise ArgumentError, "command must not be empty" if command.respond_to?(:empty?) && command.empty?

        check_docker_available!

        docker_argv = build_docker_argv(command, env, workdir)
        run_docker(docker_argv, timeout, stdin)
      end

      private

      def check_docker_available!
        return if @docker_checked
        system("docker", "info", out: File::NULL, err: File::NULL)
        @docker_checked = true
      rescue SystemCallError
        raise ProviderUnavailable,
              "Docker sandbox unavailable: `docker info` failed. " \
              "Is Docker installed and the daemon running?"
      end

      def build_docker_argv(command, env, workdir)
        argv = ["docker", "run", "--rm", "-i"]

        # Resource limits
        argv << "--memory" << @memory.to_s if @memory
        argv << "--cpus" << @cpus.to_s if @cpus

        # Security hardening
        argv << "--network" << "none" unless @network
        argv << "--read-only" if @read_only
        argv << "--cap-drop" << @cap_drop.to_s if @cap_drop
        argv << "--security-opt" << "no-new-privileges"
        argv << "--pids-limit" << "100"

        # User
        argv << "--user" << @user.to_s if @user

        # Working directory
        argv << "--workdir" << workdir if workdir

        # Environment variables
        env.each do |key, value|
          argv << "--env" << "#{key}=#{value}"
        end

        # Don't use ENTRYPOINT — we control the command
        argv << "--entrypoint" << ""

        # Image
        argv << @image

        # Command — use array form for clean argv forwarding
        case command
        when String
          # String commands run via the container's shell
          argv << "/bin/sh" << "-c" << command
        when Array
          # Array commands forward directly as argv
          argv.concat(command.map(&:to_s))
        end

        argv
      end

      def run_docker(docker_argv, timeout, stdin_data)
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe
        stdin_r, stdin_w = IO.pipe

        pid = Process.spawn(
          *docker_argv,
          pgroup: true,
          in: stdin_r,
          out: stdout_w,
          err: stderr_w
        )

        stdin_r.close
        stdout_w.close
        stderr_w.close

        # Write stdin in a thread
        stdin_thread = Thread.new do
          if stdin_data && !stdin_data.empty?
            begin
              stdin_w.write(stdin_data)
            rescue Errno::EPIPE
              # Command closed stdin early
            end
          end
          stdin_w.close
        rescue IOError
          # Already closed
        end

        # Capture output in threads
        stdout_chunks = []
        stderr_chunks = []
        stdout_thread = Thread.new { read_stream(stdout_r, stdout_chunks) }
        stderr_thread = Thread.new { read_stream(stderr_r, stderr_chunks) }

        exit_status, timed_out = wait_for_docker(pid, timeout)

        stdin_thread.join
        stdout_thread.join
        stderr_thread.join

        [stdout_r, stderr_r, stdin_w].each { |io| io.close rescue nil }

        # Final reap
        begin
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
        end

        stdout_str = stdout_chunks.join
        stderr_str = stderr_chunks.join

        Result.new(
          stdout: stdout_str,
          stderr: stderr_str,
          exit_code: exit_status&.exitstatus,
          timed_out: timed_out
        )
      end

      def wait_for_docker(pid, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return [status, false] if status

          sleep 0.1
        end

        # Timeout — use docker stop (graceful) then docker kill (force)
        begin
          # We need the container ID to stop it. For "docker run --rm",
          # the container name can be extracted, but it's tricky.
          # Simplest: just kill the docker CLI process, which stops the container
          # since we used --rm.
          Process.kill(:TERM, pid)
          _, status = Process.waitpid2(pid, 3)
          return [status, true] if status
        rescue Errno::ESRCH, Errno::ECHILD
        end

        begin
          Process.kill(:KILL, pid)
          Process.waitpid(pid, 1)
        rescue Errno::ESRCH, Errno::ECHILD
        end

        [nil, true]
      end

      def read_stream(io, chunks)
        buffer = String.new(capacity: 102_400)
        while (data = io.read(8192))
          buffer << data
          break if buffer.bytesize > 102_400
        end
        chunks << buffer
      rescue IOError
      ensure
        io.close rescue nil
      end
    end
  end
end
