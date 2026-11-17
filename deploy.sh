#!/bin/bash
# Deploy over SSH key: OpenSearch first, then galera01 (bootstrap), then the rest.
# All settings live in .env
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/.env" ] || { echo "Missing $HERE/.env"; exit 1; }
set -a; source "$HERE/.env"; set +a

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SUDO="${SUDO:-sudo}"

declare -A PUB=(
  [os01]="$OS01_IP"
  [galera01]="$GALERA01_IP"
  [galera02]="$GALERA02_IP"
  [galera03]="$GALERA03_IP"
)
ORDER=(os01 galera01 galera02 galera03)

# OpenSearch admin password: from .env, or generated once and saved to .env
if [ -z "${OS_PASSWORD:-}" ]; then
  OS_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)Aa1!"
  sed -i "s|^OS_PASSWORD=.*|OS_PASSWORD='${OS_PASSWORD}'|" "$HERE/.env"
  echo "Generated OpenSearch password and saved it to .env"
fi

SSH_OPTS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new)

# 1) discover private IPs
declare -A PRIV
for n in "${ORDER[@]}"; do
  PRIV[$n]=$(ssh "${SSH_OPTS[@]}" "$SSH_USER@${PUB[$n]}" "hostname -I | awk '{print \$1}'")
  echo "$n: public ${PUB[$n]}  private ${PRIV[$n]}"
done

# 2) build a staged copy with the real values
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -r "$HERE/modules" "$HERE/manifests" "$STAGE/"
sed -i \
  -e "s|@OS_IP@|${PRIV[os01]}|" \
  -e "s|@OS_PASS@|${OS_PASSWORD}|" \
  -e "s|@G1@|${PRIV[galera01]}|" \
  -e "s|@G2@|${PRIV[galera02]}|" \
  -e "s|@G3@|${PRIV[galera03]}|" \
  "$STAGE/manifests/site.pp"

# 3) deploy in order
for n in "${ORDER[@]}"; do
  ip="${PUB[$n]}"
  echo "=== $n ($ip) ==="

  # prepare host (fresh /opt/puppet-stack each run)
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" \
    "export DEBIAN_FRONTEND=noninteractive; \
     $SUDO hostnamectl set-hostname $n; \
     command -v puppet >/dev/null || { $SUDO apt-get update -q && $SUDO apt-get install -y -q puppet-agent curl gnupg; }; \
     $SUDO rm -rf /opt/puppet-stack && $SUDO mkdir -p /opt/puppet-stack && $SUDO chown $SSH_USER /opt/puppet-stack"

  # copy files (tar over ssh, no rsync needed)
  tar -C "$STAGE" -czf - . | ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "tar -xzf - -C /opt/puppet-stack"

  # exit code 2 = changes applied successfully
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" \
    "$SUDO puppet apply --detailed-exitcodes --modulepath=/opt/puppet-stack/modules /opt/puppet-stack/manifests/site.pp" \
    || { rc=$?; [ $rc -eq 2 ] || { echo "FAILED on $n (rc=$rc)"; exit $rc; }; }
done

echo
echo "Done. OpenSearch admin password: $OS_PASSWORD"
echo "OpenSearch: https://${PRIV[os01]}:9200  (public: https://${PUB[os01]}:9200)"
