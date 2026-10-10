# The agent image: imp-base plus the tools an agent session runs on an imp.
# It holds binaries only: no configuration, no login state and no secret. atc
# sets those up per session at launch. Build it on the imp host, from a clean
# checkout of the zgeoff/cloud commit on main that the image records:
#   imp image build images/agent --name "agent-$(git rev-parse --short HEAD)"
# docs/runbooks/agent-image.md covers the build, an update and a rollback.
#
# Every pin below is a reviewed change. The image name carries the commit, so
# each build gets a new imp image name and the previous image stays for a
# rollback.

# imp-base, pinned to the multi-arch index digest. Check a bump with:
#   gh attestation verify oci://ghcr.io/zgeoff/imp-base:X.Y.Z --repo zgeoff/imp
FROM ghcr.io/zgeoff/imp-base:0.33.0@sha256:b140d1d195497cb6abf06ae386f549fcc14ae0c45fb0e9378a7399a528758be2

ARG DEBIAN_FRONTEND=noninteractive

# Ubuntu packages come from snapshot.ubuntu.com at a fixed moment, so the
# exact versions below stay installable after the archive moves on. A bump
# moves the snapshot and the versions together; read the candidates with
#   apt-get update --snapshot <stamp> && apt-cache policy <package>
# docker-compose-plugin comes from Docker's repository, which keeps old builds.
ARG UBUNTU_SNAPSHOT=20261006T000000Z
ARG GIT_VERSION=1:2.43.0-1ubuntu7.3
ARG BASH_VERSION=5.2.21-2ubuntu4
ARG JQ_VERSION=1.7.1-3ubuntu0.24.04.2
ARG BUILD_ESSENTIAL_VERSION=12.10ubuntu1
ARG PKG_CONFIG_VERSION=1.8.1-2build1
ARG PYTHON3_VERSION=3.12.3-0ubuntu2.1
ARG PYTHON3_PIP_VERSION=24.0+dfsg-1ubuntu1.3
ARG PYTHON_IS_PYTHON3_VERSION=3.11.4-1
ARG UNZIP_VERSION=6.0-28ubuntu4.1
ARG XZ_UTILS_VERSION=5.6.1+really5.4.5-1ubuntu0.3
ARG DOCKER_COMPOSE_VERSION=5.6.0-1~ubuntu.24.04~noble

# build-essential: native npm modules and Python wheels without a binary build
# need a compiler. docker-compose-plugin: dev stacks use compose.
RUN apt-get update --snapshot "$UBUNTU_SNAPSHOT" \
 && apt-get install -y --no-install-recommends \
      "git=$GIT_VERSION" "bash=$BASH_VERSION" "jq=$JQ_VERSION" \
      "build-essential=$BUILD_ESSENTIAL_VERSION" "pkg-config=$PKG_CONFIG_VERSION" \
      "python3=$PYTHON3_VERSION" "python3-venv=$PYTHON3_VERSION" \
      "python3-pip=$PYTHON3_PIP_VERSION" "python-is-python3=$PYTHON_IS_PYTHON3_VERSION" \
      "unzip=$UNZIP_VERSION" "xz-utils=$XZ_UTILS_VERSION" \
      "docker-compose-plugin=$DOCKER_COMPOSE_VERSION" \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/log/apt /var/log/dpkg.log \
      /var/log/alternatives.log /var/cache/debconf/*-old /var/lib/dpkg/*-old

# Each download below is checked against a sha256 taken from its publisher's
# signed or attested release. The comment above each pin says where the sum
# comes from; a bump repeats that check.

# Claude Code's native linux-x64 binary. The sum is the linux-x64 checksum in
# the release's manifest.json, whose signature names Anthropic's release key
# (31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE):
#   R=https://downloads.claude.ai/claude-code-releases/$VERSION
#   curl -fsSLO "$R/manifest.json" -O "$R/manifest.json.sig"
#   curl -fsSL https://downloads.claude.ai/keys/claude-code.asc | gpg --import
#   gpg --verify manifest.json.sig manifest.json
#   jq -r '.platforms["linux-x64"].checksum' manifest.json
ARG CLAUDE_CODE_VERSION=2.1.294
ARG CLAUDE_CODE_SHA256=27122ca7b624f537546fbef35b80c66370d974ff258f3d9b10ac50bb8771f262
RUN curl -fsSL -o /usr/local/bin/claude \
      "https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}/linux-x64/claude" \
 && echo "${CLAUDE_CODE_SHA256}  /usr/local/bin/claude" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/claude

# The root-owned binary above is the pin: no background update and no
# `claude update`, which would install another version under ~/.local.
ENV DISABLE_UPDATES=1

# atc's compiled linux-x64 binary, for the session hooks of an atc daemon's
# `cloud` target, which names it as guestATC so the daemon never copies its
# own binary in. The sum is atc-linux-x64's line in the release's SHA256SUMS:
#   gh release download "@zgeoff/atc@$VERSION" -R zgeoff/atc -p SHA256SUMS -p atc-linux-x64
#   sha256sum -c --ignore-missing SHA256SUMS
ARG ATC_VERSION=3.11.2
ARG ATC_SHA256=ecda6e5428700b4d8927cdd373fa4b4aff10b38489b81c4b0d7a405010af11f4
RUN curl -fsSL -o /usr/local/bin/atc \
      "https://github.com/zgeoff/atc/releases/download/%40zgeoff/atc%40${ATC_VERSION}/atc-linux-x64" \
 && echo "${ATC_SHA256}  /usr/local/bin/atc" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/atc

# Codex's full linux package: the codex binary, its bwrap sandbox helper and
# rg. The sum is the asset digest GitHub lists on the release:
#   gh api repos/openai/codex/releases/tags/rust-v$VERSION \
#     --jq '.assets[] | select(.name=="codex-package-x86_64-unknown-linux-musl.tar.gz") | .digest'
ARG CODEX_VERSION=0.160.1
ARG CODEX_SHA256=340801565906a7028f6baaa9ab6853addaef221f0016a1417a7c1ffdd96c21f0
RUN curl -fsSL -o /tmp/codex.tar.gz \
      "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-package-x86_64-unknown-linux-musl.tar.gz" \
 && echo "${CODEX_SHA256}  /tmp/codex.tar.gz" | sha256sum -c - \
 && mkdir -p /opt/codex \
 && tar -xzf /tmp/codex.tar.gz -C /opt/codex --no-same-owner \
 && ln -s /opt/codex/bin/codex /usr/local/bin/codex \
 && rm /tmp/codex.tar.gz

# The GitHub CLI. The sum comes from the release's checksums file; check the
# tarball's build provenance first:
#   gh release download v$VERSION -R cli/cli -p "gh_${VERSION}_linux_amd64.tar.gz"
#   gh attestation verify "gh_${VERSION}_linux_amd64.tar.gz" --repo cli/cli
#   sha256sum "gh_${VERSION}_linux_amd64.tar.gz"
ARG GH_VERSION=2.102.0
ARG GH_SHA256=bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386
RUN curl -fsSL -o /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/gh.tar.gz -C /tmp \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"

# Node 24 from nodejs.org, with npm and corepack. The sum is the tarball's line
# in the release's SHASUMS256.txt.
ARG NODE_VERSION=24.21.0
ARG NODE_SHA256=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
RUN curl -fsSL -o /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
 && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner \
      --exclude='*.md' --exclude=LICENSE \
 && rm /tmp/node.tar.xz

# Bun. The sum is bun-linux-x64.zip's line in the release's SHASUMS256.txt.
ARG BUN_VERSION=1.4.2
ARG BUN_SHA256=36368faef7527875d5ffa52e53cd48021741f2a83eb6208a8dd64068d422a913
RUN curl -fsSL -o /tmp/bun.zip \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" \
 && echo "${BUN_SHA256}  /tmp/bun.zip" | sha256sum -c - \
 && unzip -q /tmp/bun.zip -d /tmp \
 && install -m 0755 /tmp/bun-linux-x64/bun /usr/local/bin/bun \
 && ln -s bun /usr/local/bin/bunx \
 && rm -rf /tmp/bun.zip /tmp/bun-linux-x64

# Go from go.dev. The sum is the sha256 that https://go.dev/dl/?mode=json
# lists for the linux-amd64 tarball.
ARG GO_VERSION=1.27.1
ARG GO_SHA256=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445
RUN curl -fsSL -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
 && echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/go.tar.gz -C /usr/local \
 && rm /tmp/go.tar.gz

# uv and uvx. The sum is the release's uv-x86_64-unknown-linux-gnu.tar.gz.sha256.
ARG UV_VERSION=0.12.23
ARG UV_SHA256=9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6
RUN curl -fsSL -o /tmp/uv.tar.gz \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
 && echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/uv.tar.gz -C /tmp \
 && install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /tmp/uv-x86_64-unknown-linux-gnu/uvx \
      /usr/local/bin/ \
 && rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-gnu

# The 1Password CLI, for 1Password Connect. The zip holds op and op.sig; check
# the signature against 1Password's code-signing key
# (3FEF 9748 469A DBE1 5DA7 CA80 AC2D 6274 2012 EA22), then take the zip's sum:
#   curl -fsSLO https://cache.agilebits.com/dist/1P/op2/pkg/v$VERSION/op_linux_amd64_v$VERSION.zip
#   unzip op_linux_amd64_v$VERSION.zip op op.sig
#   curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --import
#   gpg --verify op.sig op && sha256sum op_linux_amd64_v$VERSION.zip
ARG OP_VERSION=2.40.0
ARG OP_SHA256=74277219e8da60958c00f9aee9d2023225e98fdda8bfd2156a5d9e85e0edaab3
RUN curl -fsSL -o /tmp/op.zip \
      "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_amd64_v${OP_VERSION}.zip" \
 && echo "${OP_SHA256}  /tmp/op.zip" | sha256sum -c - \
 && unzip -q /tmp/op.zip op -d /tmp/op \
 && install -m 0755 /tmp/op/op /usr/local/bin/op \
 && rm -rf /tmp/op.zip /tmp/op

# The auto-mode CLI and its Claude Code mod, from the npm tarball. The package
# has no dependencies. The mod sits at the fixed path /opt/auto-mode/mods/auto-mode,
# for --plugin-dir. The sum is the tarball's; npm's dist.integrity is its sha512:
#   npm view auto-mode@$VERSION dist.tarball dist.integrity
ARG AUTO_MODE_VERSION=0.15.0
ARG AUTO_MODE_SHA256=22f5192137baae7b41ead26c3ed05513a37981ddf334f0e55910f312446ea962
RUN curl -fsSL -o /tmp/auto-mode.tgz \
      "https://registry.npmjs.org/auto-mode/-/auto-mode-${AUTO_MODE_VERSION}.tgz" \
 && echo "${AUTO_MODE_SHA256}  /tmp/auto-mode.tgz" | sha256sum -c - \
 && mkdir -p /opt/auto-mode \
 && tar -xzf /tmp/auto-mode.tgz -C /opt/auto-mode --strip-components=1 --no-same-owner \
 && chmod 0755 /opt/auto-mode/dist/cli.js \
 && ln -s /opt/auto-mode/dist/cli.js /usr/local/bin/auto-mode \
 && rm /tmp/auto-mode.tgz

# gitleaks, which the zgeoff repos' pre-commit hooks run on every commit. The sum
# is the linux_x64 tarball's line in the release's gitleaks_<version>_checksums.txt:
#   gh release download v$VERSION -R gitleaks/gitleaks -p "gitleaks_${VERSION}_checksums.txt"
ARG GITLEAKS_VERSION=8.30.1
ARG GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
RUN curl -fsSL -o /tmp/gitleaks.tar.gz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
 && echo "${GITLEAKS_SHA256}  /tmp/gitleaks.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks \
 && install -m 0755 /tmp/gitleaks /usr/local/bin/gitleaks \
 && rm /tmp/gitleaks.tar.gz /tmp/gitleaks

# A boot service that sets vm.overcommit_memory=1 in the guest once at each
# boot. oxlint's allocator reserves more address space than a 2 GiB imp holds
# and aborts under the kernel's default heuristic; with overcommit it runs in
# about 230 MiB. The imp agent runs each file in services.d at boot.
COPY services.d/overcommit.json /etc/imp/services.d/overcommit.json

ENV PATH=/root/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
