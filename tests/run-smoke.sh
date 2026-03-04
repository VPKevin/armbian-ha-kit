#!/usr/bin/env bash
set -euo pipefail

echo "== Smoke tests: container environement =="

# Si docker CLI est absent, ce n'est pas une erreur tant que le socket n'est pas monté.
if ! command -v docker >/dev/null 2>&1; then
  if [ -S /var/run/docker.sock ]; then
    echo "ERROR: docker CLI absent but docker socket is mounted" >&2
    exit 2
  else
    echo "docker CLI absent (ok si socket non monté)"
  fi
else
  echo "docker CLI:" $(docker --version || true)
fi

# Si le socket docker est monté, essayer docker ps
if [ -S /var/run/docker.sock ]; then
  echo "Docker socket detected at /var/run/docker.sock — running 'docker ps'"
  if ! docker ps -a --format '{{.ID}} {{.Status}}' >/dev/null 2>&1; then
    echo "ERROR: 'docker ps' failed (check permissions on the socket)"
    exit 3
  fi
  echo "docker ps OK"
else
  echo "No docker socket mounted — skipping 'docker ps'"
fi

# Test final: simple message
echo "All smoke checks passed"

exit 0
