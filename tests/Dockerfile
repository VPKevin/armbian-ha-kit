FROM debian:bookworm-slim

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    bash ca-certificates coreutils git sed \
    mawk \
    curl wget \
    shellcheck bats \
  && rm -rf /var/lib/apt/lists/*

# Installe caddy depuis les dépôts Debian (suffisant pour valider le Caddyfile)
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends caddy \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /repo

CMD bash -lc 'shellcheck scripts/install.sh scripts/lib/*.sh \
  && caddy fmt --overwrite Caddyfile \
  && grep -Fq "\${HA_DOMAIN} {" Caddyfile \
  && bats tests/*.bats'
