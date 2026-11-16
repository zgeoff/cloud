# The container that the Deploy prod job runs nixie's prod doctor in: Bun at the version nixie's
# .bun-version names, and git, which the verify CLI reads the checkout with. The job mounts the
# runner's kubectl, the nixie checkout and the nixie-verify kubeconfig, and nothing else;
# scripts/run-nixie-doctor-check.ts builds it and refuses a Bun that differs from nixie's.
FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d

ARG DEBIAN_FRONTEND=noninteractive

# git is pinned to an exact version from one snapshot.debian.org moment, which keeps that version
# after the live archive replaces it. A snapshot's Release files expire, so apt skips that check;
# the archive key still signs them. A bump moves both; read the candidates with
#   apt-get --snapshot <stamp> update && apt-cache --snapshot <stamp> policy git
ARG DEBIAN_SNAPSHOT=20261020T213255Z
ARG GIT_VERSION=1:2.47.3-0+deb13u1

RUN apt-get --snapshot "$DEBIAN_SNAPSHOT" -o Acquire::Check-Valid-Until=false update \
 && apt-get --snapshot "$DEBIAN_SNAPSHOT" install --yes --no-install-recommends "git=$GIT_VERSION" \
 && rm -rf /var/lib/apt/lists/*
