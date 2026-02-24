#!/usr/bin/env bash
set -euo pipefail

echo "== Smoke tests: container environement =="

# Vérifier présence du binaire docker
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker CLI absent"
  exit 2
fi

echo "docker CLI:" $(docker --version || true)

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
