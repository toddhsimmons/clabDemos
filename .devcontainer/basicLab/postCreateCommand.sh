#!/usr/bin/env bash
set -euo pipefail

# --- Resolve repo root + lab dir ---
REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)"
LAB_DIR="${REPO_ROOT}/basicLab"              # your lab content lives here
FLASH_DIR="${LAB_DIR}/flash"               # bind root used in topo
TOPO_FILE="${LAB_DIR}/topo.clab.yaml"

# Default to your public namespace; allow GHCR_USER to override
OWNER_DEFAULT="toddhsimmons"
OWNER="${GHCR_USER:-$OWNER_DEFAULT}"

echo "▶ Using GHCR owner: ${OWNER}"

echo "▶ postCreate: repo root=${REPO_ROOT}"
echo "▶ postCreate: lab dir  =${LAB_DIR}"
echo "▶ postCreate: topo file=${TOPO_FILE}"

# --- Python venv (avoid system pip / PEP 668) ---
echo "▶ Prepare Python venv"
sudo apt-get update -y
sudo apt-get install -y python3-venv xz-utils curl jq git

# --- Ensure Node exists for VS Code status tool & pre-seed bootstrap path ---
echo "▶ Ensuring node & bootstrap path for VS Code Server status tool"
if ! command -v node >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs ca-certificates
fi

BOOT_DIR="$HOME/.vscode-remote/bin/000000.bootstrap"
mkdir -p "${BOOT_DIR}"
cat > "${BOOT_DIR}/node" <<'EOF'
#!/bin/sh
exec node "$@"
EOF
chmod +x "${BOOT_DIR}/node"
echo "▶ Bootstrap node ready at ${BOOT_DIR}/node"

if [ ! -d "/workspaces/.venv" ]; then
  python3 -m venv /workspaces/.venv
fi
# shellcheck disable=SC1091
source /workspaces/.venv/bin/activate
python -m pip install --upgrade pip wheel setuptools



# Ensure Ansible available in the venv (no AVD via pip!)
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "▶ Installing Ansible in venv..."
  # Ansible 9.x maps to ansible-core 2.16, compatible with AVD 5.6.x
  pip install "ansible>=9,<10"
  # Optional: Python helper library for AVD
  pip install "pyavd==5.6.0"
fi

echo "▶ Installing/upgrading Arista collections with ansible-galaxy..."
# Pin versions that match your environment
ansible-galaxy collection install arista.avd:==5.6.0 --force
ansible-galaxy collection install arista.cvp:==3.11.0 --force
ansible-galaxy collection install arista.eos:==10.0.0 --force

# --- Containerlab install/upgrade (resilient, non-fatal) ---
echo "▶ Containerlab setup (opt-out with CLAB_AUTO_UPGRADE=false)"
if [ "${CLAB_AUTO_UPGRADE:-true}" = "true" ]; then
  if command -v containerlab >/dev/null 2>&1; then
    echo "▶ containerlab already present; attempting upgrade"
    sudo containerlab version upgrade || true
  else
    echo "▶ containerlab not found; attempting install"
    install_urls=( "https://get.containerlab.srlinux.dev" "https://get.containerlab.dev" )
    installed=false
    for u in "${install_urls[@]}"; do
      tries=0
      while :; do
        echo "▶ Fetching installer: $u (try $((tries+1))/3)"
        if curl -fsSL "$u" | sudo -E bash; then
          installed=true
          break
        fi
        tries=$((tries+1))
        if (( tries >= 3 )); then
          echo "ℹ️ Installer URL failed after retries: $u"
          break
        fi
        sleep 3
      done
      $installed && break
    done
    if ! command -v containerlab >/dev/null 2>&1; then
      echo "⚠️ Could not install containerlab (network/DNS?). Continuing; you can install later with:"
      echo "   curl -sL https://get.containerlab.dev | sudo -E bash"
    fi
  fi
fi
containerlab version || true

# --- Create flash tree expected by topo.clab.yaml ---
echo "▶ Ensuring flash/ directory structure for all nodes"
mkdir -p "${FLASH_DIR}"

create_flash_dir() {
  local d="$1"
  mkdir -p "${FLASH_DIR}/${d}"
}

# DC1
for n in DC1-Spine1 DC1-Spine2 DC1-Leaf1 DC1-Leaf2 DC1-Leaf3 DC1-Leaf4; do
  create_flash_dir "DC1/${n}"
done

# SAFETY symlink for nested runs
if [ ! -e "${LAB_DIR}/basicLab" ]; then
  ln -s "${LAB_DIR}" "${LAB_DIR}/basicLab"
  echo "ℹ️ Added safety symlink: ${LAB_DIR}/basicLab -> ${LAB_DIR}"
fi


# --- cEOS image handling: prefer local ".tar" sideload; optional remote pull ---
CEOS_VER="${CEOS_LAB_VERSION:-${CEOS_VERSION:-4.30.1F}}"
CEOS_TAG_LOCAL="ceos:${CEOS_VER}"
REMOTE_TAG="$(echo "${CEOS_VER}" | tr '[:upper:]' '[:lower:]')"   # 4.30.1F -> 4.30.1f

# Where users can drop their own image tar (document this in your README/notice)
IMAGES_DIR="${LAB_DIR}/images"
mkdir -p "${IMAGES_DIR}"

# Optional remote (only if user opts in)
# Example: CEOS_REMOTE="ghcr.io/yourorg/ceos:${REMOTE_TAG}"  (requires auth if private)
CEOS_REMOTE="${CEOS_REMOTE:-}"

echo "▶ Expect local tag: ${CEOS_TAG_LOCAL}"
[[ -n "${CEOS_REMOTE}" ]] && echo "▶ Remote (opt-in): ${CEOS_REMOTE}"

pull_with_retry() {
  local img="$1" tries=0 max=3
  until docker pull "${img}"; do
    tries=$((tries+1))
    if (( tries >= max )); then return 1; fi
    echo "…retrying docker pull (${tries}/${max}) in 3s"
    sleep 3
  done
  return 0
}

load_first_tar() {
  # Prefer versioned filename, then ceos.tar, then any .tar in the folder
  local candidates=(
    "${IMAGES_DIR}/ceos-${CEOS_VER}.tar"
    "${IMAGES_DIR}/ceos.tar"
  )
  # Add any other tarballs present as fallbacks
  mapfile -t others < <(ls -1 "${IMAGES_DIR}"/*.tar 2>/dev/null | grep -v -E "ceos(-${CEOS_VER})?\.tar$" || true)
  candidates+=("${others[@]}")

  for t in "${candidates[@]}"; do
    [[ -f "$t" ]] || continue
    echo "▶ Loading cEOS from tar: $t"
    if docker load -i "$t"; then
      return 0
    else
      echo "⚠️ Failed to load $t, trying next candidate…"
    fi
  done
  return 1
}

if docker image inspect "${CEOS_TAG_LOCAL}" >/dev/null 2>&1; then
  echo "✅ cEOS already present: ${CEOS_TAG_LOCAL} (skipping acquisition)"
else
  # 1) Try local sideload first
  if load_first_tar; then
    :
  # 2) If user opted into remote, try pulling (may require login)
  elif [[ -n "${CEOS_REMOTE}" ]]; then
    echo "▶ Pulling ${CEOS_REMOTE} (user-opted remote)…"
    # Optional login if user provided creds (kept generic; adjust to your registry)
    if [[ -n "${DOCKER_LOGIN_SERVER:-}" && -n "${DOCKER_LOGIN_USER:-}" && -n "${DOCKER_LOGIN_PASSWORD:-}" ]]; then
      echo "▶ Logging into ${DOCKER_LOGIN_SERVER} as ${DOCKER_LOGIN_USER}"
      printf '%s' "${DOCKER_LOGIN_PASSWORD}" | docker login "${DOCKER_LOGIN_SERVER}" -u "${DOCKER_LOGIN_USER}" --password-stdin
    fi
    if ! pull_with_retry "${CEOS_REMOTE}"; then
      echo "❌ Remote pull failed. Provide a local tar in ${IMAGES_DIR} or valid creds."
      exit 0  # don’t hard-fail whole postCreate; user can fix and rerun
    fi
  else
    echo "ℹ️ No local cEOS tar found in ${IMAGES_DIR} and no CEOS_REMOTE provided."
    echo "   Place your cEOS tarball at:"
    echo "     - ${IMAGES_DIR}/ceos-${CEOS_VER}.tar  (preferred)"
    echo "     - ${IMAGES_DIR}/ceos.tar"
    echo "   …then re-run this script. See repo notice for how to obtain the image."
    exit 0
  fi

  # After either load or pull, retag to topo name if needed
  if docker image inspect "${CEOS_TAG_LOCAL}" >/dev/null 2>&1; then
    echo "✅ Found ${CEOS_TAG_LOCAL} already"
  else
    # Try to locate a source image to retag (common names after load/pull)
    SRC_IMG="$(docker images --format '{{.Repository}}:{{.Tag}}' | \
               grep -Ei "ceos(:|@).*${REMOTE_TAG}|ceos.*${CEOS_VER}|ceos" | head -n1 || true)"
    if [[ -n "${CEOS_REMOTE}" && -z "${SRC_IMG}" ]]; then SRC_IMG="${CEOS_REMOTE}"; fi

    if [[ -n "${SRC_IMG}" ]]; then
      echo "▶ Retagging ${SRC_IMG} → ${CEOS_TAG_LOCAL}"
      docker tag "${SRC_IMG}" "${CEOS_TAG_LOCAL}"
    else
      echo "⚠️ Could not find a suitable source image to retag. Check 'docker images'."
    fi
  fi
fi

echo "✅ cEOS available as ${CEOS_TAG_LOCAL} (or will be once acquisition succeeds)"
docker images | awk 'NR==1 || /ceos/ {print}'











# CEOS_VER="${CEOS_LAB_VERSION:-${CEOS_VERSION:-4.30.1F}}"
# CEOS_TAG_LOCAL="ceos:${CEOS_VER}"

# OWNER="${GHCR_USER:-toddhsimmons}"
# REMOTE_TAG="$(echo "${CEOS_VER}" | tr '[:upper:]' '[:lower:]')"   # 4.30.1F -> 4.30.1f
# REMOTE_IMAGE="ghcr.io/${OWNER}/ceos:${REMOTE_TAG}"

# echo "▶ Expect local tag: ${CEOS_TAG_LOCAL}"
# echo "▶ Remote image   : ${REMOTE_IMAGE}"

# pull_with_retry() {
#   local img="$1" tries=0 max=3
#   until docker pull "${img}"; do
#     tries=$((tries+1))
#     if (( tries >= max )); then return 1; fi
#     echo "…retrying docker pull (${tries}/${max}) in 3s"
#     sleep 3
#   done
#   return 0
# }

# if docker image inspect "${CEOS_TAG_LOCAL}" >/dev/null 2>&1; then
#   echo "✅ cEOS already present: ${CEOS_TAG_LOCAL} (skipping pull)"
# else
#   if [[ -n "${GHCR_TOKEN:-}" ]]; then
#     echo "▶ Logging into GHCR as ${OWNER}"
#     echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${OWNER}" --password-stdin
#   else
#     echo "⚠️ GHCR_TOKEN not set; GHCR pull may fail if the image is private."
#   fi

#   echo "▶ Pulling ${REMOTE_IMAGE} ..."
#   if pull_with_retry "${REMOTE_IMAGE}"; then
#     echo "▶ Retagging to ${CEOS_TAG_LOCAL}"
#     docker tag "${REMOTE_IMAGE}" "${CEOS_TAG_LOCAL}"
#   else
#     echo "❌ Pull failed after retries. Ensure GHCR_USER='${OWNER}' and GHCR_TOKEN has scope read:packages."
#     # don't hard-exit; allow you to fix creds and re-run manually
#   fi
# fi

# echo "✅ cEOS available as ${CEOS_TAG_LOCAL} (or will be once pull succeeds)"
# docker images | awk 'NR==1 || /ceos/ {print}'

# --- QoL: auto-activate venv in interactive shells ---
grep -q "/workspaces/.venv/bin/activate" ~/.bashrc || echo "source /workspaces/.venv/bin/activate" >> ~/.bashrc

# --- Auto-deploy the lab (optional; toggle with CLAB_AUTO_DEPLOY) ---
AUTO_DEPLOY="${CLAB_AUTO_DEPLOY:-true}"
if [ "${AUTO_DEPLOY}" = "true" ]; then
  echo "▶ Auto-deploy enabled (CLAB_AUTO_DEPLOY=${AUTO_DEPLOY})"
  echo "▶ Waiting for Docker daemon..."
  tries=0; until docker info >/dev/null 2>&1; do
    tries=$((tries+1))
    if (( tries > 60 )); then
      echo "❌ Docker did not become ready in time"; break
    fi
    sleep 1
  done

  if command -v containerlab >/dev/null 2>&1; then
    echo "▶ Checking if lab is already deployed"
    if sudo containerlab inspect -t "${TOPO_FILE}" >/dev/null 2>&1; then
      echo "ℹ️ Lab already deployed, skipping deploy"
    else
      echo "▶ Deploying lab: ${TOPO_FILE}"
      if sudo containerlab deploy -t "${TOPO_FILE}"; then
        echo "✅ Lab deployed"
        sudo containerlab inspect -t "${TOPO_FILE}" || true
      else
        echo "⚠️ containerlab deploy failed; check logs and re-run:"
        echo "   sudo containerlab deploy -t \"${TOPO_FILE}\""
      fi
    fi
  else
    echo "⚠️ containerlab not available; skipping auto-deploy"
  fi
else
  echo "ℹ️ Auto-deploy disabled (CLAB_AUTO_DEPLOY=false)"
fi

echo "✅ postCreate complete."