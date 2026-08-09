#!/bin/bash

set -e

# Update and upgrade the system
sudo apt update
sudo apt upgrade -y

# Set up HAProxy Exporter to work with Prometheus
sudo useradd --no-create-home --shell /bin/false haproxy_exporter

# Install HAProxy Exporter
HAPROXY_EXPORTER_VERSION="0.15.0"
wget https://github.com/prometheus/haproxy_exporter/releases/download/v${HAPROXY_EXPORTER_VERSION}/haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xvf haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64.tar.gz

sudo mv haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64/haproxy_exporter  /usr/local/bin/

sudo chown haproxy_exporter:haproxy_exporter /usr/local/bin/haproxy_exporter

# --------------------------- 2. Configure the HAProxy Exporter --------------------

# Create a systemd service file for HAProxy Exporter
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

# Enable and start the HAProxy Exporter service
sudo systemctl daemon-reload
sudo systemctl enable --now haproxy_exporter
sudo systemctl status haproxy_exporter

# Clean up the downloaded HAProxy Exporter files
sudo rm -rf haproxy_exporter-${HAPROXY_EXPORTER_VERSION}.linux-amd64.tar.gz