# Release check

The `release check` workflow finds new atc, imp and nixie releases and opens one bump pull request
per dependency, so the release repositories know nothing about cloud. It runs on a schedule and on
dispatch. Its check job compares each dependency's newest release with the pins on `main`, and its
bump job runs only when a pin is older. The `release bump merge` workflow then merges a bump that
may merge on its own once its checks pass. A merge rolls nothing out: the rollout steps stay with a
person, and each pull request's body lists them.

| Dependency | Branch                | Pins                                                                        |
| ---------- | --------------------- | --------------------------------------------------------------------------- |
| atc        | `release-check/atc`   | the agent image, the host's atc daemon, the atc-gateway images' release     |
| imp        | `release-check/imp`   | imp's NixOS module and its lock with the imp-host image, the imp-base image |
| nixie      | `release-check/nixie` | the nixie and nixie-web images in the stack config                          |

Each pin script checks what it writes against the release itself: the atc pins take their sums from
the release's SHA256SUMS, the nixie pins take their digests from the release notes' `## Images`
list, and the imp pins take the tag's commit and the images' digests from GitHub and GHCR. A pin
script never moves a pin back to an older release.

## When a bump merges on its own

The bump job labels each pull request with its update type (`update:patch`, `update:minor` or
`update:major`, the largest step across its pins) and with `auto-merge` or `needs-review`. It labels
it `needs-review` when any of these holds:

- The update is major.
- The update is minor and the new release is 0.x, because a 0.x minor release is the breaking one.
- A nixie release in the bump adds migrations (label `migrations`). nixie's migrations run forward
  only, so a revert does not undo them.
- The bump changes nixie's sandbox images (label `sandbox-images-changed`), which a person adds to
  impd before the rollout, as
  [the nixie runbook](./nixie.md#add-nixies-images-and-model-secret-to-impd) describes.

The merge workflow runs each time a check workflow finishes on a `release-check/` branch. It merges
a pull request labelled `auto-merge` only when the release check app opened it and wrote every
commit on it, it changes no file outside its dependency's pins, and every GitHub Actions check on
its head has passed. A commit anyone else pushes to the branch therefore holds the pull request for
a person. A bump that changes `nixos/` also needs the NixOS checks, which run on an app's pull
request. The merge uses the app's token, so the push to `main` starts its workflows.

## Review a bump

1. Read the release notes the pull request links, and every release between the pin and the bump.
2. For a nixie bump with `sandbox-images-changed`, add the new sandbox images to impd before you
   apply the merged pin.
3. Merge it once its checks pass.

A later release replaces the branch, the title, the body and the labels of the open pull request,
and takes its `auto-merge` label and auto-merge off before the push. A pull request that waits for
review therefore always holds the newest release.

To hold a bump that would merge on its own, label it `needs-review`; the release check keeps that
label until a later release replaces the bump. To reject a release, close its pull request; the
release check keeps it closed until the next release, or until you delete its branch.

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
the other dependencies' bumps have run; its log holds the pin script's refusal, such as a release
whose sums differ from the pinned ones.
