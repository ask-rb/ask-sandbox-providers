# frozen_string_literal: true

require "test_helper"

class Ask::Sandbox::RuntimeExecutorTest < Minitest::Test
  include Ask::Runtime::Testing::ExecutorContract

  class FakeProvider
    attr_reader :calls

    def initialize(result:)
      @result = result
      @calls = []
    end

    def call(command, **options)
      @calls << [command, options]
      raise @result if @result.is_a?(Exception)

      @result
    end
  end

  class ContractProvider
    def call(command, **_options)
      if command == "fail"
        Ask::Sandbox::Result.new(stdout: "", stderr: "failed", exit_code: 1, timed_out: false)
      else
        Ask::Sandbox::Result.new(stdout: "ok", stderr: "", exit_code: 0, timed_out: false)
      end
    end
  end

  def test_sandbox_executor_conforms_to_runtime_contract
    context_factory = ->(event_sink:, canceller: nil) do
      Ask::Runtime::ExecutionContext.new(
        session_id: "s_sandbox", turn: 1, event_sink: event_sink, canceller: canceller
      )
    end

    assert_conforms_to_runtime_contract(
      Ask::Sandbox::RuntimeExecutor.new(ContractProvider.new),
      success_call: build_tool_call(input: { command: "ok" }),
      failure_call: build_tool_call(input: { command: "fail" }),
      cancelled_call: build_tool_call(input: { command: "ok" }),
      context_factory: context_factory
    )
  end

  def build_tool_call(**overrides)
    Ask::Runtime::ToolCall.new(
      id: "tc_sandbox",
      tool_name: "sandbox.execute",
      input: { command: ["ruby", "-e", "puts 1"] },
      session_id: "s_001",
      turn: 2,
      **overrides
    )
  end

  def build_context(**overrides)
    Ask::Runtime::ExecutionContext.new(
      session_id: "s_001",
      turn: 2,
      workspace: "/workspace",
      **overrides
    )
  end

  def test_executes_command_and_normalizes_success
    provider = FakeProvider.new(
      result: Ask::Sandbox::Result.new(
        stdout: "1\n", stderr: "", exit_code: 0, timed_out: false
      )
    )
    executor = Ask::Sandbox::RuntimeExecutor.new(provider)

    result = executor.execute(
      build_tool_call(input: {
        command: ["ruby", "-e", "puts 1"],
        timeout: 5,
        env: { "MODE" => "test" },
        stdin: "input"
      }),
      context: build_context
    )

    assert result.success?
    assert_equal({ stdout: "1\n", stderr: "", exit_code: 0, timed_out: false }, result.output)
    assert_equal [
      ["ruby", "-e", "puts 1"],
      { timeout: 5, workdir: "/workspace", env: { "MODE" => "test" }, stdin: "input" }
    ], provider.calls.first
    assert_kind_of Float, result.duration
  end

  def test_maps_nonzero_exit_to_failure_with_command_output_metadata
    provider = FakeProvider.new(
      result: Ask::Sandbox::Result.new(
        stdout: "", stderr: "nope\n", exit_code: 7, timed_out: false
      )
    )
    result = Ask::Sandbox::RuntimeExecutor.new(provider).execute(build_tool_call)

    assert result.failure?
    assert_equal "Command exited with status 7", result.error_message
    assert_equal "nope\n", result.result.metadata[:stderr]
    assert_equal 7, result.result.metadata[:exit_code]
  end

  def test_maps_timeout_to_timed_out_result
    provider = FakeProvider.new(
      result: Ask::Sandbox::Result.new(
        stdout: "partial", stderr: "", exit_code: nil, timed_out: true
      )
    )
    result = Ask::Sandbox::RuntimeExecutor.new(provider).execute(build_tool_call)

    assert result.timeout?
    assert_equal "Sandbox command timed out", result.error_message
  end

  def test_emits_started_and_terminal_events
    provider = FakeProvider.new(
      result: Ask::Sandbox::Result.new(
        stdout: "ok", stderr: "", exit_code: 0, timed_out: false
      )
    )
    events = []
    sink = Ask::Runtime::EventSink.new
    sink.on(:tool_started) { |payload| events << payload[:event] }
    sink.on(:tool_completed) { |payload| events << payload[:event] }

    executor = Ask::Sandbox::RuntimeExecutor.new(provider)
    call = build_tool_call
    result = executor.execute(call, context: build_context(event_sink: sink))

    assert result.success?
    assert_equal [Ask::Runtime::Events::ToolStarted, Ask::Runtime::Events::ToolCompleted],
      events.map(&:class)
    assert_equal "tc_sandbox", events.last.tool_call_id
    assert events.last.tool_call.completed?
  end

  def test_cancellation_before_execution_does_not_call_provider
    provider = FakeProvider.new(result: RuntimeError.new("provider should not be called"))
    canceller = Ask::Runtime::Canceller.new
    canceller.cancel

    result = Ask::Sandbox::RuntimeExecutor.new(provider).execute(
      build_tool_call,
      context: build_context(canceller: canceller)
    )

    assert result.cancelled?
    assert_empty provider.calls
  end

  def test_provider_errors_are_normalized
    provider = FakeProvider.new(result: Ask::Sandbox::ExecutionError.new("sandbox failed"))
    result = Ask::Sandbox::RuntimeExecutor.new(provider).execute(build_tool_call)

    assert result.failure?
    assert_equal "Ask::Sandbox::ExecutionError: sandbox failed", result.error_message
  end
end
