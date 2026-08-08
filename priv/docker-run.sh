#!/usr/bin/env bash
set -u

echo "$$" > "${DOCKER_CI_PIDFILE:?DOCKER_CI_PIDFILE is required}"
exec docker "$@"
