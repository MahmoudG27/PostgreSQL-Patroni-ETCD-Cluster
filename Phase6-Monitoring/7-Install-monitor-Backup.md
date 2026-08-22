# pgBackRest Monitoring with Node Exporter Textfile Collector

This document describes how to monitor `pgBackRest` on the dedicated Backup Server using the existing **Node Exporter** and its **textfile collector**.

No dedicated pgBackRest exporter is required.

## Monitoring Architecture

```text
                         Prometheus
                             │
                             │ :9100
                             ▼
                    ┌──────────────────┐
                    │   Backup Server  │
                    │                  │
                    │  Node Exporter   │
                    │      :9100       │
                    └────────┬─────────┘
                             │
                    textfile collector
                             │
                             ▼
                  pgbackrest.prom
                             ▲
                             │
                  pgBackRest metrics
                             │
                    ┌────────┴─────────┐
                    │                  │
               pgBackRest          Repository
               info --json       /var/lib/pgbackrest
```

The monitoring setup exposes these metrics:

| Metric                                          | Purpose                                          |
| ----------------------------------------------- | ------------------------------------------------ |
| `pgbackrest_backup_success`                     | Whether pgBackRest has a valid latest backup     |
| `pgbackrest_last_backup_timestamp_seconds`      | Timestamp of the latest completed backup         |
| `pgbackrest_backup_age_seconds`                 | Age of the latest backup                         |
| `pgbackrest_stanza_status`                      | Health of the pgBackRest stanza                  |
| `pgbackrest_last_wal_archived_timestamp_seconds` | Modification time of the latest WAL archive file |
| `pgbackrest_repository_size_bytes`              | Current size of the local pgBackRest repository  |

---

# 1. Install jq

On the Backup Server:

```bash
sudo apt update
sudo apt install -y jq
```

`pgBackRest` supports JSON output specifically for machine-readable monitoring, and its documentation provides examples of extracting the last backup timestamp and last archived WAL using `jq`.

---

# 2. Configure Node Exporter Textfile Collector

Create the textfile directory:

```bash
sudo mkdir -p /var/lib/node_exporter/textfile_collector
```

Set ownership:

```bash
sudo chown -R node_exporter:node_exporter \
    /var/lib/node_exporter/textfile_collector
```

The Node Exporter service must contain:

```text
--collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

For example:

```ini
[Service]
User=node_exporter
Group=node_exporter
Type=simple

ExecStart=/usr/local/bin/node_exporter \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector

Restart=on-failure
RestartSec=5s
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart node_exporter
```

Verify:

```bash
sudo systemctl status node_exporter
```

---

# 3. Create the pgBackRest Metrics Script

Create:

```bash
sudo nano /usr/local/bin/pgbackrest_metrics.sh
```

Use:

```bash
#!/bin/bash

set -u

STANZA="pg_cluster_hq"
REPOSITORY="/var/lib/pgbackrest"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
OUTPUT_FILE="${TEXTFILE_DIR}/pgbackrest.prom"
TMP_FILE="${OUTPUT_FILE}.$$"

# ------------------------------------------------------------
# Default values
# ------------------------------------------------------------

BACKUP_SUCCESS=0
STANZA_STATUS=0
LAST_BACKUP_TIMESTAMP=0
LAST_BACKUP_AGE=0
LAST_WAL_ARCHIVE_TIMESTAMP=0
REPOSITORY_SIZE=0

# ------------------------------------------------------------
# Get pgBackRest information
# ------------------------------------------------------------

JSON=$(sudo -u postgres pgbackrest \
    --stanza="${STANZA}" \
    --output=json \
    info 2>/dev/null)

PG_BACKREST_EXIT=$?

# ------------------------------------------------------------
# Parse pgBackRest information
# ------------------------------------------------------------

if [ ${PG_BACKREST_EXIT} -eq 0 ] && [ -n "${JSON}" ]; then

    # Stanza status
    STATUS_CODE=$(echo "${JSON}" | jq -r '.[0].status.code // 1')

    if [ "${STATUS_CODE}" = "0" ]; then
        STANZA_STATUS=1
    else
        STANZA_STATUS=0
    fi

    # Last successful backup timestamp
    LAST_BACKUP_TIMESTAMP=$(echo "${JSON}" | jq -r '
        .[0].backup[-1].timestamp.stop // 0
    ')

    # Make sure the timestamp is numeric
    if ! [[ "${LAST_BACKUP_TIMESTAMP}" =~ ^[0-9]+$ ]]; then
        LAST_BACKUP_TIMESTAMP=0
    fi

    # Backup exists and pgBackRest is healthy
    if [ "${LAST_BACKUP_TIMESTAMP}" -gt 0 ] &&
       [ "${STANZA_STATUS}" -eq 1 ]; then
        BACKUP_SUCCESS=1
    fi

    # Calculate backup age
    if [ "${LAST_BACKUP_TIMESTAMP}" -gt 0 ]; then
        CURRENT_TIME=$(date +%s)
        LAST_BACKUP_AGE=$((CURRENT_TIME - LAST_BACKUP_TIMESTAMP))

        # Prevent negative values in case of clock differences
        if [ "${LAST_BACKUP_AGE}" -lt 0 ]; then
            LAST_BACKUP_AGE=0
        fi
    fi

fi

# ------------------------------------------------------------
# Latest WAL archive (Extracted directly from pgBackRest JSON)
# ------------------------------------------------------------

LAST_WAL_TS=$(echo "${JSON}" | jq -r '
    .[0].archive[0].timestamp.stop // 0
')

if ! [[ "${LAST_WAL_TS}" =~ ^[0-9]+$ ]]; then
    LAST_WAL_TS=0
fi

# ------------------------------------------------------------
# Repository size
# ------------------------------------------------------------

if [ -d "${REPOSITORY}" ]; then

    REPOSITORY_SIZE=$(du -sb \
        "${REPOSITORY}" 2>/dev/null \
        | awk '{print $1}')

    if [ -z "${REPOSITORY_SIZE}" ]; then
        REPOSITORY_SIZE=0
    fi

fi

# ------------------------------------------------------------
# Write Prometheus metrics
# ------------------------------------------------------------

cat > "${TMP_FILE}" <<EOF
# HELP pgbackrest_backup_success Whether the latest pgBackRest backup is valid and the stanza is healthy. 1=success, 0=failure.
# TYPE pgbackrest_backup_success gauge
pgbackrest_backup_success{stanza="${STANZA}"} ${BACKUP_SUCCESS}

# HELP pgbackrest_last_backup_timestamp_seconds Unix timestamp of the latest completed pgBackRest backup.
# TYPE pgbackrest_last_backup_timestamp_seconds gauge
pgbackrest_last_backup_timestamp_seconds{stanza="${STANZA}"} ${LAST_BACKUP_TIMESTAMP}

# HELP pgbackrest_backup_age_seconds Age of the latest completed pgBackRest backup in seconds.
# TYPE pgbackrest_backup_age_seconds gauge
pgbackrest_backup_age_seconds{stanza="${STANZA}"} ${LAST_BACKUP_AGE}

# HELP pgbackrest_stanza_status pgBackRest stanza health status. 1=healthy, 0=unhealthy.
# TYPE pgbackrest_stanza_status gauge
pgbackrest_stanza_status{stanza="${STANZA}"} ${STANZA_STATUS}

# HELP pgbackrest_last_wal_archived_timestamp_seconds Filesystem modification timestamp of the latest WAL archive file.
# TYPE pgbackrest_last_wal_archived_timestamp_seconds gauge
pgbackrest_last_wal_archived_timestamp_seconds{stanza="${STANZA}"} ${LAST_WAL_ARCHIVE_TIMESTAMP}

# HELP pgbackrest_repository_size_bytes Size of the local pgBackRest repository in bytes.
# TYPE pgbackrest_repository_size_bytes gauge
pgbackrest_repository_size_bytes{stanza="${STANZA}"} ${REPOSITORY_SIZE}
EOF

# ------------------------------------------------------------
# Atomic replacement
# ------------------------------------------------------------

chown node_exporter:node_exporter "${TMP_FILE}"

mv "${TMP_FILE}" "${OUTPUT_FILE}"
```

Make it executable:

```bash
sudo chmod +x /usr/local/bin/pgbackrest_metrics.sh
```

---

# 4. Test the Script Manually

Run:

```bash
sudo /usr/local/bin/pgbackrest_metrics.sh
```

Check the generated file:

```bash
cat /var/lib/node_exporter/textfile_collector/pgbackrest.prom
```

Expected output:

```text
# HELP pgbackrest_backup_success Whether the latest pgBackRest backup is valid and the stanza is healthy. 1=success, 0=failure.
# TYPE pgbackrest_backup_success gauge
pgbackrest_backup_success{stanza="pg_cluster_hq"} 1

# HELP pgbackrest_last_backup_timestamp_seconds Unix timestamp of the latest completed pgBackRest backup.
# TYPE pgbackrest_last_backup_timestamp_seconds gauge
pgbackrest_last_backup_timestamp_seconds{stanza="pg_cluster_hq"} 1784508644

# HELP pgbackrest_backup_age_seconds Age of the latest completed pgBackRest backup in seconds.
# TYPE pgbackrest_backup_age_seconds gauge
pgbackrest_backup_age_seconds{stanza="pg_cluster_hq"} 123456

# HELP pgbackrest_stanza_status pgBackRest stanza health status. 1=healthy, 0=unhealthy.
# TYPE pgbackrest_stanza_status gauge
pgbackrest_stanza_status{stanza="pg_cluster_hq"} 1

# HELP pgbackrest_last_wal_archived_timestamp_seconds Filesystem modification timestamp of the latest WAL archive file.
# TYPE pgbackrest_last_wal_archived_timestamp_seconds gauge
pgbackrest_last_wal_archived_timestamp_seconds{stanza="pg_cluster_hq"} 1784509000

# HELP pgbackrest_repository_size_bytes Size of the local pgBackRest repository in bytes.
# TYPE pgbackrest_repository_size_bytes gauge
pgbackrest_repository_size_bytes{stanza="pg_cluster_hq"} 5368709120
```

---

# 5. Verify Node Exporter

Run:

```bash
curl http://localhost:9100/metrics | grep pgbackrest
```

You should see:

```text
pgbackrest_backup_success
pgbackrest_last_backup_timestamp_seconds
pgbackrest_backup_age_seconds
pgbackrest_stanza_status
pgbackrest_last_wal_archived_timestamp_seconds
pgbackrest_repository_size_bytes
```

At this point Prometheus does not need a separate pgBackRest scrape job.

It simply scrapes:

```text
Backup Server :9100
```

---

# 6. Run the Script Automatically

Create the systemd service:

```bash
sudo nano /etc/systemd/system/pgbackrest-metrics.service
```

```ini
[Unit]
Description=Generate pgBackRest Prometheus Metrics
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pgbackrest_metrics.sh
```

Create the timer:

```bash
sudo nano /etc/systemd/system/pgbackrest-metrics.timer
```

```ini
[Unit]
Description=Update pgBackRest Prometheus Metrics

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

Enable it:

```bash
sudo systemctl daemon-reload

sudo systemctl enable --now pgbackrest-metrics.timer
```

Check:

```bash
systemctl status pgbackrest-metrics.timer
```

And:

```bash
systemctl list-timers | grep pgbackrest
```

The metrics file will now be refreshed every **5 minutes**.

---

# 7. Prometheus Configuration

You do not need a separate pgBackRest exporter job.

The Backup Server is already monitored through Node Exporter:

```yaml
scrape_configs:

  - job_name: "node_exporter"
    static_configs:
      - targets:
          - "10.0.0.30:9100"
```

The pgBackRest metrics will automatically appear under this target.

Validate:

```bash
promtool check config /etc/prometheus/prometheus.yml
```

Then reload Prometheus:

```bash
curl -X POST http://localhost:9090/-/reload
```

---

# 8. Prometheus Queries

## Backup Success

```promql
pgbackrest_backup_success{stanza="pg_cluster_hq"}
```

Expected:

```text
1 = OK
0 = Problem
```

---

## Stanza Status

```promql
pgbackrest_stanza_status{stanza="pg_cluster_hq"}
```

Expected:

```text
1 = Healthy
0 = Unhealthy
```

pgBackRest documents `status: ok` as the normal healthy state; other states such as `mixed` or `other` indicate problems.

---

## Last Backup Time

```promql
pgbackrest_last_backup_timestamp_seconds{stanza="pg_cluster_hq"}
```

In Grafana, use a Date & Time visualization.

---

## Backup Age

```promql
pgbackrest_backup_age_seconds{stanza="pg_cluster_hq"}
```

Convert to hours:

```promql
pgbackrest_backup_age_seconds{stanza="pg_cluster_hq"} / 3600
```

---

## Repository Size

```promql
pgbackrest_repository_size_bytes{stanza="pg_cluster_hq"}
```

Convert to GB:

```promql
pgbackrest_repository_size_bytes{stanza="pg_cluster_hq"} / 1024 / 1024 / 1024
```

---

# 9. Alert Rules

Create or add to your Prometheus alert rules:

```yaml
groups:

  - name: pgbackrest
    rules:

      # ------------------------------------------------------
      # pgBackRest backup failed
      # ------------------------------------------------------

      - alert: PgBackRestBackupFailed
        expr: |
          pgbackrest_backup_success{stanza="pg_cluster_hq"} == 0
        for: 10m

        labels:
          severity: critical

        annotations:
          summary: "pgBackRest backup failed"
          description: "The latest pgBackRest backup for stanza pg_cluster_hq is not healthy."


      # ------------------------------------------------------
      # pgBackRest stanza unhealthy
      # ------------------------------------------------------

      - alert: PgBackRestStanzaUnhealthy
        expr: |
          pgbackrest_stanza_status{stanza="pg_cluster_hq"} == 0
        for: 10m

        labels:
          severity: critical

        annotations:
          summary: "pgBackRest stanza is unhealthy"
          description: "pgBackRest stanza pg_cluster_hq is reporting an unhealthy status."


      # ------------------------------------------------------
      # Backup is too old
      #
      # Your full backup is scheduled every Sunday.
      # 8 days gives you one day of tolerance.
      # ------------------------------------------------------

      - alert: PgBackRestBackupTooOld
        expr: |
          pgbackrest_backup_age_seconds{stanza="pg_cluster_hq"} > 8 * 24 * 3600
        for: 30m

        labels:
          severity: critical

        annotations:
          summary: "pgBackRest backup is too old"
          description: "The latest pgBackRest backup is older than 8 days."


      # ------------------------------------------------------
      # WAL archive is stale
      #
      # Alert if no new WAL archive has appeared for 30 minutes.
      # Adjust this value according to your workload.
      # ------------------------------------------------------

      - alert: PgBackRestWalArchiveStale
        expr: |
          time() - pgbackrest_last_wal_archived_timestamp_seconds{stanza="pg_cluster_hq"} > 30 * 60
        for: 15m

        labels:
          severity: critical

        annotations:
          summary: "pgBackRest WAL archive is stale"
          description: "No new WAL archive file has been detected in the pgBackRest repository for more than 30 minutes."


      # ------------------------------------------------------
      # Backup repository disk usage
      #
      # This alert requires node_exporter filesystem metrics.
      # Example threshold: 85%
      # ------------------------------------------------------

      - alert: PgBackRestRepositoryDiskAlmostFull
        expr: |
          (
            pgbackrest_repository_size_bytes{stanza="pg_cluster_hq"}
            /
            (
              node_filesystem_size_bytes{
                mountpoint="/var/lib/pgbackrest"
              }
            )
          ) > 0.85
        for: 15m

        labels:
          severity: warning

        annotations:
          summary: "pgBackRest repository disk usage is high"
          description: "The pgBackRest repository is using more than 85% of its filesystem capacity."
```

---

# 10. Important: Repository Disk Alert

If `/var/lib/pgbackrest` is **not a separate filesystem/mount**, the previous filesystem expression should be adjusted.

A more reliable setup is to monitor the filesystem that contains the repository using Node Exporter's filesystem metrics.

For example, if the repository is on `/`:

```promql
(
  node_filesystem_avail_bytes{mountpoint="/"}
  /
  node_filesystem_size_bytes{mountpoint="/"}
) < 0.15
```

This means less than 15% free space.

Recommended alert:

```yaml
- alert: BackupServerDiskAlmostFull
  expr: |
    (
      node_filesystem_avail_bytes{mountpoint="/"}
      /
      node_filesystem_size_bytes{mountpoint="/"}
    ) < 0.15
  for: 15m

  labels:
    severity: warning

  annotations:
    summary: "Backup Server disk space is low"
    description: "The Backup Server filesystem has less than 15% free space remaining."
```

---

# 11. Recommended Production Alerts

For your environment, I would keep these alerts:

```text
┌───────────────────────────────────────────────┐
│              pgBackRest Alerts                │
├───────────────────────────────────────────────┤
│                                               │
│ 🔴 PgBackRestBackupFailed                     │
│    Latest backup is not healthy               │
│                                               │
│ 🔴 PgBackRestStanzaUnhealthy                  │
│    Stanza is unhealthy                        │
│                                               │
│ 🔴 PgBackRestBackupTooOld                     │
│    No valid backup for > 8 days               │
│                                               │
│ 🔴 PgBackRestWalArchiveStale                  │
│    WAL archive stopped for > 30 minutes       │
│                                               │
│ 🟡 BackupServerDiskAlmostFull                 │
│    Less than 15% filesystem space             │
│                                               │
└───────────────────────────────────────────────┘
```

---

# 12. Final Monitoring Architecture

Your complete monitoring architecture becomes:

```text
                         ┌──────────────┐
                         │  Prometheus  │
                         │    :9090     │
                         └──────┬───────┘
                                │
       ┌────────────────────────┼────────────────────────┐
       │                        │                        │
       ▼                        ▼                        ▼
 PostgreSQL Nodes           HAProxy Nodes          Backup Server
       │                        │                        │
       │                        │                        │
 ┌─────┴────────┐         ┌─────┴─────────┐       ┌──────┴──────┐
 │ Node Exporter│         │ Node Exporter │       │Node Exporter│
 │    :9100     │         │    :9100      │       │    :9100    │
 └──────────────┘         └───────────────┘       └──────┬───────┘
       │                        │                         │
 ┌─────┴─────────┐       ┌──────┴───────┐               │
 │ PostgreSQL    │       │ HAProxy      │               │
 │ Exporter      │       │ Exporter     │               │
 │    :9187      │       │    :9101     │               │
 └───────────────┘       └──────────────┘               │
       │                        │                        │
 ┌─────┴──────┐          HAProxy :8404             pgBackRest
 │  Patroni   │                                         │
 │  :8008     │                                  textfile collector
 └────────────┘                                         │
       │                                                │
 ┌─────┴──────┐                                         │
 │    etcd    │                                         │
 │  :2379     │                                         │
 └────────────┘                                         │
                                                        │
                                              pgbackrest.prom
```

The important point is that **pgBackRest is not another network exporter** in this design. The script converts its local state into Prometheus metrics, and Node Exporter exposes those metrics through the existing `:9100` endpoint.

## Metric Summary

```text
pgbackrest_backup_success
pgbackrest_last_backup_timestamp_seconds
pgbackrest_backup_age_seconds
pgbackrest_stanza_status
pgbackrest_last_wal_archived_timestamp_seconds
pgbackrest_repository_size_bytes
```

This keeps the monitoring surface small and avoids creating unnecessary high-cardinality metrics.