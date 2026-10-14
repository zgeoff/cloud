#!/usr/bin/env bash
# atc's release job runs `bash scripts/open-atc-pin-pr.sh <version> <SHA256SUMS file>` in a clone
# of this repo; open-atc-pin-pr.ts does the work.
exec bun "$(dirname "$0")/open-atc-pin-pr.ts" "$@"
