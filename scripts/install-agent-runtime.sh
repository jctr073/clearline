#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
runtime="${CLEARLINE_AGENT_RUNTIME:-$HOME/Library/Application Support/Clearline/AgentRuntime}"
python="${CLEARLINE_PYTHON:-python3}"
"$python" -c 'import sys; sys.exit("Python 3.10 or newer is required. Set CLEARLINE_PYTHON to a supported interpreter.") if sys.version_info < (3,10) else None'
"$python" -m venv "$runtime"
"$runtime/bin/python3" -m pip install -r agent-service/requirements.txt
"$runtime/bin/python3" -m pip check
# Exercise real SDK initialization: mocked request tests miss incompatible usage types.
"$runtime/bin/python3" -c 'from agents import RunContextWrapper; assert RunContextWrapper(context=None).usage.total_tokens == 0'
printf 'Installed OpenAI Agents runtime at %s\n' "$runtime"
