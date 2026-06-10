# frozen_string_literal: true

require "json"
require "securerandom"

module Ask
  module Sandbox
    # Executes commands in a Cloudflare Workers sandbox via a user-deployed
    # proxy Worker.
    #
    # The proxy Worker wraps the +@cloudflare/sandbox+ SDK and exposes an HTTP
    # API. The user is responsible for deploying the proxy Worker to Cloudflare.
    #
    # @example
    #   sandbox = Ask::Sandbox::Cloudflare.new(
    #     worker_url: "https://sandbox-proxy.my-worker.workers.dev",
    #     auth_token: ENV["CLOUDFLARE_SANDBOX_TOKEN"]
    #   )
    #   sandbox.call(["ruby", "-e", "puts 1+1"])
    #
    class Cloudflare < Base
      # @param worker_url [String] URL of the deployed proxy Worker
      # @param auth_token [String, nil] auth token for the proxy Worker (optional)
      # @param timeout [Integer] default timeout in seconds (default: 60)
      def initialize(worker_url: nil, auth_token: nil, timeout: 60)
        @worker_url = worker_url || ENV["CLOUDFLARE_SANDBOX_WORKER_URL"]
        @auth_token = auth_token || ENV["CLOUDFLARE_SANDBOX_AUTH_TOKEN"]
        @default_timeout = timeout
      end

      # (see Base#call)
      def call(command, timeout: @default_timeout, workdir: nil, env: {}, stdin: nil)
        raise ArgumentError, "command must not be nil" if command.nil?
        raise ArgumentError, "command must not be empty" if command.respond_to?(:empty?) && command.empty?
        raise ConfigurationError, "Cloudflare sandbox requires a worker_url. " \
                                   "Set CLOUDFLARE_SANDBOX_WORKER_URL in your " \
                                   "environment or pass `worker_url:` to #{self.class.name}.new" \
                                   unless @worker_url

        command_str = case command
                      when Array then command.map(&:to_s).join(" ")
                      when String then command
                      end

        make_request(command_str, timeout)
      end

      private

      def make_request(command, timeout)
        require "net/http"
        require "json"

        uri = URI(@worker_url)
        http = Net::HTTP.new(uri.host, uri.port || (uri.scheme == "https" ? 443 : 80))
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = timeout + 5

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{@auth_token}" if @auth_token
        request.body = JSON.generate({
          sandbox_id: SecureRandom.uuid,
          command: command,
          timeout: timeout
        })

        response = http.request(request)

        case response
        when Net::HTTPOK
          body = JSON.parse(response.body)
          Result.new(
            stdout: body["stdout"].to_s,
            stderr: body["stderr"].to_s,
            exit_code: body["exit_code"],
            timed_out: body["timed_out"] == true
          )
        when Net::HTTPUnauthorized, Net::HTTPForbidden
          raise ConfigurationError,
                "Cloudflare sandbox authentication failed (#{response.code}). " \
                "Check your auth token."
        when Net::HTTPServerError
          raise ProviderUnavailable,
                "Cloudflare sandbox proxy Worker returned #{response.code}: #{response.body}"
        when Net::HTTPNotFound
          raise ProviderUnavailable,
                "Cloudflare sandbox proxy Worker not found at #{@worker_url}. " \
                "Is the Worker deployed?"
        else
          raise ProviderUnavailable,
                "Cloudflare sandbox proxy Worker returned unexpected #{response.code}: #{response.body}"
        end

      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise ProviderUnavailable,
              "Cloudflare sandbox connection timed out: #{e.message}"
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH => e
        raise ProviderUnavailable,
              "Cloudflare sandbox unavailable: #{e.message}. " \
              "Is the proxy Worker deployed and reachable at #{@worker_url}?"
      end
    end
  end
end
