#!/usr/bin/env bash
set -euo pipefail

# ---------- User variables ----------
LOCAL_FILE="images/cEOS64-lab-4.30.1F.tar.xz"
REMOTE_DIR="/workspaces/clabDemos/basicLab/images"
CEOS_VER="${CEOS_LAB_VERSION:-${CEOS_VERSION:-4.30.1F}}"
CEOS_TAG="ceos:${CEOS_VER}"
TOPO_FILE="/workspaces/clabDemos/basicLab/topo.clab.yaml"
# ------------------------------------

usage() {
  echo "Usage: $0 <codespace-name> [--deploy]"
}

CODESPACE="${1:-}"
DEPLOY="${2:-}"
[[ -z "${CODESPACE}" ]] && { usage; exit 1; }

if ! command -v gh >/dev/null 2>&1; then
  echo "❌ GitHub CLI (gh) not found. Install: brew install gh"
  exit 1
fi
if [[ ! -f "${LOCAL_FILE}" ]]; then
  echo "❌ Local file not found: ${LOCAL_FILE}"
  exit 1
fi

LOCAL_SIZE=$(stat -f%z "$LOCAL_FILE")

echo "▶ Codespace: ${CODESPACE}"
echo "▶ Local file: ${LOCAL_FILE} ($LOCAL_SIZE bytes)"
echo "▶ Target tag: ${CEOS_TAG}"

# --- check if image already loaded in Codespace ---
if gh codespace ssh -c "${CODESPACE}" -- docker image inspect "${CEOS_TAG}" >/dev/null 2>&1; then
  echo "✅ Image ${CEOS_TAG} already present in Codespace. Skipping upload/load."
  exit 0
fi

# --- ensure remote dir exists ---
gh codespace ssh -c "${CODESPACE}" -- "mkdir -p '${REMOTE_DIR}'"

# --- check if file already exists remotely with same size ---
REMOTE_FILE="${REMOTE_DIR}/$(basename "${LOCAL_FILE}")"
REMOTE_SIZE=$(gh codespace ssh -c "${CODESPACE}" -- "stat -c %s '${REMOTE_FILE}' 2>/dev/null || echo 0")
if [[ "$LOCAL_SIZE" == "$REMOTE_SIZE" && "$REMOTE_SIZE" != "0" ]]; then
  echo "ℹ️ File already exists in Codespace with matching size ($REMOTE_SIZE bytes). Skipping copy."
else
  echo "▶ Copying file to Codespace..."
  gh codespace cp -e "${LOCAL_FILE}" "remote:${REMOTE_DIR}/" -c "${CODESPACE}"
fi

# --- remote load/import ---
REMOTE_CMD=$(cat <<'EOSH'
set -euo pipefail
FILE_PATH="$1"; CEOS_TAG="$2"; TOPO_FILE="$3"; DEPLOY="$4"

if docker image inspect "$CEOS_TAG" >/dev/null 2>&1; then
  echo "✅ $CEOS_TAG already loaded."
  exit 0
fi

TMP_TAR="$(mktemp /tmp/ceos-XXXXXX.tar)"
case "$FILE_PATH" in
  *.tar.xz)  xz   -dc "$FILE_PATH" > "$TMP_TAR" ;;
  *.tar.gz)  gzip -dc "$FILE_PATH" > "$TMP_TAR" ;;
  *.tar)     cp -f "$FILE_PATH" "$TMP_TAR" ;;
esac

if tar -tf "$TMP_TAR" | grep -q '^manifest\.json$'; then
  echo "▶ docker load"
  docker load -i "$TMP_TAR"
else
  echo "▶ docker import"
  docker import "$TMP_TAR" "$CEOS_TAG"
fi
rm -f "$TMP_TAR"

if ! docker image inspect "$CEOS_TAG" >/dev/null 2>&1; then
  SRC="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i '^ceos' | head -n1 || true)"
  [ -n "$SRC" ] && docker tag "$SRC" "$CEOS_TAG" || true
fi

echo "✅ Available images:"
docker images | awk 'NR==1 || /ceos/ {print}'

if [ "$DEPLOY" = "--deploy" ]; then
  if command -v containerlab >/dev/null 2>&1; then
    echo "▶ Deploying lab..."
    sudo containerlab deploy -t "$TOPO_FILE" || echo "⚠️ containerlab deploy failed"
  fi
fi
EOSH
)

gh codespace ssh -c "${CODESPACE}" -- bash -lc \
"$(printf "%q " "$REMOTE_CMD") '${REMOTE_FILE}' '${CEOS_TAG}' '${TOPO_FILE}' '${DEPLOY:-}'"