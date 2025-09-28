#!/usr/bin/env bash
set -Eeuo pipefail

# ====== Paths & inputs ======
REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)"
LAB_DIR="${REPO_ROOT}/basicLab"
FLASH_DIR="${LAB_DIR}/flash"
TOPO_FILE="${LAB_DIR}/topo.clab.yaml"

CEOS_VER="${CEOS_LAB_VERSION:-${CEOS_VERSION:-4.30.1F}}"
CEOS_TAG_LOCAL="ceos:${CEOS_VER}"
REMOTE_TAG="$(echo "${CEOS_VER}" | tr '[:upper:]' '[:lower:]')"
IMAGES_DIR="${LAB_DIR}/images"
CEOS_REMOTE="${CEOS_REMOTE:-}"   # e.g. ghcr.io/you/ceos:${REMOTE_TAG} (optional)

echo "▶ postCreate: repo root=${REPO_ROOT}"
echo "▶ postCreate: lab dir  =${LAB_DIR}"
echo "▶ postCreate: topo file=${TOPO_FILE}"
echo "▶ Expect cEOS tag      =${CEOS_TAG_LOCAL}"

# ====== Utilities ======
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing '$1'"; exit 1; }; }

pull_with_retry() {
  local img="$1" tries=0 max=3
  until docker pull "$img"; do
    tries=$((tries+1))
    (( tries >= max )) && return 1
    echo "…retrying docker pull ($tries/$max) in 3s"
    sleep 3
  done
}

wait_for_docker() {
  echo "▶ Waiting for Docker daemon..."
  local tries=0 max=180
  # Make sure Docker tmp exists (prevents .deltas/json issues)
  sudo mkdir -p /var/lib/docker/tmp || true
  sudo chmod 700 /var/lib/docker/tmp || true
  until docker info >/dev/null 2>&1; do
    tries=$((tries+1))
    (( tries > max )) && { echo "❌ Docker did not become ready"; return 1; }
    # keep tmp sane during bring-up
    sudo mkdir -p /var/lib/docker/tmp 2>/dev/null || true
    sudo chmod 700 /var/lib/docker/tmp 2>/dev/null || true
    sleep 1
  done
  echo "✅ Docker is ready"
  return 0
}

load_first_tar() {
  # Prefer versioned filenames, then ceos.tar, then any cEOS*.tar*
  mkdir -p "${IMAGES_DIR}"
  local candidates=(
    "${IMAGES_DIR}/ceos-${CEOS_VER}.tar"
    "${IMAGES_DIR}/ceos.tar"
  )
  # include upper-case Arista naming pattern
  mapfile -t others < <(ls -1t "${IMAGES_DIR}"/cEOS*.tar* 2>/dev/null || true)
  candidates+=("${others[@]}")

  for t in "${candidates[@]}"; do
    [[ -f "$t" ]] || continue
    echo "📦 Loading cEOS from tar: $t"

    # Decompress to a temp tar file, then docker load (more reliable than streaming)
    local tmp_tar
    tmp_tar="$(mktemp /tmp/ceos-XXXXXX.tar)"
    case "$t" in
      *.tar.xz)  need xz;   xz   -dc "$t" > "$tmp_tar" ;;
      *.tar.gz)  need gzip; gzip -dc "$t" > "$tmp_tar" ;;
      *.tar)     cp -f "$t" "$tmp_tar" ;;
      *)         echo "❌ Unknown archive format: $t"; rm -f "$tmp_tar"; continue ;;
    esac

    # Force Docker to use /tmp for its temp files
    if DOCKER_TMPDIR=/tmp docker load -i "$tmp_tar"; then
      rm -f "$tmp_tar"
      return 0
    else
      echo "⚠️ docker load failed; trying containerd import..."
      if command -v ctr >/dev/null 2>&1; then
        if sudo ctr -n moby images import "$tmp_tar"; then
          rm -f "$tmp_tar"
          return 0
        fi
      fi
      rm -f "$tmp_tar"
      echo "❌ Failed to import $t"
    fi
  done
  return 1
}

# ====== Minimal tooling (only if missing) ======
echo "▶ Ensuring minimal tools (xz-utils, curl, jq, git)"
if ! command -v xz >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xz-utils curl jq git
fi

# ====== Containerlab install/upgrade (non-fatal) ======
echo "▶ Containerlab setup (CLAB_AUTO_UPGRADE=${CLAB_AUTO_UPGRADE:-true})"
if [ "${CLAB_AUTO_UPGRADE:-true}" = "true" ]; then
  if command -v containerlab >/dev/null 2>&1; then
    echo "▶ containerlab present; attempting upgrade"
    sudo containerlab version upgrade || true
  else
    echo "▶ containerlab not found; installing"
    if ! curl -fsSL https://get.containerlab.dev | sudo -E bash; then
      echo "⚠️ Could not install containerlab now; you can install later with:"
      echo "   curl -sL https://get.containerlab.dev | sudo -E bash"
    fi
  fi
fi
containerlab version || true

# ====== Create flash/ directory structure ======
echo "▶ Ensuring flash/ directory structure"
mkdir -p "${FLASH_DIR}"

create_flash_dir() { mkdir -p "${FLASH_DIR}/$1"; }

# Example sets (match your topo)
for n in GW11 Spine1-DC1 Spine2-DC1 Spine3-DC1 Leaf1-DC1 Leaf2-DC1 Leaf3-DC1 Leaf4-DC1 Host1-DC1 Host2-DC1; do
  create_flash_dir "DC1/${n}"
done
for n in GW21 Spine1-DC2 Spine2-DC2 Spine3-DC2 Leaf1-DC2 Leaf2-DC2 Leaf3-DC2 Leaf4-DC2 Host1-DC2 Host2-DC2; do
  create_flash_dir "DC2/${n}"
done
for n in GW31 Spine1-DC3 Spine2-DC3 Leaf1-DC3 Leaf2-DC3 Host1-DC3 Host2-DC3; do
  create_flash_dir "DC3/${n}"
done
for n in RR P1 P2 P3 P4; do
  create_flash_dir "MPLS/${n}"
done

# IMPORTANT: no recursive "safety symlink" (it caused basicLab/basicLab duplicates)
# (Removed on purpose)

# ====== Wait for Docker (docker-in-docker needs a moment) ======
need docker
wait_for_docker || true

# ====== Acquire cEOS image (local tar preferred, optional remote pull) ======
if docker image inspect "${CEOS_TAG_LOCAL}" >/dev/null 2>&1; then
  echo "✅ cEOS already present: ${CEOS_TAG_LOCAL}"
else
  # 1) Try to load from local tarball(s)
  if load_first_tar; then
    echo "▶ Loaded cEOS from local tar"
  # 2) Optionally pull from remote if user set CEOS_REMOTE
  elif [[ -n "${CEOS_REMOTE}" ]]; then
    echo "▶ Pulling remote (opt-in): ${CEOS_REMOTE}"
    pull_with_retry "${CEOS_REMOTE}" || echo "❌ Remote pull failed"
  else
    echo "ℹ️ No local cEOS tar in ${IMAGES_DIR} and no CEOS_REMOTE set."
    echo "   Place your tar at:"
    echo "     - ${IMAGES_DIR}/ceos-${CEOS_VER}.tar  (preferred)"
    echo "     - ${IMAGES_DIR}/ceos.tar  or a cEOS*.tar(.xz|.gz)"
    echo "   Then re-run this script or execute '.devcontainer/basicLab/load-ceos.sh'."
  fi

  # Ensure the expected local tag exists (retag if needed)
  if docker image inspect "${CEOS_TAG_LOCAL}" >/dev/null 2>&1; then
    :
  else
    SRC_IMG="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -Ei '^ceos[:@]|/ceos:' | head -n1 || true)"
    if [[ -n "$SRC_IMG" ]]; then
      echo "▶ Retagging ${SRC_IMG} → ${CEOS_TAG_LOCAL}"
      docker tag "${SRC_IMG}" "${CEOS_TAG_LOCAL}" || true
    fi
  fi
fi

echo "✅ Current cEOS images:"
docker images | awk 'NR==1 || /ceos/ {print}'

# ====== Auto-deploy with Containerlab (only if image present) ======
AUTO_DEPLOY="${CLAB_AUTO_DEPLOY:-true}"
if [ "${AUTO_DEPLOY}" = "true" ]; then
  if ! docker image inspect "${CEOS_TAG_LOCAL}" >/dev/null 2>&1; then
    echo "⚠️ Skipping deploy: ${CEOS_TAG_LOCAL} not available yet."
  elif ! command -v containerlab >/dev/null 2>&1; then
    echo "⚠️ Skipping deploy: containerlab not available."
  else
    echo "▶ Waiting for Docker again before deploy..."
    wait_for_docker || true
    echo "▶ Checking if lab already deployed"
    if sudo containerlab inspect -t "${TOPO_FILE}" >/dev/null 2>&1; then
      echo "ℹ️ Lab already deployed; skipping"
    else
      echo "▶ Deploying lab: ${TOPO_FILE}"
      if sudo containerlab deploy -t "${TOPO_FILE}"; then
        echo "✅ Lab deployed"
        sudo containerlab inspect -t "${TOPO_FILE}" || true
      else
        echo "⚠️ containerlab deploy failed; try manually:"
        echo "   sudo containerlab deploy -t \"${TOPO_FILE}\""
      fi
    fi
  fi
else
  echo "ℹ️ Auto-deploy disabled (CLAB_AUTO_DEPLOY=false)"
fi

echo "✅ postCreate complete."