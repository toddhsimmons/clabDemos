#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./load-ceos.sh                  # auto-detect in customLab/images
#   ./load-ceos.sh /path/to/file    # load a specific tar(.gz|.xz)
#   ./load-ceos.sh /path/to/dir     # search that dir for newest cEOS*.tar*

# --- locate search root ---
REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)"
DEFAULT_DIR="${REPO_ROOT}/customLab/images"

target="${1:-$DEFAULT_DIR}"

pick_file() {
  local base="$1"
  if [[ -f "$base" ]]; then
    printf '%s\n' "$base"
    return 0
  fi
  if [[ -d "$base" ]]; then
    # newest matching tarball wins
    ls -1t "$base"/cEOS*.tar* 2>/dev/null | head -n1 || true
  else
    echo ""
  fi
}

ceos_file="$(pick_file "$target")"

if [[ -z "${ceos_file}" ]]; then
  echo "ℹ️ No cEOS image found."
  echo "   Looked in: $target"
  echo "   Expecting a file like: cEOS64-lab-4.30.1F.tar.xz (or .tar/.tar.gz)"
  exit 1
fi

# --- derive version tag from filename, e.g. 4.30.1F ---
version="$(echo "${ceos_file##*/}" | sed -n 's/.*cEOS[^-]*-lab-\([0-9][0-9.]*[A-Za-z]*\)\.tar.*/\1/p')"
tag="${version:-latest}"
image="ceos:${tag}"

echo "▶ Repo root : ${REPO_ROOT}"
echo "▶ Using file: ${ceos_file}"
echo "▶ Target tag: ${image}"

# --- prechecks for decompressors ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing '$1'"; exit 1; }; }
case "${ceos_file}" in
  *.tar.xz) need xz ;;
  *.tar.gz) need gzip ;;
  *.tar)    : ;;
  *)        echo "❌ Unknown archive format: ${ceos_file}"; exit 1 ;;
esac
need docker

# already have desired tag?
if docker image inspect "${image}" >/dev/null 2>&1; then
  echo "✅ cEOS image already present: ${image}"
  docker images | awk 'NR==1 || /ceos/ {print}'
  exit 0
fi

# snapshot images before load to help retag if needed
before_ids="$(docker images -q --no-trunc | sort -u)"

# --- Decompress to a temp tar, then docker load (avoids .deltas/json issues) ---
tmp_tar="$(mktemp /tmp/ceos-XXXXXX.tar)"
cleanup() { rm -f "$tmp_tar"; }
trap cleanup EXIT

echo "📦 Preparing image tar at: $tmp_tar"
case "${ceos_file}" in
  *.tar.xz)  xz -dc "${ceos_file}" > "$tmp_tar" ;;
  *.tar.gz)  gzip -dc "${ceos_file}" > "$tmp_tar" ;;
  *.tar)     cp -f "${ceos_file}" "$tmp_tar" ;;
esac

echo "▶ docker load -i $tmp_tar"
docker load -i "$tmp_tar"

# if desired tag exists now, we're done
if docker image inspect "${image}" >/dev/null 2>&1; then
  echo "✅ Loaded as ${image}"
else
  # find newly introduced image ID and retag
  after_ids="$(docker images -q --no-trunc | sort -u)"
  new_id="$(comm -13 <(echo "$before_ids") <(echo "$after_ids") | tail -n1 || true)"
  if [[ -n "${new_id}" ]]; then
    echo "▶ Retagging ${new_id} → ${image}"
    docker tag "${new_id}" "${image}" || true
  else
    # fallback: try to find a ceos repo/tag that appeared
    src="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i '^ceos[:@]' | head -n1 || true)"
    if [[ -n "$src" ]]; then
      echo "▶ Retagging ${src} → ${image}"
      docker tag "${src}" "${image}" || true
    else
      echo "⚠️ Loaded image, but could not determine source tag to retag."
    fi
  fi
fi

echo "✅ Available cEOS images:"
docker images | awk 'NR==1 || /ceos/ {print}'