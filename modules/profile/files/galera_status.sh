#!/bin/bash
# Appends one JSON line with MariaDB/Galera health to /var/log/galera-status.json
OUT=/var/log/galera-status.json
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST=$(hostname -s)

if mysqladmin ping >/dev/null 2>&1; then
  declare -A S
  while read -r k v; do S[$k]=$v; done < <(mysql -N -e "SHOW GLOBAL STATUS LIKE 'wsrep_%'" 2>/dev/null)
  printf '{"@timestamp":"%s","host_name":"%s","mariadb_status":"up","wsrep_cluster_size":%s,"wsrep_cluster_status":"%s","wsrep_local_state_comment":"%s","wsrep_ready":"%s","wsrep_connected":"%s","wsrep_local_recv_queue":%s,"wsrep_flow_control_paused":%s}\n' \
    "$TS" "$HOST" "${S[wsrep_cluster_size]:-0}" "${S[wsrep_cluster_status]:-unknown}" \
    "${S[wsrep_local_state_comment]:-unknown}" "${S[wsrep_ready]:-OFF}" "${S[wsrep_connected]:-OFF}" \
    "${S[wsrep_local_recv_queue]:-0}" "${S[wsrep_flow_control_paused]:-0}" >> "$OUT"
else
  printf '{"@timestamp":"%s","host_name":"%s","mariadb_status":"down","wsrep_cluster_size":0,"wsrep_cluster_status":"unknown","wsrep_local_state_comment":"unknown","wsrep_ready":"OFF","wsrep_connected":"OFF","wsrep_local_recv_queue":0,"wsrep_flow_control_paused":0}\n' \
    "$TS" "$HOST" >> "$OUT"
fi
