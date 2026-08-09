#!/bin/bash

set -e

# Update and upgrade the system
sudo apt update
sudo apt upgrade -y

# Set up Node Exporter to work with Prometheus
sudo useradd --no-create-home --shell /bin/false node_exporter

# Install Node Exporter
NODE_EXPORTER_VERSION="1.12.1"
wget https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xvf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz

sudo mv node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter  /usr/local/bin/

sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# Create a systemd service file for Node Exporter
sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<EOF
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

# Enable and start the Node Exporter service
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
sudo systemctl status node_exporter

# Clean up the downloaded Node Exporter files
sudo rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz