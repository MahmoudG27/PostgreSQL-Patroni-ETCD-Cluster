# On the proposal, we mentioned that one of the required dashboards is "Backup job status (success/failure, last successful backup timestamp)".
# The problem is that there is no official exporter for pgBackRest like the others.

# Common solution: node_exporter + Textfile Collector

# node_exporter has a feature called Textfile Collector - it allows you to write any information as a simple text file, and node_exporter will read it and convert it into metrics automatically. So:

sudo mkdir -p /var/lib/node_exporter/textfile_collector
sudo chown -R node_exporter:node_exporter /var/lib/node_exporter/textfile_collector

# The systemd service file for node_exporter should be updated to include the --collector.textfile.directory flag, pointing to the directory where the text files will be stored. This allows node_exporter to read the metrics from the specified directory and expose them to Prometheus.
sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# 3. Enable and start the Node Exporter service
sudo systemctl daemon-reload
sudo systemctl restart node_exporter

# 4. Try pgBackRest JSON on Backup Server:
sudo -u postgres pgbackrest --stanza=pg_cluster_hq --output=json info # Should return JSON and that better than normal output because pgBackRest recommands use --output=json for machine-readable output.

# 5. Create Script for metrics
sudo vim /usr/local/bin/pgbackrest_metrics.sh
# And Insert:
#!/bin/bash

set -e

STANZA="pg_cluster_hq"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
OUTPUT_FILE="${TEXTFILE_DIR}/pgbackrest.prom"
TMP_FILE="${OUTPUT_FILE}.$$"

JSON=$(sudo -u postgres pgbackrest \
    --stanza="${STANZA}" \
    --output=json \
    info)

STATUS=$(echo "$JSON" | jq -r '.[0].status // "unknown"')

if [ "$STATUS" = "ok" ]; then
    STANZA_STATUS=1
else
    STANZA_STATUS=0
fi

LAST_BACKUP=$(echo "$JSON" | jq -r '
    .[0].backup[-1].timestamp.stop // 0
')

LAST_WAL=$(echo "$JSON" | jq -r '
    .[0].archive[-1].max // ""
')

BACKUP_COUNT=$(echo "$JSON" | jq '
    [.[0].backup[]?] | length
')

cat > "$TMP_FILE" <<EOF
# HELP pgbackrest_stanza_status pgBackRest stanza health status. 1=healthy, 0=unhealthy.
# TYPE pgbackrest_stanza_status gauge
pgbackrest_stanza_status{stanza="${STANZA}"} ${STANZA_STATUS}

# HELP pgbackrest_last_backup_timestamp_seconds Unix timestamp of the last completed backup.
# TYPE pgbackrest_last_backup_timestamp_seconds gauge
pgbackrest_last_backup_timestamp_seconds{stanza="${STANZA}"} ${LAST_BACKUP}

# HELP pgbackrest_backup_count Number of backups reported by pgBackRest.
# TYPE pgbackrest_backup_count gauge
pgbackrest_backup_count{stanza="${STANZA}"} ${BACKUP_COUNT}

# HELP pgbackrest_last_archived_wal Last archived WAL segment.
# TYPE pgbackrest_last_archived_wal gauge
pgbackrest_last_archived_wal{stanza="${STANZA}",wal="${LAST_WAL}"} 1
EOF

chown node_exporter:node_exporter "$TMP_FILE"

mv "$TMP_FILE" "$OUTPUT_FILE"


# Chanege permissions:
sudo chmod +x /usr/local/bin/pgbackrest_metrics.sh

# 6. Run the script manually and make sure pgbackrest.prom file created
sudo /usr/local/bin/pgbackrest_metrics.sh
cat /var/lib/node_exporter/textfile_collector/pgbackrest.prom

# 7. Make sure Node Exporter see it
curl http://localhost:9100/metrics | grep pgbackrest

# You should see something like that: 
pgbackrest_stanza_status
pgbackrest_last_backup_timestamp_seconds
pgbackrest_backup_count
pgbackrest_last_archived_wal


# 8. Run the script automatically:
# We prefer use systemd timer instead cron here because it is monitoring job.
# Create systemd timer service:

sudo tee /etc/systemd/system/pgbackrest-metrics.service > /dev/null <<EOF
[Unit]
Description=Generate pgBackRest Prometheus metrics
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pgbackrest_metrics.sh
EOF

# Then
sudo tee /etc/systemd/system/pgbackrest-metrics.timer > /dev/null <<EOF
[Unit]
Description=Update pgBackRest Prometheus metrics

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF


sudo systemctl daemon-reload
sudo systemctl enable --now pgbackrest-metrics.timer
systemctl status pgbackrest-metrics.timer

# Show the next run, the script runs every 5 minutes:
systemctl list-timers | grep pgbackrest