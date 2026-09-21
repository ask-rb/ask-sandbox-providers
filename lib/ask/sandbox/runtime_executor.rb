# frozen_string_literal: true

require "ask/runtime"

module Ask
  module Sandbox
    # Adapts a sandbox provider to the ask-runtime tool executor contract.
    #
    # The executor accepts a ToolCall whose input contains +command+ and
    # optional sandbox options (+timeout+, +workdir+, +env+, and +stdin+).
    # When no workdir is supplied, the execution context's workspace is used.
    #
    #   executor = Ask::Sandbox::RuntimeExecutor.new(Ask::Sandbox.provider)
    #   call = Ask::Runtime::ToolCall.new(
    #     tool_name: "sandbox.execute",
    #     input: { command: ["ruby", "-e", "puts 1"] }
    #   )
    #   executor.execute(call).output[:stdout] # => "1\n"
    class RuntimeExecutor
      include Ask::Runtime::ToolExecutor

      TOOL_NAME = "sandbox.execute"

      attr_reader :provider

      def initialize(provider = nil)
        @provider = provider || Ask::Sandbox.provider
      end

      def supported_tools
        [TOOL_NAME]
      end

      # Execute a sandbox command and normalize its result for ask-runtime.
      #
      # @param tool_call [Ask::Runtime::ToolCall]
      # @param context [Ask::Runtime::ExecutionContext, nil]
      # @return [Ask::Runtime::ToolResult]
      def execute(tool_call, context: nil)
        context ||= Ask::Runtime::ExecutionContext.new
        started_at = Time.now
        started_call = tool_call.with(state: :running, started_at: started_at)
        emit(Ask::Runtime::Events::ToolStarted, tool_call: started_call, context: context)

        return cancel(started_call, context, started_at, "Cancelled before execution") if context.cancelled?

        result = execute_command(tool_call.input, context)
        return cancel(started_call, context, started_at, "Cancelled during execution") if context.cancelled?

        finish(started_call, context, result, started_at)
      rescue StandardError => e
        finish(started_call, context, Ask::Runtime::ToolResult.failure(
          "#{e.class}: #{e.message}"
        ), started_at)
      end

      private

      def execute_command(input, context)
        command = input_value(input, :command)
        raise ArgumentError, "command is required" if command.nil?

        options = {
          workdir: input_value(input, :workdir) || context.workspace,
          env: input_value(input, :env) || {},
          stdin: input_value(input, :stdin)
        }
        timeout = input_value(input, :timeout)
        options[:timeout] = timeout unless timeout.nil?

        sandbox_result = @provider.call(command, **options)
        metadata = {
          stdout: sandbox_result.stdout,
          stderr: sandbox_result.stderr,
          exit_code: sandbox_result.exit_code,
          timed_out: sandbox_result.timed_out
        }

        if sandbox_result.timed_out
          timeout_result("Sandbox command timed out", metadata)
        elsif sandbox_result.success?
          Ask::Runtime::ToolResult.success(data: metadata, metadata: metadata)
        else
          Ask::Runtime::ToolResult.failure(
            "Command exited with status #{sandbox_result.exit_code}", metadata: metadata
          )
        end
      end

      def input_value(input, key)
        input[key] || input[key.to_s]
      end

      def timeout_result(message, metadata)
        Ask::Runtime::ToolResult.new(
          result: Ask::Result.failure(message, metadata: metadata),
          outcome: :timeout
        )
      end

      def finish(started_call, context, result, started_at)
        finished_at = Time.now
        duration = finished_at - started_at
        result = with_duration(result, duration)
        state = if result.timeout?
          :timed_out
        elsif result.failure?
          :failed
        else
          :completed
        end
        terminal_call = started_call.with(
          state: state,
          tool_result: result,
          error: result.error_message,
          finished_at: finished_at
        )
        event_class = {
          completed: Ask::Runtime::Events::ToolCompleted,
          failed: Ask::Runtime::Events::ToolFailed,
          timed_out: Ask::Runtime::Events::ToolTimedOut
        }.fetch(state)
        emit(event_class, tool_call: terminal_call, tool_result: result,
             context: context, timestamp: finished_at, duration: duration)
        result
      end

      def cancel(started_call, context, started_at, reason)
        finished_at = Time.now
        duration = finished_at - started_at
        result = with_duration(Ask::Runtime::ToolResult.cancelled(reason), duration)
        terminal_call = started_call.with(
          state: :cancelled,
          tool_result: result,
          error: result.error_message,
          finished_at: finished_at
        )
        emit(Ask::Runtime::Events::ToolCancelled, tool_call: terminal_call,
             tool_result: result, context: context, timestamp: finished_at, duration: duration)
        result
      end

      def with_duration(result, duration)
        Ask::Runtime::ToolResult.new(
          result: result.result,
          outcome: result.outcome,
          duration: duration
        )
      end

      def emit(event_class, tool_call:, context:, **attrs)
        event = event_class.new(
          tool_call: tool_call,
          execution_context: context,
          timestamp: attrs.delete(:timestamp) || Time.now,
          **attrs
        )
        event_type = event_class.name.split("::").last
          .gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase.to_sym
        context.event_sink.emit(event_type, event: event)
      end
    end
  end
end
