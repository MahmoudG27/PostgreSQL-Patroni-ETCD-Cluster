#!/bin/bash

set -e

# Update and upgrade the system
sudo apt update
sudo apt upgrade -y

# Set up AlertManager to work with Prometheus
sudo useradd --no-create-home --shell /bin/false alertmanager

# Install AlertManager
ALERTMANAGER_VERSION="0.33.1"
wget https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
tar xvf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz

sudo mv alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/alertmanager  /usr/local/bin/
sudo mv  alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/amtool /usr/local/bin/

# Set ownership of AlertManager binaries to the alertmanager user and group
sudo chown alertmanager:alertmanager /usr/local/bin/alertmanager
sudo chown alertmanager:alertmanager /usr/local/bin/amtool

# Create directories for AlertManager data and configuration files
sudo mkdir -p /etc/alertmanager

sudo tee /etc/alertmanager/alertmanager.yml > /dev/null <<EOF
global:
  resolve_timeout: 5m

route:
  receiver: "default"

receivers:
  - name: "default"
EOF

sudo chown -R alertmanager:alertmanager /etc/alertmanager


# Create a systemd service file for AlertManager
sudo tee /etc/systemd/system/alertmanager.service > /dev/null <<EOF
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
WorkingDirectory=/etc/alertmanager/
ExecStart=/usr/local/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --web.external-url http://0.0.0.0:9093
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the AlertManager service
sudo systemctl daemon-reload
sudo systemctl enable --now alertmanager
sudo systemctl status alertmanager

# Clean up the downloaded AlertManager files
rm -rf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64
rm -f alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz