# Grafana Loki & Alloy — Centralized Log Aggregation

This document describes how to install and configure **Loki** as the central log
store, and **Grafana Alloy** as the log collector running on every node.

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

> **Promtail is not used in this platform.**
>
> Grafana declared Promtail end of life on **2 March 2026**. Commercial support
> has ended and no further updates will be released. All collector development
> now happens in **Grafana Alloy**, which is what this document deploys.
>
> Section 25 covers converting an existing Promtail configuration if you have one.

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
          Alloy           Alloy           Alloy           Alloy
        PG nodes        HAProxy         Backup Srv      DR nodes
        10.0.0.4-6      10.0.0.100      10.0.0.30       10.1.0.4-6

     PostgreSQL log        HAProxy log     pgBackRest log
     pgAudit entries       journald        journald
     Patroni  (journald)
     etcd     (journald)
```

Alloy **pushes** to Loki. This is the opposite of Prometheus, which pulls.
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

  # Required for structured metadata, which section 17 relies on
  allow_structured_metadata: true

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

Alloy also exposes its own metrics on every node. Add those too:

```yaml
  - job_name: "alloy_hq"
    static_configs:
      - targets:
          - "10.0.0.4:12345"
          - "10.0.0.5:12345"
          - "10.0.0.6:12345"
          - "10.0.0.20:12345"
          - "10.0.0.30:12345"
          - "10.0.0.100:12345"
        labels:
          site: "hq"

  - job_name: "alloy_dr"
    static_configs:
      - targets:
          - "10.1.0.4:12345"
          - "10.1.0.5:12345"
          - "10.1.0.6:12345"
          - "10.1.0.20:12345"
          - "10.1.0.30:12345"
          - "10.1.0.100:12345"
        labels:
          site: "dr"
```

Reload Prometheus:

```bash
sudo systemctl reload prometheus
```

Useful metrics once scraped:

```text
loki_ingester_streams_created_total       stream count — watch for cardinality blowups
loki_distributor_bytes_received_total     ingest volume, for sizing
loki_request_duration_seconds             query and push latency
loki_write_sent_entries_total             lines Alloy successfully pushed
loki_write_dropped_entries_total          lines Alloy gave up on — should be zero
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
EOF

sudo systemctl restart grafana-server
```

---

# 12. Prepare PostgreSQL Logs for Loki

**Do this before installing Alloy.** It decides how hard the parsing will be.

`Phase7-Security/3-Audit-Logging-pgAudit.md` configures `log_destination = 'csvlog'`.
CSV is fine for humans and for loading into a table, but it is awkward for a log
collector — there is no CSV parsing stage, and CSV entries can span multiple
lines when a statement contains a newline.

PostgreSQL 15 and later can emit **JSON logs**, which parse with a single stage
and never span lines. PostgreSQL 18 supports it.

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
                 So the alloy user can read the file through the postgres
                 group. See section 16 — without this, Alloy silently
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

# 13. Why Alloy and Not Promtail

Promtail reached **end of life on 2 March 2026**. Grafana's notice is explicit:

```text
"Promtail is end of life (EOL) as of March 2, 2026. Commercial support has
 ended. No future support or updates will be provided. All future feature
 development will occur in Grafana Alloy. If you are currently using Promtail,
 you must migrate to Alloy or another supported client."
```

For a platform being handed to a client under a support agreement, deploying an
EOL component is not defensible. Alloy is the supported successor and is a
straight replacement here.

Practical differences you will notice:

```text
* Configuration language changes from YAML to Alloy's component syntax.
  The pipeline stages themselves keep the same names and behaviour.

* Journal support is built into the official package. Promtail's released
  binary often lacked it, which was a recurring source of confusion.

* A built-in web UI on :12345 shows every component, its health, and the
  data flowing between them. Debugging a broken pipeline stops being guesswork.

* Alloy also collects metrics and traces. If the client later wants
  application tracing, the agent is already on every node.

* It is installed from Grafana's APT repository, so it updates through the
  normal package manager instead of a manual binary download.
```

---

# 14. Install Alloy

On **every** node — PostgreSQL nodes, HAProxy, Backup Servers, Monitoring
Servers, both sites.

Add Grafana's APT repository:

```bash
sudo apt install -y gpg curl

sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://apt.grafana.com/gpg.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null

echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list
```

Install:

```bash
sudo apt update
sudo apt install -y alloy
```

Verify:

```bash
alloy --version
```

The package creates:

```text
/usr/bin/alloy                  the binary
/etc/alloy/config.alloy         the configuration
/etc/default/alloy              service environment
/var/lib/alloy/data             component state and file read positions
alloy                           a system user and group
alloy.service                   the systemd unit
```

> Do not start it yet — the shipped `config.alloy` is a placeholder.

---

# 15. Alloy User and Group Membership

Alloy must read logs it does not own. Add it to the right groups rather than
running it as root:

```bash
# systemd journal — for Patroni, etcd and system units
sudo usermod -aG systemd-journal alloy

# /var/log files owned by root:adm — syslog, HAProxy
sudo usermod -aG adm alloy

# PostgreSQL logs — database nodes ONLY
sudo usermod -aG postgres alloy
```

Confirm:

```bash
id alloy
```

> **Never run Alloy as root.** It reads files an attacker may partly control.
> Group membership plus `0640` log files is enough.

> On the HAProxy, Backup and Monitoring servers there is no `postgres` group —
> skip that line there.

---

# 16. Fix the Log File Permissions

This is the step that silently breaks everything if skipped.

`Phase7-Security/3-Audit-Logging-pgAudit.md` sets the log directory to `700` so
that only `postgres` can read it. Alloy then cannot read a single line, and it
fails **quietly** — the service runs, reports healthy, and ships nothing.

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

Verify Alloy can actually read as its own user:

```bash
sudo -u alloy head -c 200 /var/log/postgresql/postgresql-*.json
```

> **This weakens nothing that matters.** The audit-trail requirement is that a
> DBA cannot *delete or alter* the log. `0640` grants read only, and the whole
> point of shipping to Loki is that a second, independent copy exists that the
> database administrators cannot write to at all.

---

# 17. Alloy Configuration — PostgreSQL Nodes

This is the important one: it carries the pgAudit trail.

Replace `/etc/alloy/config.alloy`. Change `site`, `node` and `instance` per node.

```bash
sudo tee /etc/alloy/config.alloy > /dev/null <<'EOF'
// ===============================================================
// Destination — every pipeline forwards here
// ===============================================================
loki.write "default" {
  endpoint {
    url = "http://10.0.0.20:3100/loki/api/v1/push"

    // Buffer and retry rather than dropping lines when Loki is unreachable
    retry_on_http_429 = true

    backoff_config {
      min_period  = "500ms"
      max_period  = "5m"
      max_retries = 20
    }
  }
}

// ===============================================================
// PostgreSQL — JSON log, which carries the pgAudit entries
// ===============================================================
local.file_match "postgresql" {
  path_targets = [{
    __path__ = "/var/log/postgresql/*.json",
    job      = "postgresql",
    site     = "hq",                 // ← dr on the DR nodes
    node     = "hq-node-01",         // ← per node
    instance = "10.0.0.4:5432",      // ← matches the Prometheus instance label
  }]
}

loki.source.file "postgresql" {
  targets    = local.file_match.postgresql.targets
  forward_to = [loki.process.postgresql.receiver]
}

loki.process "postgresql" {
  forward_to = [loki.write.default.receiver]

  // ---- 1. Parse the PostgreSQL JSON log entry ----
  stage.json {
    expressions = {
      timestamp        = "timestamp",
      db_user          = "user",
      dbname           = "dbname",
      pid              = "pid",
      remote_host      = "remote_host",
      error_severity   = "error_severity",
      state_code       = "state_code",
      message          = "message",
      application_name = "application_name",
      backend_type     = "backend_type",
      session_id       = "session_id",
    }
  }

  // ---- 2. Use PostgreSQL's own timestamp, not the read time ----
  stage.timestamp {
    source = "timestamp"
    format = "2006-01-02 15:04:05.000 MST"
  }

  // ---- 3. Low-cardinality labels only. See section 21. ----
  stage.labels {
    values = {
      error_severity = "",
      dbname         = "",
    }
  }

  // ---- 4. High-cardinality fields as structured metadata ----
  // Queryable and displayed, but NOT part of the stream index.
  stage.structured_metadata {
    values = {
      db_user          = "",
      remote_host      = "",
      application_name = "",
      session_id       = "",
      pid              = "",
    }
  }

  // ---- 5. Extract the pgAudit fields out of the message ----
  // pgAudit writes:
  //   AUDIT: <type>,<stmt_id>,<sub_id>,<class>,<command>,<obj_type>,<obj_name>,<statement>,<params>
  // Lines that are not audit entries simply do not match and pass through.
  //
  // NOTE: backslashes are DOUBLED. Alloy strings use Go escape rules, so a
  // regex \d must be written \\d. This is the most common conversion mistake.
  stage.regex {
    source     = "message"
    expression = "^AUDIT: (?P<audit_type>[A-Z]+),(?P<audit_stmt_id>\\d+),(?P<audit_sub_id>\\d+),(?P<audit_class>[A-Z]+),(?P<audit_command>[^,]*),(?P<audit_object_type>[^,]*),(?P<audit_object_name>[^,]*),"
  }

  // audit_class is a closed set: READ / WRITE / FUNCTION / ROLE / DDL / MISC
  // audit_type is SESSION or OBJECT. Both are safe as labels.
  stage.labels {
    values = {
      audit_type  = "",
      audit_class = "",
    }
  }

  // The command and object name are far too varied to index
  stage.structured_metadata {
    values = {
      audit_command     = "",
      audit_object_type = "",
      audit_object_name = "",
    }
  }

  // ---- 6. Ship the human-readable message as the log line ----
  stage.output {
    source = "message"
  }
}

// ===============================================================
// Patroni and etcd — systemd journal
// ===============================================================
loki.relabel "journal" {
  forward_to = []

  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }

  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "priority"
  }
}

loki.source.journal "system" {
  path          = "/var/log/journal"
  max_age       = "12h"
  relabel_rules = loki.relabel.journal.rules
  forward_to    = [loki.process.journal.receiver]

  labels = {
    job  = "systemd-journal",
    site = "hq",
    node = "hq-node-01",
  }
}

loki.process "journal" {
  forward_to = [loki.write.default.receiver]

  // Keep only the units that matter — journald carries a lot of noise
  stage.match {
    selector = "{unit!~\"patroni.service|etcd.service|postgresql.*|pgbackrest.*|sshd.service\"}"
    action   = "drop"
  }
}
EOF
```

Set ownership:

```bash
sudo chown root:alloy /etc/alloy/config.alloy
sudo chmod 640 /etc/alloy/config.alloy
```

Check the syntax before starting — this parses the file and reports the exact
line on failure:

```bash
sudo alloy fmt /etc/alloy/config.alloy
```

---

# 18. Alloy Configuration — Other Node Types

Same file, different components. Keep `site`, `node` and `instance` consistent
with the Prometheus labels so dashboards can pivot between logs and metrics.

Every node also needs the `loki.write "default"` block from section 17.

## HAProxy nodes (10.0.0.100 / 10.1.0.100)

```alloy
local.file_match "haproxy" {
  path_targets = [{
    __path__ = "/var/log/haproxy.log",
    job      = "haproxy",
    site     = "hq",
    node     = "hq-haproxy",
    instance = "10.0.0.100:9101",
  }]
}

loki.source.file "haproxy" {
  targets    = local.file_match.haproxy.targets
  forward_to = [loki.process.haproxy.receiver]
}

loki.process "haproxy" {
  forward_to = [loki.write.default.receiver]

  // HAProxy TCP log line:
  //   client_ip:port [date] frontend backend/server times bytes flags conns
  stage.regex {
    expression = "^(?P<syslog_ts>\\w+\\s+\\d+\\s+[\\d:]+) (?P<host>\\S+) haproxy\\[(?P<pid>\\d+)\\]: (?P<client>\\S+) \\[(?P<accept_date>[^\\]]+)\\] (?P<frontend>\\S+) (?P<backend>[^/]+)/(?P<server>\\S+)"
  }

  stage.labels {
    values = {
      frontend = "",
      backend  = "",
    }
  }

  stage.structured_metadata {
    values = {
      server = "",
      client = "",
    }
  }
}
```

## Backup Servers (10.0.0.30 / 10.1.0.30)

```alloy
local.file_match "pgbackrest" {
  path_targets = [{
    __path__ = "/var/log/pgbackrest/*.log",
    job      = "pgbackrest",
    site     = "hq",
    node     = "hq-backup",
    instance = "10.0.0.30:9100",
  }]
}

loki.source.file "pgbackrest" {
  targets    = local.file_match.pgbackrest.targets
  forward_to = [loki.process.pgbackrest.receiver]
}

loki.process "pgbackrest" {
  forward_to = [loki.write.default.receiver]

  // 2026-08-24 02:00:01.123 P00   INFO: backup command begin
  stage.regex {
    expression = "^(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3}) P\\d+\\s+(?P<level>\\w+):"
  }

  stage.timestamp {
    source = "ts"
    format = "2006-01-02 15:04:05.000"
  }

  stage.labels {
    values = {
      level = "",
    }
  }
}
```

## Monitoring Server

```alloy
loki.source.journal "monitoring" {
  path          = "/var/log/journal"
  max_age       = "12h"
  relabel_rules = loki.relabel.journal.rules
  forward_to    = [loki.process.monitoring.receiver]

  labels = {
    job  = "systemd-journal",
    site = "hq",
    node = "hq-monitoring",
  }
}

loki.process "monitoring" {
  forward_to = [loki.write.default.receiver]

  stage.match {
    selector = "{unit!~\"prometheus.service|grafana-server.service|alertmanager.service|loki.service|alloy.service\"}"
    action   = "drop"
  }
}
```

---

# 19. Start Alloy and Use the Built-in UI

The package already installed the service. Expose the debugging UI on the node's
address so Prometheus can scrape it and so you can open it from a browser:

```bash
sudo tee /etc/default/alloy > /dev/null <<'EOF'
CONFIG_FILE="/etc/alloy/config.alloy"
CUSTOM_ARGS="--server.http.listen-addr=0.0.0.0:12345 --storage.path=/var/lib/alloy/data"
RESTART_ON_UPGRADE=true
EOF
```

Restrict who can reach it:

```bash
sudo ufw allow from 10.0.0.0/24 to any port 12345 proto tcp comment 'Alloy UI/metrics'
sudo ufw allow from 10.1.0.0/24 to any port 12345 proto tcp comment 'Alloy UI/metrics'
```

Start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now alloy
sudo systemctl status alloy
```

Open the UI:

```text
http://10.0.0.4:12345
```

The **Graph** page shows every component and the connections between them. A
component with a red health state names the exact error — this replaces most of
the guesswork that Promtail required.

After editing the configuration, reload without restarting:

```bash
sudo systemctl reload alloy
```

---

# 20. Verify End to End

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

Confirm Alloy is sending:

```bash
curl -s http://localhost:12345/metrics | grep -E 'loki_write_(sent|dropped)_entries_total'
```

`loki_write_sent_entries_total` increasing means lines are reaching Loki.
`loki_write_dropped_entries_total` should stay at zero.

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

You should see the `CREATE TABLE` and `DROP TABLE` entries with `audit_type`
and `audit_class` as labels, and `db_user` and `audit_object_name` in structured
metadata.

---

# 21. Label Cardinality — The Rule That Matters

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

> **If someone moves `db_user` or `audit_object_name` from
> `stage.structured_metadata` into `stage.labels`**, stream count jumps by
> orders of magnitude and Loki degrades within hours. Review this before any
> pipeline change.

---

# 22. LogQL for the Audit Trail

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

## Audit event rate by class

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

# 23. Alerting on Logs

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

# 24. Retention and Sizing

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

# 25. Converting an Existing Promtail Configuration

If a node already runs Promtail, Alloy converts the configuration mechanically:

```bash
sudo alloy convert \
  --source-format=promtail \
  --output=/etc/alloy/config.alloy \
  --report=/tmp/alloy-convert-report.txt \
  /etc/promtail/promtail-config.yml
```

Read the report before trusting the output:

```bash
cat /tmp/alloy-convert-report.txt
```

Then check what actually needs attention:

```text
* Regex backslashes. YAML passed \d through literally; Alloy string escapes
  need \\d. The converter handles this, but verify any regex you later edit
  by hand — this is the most common breakage.

* Component names. The converter generates names from the job names. Rename
  them to something readable before committing the file.

* Positions file. Promtail's positions.yaml is not carried over. Alloy tracks
  its own positions under /var/lib/alloy/data, so the first run re-reads from
  the start of each file unless you set tail_from_end.
```

Format and check the result, then decommission Promtail:

```bash
sudo alloy fmt /etc/alloy/config.alloy

sudo systemctl disable --now promtail
sudo systemctl daemon-reload
sudo systemctl enable --now alloy
```

Confirm nothing is running twice — duplicated lines in Loki mean both agents are
still shipping:

```bash
systemctl is-active promtail alloy
```

---

# 26. Troubleshooting

## Alloy runs but nothing appears in Loki

Almost always permissions. Check as the alloy user, not as root:

```bash
sudo -u alloy cat /var/log/postgresql/postgresql-*.json | head -1
```

`Permission denied` means section 16 was skipped or `log_file_mode` is still
`0600`.

## Use the UI first

```text
http://<node>:12345  →  Graph
```

Every component shows a health state and its last error. Click a component to
see the arguments it resolved and the data it is passing on. This finds most
problems in seconds.

## Check the shipping counters

```bash
sudo journalctl -u alloy -f
curl -s http://localhost:12345/metrics | grep -E 'loki_(write|source_file)'
```

```text
loki_write_sent_entries_total       it is reaching Loki
loki_write_dropped_entries_total    should stay at zero
loki_source_file_file_bytes_total   it is reading the files
```

## Configuration will not parse

```bash
sudo alloy fmt /etc/alloy/config.alloy
```

Reports the exact line and column. The usual causes are a single backslash in a
regex that needs doubling, or an unescaped `"` inside a `stage.match` selector.

## "entry out of order" or "too far behind"

The node clock is wrong, or `stage.timestamp` failed and Alloy fell back to read
time. Check the format string in section 17 matches what PostgreSQL emits:

```bash
sudo head -1 /var/log/postgresql/postgresql-*.json | jq -r .timestamp
```

## Loki rejects writes

```bash
sudo journalctl -u loki | grep -i "rate limit\|too many streams"
```

Rate limit → raise `ingestion_rate_mb`. Too many streams → a high-cardinality
label crept into a pipeline. Re-read section 21.

## Structured metadata rejected

```text
"structured metadata is disabled"
```

`allow_structured_metadata: true` is missing from `limits_config` in the Loki
configuration. See section 6.

## Everything re-ships after a restart

Alloy's state directory was wiped or is not writable:

```bash
ls -ld /var/lib/alloy/data
```

---

# 27. Log Flow Summary

```text
PostgreSQL (pgAudit)
        │
        │ writes csvlog + jsonlog
        ▼
/var/log/postgresql/*.json          0640 postgres:postgres
        │
        │ read by alloy (member of the postgres group)
        ▼
Grafana Alloy
        │  local.file_match  →  loki.source.file  →  loki.process
        │  stage.json → stage.timestamp → stage.labels
        │  stage.structured_metadata
        │  stage.regex on "AUDIT: ..."  →  audit_type / audit_class
        ▼
loki.write  →  HTTP push :3100
        ▼
Loki  (Monitoring Server 10.0.0.20)
        │
        ├──► Grafana Explore / dashboards       LogQL
        └──► Loki ruler  →  Alertmanager :9093  log-based alerts
```

---

# 28. Installation Checklist

```text
Loki — Monitoring Server
* [ ] loki user and /var/lib/loki directories created
* [ ] Binary installed, `loki --version` works
* [ ] /etc/loki/loki-config.yml in place, owned by loki, mode 640
* [ ] compactor.retention_enabled is TRUE (not just retention_period)
* [ ] allow_structured_metadata is true
* [ ] Service enabled and running, /ready returns "ready"
* [ ] Firewall allows 3100 from 10.0.0.0/24 and 10.1.0.0/24
* [ ] Prometheus scrapes the loki job
* [ ] Loki datasource added to Grafana and "Save & test" passes

PostgreSQL preparation
* [ ] log_destination includes jsonlog
* [ ] log_file_mode is 0640
* [ ] /var/log/postgresql is 750, existing files are 640
* [ ] logrotate create mode updated to 0640

Alloy — every node
* [ ] Grafana APT repository added
* [ ] alloy package installed, `alloy --version` works
* [ ] alloy user added to systemd-journal, adm, and postgres (DB nodes only)
* [ ] /etc/alloy/config.alloy written with correct site / node / instance labels
* [ ] `alloy fmt` parses the file with no error
* [ ] /etc/default/alloy sets the listen address
* [ ] Firewall allows 12345 from the platform subnets
* [ ] Service running, loki_write_sent_entries_total increasing
* [ ] `sudo -u alloy cat` on a PostgreSQL log succeeds
* [ ] Alloy UI Graph page shows all components healthy
* [ ] Prometheus scrapes the alloy jobs

End to end
* [ ] Test CREATE/INSERT/DROP appears in Loki with audit_class="DDL"
* [ ] db_user and audit_object_name present as structured metadata
* [ ] No unbounded field was added to stage.labels
* [ ] Ruler rules loaded, visible at /loki/api/v1/rules
* [ ] A test alert reached Alertmanager
* [ ] Ingest volume measured and retention sized against it
* [ ] Retention period confirmed in writing by the client
* [ ] No node is still running Promtail alongside Alloy
```
