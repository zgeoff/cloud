#!/usr/bin/env bash
# The provider's checks: gofmt, go vet and the race-enabled tests. It passes without a Go module,
# so a tree without provider/go.mod has nothing to check.
#
#   bash provider/check.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[ -f go.mod ] || exit 0
unformatted="$(gofmt -l .)"
if [ -n "$unformatted" ]; then
  echo "gofmt would change:" >&2
  echo "$unformatted" >&2
  exit 1
fi
go vet ./...
go test -race ./...
