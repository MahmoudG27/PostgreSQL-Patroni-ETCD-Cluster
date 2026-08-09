# Node Exporter — Installation & Setup

Node Exporter will be installed on each Linux server that needs to be monitored by Prometheus.

It collects system-level metrics such as:

* CPU
* Memory
* Disk
* Filesystem
* Network
* Load

Architecture:

```text id="j7k4bz"
Linux VM
   │
   │ Metrics :9100
   ▼
Node Exporter
   │
   │
   ▼
Prometheus
   :9090
```

---

# 1. Update the System

```bash id="p2wzv6"
sudo apt update
sudo apt upgrade -y
```

---

# 2. Create Node Exporter User

Create a dedicated system user:

```bash id="iy4h7g"
sudo useradd \
  --no-create-home \
  --shell /bin/false \
  node_exporter
```

Node Exporter will run using this user instead of `root`.

---

# 3. Install Node Exporter

Set the version:

```bash id="2d4g4x"
NODE_EXPORTER_VERSION="1.12.1"
```

Download Node Exporter:

```bash id="y4ms6p"
wget https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
```

Extract the archive:

```bash id="4ep9me"
tar xvf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
```

Move the binary:

```bash id="s6v0fz"
sudo mv \
  node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter \
  /usr/local/bin/
```

Set ownership:

```bash id="7ey3i9"
sudo chown node_exporter:node_exporter \
  /usr/local/bin/node_exporter
```

Verify:

```bash id="a0k3u2"
node_exporter --version
```

---

# 4. Create Node Exporter Systemd Service

Create:

```bash id="o2t0wq"
sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple

ExecStart=/usr/local/bin/node_exporter

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
```

---

# 5. Enable and Start Node Exporter

Reload systemd:

```bash id="3x5h9g"
sudo systemctl daemon-reload
```

Enable Node Exporter at boot and start it:

```bash id="x2h6sz"
sudo systemctl enable --now node_exporter
```

Check the service:

```bash id="e3n5kn"
sudo systemctl status node_exporter
```

Expected:

```text id="9r4v2c"
Active: active (running)
```

---

# 6. Verify Node Exporter

Node Exporter exposes metrics on:

```text id="e0q9sa"
:9100
```

Check that the port is listening:

```bash id="p7b2h8"
sudo ss -lntp | grep 9100
```

Test the metrics endpoint locally:

```bash id="7z2w1a"
curl http://localhost:9100/metrics
```

You should see Prometheus metrics such as:

```text id="x5f9c1"
node_cpu_seconds_total
node_memory_MemAvailable_bytes
node_filesystem_avail_bytes
```

---

# 7. Check Node Exporter Logs

Monitor the logs:

```bash id="t6x8qk"
sudo journalctl -u node_exporter -f
```

---

# 8. Configure Prometheus

Add the Node Exporter target to:

```text id="3n5k7w"
/etc/prometheus/prometheus.yml
```

Example:

```yaml id="4f0k8x"
scrape_configs:
  - job_name: "node_exporter"
    static_configs:
      - targets:
          - "10.0.0.4:9100"
          - "10.0.0.5:9100"
          - "10.0.0.6:9100"
          - "10.0.0.7:9100"
          - "10.0.0.8:9100"
```

After updating the configuration:

```bash id="5z9y3m"
promtool check config /etc/prometheus/prometheus.yml
```

Then reload Prometheus:

```bash id="h8j2v5"
curl -X POST http://localhost:9090/-/reload
```

---

# 9. Monitoring Flow

```text id="x7c4m2"
             HQ PostgreSQL Nodes
          ┌────────┬────────┬────────┐
          │        │        │        │
          ▼        ▼        ▼        ▼
        Node     Node     Node     Node
       Exporter Exporter Exporter Exporter
          │        │        │        │
          └────────┴────────┴────────┘
                       │
                       │ :9100
                       ▼
                  Prometheus
                    :9090
                       │
                       ▼
                    Grafana
                    :3000
```

---

# 10. Installation Checklist

Install Node Exporter on every VM that needs system monitoring.

* [ ] Node Exporter user created.
* [ ] Node Exporter installed.
* [ ] systemd service created.
* [ ] Node Exporter service running.
* [ ] Port `9100` accessible.
* [ ] `/metrics` endpoint responding.
* [ ] Target added to Prometheus.
* [ ] Target shows `UP` in Prometheus.
* [ ] Metrics visible in Grafana.

---

# 11. Cleanup

Remove the extracted installation directory:

```bash
sudo rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64
```