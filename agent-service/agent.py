"""Clearline's optional OpenAI Agents SDK worker. Private stdin/stdout, no listener.

Never print prompts, keys, response bodies, or exception details to logs. Stdout is
only the private result pipe consumed by the Swift client. Tracing is disabled.
"""
import asyncio
import json
import logging
import sys

logging.disable(logging.CRITICAL)


async def execute(payload):
    from agents import Agent, ModelSettings, OpenAIResponsesModel, Runner, set_tracing_disabled
    from openai import AsyncOpenAI
    from openai.types.shared import Reasoning
    from pydantic import BaseModel, ConfigDict

    set_tracing_disabled(True)

    class Edit(BaseModel):
        model_config = ConfigDict(extra="forbid")
        location: int
        length: int
        original: str
        replacement: str
        category: str
        explanation: str

    class Proposal(BaseModel):
        model_config = ConfigDict(extra="forbid")
        text: str
        explanation: str
        tone: str
        warnings: list[str]
        recommendations: list[str]
        edits: list[Edit]

    request = payload["request"]
    # Keep aligned with ModelCapability in ClearlineCore (official API model docs).
    standard_efforts = ("none", "low", "medium", "high", "xhigh")
    allowed = {
        "gpt-4.1-mini": (), "gpt-4.1": (),
        "gpt-5.4": standard_efforts, "gpt-5.5": standard_efforts,
        "gpt-5.6-luna": standard_efforts + ("max",),
        "gpt-5.6-terra": standard_efforts + ("max",),
        "gpt-5.6-sol": standard_efforts + ("max",),
        "gpt-6-astra": ("low", "medium", "high", "xhigh", "max"),
    }
    model = request["model"]
    if not isinstance(model, str) or not model.strip():
        raise ValueError("unsupported_model")
    effort = request.get("reasoning", {}).get("effort")
    if (effort is not None and effort not in allowed.get(model, ())) or (allowed.get(model, ()) and effort is None):
        raise ValueError("unsupported_effort")
    settings = ModelSettings(max_tokens=request["max_output_tokens"], store=False)
    if effort is not None:
        settings.reasoning = Reasoning(effort=effort)
    async with AsyncOpenAI(api_key=payload["api_key"], max_retries=2, timeout=payload["timeout"]) as client:
        agent = Agent(
            name="Clearline writing assistant",
            instructions=request["instructions"],
            model=OpenAIResponsesModel(model=model, openai_client=client),
            model_settings=settings,
            output_type=Proposal,
            tools=[],
        )
        result = await asyncio.wait_for(Runner.run(agent, request["input"], max_turns=1), timeout=payload["timeout"])
        reports = []
        for response in getattr(result, "raw_responses", []):
            usage = response.usage
            reports.append({"model": model, "usage": {
                "input_tokens": usage.input_tokens,
                "output_tokens": usage.output_tokens,
                "input_tokens_details": {"cached_tokens": usage.input_tokens_details.cached_tokens},
                "output_tokens_details": {"reasoning_tokens": usage.output_tokens_details.reasoning_tokens},
            }})
        return {"result": result.final_output.model_dump(), "usage": reports}


def main():
    try:
        raw = sys.stdin.buffer.read(1_000_001)
        if len(raw) > 1_000_000:
            raise ValueError("too_large")
        payload = json.loads(raw)
        output = asyncio.run(execute(payload))
    except BaseException as exc:
        name = type(exc).__name__
        code = {"AuthenticationError": "authentication", "PermissionDeniedError": "authentication", "RateLimitError": "rate_limit", "TimeoutError": "timeout", "APITimeoutError": "timeout", "APIConnectionError": "connection"}.get(name, "runtime")
        output = {"error": code}
    sys.stdout.write(json.dumps(output))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
