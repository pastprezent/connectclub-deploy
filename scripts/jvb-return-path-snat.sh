#!/usr/bin/env bash
# JVB ICE return-path SNAT — preserve HostPort on outbound UDP.
#
# Root cause (STAGE 185.219.135.194, 2026-10-19):
#   Selected ICE pair is HostPort/srflx. Client→JVB works (prflx learned), but
#   JVB→client checks fail because Docker MASQUERADE rewrites outbound UDP
#   source ports to ephemeral values. Clients punched a hole toward :HostPort.
#
# Fix:
#   For each running jvb-* container, SNAT udp -s <dockerIP> --sport <HostPort>
#   to PUBLIC:HostPort so the return path keeps the advertised HostPort.
#
# Critical: iptables -S prints -s 172.18.0.16/32 while docker inspect prints
# 172.18.0.16. Without normalizing CIDR suffixes, cleanup treats live rules as
# stale and DELETE them immediately after ADD. Always use norm_ip().
#
# Usage:
#   DOCKER_HOST_ADDRESS=185.219.135.194 ./scripts/jvb-return-path-snat.sh
#   ./scripts/jvb-return-path-snat.sh --sync-only
#   ./scripts/jvb-return-path-snat.sh --install-cron
#
# See docs/jvb-return-path-snat.md

set -euo pipefail

PUBLIC="${DOCKER_HOST_ADDRESS:-185.219.135.194}"
TAG_COMMENT=jvb-hostport-snat
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Prefer deploy root .env when present (same layout as /root/connectclub-deploy).
DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$DEPLOY_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$DEPLOY_ROOT/.env"
  set +a
fi
PUBLIC="${DOCKER_HOST_ADDRESS:-$PUBLIC}"

# iptables -S prints -s 172.18.0.16/32; docker inspect prints 172.18.0.16
norm_ip() {
  local x="${1:-}"
  x="${x%%/*}"
  printf '%s' "$x"
}

sync_snat() {
  local id name ip ports port key a keep spec line sip sport
  local -a alive_keys=()

  if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    iptables -C DOCKER-USER -j RETURN 2>/dev/null || iptables -I DOCKER-USER -j RETURN
  fi

  while read -r id; do
    [[ -z "$id" ]] && continue
    name=$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$id" | awk '{print $1}')
    ip=$(norm_ip "$ip")
    ports=$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}' "$id")
    if [[ -z "$ip" || -z "$ports" ]]; then
      echo "skip $name (ip/ports empty)"
      continue
    fi
    for port in $ports; do
      key="$ip:$port"
      alive_keys+=("$key")
      if iptables -t nat -C POSTROUTING -p udp -s "$ip" --sport "$port" -j SNAT --to-source "${PUBLIC}:${port}" -m comment --comment "$TAG_COMMENT" 2>/dev/null \
        || iptables -t nat -C POSTROUTING -p udp -s "${ip}/32" --sport "$port" -j SNAT --to-source "${PUBLIC}:${port}" -m comment --comment "$TAG_COMMENT" 2>/dev/null; then
        echo "ok  $name $key -> ${PUBLIC}:$port"
      else
        iptables -t nat -I POSTROUTING -p udp -s "$ip" --sport "$port" -j SNAT --to-source "${PUBLIC}:${port}" -m comment --comment "$TAG_COMMENT"
        echo "ADD $name $key -> ${PUBLIC}:$port"
      fi
    done
  done < <(docker ps -q --filter name=jvb-)

  while read -r line; do
    sip=$(echo "$line" | sed -n 's/.* -s \([^ ]*\) .*/\1/p')
    sport=$(echo "$line" | sed -n 's/.* --sport \([^ ]*\) .*/\1/p')
    sip=$(norm_ip "$sip")
    [[ -z "$sip" || -z "$sport" ]] && continue
    key="$sip:$sport"
    keep=0
    for a in "${alive_keys[@]:-}"; do
      [[ "$a" == "$key" ]] && keep=1 && break
    done
    if [[ "$keep" -eq 0 ]]; then
      spec=${line#-A POSTROUTING }
      # shellcheck disable=SC2086
      iptables -t nat -D POSTROUTING $spec && echo "DEL stale $key" || true
    fi
  done < <(iptables -t nat -S POSTROUTING | grep -F "comment $TAG_COMMENT" || true)
}

install_cron() {
  local cron_path=/etc/cron.d/jvb-hostport-snat
  local install_path="$DEPLOY_ROOT/jvb-return-path-snat.sh"

  # Keep a stable path at deploy root for cron (matches live STAGE layout).
  cp -f "$SCRIPT_PATH" "$install_path"
  chmod 755 "$install_path"
  grep -q 'norm_ip' "$install_path" || {
    echo "ERROR: installed script missing norm_ip" >&2
    exit 1
  }

  printf '%s\n' "* * * * * root $install_path --sync-only >> /var/log/jvb-snat-sync.log 2>&1" > "$cron_path"
  chmod 644 "$cron_path"
  systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || service cron start 2>/dev/null || true

  echo "cron.d:"
  cat "$cron_path"
  echo "install: $install_path"
  ls -la "$install_path"
}

case "${1:-}" in
  --sync-only)
    sync_snat
    exit 0
    ;;
  --install-cron)
    echo "PUBLIC=$PUBLIC"
    sync_snat
    install_cron
    echo "===== re-run via installed path ====="
    "$DEPLOY_ROOT/jvb-return-path-snat.sh" --sync-only
    RULES=$(iptables -t nat -S POSTROUTING | grep -F "comment $TAG_COMMENT" || true)
    if [[ -z "$RULES" ]]; then
      echo "ERROR: no SNAT rules after sync — aborting." >&2
      iptables -t nat -S POSTROUTING | head -40 || true
      exit 1
    fi
    echo "===== SNAT rules ====="
    echo "$RULES"
    exit 0
    ;;
  ""|--help|-h)
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
      sed -n '2,22p' "$SCRIPT_PATH"
      exit 0
    fi
    ;;
esac

echo "PUBLIC=$PUBLIC"
echo "===== JVBs ====="
docker ps --filter name=jvb- --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}' || true
echo "===== apply SNAT ====="
sync_snat
echo "===== NAT POSTROUTING (SNAT/MASQUERADE) ====="
iptables -t nat -S POSTROUTING 2>/dev/null | grep -E "SNAT|MASQUERADE|$TAG_COMMENT" | head -40 || true
