# The agent image

The agent image is the imp image an agent session runs on: imp's base image plus the tools a session
uses, each at a pinned version whose download is checked against a published checksum. It holds
binaries only, with no configuration, no login state and no secret, because atc sets each session up
at launch with its grants, placeholder variables and config. The image is built on impd's host from
a commit of this repo, and each build gets a new image name, so the image that ran before stays on
the host for a rollback. [The atc gateway](./atc-gateway.md) covers the daemons whose sessions run
on it.

## What the image holds

The Dockerfile pins every input. The base image is pinned by digest, the Ubuntu packages come from
Ubuntu's snapshot archive at a fixed moment so their exact versions stay installable, and every
other download carries a checksum taken from its publisher's signed or attested release. The tools
are the coding agents, atc, auto-mode with its mod, GitHub's CLI, the language toolchains,
1Password's CLI and gitleaks. Claude Code is installed with its own updates turned off, so a session
runs the version the image pins.

The build runs no tool, because a tool can write state the first time it runs: a version check alone
can create a tool's config directory. That keeps the image free of anything a session could inherit
from another.

Two boot services adapt a small imp to the tools. One sets the kernel's memory overcommit, so a tool
whose allocator reserves large buffers can start. The other sizes a swapfile from the free space on
the imp's disk when the imp first boots, so a command that needs more memory than the imp holds
pages out and slows down instead of stopping the imp, and a small disk keeps room for the session's
checkout.

## Build and check

The image is built by impd, not by CI: the build script sends a `git archive` of a commit on `main`
to the imp host, and impd builds it into an image named after that commit. The script then checks
the new image in a fresh imp and removes a failed image unless told to keep it, so the host holds
only images that passed.

The check runs the same way in CI against a Docker build of the image, and on the host against a
live imp. It compares each tool's version with its pin, checks that no login state exists and that
no environment variable looks like a credential, and runs gitleaks over the whole filesystem with a
narrow allowlist for files that upstream packages ship. A secret in the image therefore fails the
build before any session can run on it.

## Pins and the atc release

The [release check](../../runbooks/release-check.md) opens the bump pull requests that move the
image's pins to new releases: atc, together with the host's daemon and the gateway images, the imp
base image, and auto-mode, the CLI and mod that gateway sessions load. atc's own release knows
nothing about this repo. A later release replaces its dependency's branch and turns the old
auto-merge off first, so a newer pin always waits for its own checks, and a pin never moves
backwards. Every other pin change is an ordinary reviewed PR.

## How a daemon uses the image

An atc daemon names the image in the config of its imp execution target, outside this repo. The
image switch script rewrites that one target's image in the daemon's config on the machine that runs
it, after it copies the config aside, and points the target's session hooks at the atc inside the
image, so the daemon never uploads its own binary into a fresh imp. A daemon reads its targets only
at start, so a switch takes effect at the daemon's next restart, which the script never runs itself.
A switch changes new imps only; an imp keeps the image it was created from
([the agent image runbook](../../runbooks/agent-image.md)).
