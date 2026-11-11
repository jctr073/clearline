#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
runtime="${CLEARLINE_AGENT_RUNTIME:-$HOME/Library/Application Support/Clearline/AgentRuntime}"
python="${CLEARLINE_PYTHON:-python3}"
"$python" -c 'import sys; sys.exit("Python 3.11 or newer is required. Set CLEARLINE_PYTHON to a supported interpreter.") if sys.version_info < (3,11) else None'
"$python" -m venv "$runtime"
# This environment receives the OpenAI key: keep it private to this user.
chmod 700 "$runtime"
# requirements.txt locks every dependency, including transitive ones, to a hash.
"$runtime/bin/python3" -m pip install --require-hashes --no-deps -r agent-service/requirements.txt
"$runtime/bin/python3" -m pip check
# Exercise real SDK initialization: mocked request tests miss incompatible usage types.
"$runtime/bin/python3" -c 'from agents import RunContextWrapper; assert RunContextWrapper(context=None).usage.total_tokens == 0'
printf 'Installed OpenAI Agents runtime at %s\n' "$runtime"
