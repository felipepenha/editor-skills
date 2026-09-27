#!/usr/bin/env bash
# verify-fig.sh - Compile a standalone TikZ/PGFPlots figure in overleaf-server and render to PNG
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-standalone-fig.tex> [output-png-path]" >&2
  exit 1
fi

INPUT_TEX="$1"
OUTPUT_ARG="${2:-${INPUT_TEX%.*}.png}"
OUT_DIR="$(cd "$(dirname "$OUTPUT_ARG")" 2>/dev/null && pwd -P || pwd)"
OUTPUT_PNG="${OUT_DIR}/$(basename "$OUTPUT_ARG")"

if [[ ! -f "$INPUT_TEX" ]]; then
  echo "Error: File not found: $INPUT_TEX" >&2
  exit 1
fi

# Detect container engine: podman prioritized over docker
if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
  ENGINE="$CONTAINER_ENGINE"
elif [[ -n "${CONTAINER_CLI:-}" ]]; then
  ENGINE="$CONTAINER_CLI"
elif command -v podman >/dev/null 2>&1; then
  ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
else
  echo "Error: Neither podman nor docker found." >&2
  exit 1
fi

CONTAINER="overleaf-server"
if ! "${ENGINE}" ps --format "{{.Names}}" | grep -q "^${CONTAINER}$"; then
  echo "Error: Container '${CONTAINER}' is not running." >&2
  exit 1
fi

INPUT_DIR="$(cd "$(dirname "$INPUT_TEX")" && pwd)"
BASE_NAME="$(basename "$INPUT_TEX")"
TMP_DIR="/tmp/tex_verify_$$"

"${ENGINE}" exec "$CONTAINER" mkdir -p "$TMP_DIR"
"${ENGINE}" cp "${INPUT_DIR}/." "${CONTAINER}:${TMP_DIR}/"

echo "==> Compiling figure inside ${CONTAINER} (${ENGINE})..."
if ! "${ENGINE}" exec -w "$TMP_DIR" "$CONTAINER" pdflatex -interaction=nonstopmode "$BASE_NAME" >/dev/null 2>&1; then
  echo "Error: Compilation failed. Showing log errors:" >&2
  "${ENGINE}" exec -w "$TMP_DIR" "$CONTAINER" grep -E -A 2 "^! " "${BASE_NAME%.*}.log" >&2 || true
  "${ENGINE}" exec "$CONTAINER" rm -rf "$TMP_DIR"
  exit 1
fi

echo "==> Rendering figure to 200 DPI PNG..."
"${ENGINE}" exec -w "$TMP_DIR" "$CONTAINER" pdftoppm -png -r 200 "${BASE_NAME%.*}.pdf" fig_render
"${ENGINE}" cp "${CONTAINER}:${TMP_DIR}/fig_render-1.png" "$OUTPUT_PNG"
"${ENGINE}" exec "$CONTAINER" rm -rf "$TMP_DIR"

echo "==> Figure successfully rendered to: ${OUTPUT_PNG}"
echo "    Inspect visually using view_file or image viewer."
