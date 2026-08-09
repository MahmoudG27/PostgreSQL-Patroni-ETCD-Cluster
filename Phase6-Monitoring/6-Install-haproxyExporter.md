# HAProxy Exporter Setup

This guide explains how to install and configure the **HAProxy Exporter** for Prometheus on a Linux system using `systemd`.

## Overview

The setup performs the following steps:

1. Update and upgrade the system.
2. Create a dedicated `haproxy_exporter` user.
3. Download and install HAProxy Exporter.
4. Create a `systemd` service for the exporter.
5. Enable and start the service.
6. Verify the service status.
7. Remove the downloaded archive.

### Architecture

```text
HAProxy
   │
   │  http://127.0.0.1:8404/stats;csv
   ▼
HAProxy Exporter
   │
   │  :9101/metrics
   ▼
Prometheus
```

---

# 1. Update the System

First, update the package index and upgrade installed packages:

```bash
sudo apt update
sudo apt upgrade -y
```

---

# 2. Create a Dedicated User

Create a dedicated system user for HAProxy Exporter:

```bash
sudo useradd --no-create-home --shell /bin/false haproxy_exporter
```

The exporter will run using this user instead of `root`.

This is a security best practice because the exporter does not need administrative privileges.

---

# 3. Install HAProxy Exporter

Define the HAProxy Exporter version:

```bash
HAPROXY_EXPORTER_VERSION="0.15.0"
```

Download the release:

```bash
wget https://github.com/prometheus/haproxy_exporter/releases/download/v${HAPROXY_EXPORTER_VERSION}/haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64.tar.gz
```

Extract the archive:

```bash
tar xvf haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64.tar.gz
```

Move the exporter binary to `/usr/local/bin`:

```bash
sudo mv haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64/haproxy_exporter /usr/local/bin/
```

Set the correct owner:

```bash
sudo chown haproxy_exporter:haproxy_exporter /usr/local/bin/haproxy_exporter
```

You can verify the installation with:

```bash
/usr/local/bin/haproxy_exporter --version
```

---

# 4. Configure HAProxy Exporter with systemd

Create a systemd service file:

```bash
sudo nano /etc/systemd/system/haproxy_exporter.service
```

Add the following configuration:

```ini
[Unit]
Description=HAProxy Exporter
Wants=network-online.target
After=network-online.target haproxy.service

[Service]
User=haproxy_exporter
Group=haproxy_exporter
Type=simple

ExecStart=/usr/local/bin/haproxy_exporter \
  --haproxy.scrape-uri=http://127.0.0.1:8404/stats;csv \
  --web.listen-address=:9101

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

## systemd Configuration Explained

### `[Unit]`

```ini
[Unit]
Description=HAProxy Exporter
Wants=network-online.target
After=network-online.target haproxy.service
```

* `Description` provides a human-readable description.
* `Wants=network-online.target` tells systemd that the service needs the network to be available.
* `After=...` controls the startup order.

In this case, the exporter starts after:

* The network is online.
* `haproxy.service` has been started.

> `After=` controls ordering. It does not automatically start the listed service.

---

### `[Service]`

```ini
[Service]
User=haproxy_exporter
Group=haproxy_exporter
Type=simple
```

The exporter runs as:

```text
User:  haproxy_exporter
Group: haproxy_exporter
```

This prevents the exporter from running as `root`.

The service uses:

```ini
Type=simple
```

because the exporter runs as a foreground process.

---

### `ExecStart`

```ini
ExecStart=/usr/local/bin/haproxy_exporter \
  --haproxy.scrape-uri=http://127.0.0.1:8404/stats;csv \
  --web.listen-address=:9101
```

This is the actual command executed by systemd.

The exporter reads HAProxy statistics from:

```text
http://127.0.0.1:8404/stats;csv
```

and exposes Prometheus metrics on:

```text
:9101
```

Prometheus can then scrape:

```text
http://<server-ip>:9101/metrics
```

---

### Restart Policy

```ini
Restart=on-failure
RestartSec=5s
```

If the exporter exits unexpectedly, systemd will restart it after 5 seconds.

---

### `[Install]`

```ini
[Install]
WantedBy=multi-user.target
```

This allows the service to be enabled so that it starts automatically during system boot.

---

# 5. Reload systemd

After creating or modifying a systemd unit, reload the systemd configuration:

```bash
sudo systemctl daemon-reload
```

This makes systemd aware of the new service file.

---

# 6. Enable and Start the Exporter

Enable the service to start automatically at boot:

```bash
sudo systemctl enable haproxy_exporter
```

Start it:

```bash
sudo systemctl start haproxy_exporter
```

Or combine both operations:

```bash
sudo systemctl enable --now haproxy_exporter
```

---

# 7. Check the Service Status

Verify that the exporter is running:

```bash
sudo systemctl status haproxy_exporter
```

You should see something similar to:

```text
Active: active (running)
```

---

# 8. Check the Logs

If the service fails to start, check its logs with:

```bash
sudo journalctl -u haproxy_exporter
```

To follow the logs in real time:

```bash
sudo journalctl -u haproxy_exporter -f
```

---

# 9. Verify the Metrics Endpoint

HAProxy Exporter exposes Prometheus metrics on port `9101`.

Test it locally:

```bash
curl http://127.0.0.1:9101/metrics
```

You should receive Prometheus-formatted metrics.

You can also check whether the port is listening:

```bash
sudo ss -lntp | grep 9101
```

---

# 10. Clean Up

After confirming that the exporter is installed successfully, remove the downloaded archive:

```bash
sudo rm -rf haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64.tar.gz
```

You can also remove the extracted directory if it still exists:

```bash
rm -rf haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64
```

---

# Useful systemctl Commands

### Start

```bash
sudo systemctl start haproxy_exporter
```

### Stop

```bash
sudo systemctl stop haproxy_exporter
```

### Restart

```bash
sudo systemctl restart haproxy_exporter
```

### Enable at boot

```bash
sudo systemctl enable haproxy_exporter
```

### Disable at boot

```bash
sudo systemctl disable haproxy_exporter
```

### Check status

```bash
sudo systemctl status haproxy_exporter
```

### View logs

```bash
sudo journalctl -u haproxy_exporter
```

---

# Complete Installation Script

The complete installation can be automated with the following script:

```bash
#!/bin/bash

set -e

# Update and upgrade the system
sudo apt update
sudo apt upgrade -y

# Create HAProxy Exporter user
sudo useradd --no-create-home --shell /bin/false haproxy_exporter

# Install HAProxy Exporter
HAPROXY_EXPORTER_VERSION="0.15.0"

wget https://github.com/prometheus/haproxy_exporter/releases/download/v${HAPROXY_EXPORTER_VERSION}/haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64.tar.gz

tar xvf haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64.tar.gz

sudo mv \
  haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64/haproxy_exporter \
  /usr/local/bin/

sudo chown haproxy_exporter:haproxy_exporter \
  /usr/local/bin/haproxy_exporter

# Create systemd service
sudo tee /etc/systemd/system/haproxy_exporter.service > /dev/null <<'EOF'
[Unit]
Description=HAProxy Exporter
Wants=network-online.target
After=network-online.target haproxy.service

[Service]
User=haproxy_exporter
Group=haproxy_exporter
Type=simple

ExecStart=/usr/local/bin/haproxy_exporter \
  --haproxy.scrape-uri=http://127.0.0.1:8404/stats;csv \
  --web.listen-address=:9101

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
sudo systemctl daemon-reload

# Enable and start the service
sudo systemctl enable --now haproxy_exporter

# Show service status
sudo systemctl status haproxy_exporter

# Clean up
rm -rf haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64.tar.gz
rm -rf haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64
```

## Result

After completing the setup:

```text
HAProxy
   │
   │  :8404/stats;csv
   ▼
HAProxy Exporter
   │
   │  :9101/metrics
   ▼
Prometheus
```

The HAProxy Exporter is managed by `systemd` and will automatically restart if it fails and start automatically after a system reboot.
