# Grafana Loki & Promtail — Centralized Log Aggregation

This document describes how to install and configure **Loki** as the central log
store, and **Promtail** as the log shipper running on every node.

Loki runs on the same Monitoring Server as Prometheus and Grafana:

```text
http://10.0.0.20:3100
```

It closes the Scope of Work requirement that metrics alone do not satisfy:

```text
"Implement health monitoring, alerting, dashboards, and log visibility."
```

and it is the destination for the pgAudit trail produced in
`Phase7-Security/3-Audit-Logging-pgAudit.md`.

---

# 1. Why Loki and Not Something Else

Prometheus already answers *"is the database slow?"*. It cannot answer
*"who dropped that table at 02:14?"* — that lives in the logs.

```text
* Loki indexes only labels, not the log body. Storage cost is close to raw
  compressed files, unlike Elasticsearch which indexes every token.

* It reuses the Grafana already deployed. No new UI, no new login, and log
  panels sit next to the metric panels on the same dashboard.

* It reuses the Alertmanager already deployed, so a log-based alert and a
  metric-based alert follow the same routing and escalation.

* LogQL deliberately looks like PromQL, so the team learns one query language.
```

The trade-off is that Loki is weak at full-text search across huge time ranges.
That is acceptable here: audit queries are almost always scoped to a node, a
database and a time window.

---

# 2. Architecture

```text
                        Monitoring Server
                        10.0.0.20
                        ┌──────────────────────────────┐
                        │  Grafana      :3000          │
                        │  Prometheus   :9090          │
                        │  Alertmanager :9093          │
                        │  Loki         :3100   ◄──────┼─── push
                        └──────────────────────────────┘
                                     ▲
                                     │  HTTP push (:3100/loki/api/v1/push)
             ┌───────────────┬───────┴───────┬───────────────┐
             │               │               │               │
        Promtail        Promtail        Promtail        Promtail
        PG nodes        HAProxy         Backup Srv      DR nodes
        10.0.0.4-6      10.0.0.100      10.0.0.30       10.1.0.4-6

     PostgreSQL log        HAProxy log     pgBackRest log
     pgAudit entries       journald        journald
     Patroni  (journald)
     etcd     (journald)
```

Promtail **pushes** to Loki. This is the opposite of Prometheus, which pulls.
The practical consequence: Loki must be reachable *from* every node, and a node
that cannot reach Loki buffers locally and retries rather than losing lines.

---

# 3. One Loki, or One per Site?

The same decision already made for Prometheus applies here.

| | One Loki (HQ) | One per site |
|---|---|---|
| Cost | One VM | Two VMs |
| Cross-site queries | One place for everything | Two datasources in Grafana |
| If HQ site is lost | **DR logs are also lost** | DR keeps its own logs |
| Cross-site traffic | DR logs cross the WAN continuously | None |

This document installs **one Loki on the HQ Monitoring Server**, matching the
existing `prometheus.yml` which already scrapes both sites from one place.

> **Raise this with the client.** During a DR activation — exactly when logs
> matter most — a single HQ Loki is unavailable. If they want log visibility
> during a site loss, budget the second monitoring VM.

---

# 4. Create the Loki User and Directories

On the Monitoring Server (`10.0.0.20`):

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin loki

sudo mkdir -p /etc/loki
sudo mkdir -p /var/lib/loki/{chunks,rules,rules-temp,tsdb-index,tsdb-cache,compactor}

sudo chown -R loki:loki /var/lib/loki
sudo chmod 750 /var/lib/loki
```

---

# 5. Install the Loki Binary

Pick the release version. Do not hard-code an old one — read the current release
tag from GitHub:

```bash
sudo apt install -y unzip curl jq

LOKI_VERSION=$(curl -s https://api.github.com/repos/grafana/loki/releases/latest \
  | jq -r .tag_name | sed 's/^v//')

echo "Installing Loki ${LOKI_VERSION}"
```

Download and install:

```bash
cd /tmp

curl -fLO "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"

unzip -o loki-linux-amd64.zip
sudo mv loki-linux-amd64 /usr/local/bin/loki
sudo chown root:root /usr/local/bin/loki
sudo chmod 755 /usr/local/bin/loki
```

Verify:

```bash
loki --version
```

---

# 6. Loki Configuration

Create `/etc/loki/loki-config.yml`:

```bash
sudo tee /etc/loki/loki-config.yml > /dev/null <<'EOF'
# ---------------------------------------------------------------
# Single-binary Loki with filesystem storage.
# Sized for a 10-node PostgreSQL platform, not for multi-tenant SaaS.
# ---------------------------------------------------------------

auth_enabled: false          # single tenant; the network restricts access

server:
  http_listen_address: 0.0.0.0
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-04-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /var/lib/loki/tsdb-index
    cache_location: /var/lib/loki/tsdb-cache
  filesystem:
    directory: /var/lib/loki/chunks

limits_config:
  # Retention. Change this to whatever the client confirms in writing —
  # audit log retention is a compliance decision, not a technical one.
  retention_period: 90d

  # Reject logs older than a week. Protects against a misconfigured clock
  # flooding the store with backdated entries.
  reject_old_samples: true
  reject_old_samples_max_age: 168h

  ingestion_rate_mb: 16
  ingestion_burst_size_mb: 32
  max_query_series: 5000
  max_query_parallelism: 16

  # Enables the log-volume panel in Grafana Explore
  volume_enabled: true

compactor:
  working_directory: /var/lib/loki/compactor
  delete_request_store: filesystem
  # retention_period above is only enforced when this is true
  retention_enabled: true
  retention_delete_delay: 2h
  compaction_interval: 10m

ruler:
  storage:
    type: local
    local:
      directory: /var/lib/loki/rules
  rule_path: /var/lib/loki/rules-temp
  alertmanager_url: http://localhost:9093
  enable_api: true
  enable_alertmanager_v2: true

analytics:
  reporting_enabled: false
EOF

sudo chown -R loki:loki /etc/loki
sudo chmod 640 /etc/loki/loki-config.yml
```

> **`retention_enabled: true` in the compactor is the switch that actually
> deletes data.** Setting `retention_period` alone does nothing — the logs grow
> forever and the disk fills. This is the single most common Loki
> misconfiguration.

---

# 7. Loki systemd Service

```bash
sudo tee /etc/systemd/system/loki.service > /dev/null <<'EOF'
[Unit]
Description=Grafana Loki log aggregation
Documentation=https://grafana.com/docs/loki/
After=network-online.target
Wants=network-online.target

[Service]
User=loki
Group=loki
Type=simple
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki-config.yml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

# Hardening
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/loki

[Install]
WantedBy=multi-user.target
EOF
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now loki
sudo systemctl status loki
```

---

# 8. Verify Loki Is Running

```bash
curl -s http://localhost:3100/ready
```

Expect:

```text
ready
```

`ready` can take 15–30 seconds after start while the ingester joins the ring.
Until then it returns `Ingester not ready`.

Check the metrics endpoint — Prometheus will scrape this later:

```bash
curl -s http://localhost:3100/metrics | head
```

Check the logs if anything is wrong:

```bash
sudo journalctl -u loki -f
```

---

# 9. Firewall

Every node pushes to `3100` on the Monitoring Server. Only the platform nodes
need that access — not the whole network.

On the Monitoring Server:

```bash
sudo ufw allow from 10.0.0.0/24 to any port 3100 proto tcp comment 'Loki push HQ'
sudo ufw allow from 10.1.0.0/24 to any port 3100 proto tcp comment 'Loki push DR'
```

Verify from a database node:

```bash
curl -s http://10.0.0.20:3100/ready
```

---

# 10. Let Prometheus Monitor Loki

Loki is now part of the platform, so it needs to be watched like everything else.
Add to `Phase6-Monitoring/prometheus/prometheus.yml`:

```yaml
  - job_name: "loki"
    static_configs:
      - targets: ["10.0.0.20:3100"]
        labels:
          site: "hq"
```

Reload Prometheus:

```bash
sudo systemctl reload prometheus
```

Useful metrics once it is scraped:

```text
loki_ingester_streams_created_total       stream count — watch for cardinality blowups
loki_distributor_bytes_received_total     ingest volume, for sizing
loki_request_duration_seconds             query and push latency
loki_ingester_chunks_flushed_total        flush activity
```

---

# 11. Add Loki as a Grafana Datasource

In Grafana (`http://10.0.0.20:3000`):

```text
Connections → Data sources → Add new data source → Loki

Name : Loki
URL  : http://localhost:3100

Save & test
```

Or provision it as a file so it survives a rebuild:

```bash
sudo tee /etc/grafana/provisioning/datasources/loki.yml > /dev/null <<'EOF'
apiVersion: 1

datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://localhost:3100
    isDefault: false
    jsonData:
      maxLines: 1000
      # Jump straight from a log line to the metrics for the same node
      derivedFields:
        - name: instance
          matcherRegex: 'instance="([^"]+)"'
          datasourceUid: prometheus
          url: '$${__value.raw}'
EOF

sudo systemctl restart grafana-server
```

---

# 12. Prepare PostgreSQL Logs for Loki

**Do this before installing Promtail.** It decides how hard the parsing will be.

`Phase7-Security/3-Audit-Logging-pgAudit.md` configures `log_destination = 'csvlog'`.
CSV is fine for humans and for loading into a table, but it is awkward for
Promtail — Promtail has no CSV parser, and CSV entries can span multiple lines
when a statement contains a newline.

PostgreSQL 15 and later can emit **JSON logs**, which Promtail parses natively
with a single stage, and which never span lines. PostgreSQL 18 supports it.

Via `patronictl edit-config`:

```yaml
postgresql:
  parameters:
    logging_collector: 'on'
    log_destination: 'csvlog,jsonlog'
    log_directory: '/var/log/postgresql'
    log_filename: 'postgresql-%Y-%m-%d_%H%M%S.log'
    log_file_mode: '0640'
    log_rotation_age: '1d'
    log_rotation_size: '100MB'
```

Two changes from the pgAudit document:

```text
log_destination  csvlog  →  csvlog,jsonlog
                 PostgreSQL writes both. Keep CSV for offline analysis and
                 for anything the client's auditors already expect; ship JSON
                 to Loki.

log_file_mode    0600    →  0640
                 So the promtail user can read the file through the postgres
                 group. See section 15 — without this, Promtail silently
                 collects nothing.
```

`log_destination` is reloadable; `logging_collector` and `log_file_mode` need a
restart if they were not already set.

Confirm both files appear:

```bash
ls -l /var/log/postgresql/
```

```text
postgresql-2026-08-24_000000.csv
postgresql-2026-08-24_000000.json
postgresql-2026-08-24_000000.log
```

---

# 13. Create the Promtail User

On **every** node — PostgreSQL nodes, HAProxy, Backup Servers, both sites:

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin promtail

sudo mkdir -p /etc/promtail /var/lib/promtail
sudo chown -R promtail:promtail /var/lib/promtail
```

Promtail must be able to read logs it does not own. Add it to the right groups
rather than running it as root:

```bash
# systemd journal — for Patroni, etcd and system units
sudo usermod -aG systemd-journal promtail

# /var/log files owned by root:adm — syslog, HAProxy
sudo usermod -aG adm promtail

# PostgreSQL logs (database nodes only)
sudo usermod -aG postgres promtail
```

> **Never run Promtail as root.** It reads files an attacker may partly control.
> Group membership plus `0640` log files is enough.

---

# 14. Install the Promtail Binary

Use the **same version as Loki**:

```bash
LOKI_VERSION=$(curl -s https://api.github.com/repos/grafana/loki/releases/latest \
  | jq -r .tag_name | sed 's/^v//')

cd /tmp

curl -fLO "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/promtail-linux-amd64.zip"

unzip -o promtail-linux-amd64.zip
sudo mv promtail-linux-amd64 /usr/local/bin/promtail
sudo chown root:root /usr/local/bin/promtail
sudo chmod 755 /usr/local/bin/promtail

promtail --version
```

Check whether this build can read the systemd journal:

```bash
promtail --help 2>&1 | grep -i journal
```

> **If journal support is missing**, the released binary was built without it.
> Two options: install Promtail from Grafana's APT repository (that package is
> built with journal support), or drop the `journal` scrape blocks in section 17
> and read `/var/log/syslog` instead. Section 21 covers the symptom.

---

# 15. Fix the Log File Permissions

This is the step that silently breaks everything if skipped.

`Phase7-Security/3-Audit-Logging-pgAudit.md` sets the log directory to `700` so
that only `postgres` can read it. Promtail then cannot read a single line, and
it fails **quietly** — the service runs, reports healthy, and ships nothing.

On the database nodes:

```bash
# Directory: group can traverse and list
sudo chown -R postgres:postgres /var/log/postgresql
sudo chmod 750 /var/log/postgresql

# Files: group can read (log_file_mode = '0640' in section 12 handles new files)
sudo chmod 640 /var/log/postgresql/*
```

Update the logrotate rule from the pgAudit document so rotated files keep the
same mode:

```bash
sudo sed -i 's/create 0600 postgres postgres/create 0640 postgres postgres/' \
  /etc/logrotate.d/postgresql-audit
```

Verify Promtail can actually read as its own user:

```bash
sudo -u promtail head -c 200 /var/log/postgresql/postgresql-*.json
```

> **This weakens nothing that matters.** The audit-trail requirement is that a
> DBA cannot *delete or alter* the log. `0640` grants read only, and the whole
> point of shipping to Loki is that a second, independent copy exists that the
> database administrators cannot write to at all.

---

# 16. Promtail Configuration — PostgreSQL Nodes

This is the important one: it carries the pgAudit trail.

Create `/etc/promtail/promtail-config.yml`. Change `site`, `node` and the Loki
address per node.

```bash
sudo tee /etc/promtail/promtail-config.yml > /dev/null <<'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: info

positions:
  # Remembers how far into each file Promtail has read, so a restart
  # does not re-ship everything.
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://10.0.0.20:3100/loki/api/v1/push
    # Buffer and retry rather than dropping lines when Loki is unreachable
    backoff_config:
      min_period: 500ms
      max_period: 5m
      max_retries: 20
    batchwait: 1s
    batchsize: 1048576

scrape_configs:

  # ===============================================================
  # PostgreSQL — JSON log, which carries the pgAudit entries
  # ===============================================================
  - job_name: postgresql
    static_configs:
      - targets: [localhost]
        labels:
          job: postgresql
          site: hq                      # ← dr on the DR nodes
          node: hq-node-01              # ← per node
          instance: 10.0.0.4:5432       # ← matches the Prometheus instance label
          __path__: /var/log/postgresql/*.json

    pipeline_stages:

      # ---- 1. Parse the PostgreSQL JSON log entry ----
      - json:
          expressions:
            timestamp:        timestamp
            db_user:          user
            dbname:           dbname
            pid:              pid
            remote_host:      remote_host
            error_severity:   error_severity
            state_code:       state_code
            message:          message
            application_name: application_name
            backend_type:     backend_type
            session_id:       session_id

      # ---- 2. Use PostgreSQL's own timestamp, not the read time ----
      - timestamp:
          source: timestamp
          format: "2006-01-02 15:04:05.000 MST"

      # ---- 3. Low-cardinality labels only. See section 20. ----
      - labels:
          error_severity:
          dbname:

      # ---- 4. High-cardinality fields as structured metadata ----
      # Queryable and displayed, but NOT part of the stream index.
      - structured_metadata:
          db_user:
          remote_host:
          application_name:
          session_id:
          pid:

      # ---- 5. Extract the pgAudit fields out of the message ----
      # pgAudit writes:
      #   AUDIT: <type>,<stmt_id>,<sub_id>,<class>,<command>,<obj_type>,<obj_name>,<statement>,<params>
      # Lines that are not audit entries simply do not match and pass through.
      - regex:
          source: message
          expression: '^AUDIT: (?P<audit_type>[A-Z]+),(?P<audit_stmt_id>\d+),(?P<audit_sub_id>\d+),(?P<audit_class>[A-Z]+),(?P<audit_command>[^,]*),(?P<audit_object_type>[^,]*),(?P<audit_object_name>[^,]*),'

      # audit_class is a closed set: READ / WRITE / FUNCTION / ROLE / DDL / MISC
      # audit_type is SESSION or OBJECT. Both are safe as labels.
      - labels:
          audit_type:
          audit_class:

      # The command and object name are far too varied to index
      - structured_metadata:
          audit_command:
          audit_object_type:
          audit_object_name:

      # ---- 6. Ship the human-readable message as the log line ----
      - output:
          source: message

  # ===============================================================
  # Patroni and etcd — systemd journal
  # ===============================================================
  - job_name: journal
    journal:
      path: /var/log/journal
      max_age: 12h
      json: false
      labels:
        job: systemd-journal
        site: hq
        node: hq-node-01
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
      - source_labels: ['__journal_priority_keyword']
        target_label: priority
    pipeline_stages:
      # Keep only the units that matter — journald carries a lot of noise
      - match:
          selector: '{unit!~"patroni.service|etcd.service|postgresql.*|pgbackrest.*|sshd.service|haproxy.service"}'
          action: drop
EOF
```

Set ownership:

```bash
sudo chown -R promtail:promtail /etc/promtail
sudo chmod 640 /etc/promtail/promtail-config.yml
```

---

# 17. Promtail Configuration — Other Node Types

Same file, different `scrape_configs`. Keep `site`, `node` and `instance`
consistent with the Prometheus labels so dashboards can pivot between the two.

## HAProxy nodes (10.0.0.100 / 10.1.0.100)

```yaml
  - job_name: haproxy
    static_configs:
      - targets: [localhost]
        labels:
          job: haproxy
          site: hq
          node: hq-haproxy
          instance: 10.0.0.100:9101
          __path__: /var/log/haproxy.log

    pipeline_stages:
      # HAProxy TCP log line:
      # client_ip:port [date] frontend backend/server times bytes flags conns
      - regex:
          expression: '^(?P<syslog_ts>\w+\s+\d+\s+[\d:]+) (?P<host>\S+) haproxy\[(?P<pid>\d+)\]: (?P<client>\S+) \[(?P<accept_date>[^\]]+)\] (?P<frontend>\S+) (?P<backend>[^/]+)/(?P<server>\S+)'
      - labels:
          frontend:
          backend:
      - structured_metadata:
          server:
          client:
```

## Backup Servers (10.0.0.30 / 10.1.0.30)

```yaml
  - job_name: pgbackrest
    static_configs:
      - targets: [localhost]
        labels:
          job: pgbackrest
          site: hq
          node: hq-backup
          instance: 10.0.0.30:9100
          __path__: /var/log/pgbackrest/*.log

    pipeline_stages:
      # 2026-08-24 02:00:01.123 P00   INFO: backup command begin
      - regex:
          expression: '^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) P\d+\s+(?P<level>\w+):'
      - timestamp:
          source: ts
          format: "2006-01-02 15:04:05.000"
      - labels:
          level:
```

## Monitoring Server itself

```yaml
  - job_name: monitoring-stack
    journal:
      path: /var/log/journal
      max_age: 12h
      labels:
        job: systemd-journal
        site: hq
        node: hq-monitoring
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
    pipeline_stages:
      - match:
          selector: '{unit!~"prometheus.service|grafana-server.service|alertmanager.service|loki.service"}'
          action: drop
```

---

# 18. Promtail systemd Service

Identical on every node:

```bash
sudo tee /etc/systemd/system/promtail.service > /dev/null <<'EOF'
[Unit]
Description=Promtail log shipper for Loki
Documentation=https://grafana.com/docs/loki/latest/send-data/promtail/
After=network-online.target
Wants=network-online.target

[Service]
User=promtail
Group=promtail
# Needed so the systemd-journal and postgres group memberships apply
SupplementaryGroups=systemd-journal adm postgres
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail-config.yml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/promtail

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now promtail
sudo systemctl status promtail
```

> On the HAProxy, Backup and Monitoring servers there is no `postgres` group.
> Remove it from `SupplementaryGroups=` there, or systemd refuses to start the
> unit.

Verify Promtail's own health endpoint:

```bash
curl -s http://localhost:9080/ready
curl -s http://localhost:9080/metrics | grep promtail_sent_entries_total
```

`promtail_sent_entries_total` increasing means lines are reaching Loki.

---

# 19. Verify End to End

Generate an audit event on the PostgreSQL leader:

```bash
sudo -u postgres psql -c "CREATE TABLE loki_probe (id int);"
sudo -u postgres psql -c "INSERT INTO loki_probe VALUES (1);"
sudo -u postgres psql -c "DROP TABLE loki_probe;"
```

Confirm it reached the local log:

```bash
sudo grep AUDIT /var/log/postgresql/postgresql-*.json | tail -3
```

Query Loki directly from the Monitoring Server:

```bash
curl -sG http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="postgresql", audit_class="DDL"}' \
  --data-urlencode 'limit=5' | jq '.data.result[].values[][1]'
```

Then in Grafana:

```text
Explore → Loki → {job="postgresql", audit_class="DDL"}
```

You should see the `CREATE TABLE` and `DROP TABLE` entries with `audit_type`,
`audit_class` as labels, and `db_user`, `audit_object_name` in structured
metadata.

---

# 20. Label Cardinality — The Rule That Matters

Loki builds one **stream** per unique combination of label values. Too many
streams and Loki slows down, then starts rejecting writes.

```text
SAFE as labels (small, closed sets)
    job, site, node, instance, unit, dbname,
    error_severity, audit_type, audit_class, level, frontend, backend

NEVER as labels (unbounded)
    db_user in a multi-tenant database, session_id, pid, remote_host,
    audit_object_name, audit_command, query text, transaction id, timestamps
```

Everything in the second list goes into **structured metadata** instead. It is
still searchable and still displayed — it just does not create a new stream.

Rough sizing for this platform:

```text
6 PG nodes × 2 jobs × ~6 severities × ~6 audit classes  ≈  400 streams
```

That is comfortable. Watch it in Prometheus:

```promql
loki_ingester_streams_created_total
sum(rate(loki_distributor_bytes_received_total[5m]))
```

> **If someone adds `db_user` or `audit_object_name` as a label**, stream count
> jumps by orders of magnitude and Loki degrades within hours. Review this
> before any pipeline change.

---

# 21. LogQL for the Audit Trail

This is what the whole setup is for. These are the queries to hand the client.

## Every audit event on a site

```logql
{job="postgresql", site="hq"} |= "AUDIT:"
```

## All schema changes — who ran DDL

```logql
{job="postgresql", audit_class="DDL"}
```

## Who dropped a table, and when

```logql
{job="postgresql", audit_class="DDL"} |= "DROP TABLE"
```

## Permission and role changes

```logql
{job="postgresql", audit_class="ROLE"}
```

This is usually the first query an auditor asks for: `GRANT`, `REVOKE`,
`CREATE ROLE`, `ALTER ROLE`.

## Everything a specific user did

```logql
{job="postgresql"} | db_user = "app_user"
```

`db_user` is structured metadata, so it filters with `|` rather than sitting
inside `{}`.

## All access to a sensitive table

```logql
{job="postgresql"} |= "employees_salary"
```

Combine with the object-level auditing from
`Phase7-Security/3-Audit-Logging-pgAudit.md` section 8 to capture reads too.

## Writes on a specific database

```logql
{job="postgresql", audit_class="WRITE", dbname="appdb"}
```

## Failed logins — brute force detection

```logql
{job="postgresql"} |= "password authentication failed"
```

As a rate, for a dashboard panel:

```logql
sum by (node) (
  rate({job="postgresql"} |= "password authentication failed" [5m])
)
```

## Errors and fatals only

```logql
{job="postgresql", error_severity=~"ERROR|FATAL|PANIC"}
```

## Audit event rate by command type

```logql
sum by (audit_class) (
  rate({job="postgresql", audit_type="SESSION"} [5m])
)
```

## Patroni failovers and leader changes

```logql
{job="systemd-journal", unit="patroni.service"} |~ "promoted|demoted|Lock owner|leader"
```

## etcd leader elections

```logql
{job="systemd-journal", unit="etcd.service"} |~ "elected|leader changed|lost leader"
```

## Backup failures

```logql
{job="pgbackrest", level=~"ERROR|WARN"}
```

## Correlating a failover with what the database was doing

```logql
{site="hq", node="hq-node-01"}
```

Dropping `job` gives every log source on that node on one timeline — Patroni,
PostgreSQL, etcd, system. This is the query to run during an incident.

---

# 22. Alerting on Logs

Loki's ruler evaluates LogQL rules and sends to the same Alertmanager already
configured, so log alerts route exactly like metric alerts.

```bash
sudo mkdir -p /var/lib/loki/rules/fake
sudo tee /var/lib/loki/rules/fake/postgresql.yml > /dev/null <<'EOF'
groups:

  - name: postgresql_audit_alerts
    interval: 1m
    rules:

      - alert: RepeatedFailedLogins
        expr: |
          sum by (site, node) (
            count_over_time({job="postgresql"} |= "password authentication failed" [5m])
          ) > 10
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Repeated failed logins on {{ $labels.node }}"
          description: "{{ $value }} failed authentication attempts in 5 minutes. Possible brute force or a misconfigured application."

      - alert: UnexpectedSchemaChange
        expr: |
          sum by (site, node) (
            count_over_time({job="postgresql", audit_class="DDL"} [10m])
          ) > 0
        labels:
          severity: warning
        annotations:
          summary: "Schema change executed on {{ $labels.node }}"
          description: "DDL was executed outside a change window. Check the audit trail in Loki."

      - alert: RoleOrPermissionChange
        expr: |
          sum by (site, node) (
            count_over_time({job="postgresql", audit_class="ROLE"} [10m])
          ) > 0
        labels:
          severity: warning
        annotations:
          summary: "Role or permission change on {{ $labels.node }}"
          description: "GRANT, REVOKE or role modification detected. This is a privileged action subject to change control."

      - alert: PostgresPanicOrFatal
        expr: |
          sum by (site, node) (
            count_over_time({job="postgresql", error_severity=~"FATAL|PANIC"} [5m])
          ) > 5
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Repeated FATAL/PANIC on {{ $labels.node }}"
          description: "PostgreSQL is logging fatal errors repeatedly."

  - name: patroni_log_alerts
    interval: 1m
    rules:

      - alert: PatroniFailoverDetected
        expr: |
          sum by (site, node) (
            count_over_time({job="systemd-journal", unit="patroni.service"} |~ "promoted|demoted" [5m])
          ) > 0
        labels:
          severity: critical
        annotations:
          summary: "Patroni role change on {{ $labels.node }}"
          description: "A promotion or demotion appeared in the Patroni log. Correlate with the Patroni dashboard."
EOF

sudo chown -R loki:loki /var/lib/loki/rules
sudo systemctl restart loki
```

> The `fake` directory name is not a placeholder — it is the tenant ID Loki uses
> when `auth_enabled: false`. The path must be
> `<rules_directory>/fake/<file>.yml` or the rules are never loaded.

Confirm the rules loaded:

```bash
curl -s http://localhost:3100/loki/api/v1/rules | jq '.data.groups[].name'
```

`UnexpectedSchemaChange` and `RoleOrPermissionChange` are deliberately noisy —
they fire on *any* DDL or role change. That is correct for a production database
under change control. If the client runs frequent migrations, narrow them to a
maintenance-window exclusion rather than removing them.

---

# 23. Retention and Sizing

Estimate before promising the client a disk size. Measure on the demo cluster:

```bash
# Bytes per day arriving at Loki
curl -s http://localhost:3100/metrics \
  | grep '^loki_distributor_bytes_received_total'
```

Rough guide for this platform:

```text
Baseline PostgreSQL logging          ~50–200 MB/node/day
+ pgAudit ddl,role,write             roughly doubles it
+ pgAudit read                       multiplies by 10 or more — do not enable globally
Loki compression                     ~10:1 on text logs

6 PG nodes × 300 MB/day × 90 days ÷ 10  ≈  16 GB
```

Add headroom and the journald/HAProxy/pgBackRest streams on top.

Change retention in `limits_config.retention_period`. Per-stream retention is
also possible when audit logs must be kept longer than everything else:

```yaml
limits_config:
  retention_period: 30d

  retention_stream:
    - selector: '{job="postgresql"}'
      priority: 1
      period: 365d
```

> **Get the retention number in writing from the client.** The Scope of Work asks
> for "retention guidance" and the difference between 90 days and 7 years is the
> difference between one disk and a storage project.

---

# 24. Promtail's Status — Read This Before Standardising On It

Grafana has frozen Promtail's features and designated **Grafana Alloy** as its
successor. Promtail still works and is still widely deployed, but it is no longer
receiving new features, and it will eventually stop receiving fixes.

For this project that is a manageable risk:

```text
* The configuration above is stable and does what is needed today.
* Alloy reads Promtail configuration through a converter, so migration is
  mechanical rather than a rewrite:

      alloy convert --source-format=promtail \
                    --output=/etc/alloy/config.alloy \
                    /etc/promtail/promtail-config.yml

* Loki itself is unaffected — only the shipper changes.
```

**Raise it with the client rather than letting them find out later.** If they
want the longer-lived option from day one, deploy Alloy instead and use the
converter output as the starting point. The Loki side of this document does not
change either way.

---

# 25. Troubleshooting

## Promtail runs but nothing appears in Loki

Almost always permissions. Check as the promtail user, not as root:

```bash
sudo -u promtail cat /var/log/postgresql/postgresql-*.json | head -1
```

`Permission denied` means section 15 was skipped or `log_file_mode` is still
`0600`.

## Check what Promtail thinks it is doing

```bash
sudo journalctl -u promtail -f
curl -s http://localhost:9080/metrics | grep -E 'promtail_(sent|dropped|read)'
```

```text
promtail_read_bytes_total       it is reading the files
promtail_sent_entries_total     it is reaching Loki
promtail_dropped_entries_total  should stay at zero
```

## Test a pipeline without shipping anything

```bash
promtail -config.file=/etc/promtail/promtail-config.yml -dry-run -inspect
```

`-inspect` prints every extracted field at each stage. This is the fastest way to
debug the pgAudit regex.

## "entry out of order" or "too far behind"

The node clock is wrong, or `timestamp` parsing failed and Promtail fell back to
read time. Check the format string in section 16 matches what PostgreSQL emits:

```bash
sudo head -1 /var/log/postgresql/postgresql-*.json | jq -r .timestamp
```

## Journal scraping fails with "journal reading is not supported"

The binary was built without journal support — see the note in section 14.

## Loki rejects writes

```bash
sudo journalctl -u loki | grep -i "rate limit\|too many streams"
```

Rate limit → raise `ingestion_rate_mb`. Too many streams → a high-cardinality
label crept into a pipeline. Re-read section 20.

## Positions reset and everything re-ships

`/var/lib/promtail/positions.yaml` was deleted or is not writable:

```bash
ls -l /var/lib/promtail/positions.yaml
```

---

# 26. Log Flow Summary

```text
PostgreSQL (pgAudit)
        │
        │ writes csvlog + jsonlog
        ▼
/var/log/postgresql/*.json          0640 postgres:postgres
        │
        │ read by promtail (member of the postgres group)
        ▼
Promtail pipeline
        │  json  →  timestamp  →  labels  →  structured_metadata
        │  regex on "AUDIT: ..."  →  audit_type / audit_class
        ▼
HTTP push :3100
        ▼
Loki  (Monitoring Server 10.0.0.20)
        │
        ├──► Grafana Explore / dashboards       LogQL
        └──► Loki ruler  →  Alertmanager :9093  log-based alerts
```

---

# 27. Installation Checklist

```text
Loki — Monitoring Server
* [ ] loki user and /var/lib/loki directories created
* [ ] Binary installed, `loki --version` works
* [ ] /etc/loki/loki-config.yml in place, owned by loki, mode 640
* [ ] compactor.retention_enabled is TRUE (not just retention_period)
* [ ] Service enabled and running, /ready returns "ready"
* [ ] Firewall allows 3100 from 10.0.0.0/24 and 10.1.0.0/24
* [ ] Prometheus scrapes the loki job
* [ ] Loki datasource added to Grafana and "Save & test" passes

PostgreSQL preparation
* [ ] log_destination includes jsonlog
* [ ] log_file_mode is 0640
* [ ] /var/log/postgresql is 750, existing files are 640
* [ ] logrotate create mode updated to 0640

Promtail — every node
* [ ] promtail user created and added to systemd-journal, adm, postgres
* [ ] Binary installed, same version as Loki
* [ ] Journal support confirmed, or journal blocks removed
* [ ] Config in place with correct site / node / instance labels
* [ ] SupplementaryGroups matches the node type (no postgres on non-DB nodes)
* [ ] Service running, promtail_sent_entries_total increasing
* [ ] `sudo -u promtail cat` on a PostgreSQL log succeeds

End to end
* [ ] Test CREATE/INSERT/DROP appears in Loki with audit_class="DDL"
* [ ] db_user and audit_object_name present as structured metadata
* [ ] No unbounded field was added as a label
* [ ] Ruler rules loaded, visible at /loki/api/v1/rules
* [ ] A test alert reached Alertmanager
* [ ] Ingest volume measured and retention sized against it
* [ ] Retention period confirmed in writing by the client
* [ ] Promtail-vs-Alloy decision raised with the client
```
