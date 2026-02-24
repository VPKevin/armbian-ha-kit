# Multi-stage Dockerfile for tests
# Targets:
#  - lint    : léger, pour exécuter shellcheck / bats / shfmt (fast)
#  - armbian : image proche d'une box Armbian (ophub/armbian-trixie) pour exécuter le bootstrap

# -----------------------
# Target: lint
# -----------------------
FROM debian:bookworm-slim AS lint

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    bash curl ca-certificates git \
    shellcheck shfmt bats jq \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /repo

# Usage: mount your repo at /repo and run the checks you need
ENTRYPOINT ["/bin/bash", "-lc"]
CMD ["echo 'Use: docker run --rm -v $(pwd):/repo -w /repo <image> shellcheck scripts/*.sh' "]

# -----------------------
# Target: armbian
# -----------------------
FROM ophub/armbian-trixie:latest AS armbian

ENV DEBIAN_FRONTEND=noninteractive

# Installer utilitaires de base
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https \
    sudo iproute2 iputils-ping bash nano procps dirmngr whiptail \
  && rm -rf /var/lib/apt/lists/*

# Ajouter dépôt officiel Docker pour installer docker-compose-plugin
RUN set -eux; \
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; \
  echo "deb [arch=arm64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list; \
  apt-get update -y

# Installer docker et plugin compose
RUN apt-get install -y --no-install-recommends docker.io docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*

# Installer aussi le binaire docker-compose officiel (backup)
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
  && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64 \
  && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Créer un utilisateur non-root 'tester'
RUN useradd -m tester && echo "tester ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tester
USER tester
WORKDIR /home/tester

# Copier les scripts utiles (entrypoint / smoke test)
COPY --chown=tester:tester tests/entrypoint-bootstrap.sh /usr/local/bin/entrypoint-bootstrap.sh
COPY --chown=tester:tester tests/run-smoke.sh /usr/local/bin/run-smoke.sh
RUN sudo chmod +x /usr/local/bin/entrypoint-bootstrap.sh /usr/local/bin/run-smoke.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-bootstrap.sh"]
CMD ["--help"]
