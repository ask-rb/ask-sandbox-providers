# frozen_string_literal: true

module Ask
  module Sandbox
    # @!group Errors

    # Base error class for all sandbox provider errors.
    class Error < StandardError; end

    # Raised when a provider is misconfigured (missing API key, invalid image, etc.).
    class ConfigurationError < Error; end

    # Raised when a provider's runtime is unavailable (Docker not running, etc.).
    class ProviderUnavailable < Error; end

    # Raised when execution fails unexpectedly.
    class ExecutionError < Error; end

    # @!endgroup

    # Structured result from a sandbox command execution.
    #
    # @!attribute [r] stdout
    #   @return [String] captured standard output
    # @!attribute [r] stderr
    #   @return [String] captured standard error
    # @!attribute [r] exit_code
    #   @return [Integer, nil] process exit code (nil if killed by signal)
    # @!attribute [r] timed_out
    #   @return [Boolean] whether execution was terminated due to timeout
    Result = Data.define(:stdout, :stderr, :exit_code, :timed_out) do
      # @return [Boolean] true if the command exited successfully (exit code 0)
      def success?
        exit_code == 0
      end
    end

    # Abstract base class for all sandbox providers.
    #
    # A sandbox provider is responsible for executing commands in an isolated
    # environment. Subclasses implement +#call+ which runs a command and returns
    # an {Ask::Sandbox::Result}.
    #
    # @example
    #   sandbox = Ask::Sandbox::Local.new
    #   result = sandbox.call("ls -la", timeout: 10)
    #   result.stdout  # => "..."
    #   result.exit_code  # => 0
    #
    class Base
      # Execute a command in the sandbox.
      #
      # @param command [String, Array<String>]
      #   When a String, executed via a shell (bash -c).
      #   When an Array, executed directly with no shell interpretation.
      # @param timeout [Integer] max execution time in seconds (default: 30)
      # @param workdir [String, nil] working directory inside the sandbox
      # @param env [Hash{String => String}] extra environment variables
      # @param stdin [String, nil] data to pipe to the command's stdin
      # @return [Ask::Sandbox::Result]
      def call(command, timeout: 30, workdir: nil, env: {}, stdin: nil)
        raise NotImplementedError, "#{self.class} must implement #call(command, ...)"
      end
    end
  end
end
