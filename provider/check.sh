#!/usr/bin/env bash
# The provider's checks: gofmt, go vet, golangci-lint (staticcheck and unused), deadcode with
# its test roots, and the race-enabled tests. The two linters are Go tools pinned in tools.mod,
# a modfile apart from go.mod, so the provider's own dependencies stay free of them. It passes
# without a Go module, so a tree without provider/go.mod has nothing to check.
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
go tool -modfile=tools.mod golangci-lint run ./...
# deadcode exits 0 on findings, so any output fails the check
dead="$(go tool -modfile=tools.mod deadcode -test ./...)"
if [ -n "$dead" ]; then
  echo "deadcode found unreachable functions:" >&2
  echo "$dead" >&2
  exit 1
fi
go test -race ./...
