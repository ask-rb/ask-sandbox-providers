# frozen_string_literal: true

require_relative "ask/sandbox/version"
require_relative "ask/sandbox/base"
require_relative "ask/sandbox/local"
require_relative "ask/sandbox/docker"
require_relative "ask/sandbox/daytona"
require_relative "ask/sandbox/cloudflare"

module Ask
  module Sandbox
    class << self
      # The currently configured sandbox provider.
      # Defaults to {Ask::Sandbox::Local} (subprocess + rlimits).
      #
      # @return [Ask::Sandbox::Base]
      def provider
        @provider ||= Ask::Sandbox::Local.new
      end

      # Set the sandbox provider.
      #
      # @param provider [Ask::Sandbox::Base, Symbol]
      #   Pass a provider instance, or +:local+/+:docker+/+:daytona+/+:cloudflare+
      #   to use a default instance of that provider.
      def provider=(provider)
        @provider = case provider
        when Symbol then resolve_provider(provider)
        else provider
        end
      end

      private

      def resolve_provider(name)
        case name
        when :local then Local.new
        when :docker then Docker.new
        when :daytona then Daytona.new
        when :cloudflare then Cloudflare.new
        else raise ArgumentError, "Unknown sandbox provider: #{name.inspect}. " \
                                   "Supported: :local, :docker, :daytona, :cloudflare"
        end
      end
    end
  end
end
