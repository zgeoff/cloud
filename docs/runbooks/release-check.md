# Release check

The `release check` workflow finds new atc, imp, nixie and auto-mode releases and opens one bump
pull request per dependency, so the release repositories know nothing about cloud. It runs on a
schedule and on dispatch. Its check job compares each dependency's newest release with the pins on
`main`, and its bump job runs only when a pin is older. The `release bump merge` workflow then
merges a bump that may merge on its own once its checks pass. A merged nixie bump changes the stack
config, so the `Deploy prod` workflow applies it to prod with no person involved, unless its guard
holds the plan ([the prod apply job](./prod-apply.md)). The same holds for the later pull request
that pins the atc-gateway images an atc bump publishes
([The atc-gateway images](#the-atc-gateway-images)). A host switch and an agent image rebuild stay
with a person, and each pull request's body lists the steps its merge leaves. An atc major release
reaches the host's atc daemon only after the atc gateway runs that major, because the host switch
refuses a skew ([Switch the host](./workflows.md#switch-the-host)). An atc release reaches a
daemon's `cloud` target only in the order that
[the agent image runbook](./agent-image.md#roll-out-an-atc-release) gives: the image first, then the
daemon.

| Dependency         | Branch                             | Pins                                                                        |
| ------------------ | ---------------------------------- | --------------------------------------------------------------------------- |
| atc                | `release-check/atc`                | the agent image, the host's atc daemon, the atc-gateway images' release     |
| imp                | `release-check/imp`                | imp's NixOS module and its lock with the imp-host image, the imp-base image |
| nixie              | `release-check/nixie`              | the nixie and nixie-web images in the stack config                          |
| auto-mode          | `release-check/auto-mode`          | the auto-mode tarball in the agent image                                    |
| atc-gateway-images | `release-check/atc-gateway-images` | the atc-gateway and backup images in the stack config                       |

The release registry in `scripts/release/` holds one record per dependency: its repository, its tag
form, what its releases publish, and each pin's lines in the files. The bump reads each value it
writes from the release itself: the atc pins take their sums from the release's SHA256SUMS, the
nixie pins take their digests from the release notes' `## Images` list, the imp pins take the tag's
commit and the images' digests from GitHub and GHCR, and the auto-mode pin takes its sum from the
npm tarball, which it checks against npm's integrity hash and the release's version. Before it
writes anything, it checks every pin line of the dependency, so a pin at the release with another
sum fails the bump and changes no file. The bump never moves a pin back to an older release.

The pin table (`scripts/release/release-pins.json`) holds every registry pin's parts, and each bump
writes its entries beside the pins. CI's release pin check (`bun run check:release-pins`) fails a
pull request in which a pin line and the table disagree, so a pin edited by hand needs
`bun scripts/release/check-release-pins.ts --write` to update the table. The merge workflow holds a
bump that leaves the table unchanged, because only a bump opened before the table existed can do
that, and the next run rebuilds its branch.

CI's image pin check (`bun run check:image-pins`) covers the pins a person edits too. A release tag
of an image this repo publishes is never replaced, so the check fails a pull request whose release
tag names another digest at the registry. An upstream tag, such as Distroless's `nonroot`, moves
when its publisher rebuilds the image, so for an upstream pin the check asks only that the registry
still serves the pinned digest. The atc-gateway packages on GHCR are private, so the check reads
them with a GitHub token that can read packages: CI hands it the workflow's token, and on a PC it
takes the token that `gh auth token` prints, which needs the `read:packages` scope
(`gh auth refresh -s read:packages`).

## The atc-gateway images

This repository builds and publishes the atc-gateway images itself, so their digests exist only
after a merge. The registry record `atc-gateway-images` holds their pins in the stack config, and
the release check never reads it. Instead, the `atc-gateway images` workflow runs on each push to
`main` that changes `images/atc-gateway/versions.env`, such as a merged atc bump:

1. Its decide job compares the push with the commit before it. A pull request skips the job, and the
   publish job refuses any ref other than `main`, so a pull request never publishes.
2. Its publish job builds both images at the pins, pushes each tag that GHCR lacks, and reads both
   tags' digests from GHCR.
3. As the release check app, it opens or updates `release-check/atc-gateway-images`, which pins
   those digests and the pin table.
4. The merge workflow merges it by the rules in
   [When a bump merges on its own](#when-a-bump-merges-on-its-own), and the `Deploy prod` workflow
   applies it.

Two runs can finish out of order. A run whose tags differ from those in `main`'s pin file leaves the
branch alone, and the run for the newer push pins them.

The gateway image's tag is the atc release, so its pull request takes the release check's labels. A
pull request that moves only the backup image's tag moves no release version, so it waits for a
review. A manual run on `main` with `push: true` publishes and opens the pull request too, which
repairs a run that failed after its push:

```bash
gh workflow run atc-gateway-images.yml --ref main -f push=true
```

## When a bump merges on its own

The bump job labels each pull request with its update type (`update:patch`, `update:minor` or
`update:major`, the largest step across its pins) and with `auto-merge` or `needs-review`. It labels
it `needs-review` when any of these holds:

- The update is major.
- The update is minor and the new release is 0.x, because a 0.x minor release is the breaking one.
- A nixie release in the bump adds migrations (label `migrations`). nixie's migrations run forward
  only, so a revert does not undo them.

A nixie bump that changes nixie's sandbox images needs no review for that change, because nixie adds
its own images to impd at start.

The merge workflow runs each time CI finishes on a `release-check/` branch, and each time such a
pull request gets the `auto-merge` label. The label event matters when a bump run fails after its
push: the pull request loses the label, its checks can all finish before the next run puts the label
back, and no later check finishes to start a merge. The workflow merges a pull request labelled
`auto-merge` only when the release check app opened it and wrote every commit on it, it changes no
file outside its dependency's pins, and every GitHub Actions check on its head has passed. A commit
anyone else pushes to the branch therefore holds the pull request for a person. CI's `checks` job
must also have passed, because it holds every check, the agent image check and the fixtures
included, and it can register its check run after the label event. The merge uses the app's token,
so the push to `main` starts its workflows.

## Review a bump

1. Read the release notes the pull request links, and every release between the pin and the bump.
2. Merge it once its checks pass. For a nixie bump, read the `Deploy prod` run it starts, and answer
   it if its guard holds the plan, as [the prod apply job](./prod-apply.md) describes.

A later release replaces the branch, the title, the body and the labels of the open pull request,
and takes its `auto-merge` label and auto-merge off before the push. A pull request that waits for
review therefore always holds the newest release.

To hold a bump that would merge on its own, label it `needs-review`. To reject a release, close its
pull request. The release check keys both on the release in the title of the branch's commit, not on
the files. When `main` changes another pin in a file the bump changes, the release check rebuilds
the branch and keeps the `needs-review` label, with no `auto-merge` beside it, and it leaves a
closed pull request closed. A later release drops the hold and opens a rejected bump again, as does
deleting its branch.

## Add a dependency

1. Add a record to the release registry. Its source kind decides how the bump reads a release. Each
   pin line's pattern captures each part of the line in a named group, so the bump reads a version
   and writes a sum or a digest with no code of the dependency's own.
2. Run `bun scripts/release/check-release-pins.ts --write`, which adds the new pins to the pin
   table.
3. Run `bun run test`. The registry's tests fail when a pattern matches no line, or more than one,
   in the checkout's files.

## Pin a release by hand

Run the manual pin from a clean checkout of `main`. It reads the release and writes the dependency's
pins as a bump pull request would, and opens no pull request:

```bash
bun scripts/release/run-release-pin.ts <dependency> <version>
```

## Set up the app

The workflows act as a GitHub App installed on this repository, with these repository permissions:

| Permission    | Access | For                                                |
| ------------- | ------ | -------------------------------------------------- |
| Contents      | write  | push the `release-check/` branches, merge          |
| Pull requests | write  | open, edit and label the pull requests, auto-merge |
| Metadata      | read   | granted with any permission                        |

Store its client ID as the Actions secret `RELEASE_CHECK_APP_CLIENT_ID` and a private key as
`RELEASE_CHECK_APP_PRIVATE_KEY`. Until both exist, the check job still runs and reports what it
found, and the bump job fails at its first step.

## Run it now

```bash
gh workflow run release-check.yml --ref main
gh run list --workflow release-check.yml --limit 3
```

The run's summary lists each pin older than its newest release. A failed bump fails the job after
the other dependencies' bumps have run; its log holds the bump's refusal, such as a release whose
sums differ from the pinned ones.
