#!/usr/bin/env bash
# Собирает единый remnanode-setup.sh из lib/*.sh. Единый файл нужен для
# `bash <(curl ...)`; lib/ — источник истины для разработки и тестов.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/remnanode-setup.sh"
TMP="$(mktemp "$ROOT/.remnanode-setup.XXXXXX")"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

{
  cat "$ROOT/lib/00-header.sh"
  printf '\n# AUTO-GENERATED: remnanode-setup.sh собирается из lib/*.sh через build.sh.\n\n'
  for f in "$ROOT"/lib/*.sh; do
    [[ "$(basename "$f")" == "00-header.sh" || "$(basename "$f")" == "90-main.sh" ]] && continue
    cat "$f"
    printf '\n'
  done
  cat "$ROOT/lib/90-main.sh"
} > "$TMP"

chmod 644 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
bash -n "$OUT" || { echo "build: bash -n failed" >&2; exit 1; }
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$OUT" >/dev/null || { echo "build: shellcheck failed" >&2; exit 1; }
fi
printf 'built %s (%s lines)\n' "$OUT" "$(wc -l < "$OUT")"
