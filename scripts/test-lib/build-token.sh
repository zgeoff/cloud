# shellcheck shell=bash
# build_token <seed> <label>: a token in imp's format, imp_<16>.<43>, derived from the
# seed and the label alone, so a rerun with the same seed repeats every value.
build_token() {
  local seed="$1" label="$2" id secret
  id="$(printf '%s' "$seed-$label-id" | sha256sum)"
  secret="$(printf '%s' "$seed-$label-secret" | sha256sum)"
  printf 'imp_%.16s.%.43s' "$id" "$secret"
}
