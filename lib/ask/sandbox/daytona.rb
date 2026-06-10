# frozen_string_literal: true

module Ask
  module Sandbox
    # Executes commands in a Daytona sandbox via the official +daytona+ gem.
    #
    # The +daytona+ gem is loaded lazily (inside +#call+). If the gem is not
    # installed, a clear {LoadError} is raised with installation instructions.
    #
    # @example
    #   sandbox = Ask::Sandbox::Daytona.new(
    #     api_key: "dta_xxxx",
    #     server_url: "https://api.daytona.io"
    #   )
    #   sandbox.call(["ruby", "-e", "puts 1+1"])
    #
    class Daytona < Base
      # @param api_key [String, nil] Daytona API key. If nil, tries to resolve
      #   via {Ask::Auth.lookup}("DAYTONA_API_KEY") or +ENV["DAYTONA_API_KEY"]+.
      # @param server_url [String, nil] Daytona server URL. Falls back to the
      #   +daytona+ gem's default.
      # @param image [String, nil] sandbox image (e.g. "ruby:3.4")
      # @param timeout [Integer] default timeout in seconds (default: 120 —
      #   Daytona sandboxes may take time to boot)
      def initialize(api_key: nil, server_url: nil, image: nil, timeout: 120)
        @api_key = api_key
        @server_url = server_url
        @image = image
        @default_timeout = timeout
      end

      # (see Base#call)
      #
      # Lazily loads the +daytona+ gem on first call.
      def call(command, timeout: @default_timeout, workdir: nil, env: {}, stdin: nil)
        raise ArgumentError, "command must not be nil" if command.nil?
        raise ArgumentError, "command must not be empty" if command.respond_to?(:empty?) && command.empty?

        api_key = resolve_api_key
        ensure_daytona_gem!
        execute_on_daytona(command, api_key, timeout)
      end

      private

      def resolve_api_key
        key = @api_key
        key ||= ENV["DAYTONA_API_KEY"]

        if defined?(Ask::Auth) && Ask::Auth.respond_to?(:lookup)
          key ||= Ask::Auth.lookup("DAYTONA_API_KEY") rescue nil
        end

        raise ConfigurationError,
              "Daytona sandbox requires an API key. Set DAYTONA_API_KEY in your " \
              "environment or pass `api_key:` to #{self.class.name}.new" if key.nil? || key.empty?

        key
      end

      def ensure_daytona_gem!
        require "daytona"
      rescue LoadError => e
        raise LoadError,
              "The `daytona` gem is required for the Daytona sandbox provider. " \
              "Add `gem 'daytona'` to your Gemfile or run `gem install daytona`. " \
              "(original: #{e.message})"
      end

      def execute_on_daytona(command, api_key, timeout)
        # Build the command string
        command_str = case command
                      when Array then command.map(&:to_s).join(" ")
                      when String then command
                      end

        # Create a Daytona client and sandbox
        client = Daytona::Client.new(api_key: api_key, server_url: @server_url)

        sandbox = client.sandboxes.create(image: @image || "ruby:3.4")

        begin
          result = sandbox.process.execute(command_str, timeout: timeout)

          Result.new(
            stdout: result["stdout"].to_s,
            stderr: result["stderr"].to_s,
            exit_code: result["exit_code"],
            timed_out: result["timed_out"] == true
          )
        rescue => e
          raise ExecutionError,
                "Daytona sandbox execution failed: #{e.message}"
        ensure
          # Clean up the sandbox
          begin
            sandbox.delete
          rescue => e
            # Non-fatal: log but don't propagate
          end
        end
      end
    end
  end
end
