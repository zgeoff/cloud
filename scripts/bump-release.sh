#!/usr/bin/env bash
# Open or update the bump pull request for one line of find-release-bumps.sh: read what the
# release publishes, label the bump, and hand the pin to open-release-bump-pr.sh. Run it from the
# root of a zgeoff/cloud clone, with gh signed in to the release check app's token, a git identity,
# and docker. The release check workflow's bump job runs it once per line:
#
#   bash scripts/bump-release.sh <dependency> <version> <pinned version>...
#
# | Dependency | Reads                                                      | Pins with      |
# | ---------- | ---------------------------------------------------------- | -------------- |
# | atc        | the release's SHA256SUMS                                   | pin-atc.sh     |
# | imp        | the tag's commit; the imp-host and imp-base image digests  | pin-imp.sh     |
# | nixie      | the notes of the pinned release, the target and each between | pin-nixie.sh |
# | auto-mode  | the npm tarball and its dist.integrity                     | pin-auto-mode.sh |
#
# The pinned versions come in find-release-bumps.sh's order, and set the update type. A nixie bump
# also takes find-nixie-release-flags.sh's flags. label-release-bump.sh decides the labels, and
# the body says why the pull request merges on its own or waits for a review, and what rolls the
# merged pin out.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: bump-release.sh <dependency> <version> <pinned version>..." >&2
  exit 2
fi
dependency="$1"
version="$2"
pinned=("${@:3}")
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

flags=()
case "$dependency" in
  atc)
    names=("the agent image (\`images/agent/Dockerfile\`)" "the host's atc daemon (\`nixos/packages/atc.nix\`)"
      "the atc-gateway images (\`images/atc-gateway/versions.env\`)")
    url="https://github.com/zgeoff/atc/releases/tag/%40zgeoff/atc%40$version"
    gh release download "@zgeoff/atc@$version" -R zgeoff/atc -p SHA256SUMS -D "$work"
    pin=(bash "$here/pin-atc.sh" "$version" "$work/SHA256SUMS")
    rollout="Rebuild the agent image (\`docs/runbooks/agent-image.md\`) and publish the atc-gateway images. The \`Deploy prod\` workflow applies the pull request that pins their digests once it merges (\`docs/runbooks/prod-apply.md\`). Then switch the host (\`docs/runbooks/workflows.md\`), which refuses while the deployed gateway runs another atc major than the daemon pin."
    ;;
  imp)
    names=("imp's NixOS module and the imp-host image (\`nixos/\`)" "the imp-base image (\`images/agent/Dockerfile\`)")
    url="https://github.com/zgeoff/impz/releases/tag/v$version"
    commit="$(gh api "repos/zgeoff/impz/commits/v$version" --jq .sha)"
    digests=()
    for image in imp-host imp-base; do
      docker buildx imagetools inspect "ghcr.io/zgeoff/$image:$version" --format '{{json .Manifest}}' > "$work/$image.json"
      digests+=("$(jq -r .digest "$work/$image.json")")
    done
    pin=(bash "$here/pin-imp.sh" "$version" "$commit" "${digests[@]}")
    rollout="Copy impd's database, then switch the host, as \`docs/runbooks/workflows.md\` (Upgrade imp) describes; rebuild the agent image for imp-base (\`docs/runbooks/agent-image.md\`)."
    ;;
  nixie)
    names=("nixie (\`infra/Pulumi.prod.yaml\`)" "nixie-web (\`infra/Pulumi.prod.yaml\`)")
    url="https://github.com/zgeoff/nixie/releases/tag/v$version"
    from="$(printf '%s\n' "${pinned[@]}" | sort -V | head -1)"
    gh release view "v$from" -R zgeoff/nixie --json body --jq .body > "$work/pinned.md"
    gh release view "v$version" -R zgeoff/nixie --json body --jq .body > "$work/target.md"
    # every release after the pinned one must be in the list, or its migrations go unread
    tags="$(gh release list -R zgeoff/nixie --exclude-drafts --exclude-pre-releases --limit 30 \
      --json tagName --jq '.[].tagName')"
    if ! grep -qx "v$from" <<< "$tags"; then
      echo "the latest 30 nixie releases do not reach the pinned v$from, so the releases between go unread" >&2
      exit 1
    fi
    between=()
    while read -r tag; do
      each="${tag#v}"
      if [[ "$each" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$each" != "$from" ] && [ "$each" != "$version" ] &&
        [ "$(printf '%s\n' "$from" "$each" "$version" | sort -V | sed -n 2p)" = "$each" ]; then
        gh release view "$tag" -R zgeoff/nixie --json body --jq .body > "$work/$tag.md"
        between+=("$work/$tag.md")
      fi
    done <<< "$tags"
    bash "$here/find-nixie-release-flags.sh" "$work/pinned.md" "$work/target.md" "${between[@]}" > "$work/flags"
    mapfile -t flags < "$work/flags"
    pin=(bash "$here/pin-nixie.sh" "$version" "$work/target.md")
    rollout="The \`Deploy prod\` workflow applies the stack config once CI passes on main, unless its guard holds the plan (\`docs/runbooks/prod-apply.md\`). Check the deploy (\`docs/runbooks/nixie.md\`)."
    ;;
  auto-mode)
    names=("the agent image (\`images/agent/Dockerfile\`)")
    url="https://github.com/zgeoff/auto-mode/releases/tag/auto-mode-v$version"
    # the GitHub release comes first and npm publishes in the same run, so a release that npm
    # lacks yet fails this run, and the next one pins it
    curl -fsSL "https://registry.npmjs.org/auto-mode/$version" > "$work/package.json"
    tarball="$(jq -r .dist.tarball "$work/package.json")"
    integrity="$(jq -r .dist.integrity "$work/package.json")"
    if [ "$tarball" != "https://registry.npmjs.org/auto-mode/-/auto-mode-$version.tgz" ]; then
      echo "npm lists auto-mode $version's tarball at $tarball, not where the agent image fetches it" >&2
      exit 1
    fi
    curl -fsSL -o "$work/auto-mode.tgz" "$tarball"
    pin=(bash "$here/pin-auto-mode.sh" "$version" "$work/auto-mode.tgz" "$integrity")
    rollout="Rebuild the agent image (\`docs/runbooks/agent-image.md\`). Gateway sessions load the new mod from \`/opt/auto-mode/mods/auto-mode\` once they start on the new image."
    ;;
  *)
    echo "not a release check dependency: '$dependency'" >&2
    exit 2
    ;;
esac
if [ "${#pinned[@]}" != "${#names[@]}" ]; then
  echo "$dependency has ${#names[@]} pins, but ${#pinned[@]} pinned versions were given" >&2
  exit 2
fi

bash "$here/label-release-bump.sh" "$version" "${pinned[@]}" -- "${flags[@]}" > "$work/labels"

{
  echo "Bumps $dependency to [$version]($url). The release check opened this pull request."
  echo
  echo "| Pin | From | To |"
  echo "| --- | --- | --- |"
  for i in "${!names[@]}"; do
    each="${pinned[$i]}"
    if [ "$(printf '%s\n' "$each" "$version" | sort -V | tail -1)" = "$each" ]; then
      echo "| ${names[$i]} | $each | unchanged |"
    else
      echo "| ${names[$i]} | $each | $version |"
    fi
  done
  echo
  if grep -qx auto-merge "$work/labels"; then
    echo "It merges on its own once every check on its head passes, including the NixOS checks when it changes \`nixos/\`."
  else
    echo "It waits for a review, because:"
    echo
    while read -r label; do
      case "$label" in
        update:major) echo "- it is a major release." ;;
        update:minor) if [[ "$version" == 0.* ]]; then echo "- it is a minor release of a 0.x dependency, which may break."; fi ;;
        migrations) echo "- a release in the bump adds database migrations, which a revert does not undo." ;;
        sandbox-images-changed) echo "- the release changes nixie's sandbox images, which a person adds to impd before the merge, because the \`Deploy prod\` workflow applies the merged pin (\`docs/runbooks/nixie.md\`)." ;;
      esac
    done < "$work/labels"
  fi
  echo
  echo "After the merge: $rollout"
} > "$work/body"

bash "$here/open-release-bump-pr.sh" "$dependency" "$version" "$work/body" "$work/labels" "${pin[@]}"
