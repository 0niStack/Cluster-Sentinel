# Cluster Sentinel

Puppet-automated **MariaDB Galera cluster** (3 nodes) with **Filebeat** shipping
logs and live health data to a central **OpenSearch** server. One place to see
whether MariaDB is up or down, the cluster size, and the sync state of every node.

```
 galera01 ─┐                       ┌────────────┐
 galera02 ─┼─ Filebeat ─ HTTPS ──▶ │ OpenSearch │  index: galera-logs-YYYY.MM.dd
 galera03 ─┘   (logs + status)     │   (os01)   │
                                   └────────────┘
```

## What gets installed

| VM | Hostname | Role |
|---|---|---|
| lab-1 | `os01` | OpenSearch 2.x (security enabled) + OpenSearch Dashboards (web UI) |
| lab-2 | `galera01` | MariaDB + Galera 4 (bootstraps the cluster) + Filebeat |
| lab-3 | `galera02` | MariaDB + Galera 4 (joins) + Filebeat |
| lab-4 | `galera03` | MariaDB + Galera 4 (joins) + Filebeat |

Filebeat sends two kinds of documents (`log_type` field):

- `mariadb_error`: lines from `/var/log/mysql/error.log`
- `galera_status`: one JSON line per minute from `/usr/local/bin/galera_status.sh`

Status fields: `mariadb_status` (up/down), `wsrep_cluster_size`,
`wsrep_cluster_status`, `wsrep_local_state_comment`, `wsrep_ready`,
`wsrep_connected`, `wsrep_local_recv_queue`, `wsrep_flow_control_paused`.

## Project layout

```
Cluster-Sentinel/
├── .env                  # your settings (not committed)
├── .gitignore
├── deploy.sh             # deploys everything over SSH key
├── manifests/site.pp     # node definitions (values filled in by deploy.sh)
└── modules/profile/
    ├── files/galera_status.sh
    └── manifests/
        ├── opensearch.pp
        ├── dashboards.pp
        ├── galera.pp
        └── filebeat.pp
```

## Requirements

- 4 VMs running Ubuntu 22.04+ or Debian 12, internet access, SSH key login
- `os01` with at least 4 GB RAM (for example a `t3.medium`)
- On your own machine: `bash`, `ssh`, `tar`, `openssl`
- No Puppet master needed: `deploy.sh` installs Puppet on each VM and runs `puppet apply`

### Network ports (AWS security group)

| Port | From | To |
|---|---|---|
| 22 | your IP | all VMs |
| 9200 | the 3 Galera VMs | `os01` |
| 5601 | **your IP only** | `os01` (Dashboards web UI, plain HTTP) |
| 3306, 4567 (TCP+UDP), 4568, 4444 | Galera VMs | each other |

Easiest: allow all traffic between the VMs by letting the security group reference itself.

## Configure

Edit `.env`: set `SSH_USER`, `SSH_KEY` and the four public IPs.
Leave `OS_PASSWORD=` empty. `deploy.sh` generates a strong password on the first
run and saves it to `.env`, so later runs reuse it. To choose your own, use at
least 8 characters with upper case, lower case, a number and a symbol.

## Run

```bash
chmod +x deploy.sh modules/profile/files/galera_status.sh
./deploy.sh
```

Order is fixed: `os01`, then `galera01` (bootstraps), then `galera02`, `galera03`.
Filebeat waits (up to about 5 minutes) until OpenSearch answers on port 9200.
The first run takes about 10 to 15 minutes. Re-running is safe.

## Web UI (OpenSearch Dashboards)

Open `http://<os01-public-ip>:5601` and log in as `admin` with the `OS_PASSWORD`
from `.env`. Then go to **Dashboards Management > Index patterns**, create
`galera-logs-*` with `@timestamp` as the time field, and browse it in **Discover**.
Port 5601 is plain HTTP: open it to your own IP only.

## Verify

Cluster size, on any Galera node:
```bash
sudo mysql -e "SHOW STATUS LIKE 'wsrep_cluster_size'"   # expect 3
```

Latest status documents (wait about 2 minutes after deploy):
```bash
source .env
curl -sk -u admin:"$OS_PASSWORD" \
  "https://<os01-private-ip>:9200/galera-logs-*/_search?pretty&size=3&sort=@timestamp:desc&q=log_type:galera_status"
```

Is any node down or the cluster smaller than 3 in the last 5 minutes?
```bash
curl -sk -u admin:"$OS_PASSWORD" "https://<os01-private-ip>:9200/galera-logs-*/_search?pretty" \
  -H 'Content-Type: application/json' -d '{
    "size": 10,
    "query": { "bool": {
      "filter": [ { "term": { "log_type": "galera_status" } },
                  { "range": { "@timestamp": { "gte": "now-5m" } } } ],
      "should": [ { "term": { "mariadb_status": "down" } },
                  { "range": { "wsrep_cluster_size": { "lt": 3 } } } ],
      "minimum_should_match": 1 } } }'
```

If a whole VM dies it cannot report anything. Alert on a `host_name` that stops
sending `galera_status` documents for a few minutes.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Could not find node statement` | Node names are matched by prefix in `site.pp` (`os01`, `galera0N`); AWS adds `.ec2.internal`. |
| Deploy seems stuck on a Galera node | Filebeat is waiting for OpenSearch. Test: `curl -sk -m 5 -o /dev/null -w "%{http_code}\n" https://<os01-private-ip>:9200`. `401` = wrong password, `000` = port 9200 blocked. |
| `401` from OpenSearch | OpenSearch only reads the admin password at install time. Keep `OS_PASSWORD` in `.env` constant, or reset `os01` (below). |
| `No SSL configuration found` | `opensearch.yml` was overwritten. The module now edits only the needed lines. Reset `os01` (below). |
| Filebeat exits with status 2 and a register dump | Filebeat 7.12.1 crashes on newer Ubuntu with its syscall filter. The module sets `seccomp.enabled: false`. Then `sudo systemctl reset-failed filebeat && sudo systemctl restart filebeat`. |
| Cannot open the web UI | Dashboards listens on port 5601: add the security group rule for your IP, and check `systemctl status opensearch-dashboards` on `os01`. |
| OpenSearch will not start | Check RAM (4 GB+) and `journalctl -u opensearch`. |
| Galera node will not join | Check `/var/log/mysql/error.log` and ports 4567/4568/4444 between nodes. |

### Reset os01

Removes OpenSearch so the next deploy reinstalls it with the password in `.env`:
```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<os01-public-ip> \
  "sudo systemctl stop opensearch; sudo apt-get purge -y opensearch; sudo rm -rf /etc/opensearch /var/lib/opensearch /usr/share/opensearch"
```

## Notes and security

- `.env` holds the OpenSearch password: keep it out of git (already in `.gitignore`).
- Filebeat uses `ssl.verification_mode: none` because OpenSearch ships a self-signed certificate. Use a real CA for production.
- Filebeat is pinned to the OSS build `7.12.1`, the last version that works with OpenSearch.
- OpenSearch runs as a single node. This is a lab setup, not a highly available log store.
- Galera state transfer uses `rsync`; the `mysql` root account uses unix socket auth for the status script.
