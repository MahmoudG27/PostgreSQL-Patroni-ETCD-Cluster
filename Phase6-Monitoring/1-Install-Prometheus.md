# Prometheus Monitoring — Installation & Configuration

This document describes how to install and configure **Prometheus** as the central monitoring and metrics collection server.

Prometheus will run on a dedicated Monitoring Server and will expose its web interface on:

```text
http://<MONITORING-SERVER-IP>:9090
```

The Prometheus server will later be used to collect metrics from components such as:

* PostgreSQL / Patroni nodes
* HAProxy
* Node Exporter
* HAProxy Exporter
* Other infrastructure components

---

# 1. Monitoring Architecture

The monitoring architecture is based on a central Prometheus server.

```text
                         Monitoring Server
                         ┌─────────────────┐
                         │   Prometheus    │
                         │     :9090       │
                         └────────┬────────┘
                                  │
                    ┌─────────────┼─────────────┐
                    │             │             │
                    ▼             ▼             ▼
              Node Exporter   HAProxy       PostgreSQL
                    │          Exporter       Exporter
                    │             │             │
                    ▼             ▼             ▼
               HQ Nodes        HAProxy       PostgreSQL
```

Prometheus periodically **scrapes** metrics from the configured targets.

The basic flow is:

```text
Exporter
   │
   │ Metrics
   ▼
Prometheus
   │
   │ Query
   ▼
Prometheus UI / Grafana
```

---

# 2. Prometheus Server

The Prometheus server will contain:

```text
/etc/prometheus/
```

for configuration files, and:

```text
/var/lib/prometheus/
```

for the Prometheus time-series database.

The Prometheus binary will be installed under:

```text
/usr/local/bin/prometheus
```

and:

```text
/usr/local/bin/promtool
```

---

# 3. Update the System

Update the package repository:

```bash
sudo apt update
```

Upgrade installed packages:

```bash
sudo apt upgrade -y
```

---

# 4. Create the Prometheus User

Create a dedicated system user for Prometheus:

```bash
sudo useradd \
  --no-create-home \
  --shell /bin/false \
  prometheus
```

The Prometheus service will run using this user instead of `root`.

This is important from a security perspective because Prometheus does not need root privileges to perform its normal operations.

---

# 5. Create Prometheus Directories

Create the configuration directory:

```bash
sudo mkdir -p /etc/prometheus
```

Create the data directory:

```bash
sudo mkdir -p /var/lib/prometheus
```

The directory structure will be:

```text
/etc/prometheus/
    │
    ├── prometheus.yml
    ├── consoles/
    └── console_libraries/

/var/lib/prometheus/
    │
    └── Prometheus TSDB data
```

---

# 6. Download Prometheus

Choose the Prometheus version.

Example:

```bash
PROMETHEUS_VERSION="3.13.2"
```

Download the Linux AMD64 release:

```bash
wget https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
```

Extract the archive:

```bash
tar xvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
```

This creates:

```text
prometheus-3.13.2.linux-amd64/
```

The extracted directory contains the Prometheus binaries and default configuration files.

---

# 7. Install Prometheus Binaries

Move the Prometheus binary:

```bash
sudo mv \
  prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus \
  /usr/local/bin/
```

Move `promtool`:

```bash
sudo mv \
  prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool \
  /usr/local/bin/
```

Verify:

```bash
prometheus --version
```

And:

```bash
promtool --version
```

---

# 8. Install Prometheus Configuration Files

Move the default Prometheus configuration:

```bash
sudo mv \
  prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus.yml \
  /etc/prometheus/
```

Move the console templates:

```bash
sudo mv \
  prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles \
  /etc/prometheus/consoles
```

Move the console libraries:

```bash
sudo mv \
  prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries \
  /etc/prometheus/console_libraries
```

The final structure should look like:

```text
/etc/prometheus/
├── prometheus.yml
├── consoles/
└── console_libraries/
```

---

# 9. Set Ownership

Prometheus must be able to read its configuration and write its TSDB data.

Set ownership of the configuration directory:

```bash
sudo chown -R prometheus:prometheus /etc/prometheus
```

Set ownership of the data directory:

```bash
sudo chown -R prometheus:prometheus /var/lib/prometheus
```

Set ownership of the binaries:

```bash
sudo chown prometheus:prometheus /usr/local/bin/prometheus
sudo chown prometheus:prometheus /usr/local/bin/promtool
```

---

# 10. Prometheus Configuration

The main configuration file is:

```text
/etc/prometheus/prometheus.yml
```

Prometheus uses this file to define:

* Scrape interval
* Targets
* Jobs
* Exporters
* Alerting configuration
* Rules
* Other monitoring settings

For example:

```yaml
global:
  scrape_interval: 15s

scrape_configs:

  - job_name: "prometheus"
    static_configs:
      - targets:
          - "localhost:9090"
```

This configuration tells Prometheus to monitor itself.

---

# 11. Prometheus Systemd Service

Create the systemd service:

```bash
sudo tee /etc/systemd/system/prometheus.service > /dev/null <<'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple

Restart=on-failure
RestartSec=5s

ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle \
  --log.level=info

[Install]
WantedBy=multi-user.target
EOF
```

---

# 12. Systemd Service Explanation

The service runs as:

```ini
User=prometheus
Group=prometheus
```

Prometheus configuration:

```text
/etc/prometheus/prometheus.yml
```

Prometheus data directory:

```text
/var/lib/prometheus/
```

Prometheus listens on:

```text
0.0.0.0:9090
```

Therefore the Prometheus web interface is available on:

```text
http://<MONITORING-SERVER-IP>:9090
```

The lifecycle option:

```text
--web.enable-lifecycle
```

allows Prometheus configuration to be reloaded without completely restarting the service.

---

# 13. Reload systemd

After creating the service:

```bash
sudo systemctl daemon-reload
```

Enable Prometheus at boot:

```bash
sudo systemctl enable prometheus
```

Start Prometheus:

```bash
sudo systemctl start prometheus
```

Or enable and start it at the same time:

```bash
sudo systemctl enable --now prometheus
```

---

# 14. Check Prometheus Status

Check the service:

```bash
sudo systemctl status prometheus
```

Expected state:

```text
Active: active (running)
```

---

# 15. Check Prometheus Logs

Monitor the Prometheus logs:

```bash
sudo journalctl -u prometheus -f
```

You should not see configuration or startup errors.

To see the latest logs:

```bash
sudo journalctl -u prometheus --no-pager -n 100
```

---

# 16. Validate Prometheus Configuration

Before restarting Prometheus after modifying its configuration, validate the configuration using `promtool`.

Run:

```bash
promtool check config /etc/prometheus/prometheus.yml
```

A successful validation should report that the configuration is valid.

This step should be performed whenever:

```text
/etc/prometheus/prometheus.yml
```

is modified.

---

# 17. Access the Prometheus Web Interface

From a browser:

```text
http://<MONITORING-SERVER-IP>:9090
```

For example, if the Monitoring Server has:

```text
10.0.0.20
```

the Prometheus UI would be:

```text
http://10.0.0.20:9090
```

The Prometheus web interface allows you to:

* Execute PromQL queries
* Inspect metrics
* Check targets
* Check configuration
* Inspect runtime information

---

# 18. Check Prometheus Targets

After exporters are configured, Prometheus exposes the target status from:

```text
/targets
```

For example:

```text
http://10.0.0.20:9090/targets
```

A healthy target should show:

```text
State: UP
```

An unhealthy target will show:

```text
State: DOWN
```

The `/targets` page is one of the first places to check when troubleshooting monitoring.

---

# 19. Reload Configuration

After modifying:

```text
/etc/prometheus/prometheus.yml
```

first validate it:

```bash
promtool check config /etc/prometheus/prometheus.yml
```

If the configuration is valid, reload Prometheus.

Because lifecycle support is enabled:

```text
--web.enable-lifecycle
```

you can reload the configuration using:

```bash
curl -X POST http://localhost:9090/-/reload
```

Alternatively, restart the service:

```bash
sudo systemctl restart prometheus
```

---

# 20. Prometheus Monitoring Targets

The Prometheus server itself is only the central monitoring engine.

To monitor the complete infrastructure, exporters should be installed on the relevant systems.

The planned monitoring stack can include:

```text
                    Prometheus
                         │
          ┌──────────────┼──────────────┐
          │              │              │
          ▼              ▼              ▼
    Node Exporter   HAProxy Exporter   PostgreSQL
          │              │            Exporter
          ▼              ▼              ▼
      Linux VMs        HAProxy       PostgreSQL
```

For the PostgreSQL/Patroni environment, monitoring can cover:

### Infrastructure

* CPU
* Memory
* Disk
* Network
* Filesystem

### PostgreSQL

* Connections
* Transactions
* WAL
* Replication
* Locks
* Database size
* Query activity

### Patroni

* Primary/Replica state
* Cluster health
* Leader status
* Replication state

### HAProxy

* Frontend connections
* Backend connections
* Server health
* Primary availability
* Traffic statistics

### Backup

* pgBackRest backup status
* Backup size
* Backup age
* WAL archiving
* Repository health

---

# 21. Monitoring Architecture for the HQ Environment

The complete monitoring architecture can be represented as:

```text
                           Applications
                                │
                                ▼
                             HAProxy
                                │
                                │
                    ┌───────────┴───────────┐
                    │                       │
                    ▼                       ▼
              hq-node-01              hq-node-02
              PostgreSQL              PostgreSQL
              Patroni                Patroni
                    │                       │
                    └───────────┬───────────┘
                                │
                         hq-node-03/04/05
                                │
                                │
                                ▼
                        Exporter Metrics
                                │
                                ▼
                     ┌──────────────────┐
                     │    Prometheus    │
                     │      :9090       │
                     └────────┬─────────┘
                              │
                              ▼
                           Grafana
```

Prometheus collects the metrics, while Grafana can later be used to create dashboards and visualize the collected data.

---

# 22. Prometheus Data Storage

Prometheus stores its time-series database under:

```text
/var/lib/prometheus/
```

This directory should have enough disk space for the expected retention period and monitoring workload.

Check disk usage:

```bash
df -h /var/lib/prometheus
```

Check Prometheus data directory:

```bash
sudo du -sh /var/lib/prometheus
```

---

# 23. Basic Prometheus Health Checks

## Check service

```bash
sudo systemctl status prometheus
```

## Check logs

```bash
sudo journalctl -u prometheus -f
```

## Check configuration

```bash
promtool check config /etc/prometheus/prometheus.yml
```

## Check Prometheus version

```bash
prometheus --version
```

## Check listening port

```bash
sudo ss -lntp | grep 9090
```

Expected:

```text
0.0.0.0:9090
```

---

# 24. Troubleshooting

## Prometheus is not starting

Check:

```bash
sudo systemctl status prometheus
```

Then:

```bash
sudo journalctl -u prometheus -n 100 --no-pager
```

Validate the configuration:

```bash
promtool check config /etc/prometheus/prometheus.yml
```

---

## Permission denied

Check ownership:

```bash
ls -ld /etc/prometheus
ls -ld /var/lib/prometheus
```

Fix ownership:

```bash
sudo chown -R prometheus:prometheus /etc/prometheus
sudo chown -R prometheus:prometheus /var/lib/prometheus
```

---

## Port 9090 is not reachable

Check whether Prometheus is listening:

```bash
sudo ss -lntp | grep 9090
```

Check the service:

```bash
sudo systemctl status prometheus
```

Also verify that the server firewall allows TCP port:

```text
9090
```

---

# 25. Installation Checklist

After completing the installation:

* [ ] Prometheus user created.
* [ ] `/etc/prometheus` created.
* [ ] `/var/lib/prometheus` created.
* [ ] Prometheus downloaded.
* [ ] `prometheus` binary installed.
* [ ] `promtool` installed.
* [ ] `prometheus.yml` installed.
* [ ] Console templates installed.
* [ ] Console libraries installed.
* [ ] Correct file ownership configured.
* [ ] systemd service created.
* [ ] systemd daemon reloaded.
* [ ] Prometheus enabled at boot.
* [ ] Prometheus service running.
* [ ] Prometheus configuration validated.
* [ ] Port `9090` listening.
* [ ] Prometheus Web UI accessible.
* [ ] Prometheus targets configured.
* [ ] Exporters installed on monitored systems.
* [ ] All required targets show `UP`.

---

# 26. Final Prometheus State

The Monitoring Server should finally have:

```text
/usr/local/bin/
├── prometheus
└── promtool

/etc/prometheus/
├── prometheus.yml
├── consoles/
└── console_libraries/

/var/lib/prometheus/
└── Prometheus TSDB
```

And the service:

```text
prometheus.service
        │
        ▼
     Prometheus
        │
        │ :9090
        ▼
   Monitoring UI
```

The overall infrastructure becomes:

```text
                         ┌───────────────┐
                         │ Applications  │
                         └───────┬───────┘
                                 │
                                 ▼
                            ┌─────────┐
                            │ HAProxy │
                            └────┬────┘
                                 │
                                 ▼
                       ┌───────────────────┐
                       │ Patroni PostgreSQL│
                       │      Cluster      │
                       └─────────┬─────────┘
                                 │
                                 │ Metrics
                                 ▼
                       ┌───────────────────┐
                       │     Exporters     │
                       └─────────┬─────────┘
                                 │
                                 ▼
                       ┌───────────────────┐
                       │    Prometheus     │
                       │       :9090       │
                       └─────────┬─────────┘
                                 │
                                 ▼
                              Grafana
```

Prometheus is therefore the **central metrics collection layer** for the PostgreSQL HA environment.