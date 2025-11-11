#!/usr/bin/env bash
set -euo pipefail

# tunnel_codespace.sh
# Open local SSH tunnels from your Mac to your GitHub Codespace,
# covering all Containerlab SSH port mappings in your topology.
#
# Usage:
#   ./tunnel_codespace.sh <codespace-name>
#   ./tunnel_codespace.sh <codespace-name> --print-only   # just print the gh command
#
# Example:
#   ./tunnel_codespace.sh psychic-space-telegram-gg76jr55jp29w4v
#
# After it starts, connect in SecureCRT or ssh to 127.0.0.1:<PORT> (e.g., 2001).

CODESPACE_NAME="${1:-}"
PRINT_ONLY="${2:-}"

if [[ -z "${CODESPACE_NAME}" ]]; then
  echo "Usage: $0 <codespace-name> [--print-only]" >&2
  echo "Tip: list codespaces with: gh codespace list" >&2
  exit 1
fi

# Ensure GitHub CLI is present
if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI (gh) is not installed. Install via 'brew install gh'." >&2
  exit 2
fi

# Validate you can see the Codespace
if ! gh codespace list | grep -q "${CODESPACE_NAME}"; then
  echo "WARNING: Codespace '${CODESPACE_NAME}' not found in 'gh codespace list' output. Continuing anyway..." >&2
fi

# If you want to override the default ports, set PORTS env var as a space-separated list before running:
#   PORTS='2001 2002 2222' ./tunnel_codespace.sh <codespace-name>
if [[ -n "${PORTS:-}" ]]; then
  read -r -a PORT_LIST <<<"${PORTS}"
else

 # Default port list based on Loopback0 mapping:
  PORT_LIST=(
    2011 2012 2013 2014 2021 2022 2023 2024 2031 2032 2033 2051 2052
  )

  # DC1: 2001–2010, DC2: 2101–2110, DC3: 2201–2207, MPLS: 2301–2305
  # PORT_LIST=(
  #   2001 2002 2003 2004 2005 2006 2007 2008 2009 2010
  #   2101 2102 2103 2104 2105 2106 2107 2108 2109 2110
  #   2201 2202 2203 2204 2205 2206 2207
  #   2301 2302 2303 2304 2305
  # )

fi

# Build -L arguments
LARGS=()
for p in "${PORT_LIST[@]}"; do
  LARGS+=("-L" "${p}:127.0.0.1:${p}")
done

# Pretty print a mapping table for reference
cat <<'MAP'
Device → Port (default mapping)
--------------------------------
DC1
  Spine1-DC1  2011   Spine2-DC1  2012   
  Leaf1-DC1   2021   Leaf2-DC1   2022   Leaf3-DC1   2023   Leaf4-DC1 2024

Connect from your Mac/SecureCRT as:  Hostname=127.0.0.1, Port=<above>, Username=admin, Password=admin
MAP

echo
echo "Opening SSH tunnels to Codespace: ${CODESPACE_NAME}"
echo "Press Ctrl-C to close tunnels."
echo

# Compose the full gh command
# shellcheck disable=SC2068
CMD=(gh codespace ssh -c "${CODESPACE_NAME}" -- -N ${LARGS[@]})

if [[ "${PRINT_ONLY}" == "--print-only" ]]; then
  printf 'Command:\n'
  printf '  '
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

# Exec the command (keep in foreground, so you can Ctrl-C to stop)
exec "${CMD[@]}"
