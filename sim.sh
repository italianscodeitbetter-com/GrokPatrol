#!/bin/bash
# MuJoCo museum: the Go1 with physics and its trained policy, fixed cameras, people and a suitcase.
# Needs ./run.sh running. Add --viewer to open the native MuJoCo window as well.
cd "$(dirname "$0")"
if [[ " $* " == *" --viewer "* ]]; then
  exec .venv/bin/mjpython sim/world.py "$@"   # on macOS the viewer must own the main thread
fi
exec .venv/bin/python sim/world.py "$@"
