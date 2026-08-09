#!/bin/bash

set -e

# Update and upgrade the system
sudo apt update
sudo apt upgrade -y

# Create Prometheus user and group
sudo useradd --no-create-home --shell /bin/false prometheus

# Create directories for Prometheus data and configuration files
sudo mkdir -p /etc/prometheus
sudo mkdir -p /var/lib/prometheus

# Download Prometheus (change the version if needed)
PROMETHEUS_VERSION="3.13.2"
wget https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
tar xvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz

# Move Prometheus binaries to /usr/local/bin
sudo mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
sudo mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/

# Set ownership of Prometheus binaries to the prometheus user and group
sudo chown prometheus:prometheus /usr/local/bin/prometheus
sudo chown prometheus:prometheus /usr/local/bin/promtool

# Move Prometheus configuration files to /etc/prometheus
sudo mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus.yml /etc/prometheus/
sudo mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles /etc/prometheus/consoles
sudo mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries /etc/prometheus/console_libraries

# Set ownership of Prometheus configuration files to the prometheus user and group
sudo chown -R prometheus:prometheus /etc/prometheus
sudo chown -R prometheus:prometheus /var/lib/prometheus

# Create a systemd service file for Prometheus
sudo tee /etc/systemd/system/prometheus.service > /dev/null <<EOF
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
    --config.file /etc/prometheus/prometheus.yml \
    --storage.tsdb.path /var/lib/prometheus/ \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries \
    --web.listen-address=0.0.0.0:9090 \
    --web.enable-lifecycle \
    --log.level=info

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd to apply the new service file and enable Prometheus to start on boot
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus
sudo systemctl status prometheus

# Clean up the downloaded Prometheus files
rm -rf prometheus-${PROMETHEUS_VERSION}.linux-amd64
rm prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz

# Validate Prometheus configuration
promtool check config /etc/prometheus/prometheus.yml