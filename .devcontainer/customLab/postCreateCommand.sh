#!/usr/bin/env bash
set -Eeuo pipefail

# ====== Paths & inputs ======
REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)"
LAB_DIR="${REPO_ROOT}/customLab"
FLASH_DIR="${LAB_DIR}/flash"
TOPO_FILE="${LAB_DIR}/topo.clab.yaml"
IMAGES_DIR="${LAB_DIR}/images"

CEOS_VER="${CEOS_LAB_VERSION:-${CEOS_VERSION:-4.30.1F}}"
CEOS_TAG_LOCAL="ceos:${CEOS_VER}"
REMOTE_TAG="$(echo "${CEOS_VER}" | tr '[:upper:]' '[:lower:]')"
CEOS_REMOTE="${CEOS_REMOTE:-}"  # e.g. ghcr.io/you/ceos:${REMOTE_TAG} (optional, if you ever want remote)

echo "▶ repo root   : ${REPO_ROOT}"
echo "▶ lab dir     : ${LAB_DIR}"
echo "▶ topo file   : ${TOPO_FILE}"
echo "▶ expected tag: ${CEOS_TAG_LOCAL}"

# ====== Tiny helpers ======
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing '$1'"; exit 1; }; }

pull_with_retry() {
  local img="$1" tries=0 max=3
  until docker pull "$img"; do
    tries=$((tries+1))
    (( tries >= max )) && return 1
    echo "…retrying docker pull ($tries/$max) in 3s"; sleep 3
  done
}

wait_for_docker() {
  echo "▶ Waiting for Docker daemon..."
  local tries=0 max=180
  # keep daemon tmp sane while waiting
  sudo mkdir -p /var/lib/docker/tmp || true
  sudo chmod 1777 /var/lib/docker/tmp || true
  # (safe devcontainer hack) ensure tmp points at /tmp
  sudo ln -sfn /tmp /var/lib/docker/tmp || true
  until docker info >/dev/null 2>&1; do
    tries=$((tries+1))
    (( tries > max )) && { echo "❌ Docker did not become ready"; return 1; }
    sleep 1
  done
  echo "✅ Docker is ready"
}

# Load cEOS from a local tar(.xz|.gz|.tar). Uses docker load if a docker-archive (manifest.json present),
# otherwise uses docker import for a rootfs tar.
load_ceos_from_local() {
  mkdir -p "${IMAGES_DIR}"
  # Preferred names first, then any cEOS*.tar*
  local candidates=(
    "${IMAGES_DIR}/ceos-${CEOS_VER}.tar"
    "${IMAGES_DIR}/ceos.tar"
  )
  mapfile -t others < <(ls -1t "${IMAGES_DIR}"/cEOS*.tar* 2>/dev/null || true)
  candidates+=("${others[@]}")

  for t in "${candidates[@]}"; do
    [[ -f "$t" ]] || continue
    echo "📦 Found local image: $t"

    # Decompress to temp tar
    local tmp_tar
    tmp_tar="$(mktemp /tmp/ceos-XXXXXX.tar)"
    case "$t" in
      *.tar.xz)  need xz;   xz   -dc "$t" > "$tmp_tar" ;;
      *.tar.gz)  need gzip; gzip -dc "$t" > "$tmp_tar" ;;
      *.tar)     cp -f "$t" "$tmp_tar" ;;
      *)         echo "❌ Unknown archive format: $t"; rm -f "$tmp_tar"; continue ;;
    esac

    # Detect tar type: docker image tar (has manifest.json) vs rootfs tar (no manifest.json)
    if tar -tf "$tmp_tar" | grep -q '^manifest\.json$'; then
      echo "▶ Detected docker image tar → docker load"
      if sudo DOCKER_TMPDIR=/tmp docker load -i "$tmp_tar"; then
        rm -f "$tmp_tar"
        return 0
      else
        echo "❌ docker load failed for $t"
      fi
    else
      echo "▶ Detected rootfs tar → docker import to ${CEOS_TAG_LOCAL}"
      if sudo docker import "$tmp_tar" "${CEOS_TAG_LOCAL}"; then
        rm -f "$tmp_tar"
        return 0
      else
        echo "❌ docker import failed for $t"
      fi
    fi

    rm -f "$tmp_tar"
    echo "❌ Import/load failed for $t (will try next candidate if any)"
  done

  return 1
}

# ====== Minimal tooling (only if missing) ======
echo "▶ Ensuring basic tools (xz-utils, curl, jq, git)"
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
    curl -fsSL https://get.containerlab.dev | sudo -E bash || true
  fi
fi
containerlab version || true

# ====== Create flash/ structure ======
echo "▶ Ensuring flash/ directory structure"
mkdir -p "${FLASH_DIR}"
create_flash_dir() { mkdir -p "${FLASH_DIR}/$1"; }
for n in DC1-Spine1 DC1-Spine2 DC1-Leaf1 DC1-Leaf2 DC1-Leaf3 DC1-Leaf4; do create_flash_dir "DC1/${n}"; done

# ====== Docker ready (dind) ======
need docker
wait_for_docker || true


# --- Ensure Containerlab extension is installed early (non-fatal) ---
if command -v code >/dev/null 2>&1; then
  echo "▶ Ensuring VS Code Containerlab extension (srl-labs.vscode-containerlab) is installed..."
  # install via 'code' CLI if available; non-fatal
  code --install-extension srl-labs.vscode-containerlab || true
else
  echo "ℹ️ 'code' CLI not available in this session; extension may be installed by Codespaces UI."
fi


# ====== Acquire cEOS image ======
if docker image inspect "${CEOS_TAG_LOCAL}" >/dev/null 2>&1; then
  echo "✅ cEOS already present: ${CEOS_TAG_LOCAL}"
else
  if load_ceos_from_local; then
    echo "✅ Loaded cEOS from local tar(s)"
  elif [[ -n "${CEOS_REMOTE}" ]]; then
    echo "▶ Pulling remote (opt-in): ${CEOS_REMOTE}"
    pull_with_retry "${CEOS_REMOTE}" || echo "❌ Remote pull failed"
  else
    echo "ℹ️ No local tar in ${IMAGES_DIR} and no CEOS_REMOTE set."
    echo "   Put your cEOS tar here (e.g., cEOS64-lab-${CEOS_VER}.tar.xz) and rerun:"
    echo "   bash .devcontainer/customLab/postCreateCommand.sh"
  fi

  # Retag to expected local name if docker load produced a different tag
  if docker image inspect "${CEOS_TAG_LOCAL}" >/dev/null 2>&1; then
    :
  else
    SRC_IMG="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -Ei '^ceos[:@]|/ceos:' | head -n1 || true)"
    if [[ -n "$SRC_IMG" ]]; then
      echo "▶ Retagging ${SRC_IMG} → ${CEOS_TAG_LOCAL}"
      sudo docker tag "${SRC_IMG}" "${CEOS_TAG_LOCAL}" || true
    fi
  fi
fi

echo "✅ Current cEOS images:"
docker images | awk 'NR==1 || /ceos/ {print}'

# ====== Auto-deploy with Containerlab (only if image present) ======
AUTO_DEPLOY="${CLAB_AUTO_DEPLOY:-true}"
if [ "${AUTO_DEPLOY}" = "true" ]; then
  if ! docker image inspect "${CEOS_TAG_LOCAL}" >/dev/null 2>&1; then
    echo "⚠️ Skipping deploy: ${CEOS_TAG_LOCAL} not available."
  elif ! command -v containerlab >/dev/null 2>&1; then
    echo "⚠️ Skipping deploy: containerlab not available."
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
else
  echo "ℹ️ Auto-deploy disabled (CLAB_AUTO_DEPLOY=false)"
fi

echo "✅ postCreate complete."