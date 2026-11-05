#!/bin/bash
# Ronda: the backend lives in admin/backend. Same as before: DOG=mujoco (default here, run ./sim.sh too),
# DOG=sim (kinematic, no 3D) or DOG=go1 ./run.sh. Mac console on http://localhost:8000, Next console in admin/web.
cd "$(dirname "$0")"
DOG="${DOG:-mujoco}" exec ./admin/run.sh "$@"
