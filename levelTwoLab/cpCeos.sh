#!/usr/bin/env bash
set -euo pipefail

# ---------- User variables (edit if your paths/names change) ----------
LOCAL_FILE="images/cEOS64-lab-4.30.1F.tar.xz"
REMOTE_DIR="/workspaces/clabDemos/levelTwoLab/images"
CEOS_VER="${CEOS_LAB_VERSION:-${CEOS_VERSION:-4.30.1F}}"
CEOS_TAG="ceos:${CEOS_VER}"
TOPO_FILE="/workspaces/clabDemos/levelTwoLab/topo.clab.yaml"
# ----------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $0 [--deploy] [--force] [<codespace-name>]

If <codespace-name> is omitted, the script will list your codespaces and prompt.
--deploy  : run containerlab deploy inside the codespace after loading
--force   : force re-upload and reload even if already present
EOF
}

# ---- parse flags ----
DEPLOY=""
FORCE=""
CODESPACE=""

for arg in "$@"; do
  case "$arg" in
    --deploy) DEPLOY="--deploy" ;;
    --force)  FORCE="--force" ;;
    -h|--help) usage; exit 0 ;;
    *) CODESPACE="$arg" ;;
  esac
done

# ---- prerequisites (Mac) ----
if ! command -v gh >/dev/null 2>&1; then
  echo "❌ GitHub CLI (gh) not found. Install: brew install gh"
  exit 1
fi
if [[ ! -f "${LOCAL_FILE}" ]]; then
  echo "❌ Local file not found: ${LOCAL_FILE}"
  exit 1
fi

# If codespace not provided, list and prompt
if [[ -z "${CODESPACE}" ]]; then
  echo "ℹ️ No codespace specified. Available Codespaces:"
  gh codespace list
  echo
  read -rp "Enter codespace name: " CODESPACE
  [[ -z "${CODESPACE}" ]] && { echo "❌ No codespace provided"; exit 1; }
fi

echo "▶ Codespace: ${CODESPACE}"
echo "▶ Local file: ${LOCAL_FILE}"
echo "▶ Remote dir: ${REMOTE_DIR}"
echo "▶ Target tag: ${CEOS_TAG}"

# ---- helpers ----
get_local_size() {
  # macOS: stat -f%z ; Linux: stat -c %s
  if stat -f%z "${LOCAL_FILE}" >/dev/null 2>&1; then
    stat -f%z "${LOCAL_FILE}"
  else
    stat -c %s "${LOCAL_FILE}"
  fi
}

# ---- short-circuit if image already loaded (unless --force) ----
if [[ -z "${FORCE}" ]]; then
  if gh codespace ssh -c "${CODESPACE}" -- docker image inspect "${CEOS_TAG}" >/dev/null 2>&1; then
    echo "✅ Image ${CEOS_TAG} already present in Codespace. Skipping upload/load."
    exit 0
  fi
fi

# ---- ensure remote dir exists ----
gh codespace ssh -c "${CODESPACE}" -- "mkdir -p '${REMOTE_DIR}'"

# ---- skip copy if same file already exists remotely (unless --force) ----
LOCAL_SIZE="$(get_local_size)"
REMOTE_FILE="${REMOTE_DIR}/$(basename "${LOCAL_FILE}")"
REMOTE_SIZE="$(gh codespace ssh -c "${CODESPACE}" -- "stat -c %s '${REMOTE_FILE}' 2>/dev/null || echo 0")"

if [[ -z "${FORCE}" && "${LOCAL_SIZE}" = "${REMOTE_SIZE}" && "${REMOTE_SIZE}" != "0" ]]; then
  echo "ℹ️ Remote file already present with matching size (${REMOTE_SIZE} bytes). Skipping copy."
else
  echo "▶ Copying file to Codespace..."
  gh codespace cp -e "${LOCAL_FILE}" "remote:${REMOTE_DIR}/" -c "${CODESPACE}"
fi

# ---- remote: load/import and optional deploy ----
REMOTE_CMD=$(cat <<'EOSH'
set -euo pipefail
FILE_PATH="$1"; CEOS_TAG="$2"; TOPO_FILE="$3"; DEPLOY_FLAG="${4:-}"; FORCE_FLAG="${5:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'"; exit 1; }; }
need docker; need tar
case "$FILE_PATH" in *.xz) need xz ;; *.gz) need gzip ;; esac

# Wait for docker (dind) briefly
i=0; until docker info >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 120 ] && { echo "Docker not ready"; exit 1; }; sleep 1; done

# Skip if already loaded (unless --force)
if [ -z "$FORCE_FLAG" ] && docker image inspect "$CEOS_TAG" >/dev/null 2>&1; then
  echo "✅ $CEOS_TAG already loaded."
  exit 0
fi

TMP_TAR="$(mktemp /tmp/ceos-XXXXXX.tar)"
case "$FILE_PATH" in
  *.tar.xz)  xz   -dc "$FILE_PATH" > "$TMP_TAR" ;;
  *.tar.gz)  gzip -dc "$FILE_PATH" > "$TMP_TAR" ;;
  *.tar)     cp -f "$FILE_PATH" "$TMP_TAR" ;;
  *)         echo "Unknown archive: $FILE_PATH"; exit 1 ;;
esac

# docker image tar vs rootfs tar detection
if tar -tf "$TMP_TAR" | grep -q '^manifest\.json$'; then
  echo "▶ docker load"
  docker load -i "$TMP_TAR"
else
  echo "▶ docker import"
  docker import "$TMP_TAR" "$CEOS_TAG"
fi
rm -f "$TMP_TAR"

# Ensure final tag exists (for docker-load case)
if ! docker image inspect "$CEOS_TAG" >/dev/null 2>&1; then
  SRC="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i '^ceos' | head -n1 || true)"
  [ -n "$SRC" ] && docker tag "$SRC" "$CEOS_TAG" || true
fi

echo "✅ Available images:"
docker images | awk 'NR==1 || /ceos/ {print}'

if [ "$DEPLOY_FLAG" = "--deploy" ]; then
  if command -v containerlab >/dev/null 2>&1; then
    echo "▶ Deploying lab..."
    sudo containerlab deploy -t "$TOPO_FILE" || echo "⚠️ containerlab deploy failed"
  else
    echo "ℹ️ containerlab not installed; skipping deploy"
  fi
fi
EOSH
)

# shellcheck disable=SC2029
gh codespace ssh -c "${CODESPACE}" -- bash -lc \
"$(printf "%q " "$REMOTE_CMD") '${REMOTE_FILE}' '${CEOS_TAG}' '${TOPO_FILE}' '${DEPLOY}' '${FORCE}'"

echo "✅ Done."