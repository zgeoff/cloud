# The agent image: imp-base plus the tools an agent session runs on an imp.
# It holds binaries only: no configuration, no login state and no secret. atc
# sets those up per session at launch. Build it on the imp host, from a clean
# checkout of the zgeoff/cloud commit on main that the image records:
#   impz image build images/agent --name "agent-$(git rev-parse --short HEAD)"
# docs/runbooks/agent-image.md covers the build, an update and a rollback.
#
# Every pin below is a reviewed change. The image name carries the commit, so
# each build gets a new imp image name and the previous image stays for a
# rollback.

# imp-base, pinned to the multi-arch index digest. Check a bump with:
#   gh attestation verify oci://ghcr.io/zgeoff/imp-base:X.Y.Z --repo zgeoff/impz
FROM ghcr.io/zgeoff/imp-base:4.2.4@sha256:3ad7941a285b41d31078a4c69e01899b92f6c0c4b6534adf6aa7dd6dd05f6787

ARG DEBIAN_FRONTEND=noninteractive

# Ubuntu packages are pinned to exact versions, and UBUNTU_SNAPSHOT names a
# snapshot.ubuntu.com moment that holds every one of them. sbin/install-ubuntu-packages
# resolves the pins and their dependencies against that snapshot only, and fetches
# each file from the live archive or the snapshot, so a pin keeps installing after
# Ubuntu replaces that version in the live archive. A bump moves the snapshot and
# the versions together; read the candidates with
#   apt-get update --snapshot <stamp> && apt-cache --snapshot <stamp> policy <package>
# docker-compose-plugin comes from Docker's repository, which keeps old builds.
ARG UBUNTU_SNAPSHOT=20261021T120000Z
ARG GIT_VERSION=1:2.43.0-1ubuntu7.4
ARG BASH_VERSION=5.2.21-2ubuntu4
ARG JQ_VERSION=1.7.1-3ubuntu0.24.04.2
ARG BUILD_ESSENTIAL_VERSION=12.10ubuntu1
ARG PKG_CONFIG_VERSION=1.8.1-2build1
ARG PYTHON3_VERSION=3.12.3-0ubuntu2.1
ARG PYTHON3_PIP_VERSION=24.0+dfsg-1ubuntu1.3
ARG PYTHON_IS_PYTHON3_VERSION=3.11.4-1
ARG UNZIP_VERSION=6.0-28ubuntu4.1
ARG XZ_UTILS_VERSION=5.6.1+really5.4.5-1ubuntu0.4
ARG DOCKER_COMPOSE_VERSION=5.6.0-1~ubuntu.24.04~noble

# build-essential: native npm modules and Python wheels without a binary build
# need a compiler. docker-compose-plugin: dev stacks use compose.
COPY sbin/install-ubuntu-packages /tmp/install-ubuntu-packages
RUN /tmp/install-ubuntu-packages "https://snapshot.ubuntu.com/ubuntu/$UBUNTU_SNAPSHOT/" \
      "git=$GIT_VERSION" "bash=$BASH_VERSION" "jq=$JQ_VERSION" \
      "build-essential=$BUILD_ESSENTIAL_VERSION" "pkg-config=$PKG_CONFIG_VERSION" \
      "python3=$PYTHON3_VERSION" "python3-venv=$PYTHON3_VERSION" \
      "python3-pip=$PYTHON3_PIP_VERSION" "python-is-python3=$PYTHON_IS_PYTHON3_VERSION" \
      "unzip=$UNZIP_VERSION" "xz-utils=$XZ_UTILS_VERSION" \
      "docker-compose-plugin=$DOCKER_COMPOSE_VERSION" \
 && rm /tmp/install-ubuntu-packages

# Each download below is checked against a sha256 taken from its publisher's
# signed or attested release. The comment above each pin says where the sum
# comes from; a bump repeats that check.

# Every download retries. Plain --retry skips a dropped connection (curl exit 56)
# and an HTTP/2 stream that did not close cleanly (exit 92), so it needs
# --retry-all-errors. The fixed delay keeps a retried 404 to about 10 seconds.
ARG CURL_RETRY="--retry 5 --retry-all-errors --retry-delay 2"

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
RUN curl -fsSL ${CURL_RETRY} -o /usr/local/bin/claude \
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
ARG ATC_VERSION=7.3.1
ARG ATC_SHA256=9ca1c9f59fc1ba68004b6ba2d52714d6afad80322db69e39eda8b2b2c0d3f484
RUN curl -fsSL ${CURL_RETRY} -o /usr/local/bin/atc \
      "https://github.com/zgeoff/atc/releases/download/%40zgeoff/atc%40${ATC_VERSION}/atc-linux-x64" \
 && echo "${ATC_SHA256}  /usr/local/bin/atc" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/atc

# Codex's full linux package: the codex binary, its bwrap sandbox helper and
# rg. The sum is the asset digest GitHub lists on the release:
#   gh api repos/openai/codex/releases/tags/rust-v$VERSION \
#     --jq '.assets[] | select(.name=="codex-package-x86_64-unknown-linux-musl.tar.gz") | .digest'
ARG CODEX_VERSION=0.160.1
ARG CODEX_SHA256=340801565906a7028f6baaa9ab6853addaef221f0016a1417a7c1ffdd96c21f0
RUN curl -fsSL ${CURL_RETRY} -o /tmp/codex.tar.gz \
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
RUN curl -fsSL ${CURL_RETRY} -o /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/gh.tar.gz -C /tmp \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"

# The gh-stack extension, for stacked PRs (`gh stack`). gh finds an extension
# only in its extensions folder with a manifest, so install both there. The sum
# is the asset digest GitHub lists on the release:
#   gh api repos/github/gh-stack/releases/tags/v$VERSION \
#     --jq '.assets[] | select(.name == "linux-amd64") | .digest'
ARG GH_STACK_VERSION=0.2.0
ARG GH_STACK_SHA256=577065033b49d4505730ea0ad43ab1b0374b0d9b1308e9765647a6aa8eba3cb7
RUN dir=/root/.local/share/gh/extensions/gh-stack \
 && mkdir -p "$dir" \
 && curl -fsSL ${CURL_RETRY} -o "$dir/gh-stack" \
      "https://github.com/github/gh-stack/releases/download/v${GH_STACK_VERSION}/linux-amd64" \
 && echo "${GH_STACK_SHA256}  $dir/gh-stack" | sha256sum -c - \
 && chmod 0755 "$dir/gh-stack" \
 && printf 'owner: github\nname: gh-stack\nhost: github.com\ntag: v%s\nispinned: true\npath: %s\n' \
      "$GH_STACK_VERSION" "$dir/gh-stack" > "$dir/manifest.yml" \
 && GH_TELEMETRY=0 DO_NOT_TRACK=1 GH_NO_UPDATE_NOTIFIER=1 gh stack --help >/dev/null

# Node 24 from nodejs.org, with npm and corepack. The sum is the tarball's line
# in the release's SHASUMS256.txt.
ARG NODE_VERSION=24.21.0
ARG NODE_SHA256=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
RUN curl -fsSL ${CURL_RETRY} -o /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
 && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner \
      --exclude='*.md' --exclude=LICENSE \
 && rm /tmp/node.tar.xz

# Bun, at each version that a zgeoff repo pins in its .bun-version, so a session
# runs the Bun its checkout pins: each in /opt/bun/<version>, with
# /opt/bun/default linked to BUN_VERSION, the newest. /usr/local/bin/bun and
# bunx are bin/bun, which runs the version that the nearest .bun-version pins,
# and the default without one. A repo that moves to a version no pin below
# names adds a pin here. Each sum is bun-linux-x64.zip's line in the release's
# SHASUMS256.txt.
ARG BUN_VERSION=1.4.3
ARG BUN_SHA256=3e730528d89775f03f87f05c06787c4df4099d0a37f3f252e7b829cb23816e18
ARG BUN_OLDER_VERSION=1.4.2
ARG BUN_OLDER_SHA256=36368faef7527875d5ffa52e53cd48021741f2a83eb6208a8dd64068d422a913
RUN for pin in "$BUN_VERSION $BUN_SHA256" "$BUN_OLDER_VERSION $BUN_OLDER_SHA256"; do \
      version=${pin% *} sum=${pin#* } \
   && curl -fsSL ${CURL_RETRY} -o /tmp/bun.zip \
        "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-linux-x64.zip" \
   && echo "${sum}  /tmp/bun.zip" | sha256sum -c - \
   && unzip -q /tmp/bun.zip -d /tmp \
   && install -D -m 0755 /tmp/bun-linux-x64/bun "/opt/bun/${version}/bun" \
   && ln -s bun "/opt/bun/${version}/bunx" \
   && rm -rf /tmp/bun.zip /tmp/bun-linux-x64 \
   || exit 1; \
    done \
 && ln -s "$BUN_VERSION" /opt/bun/default
COPY bin/bun /usr/local/bin/bun
RUN ln -s bun /usr/local/bin/bunx

# A Claude Code SessionStart hook that installs the packages a checkout locks, when it has no
# node_modules, so a repo's hooks import the versions its bun.lock pins and never the newest one
# that Bun's auto-install takes. It is a managed settings drop-in, so it adds to the session's own
# hooks and needs no change to the config that atc writes per session.
COPY sbin/install-checkout-packages /usr/local/sbin/install-checkout-packages
COPY claude-code/managed-settings.d/install-checkout-packages.json \
     /etc/claude-code/managed-settings.d/install-checkout-packages.json

# Go from go.dev. The sum is the sha256 that https://go.dev/dl/?mode=json
# lists for the linux-amd64 tarball.
ARG GO_VERSION=1.27.1
ARG GO_SHA256=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445
RUN curl -fsSL ${CURL_RETRY} -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
 && echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/go.tar.gz -C /usr/local \
 && rm /tmp/go.tar.gz

# uv and uvx. The sum is the release's uv-x86_64-unknown-linux-gnu.tar.gz.sha256.
ARG UV_VERSION=0.12.23
ARG UV_SHA256=9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6
RUN curl -fsSL ${CURL_RETRY} -o /tmp/uv.tar.gz \
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
RUN curl -fsSL ${CURL_RETRY} -o /tmp/op.zip \
      "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_amd64_v${OP_VERSION}.zip" \
 && echo "${OP_SHA256}  /tmp/op.zip" | sha256sum -c - \
 && unzip -q /tmp/op.zip op -d /tmp/op \
 && install -m 0755 /tmp/op/op /usr/local/bin/op \
 && rm -rf /tmp/op.zip /tmp/op

# The auto-mode CLI and its Claude Code mod, from the npm tarball. The package
# has no dependencies. The mod sits at the fixed path /opt/auto-mode/mods/auto-mode,
# for --plugin-dir. The sum is the tarball's. The release bump (scripts/release/) checks the
# tarball against npm's dist.integrity, its sha512, and writes this pin:
#   npm view auto-mode@$VERSION dist.tarball dist.integrity
ARG AUTO_MODE_VERSION=3.0.1
ARG AUTO_MODE_SHA256=b0224e465641461e9594021f2dc7af1c09e37f93cd7947f91283cd9bee6ff07a
RUN curl -fsSL ${CURL_RETRY} -o /tmp/auto-mode.tgz \
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
RUN curl -fsSL ${CURL_RETRY} -o /tmp/gitleaks.tar.gz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
 && echo "${GITLEAKS_SHA256}  /tmp/gitleaks.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks \
 && install -m 0755 /tmp/gitleaks /usr/local/bin/gitleaks \
 && rm /tmp/gitleaks.tar.gz /tmp/gitleaks

# shellcheck and shfmt, which the atc and imp pre-push lint:shell hooks run, at
# the versions those repos' CI pins. Neither release publishes a checksums file,
# so each sum is the asset digest GitHub lists on the release:
#   gh api repos/koalaman/shellcheck/releases/tags/v$VERSION \
#     --jq '.assets[] | select(.name=="shellcheck-v'"$VERSION"'.linux.x86_64.tar.xz") | .digest'
#   gh api repos/mvdan/sh/releases/tags/v$VERSION \
#     --jq '.assets[] | select(.name=="shfmt_v'"$VERSION"'_linux_amd64") | .digest'
ARG SHELLCHECK_VERSION=0.11.0
ARG SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
RUN curl -fsSL ${CURL_RETRY} -o /tmp/shellcheck.tar.xz \
      "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
 && echo "${SHELLCHECK_SHA256}  /tmp/shellcheck.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/shellcheck.tar.xz -C /tmp "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" \
 && install -m 0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
 && rm -rf /tmp/shellcheck.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VERSION}"

ARG SHFMT_VERSION=3.13.1
ARG SHFMT_SHA256=fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1
RUN curl -fsSL ${CURL_RETRY} -o /usr/local/bin/shfmt \
      "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" \
 && echo "${SHFMT_SHA256}  /usr/local/bin/shfmt" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/shfmt

# A boot service that sets vm.overcommit_memory=1 in the guest once at each
# boot. oxlint's allocator reserves more address space than a 2 GiB imp holds
# and aborts under the kernel's default heuristic; with overcommit it runs in
# about 230 MiB. The imp agent runs each file in services.d at boot.
COPY services.d/overcommit.json /etc/imp/services.d/overcommit.json

# A boot service that turns on a swapfile of up to 2 GiB, made at the first
# boot and sized from the free disk space. A type-aware lint holds about
# 1.4 GiB, which leaves a 2 GiB imp without free memory; with no swap the guest
# stops answering, and with swap it slows down.
# Git keeps the script executable, and COPY keeps its mode.
COPY sbin/setup-swap /usr/local/sbin/setup-swap
COPY services.d/swap.json /etc/imp/services.d/swap.json

ENV PATH=/root/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
