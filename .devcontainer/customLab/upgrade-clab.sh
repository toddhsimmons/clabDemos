#!/usr/bin/env bash
set -euo pipefail
if ! command -v containerlab >/dev/null 2>&1; then
  echo "ℹ️ Containerlab not found, installing..."
  curl -sL https://get.containerlab.dev | sudo -E bash
else
  echo "ℹ️ Checking for Containerlab updates..."
  # Upgrade if a newer version exists; don't fail the Codespace if no update is needed
  sudo containerlab version upgrade || true
fi

echo "✅ Containerlab is ready: $(containerlab version | head -n1)"