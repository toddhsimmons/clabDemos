#!/usr/bin/env bash
set -euo pipefail

# Find any cEOS image in repo root (supports .tar, .tar.gz, .tar.xz)
ceos_file="$(ls -1 cEOS*.tar* 2>/dev/null | head -n1 || true)"
if [[ -z "${ceos_file}" ]]; then
  echo "ℹ️ No cEOS image found (looking for cEOS*.tar, *.tar.gz, *.tar.xz). Skipping."
  exit 0
fi

# Parse version like 4.30.1F out of cEOS64-lab-4.30.1F.tar.xz
version="$(echo "${ceos_file}" | sed -n 's/.*cEOS[^-]*-lab-\([0-9][0-9.]*[A-Za-z]*\)\.tar.*/\1/p')"
tag="${version:-latest}"
image="ceos:${tag}"

if docker image inspect "${image}" >/dev/null 2>&1; then
  echo "✅ cEOS image already present: ${image}"
  exit 0
fi

echo "📦 Loading ${ceos_file} as ${image} ..."
case "${ceos_file}" in
  *.tar.xz)  xz -dc "${ceos_file}" | docker load ;;
  *.tar.gz)  gzip -dc "${ceos_file}" | docker load ;;
  *.tar)     docker load -i "${ceos_file}" ;;
  *)         echo "❌ Unknown archive format: ${ceos_file}" >&2; exit 1 ;;
esac

# Try to tag to our canonical name if the tarball used a different repo/tag
if ! docker image inspect "${image}" >/dev/null 2>&1; then
  # last loaded non-dangling image ID
  loaded_id="$(docker images --no-trunc --quiet | head -n1)"
  if [[ -n "${loaded_id}" ]]; then
    docker tag "${loaded_id}" "${image}" || true
  fi
fi

echo "✅ cEOS available as ${image}"
docker images | awk 'NR==1 || /ceos/ {print}'