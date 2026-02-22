FROM debian:bookworm-slim

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    bash ca-certificates coreutils git sed \
    mawk \
    shellcheck bats \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /repo

CMD ["bash", "-lc", "shellcheck scripts/install.sh scripts/lib/*.sh && bats tests/*.bats"]
