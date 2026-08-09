#!/bin/bash

set -e

# Update and upgrade the system
sudo apt update
sudo apt upgrade -y

# Set up Postgres Exporter to work with Prometheus
sudo useradd --no-create-home --shell /bin/false postgres_exporter

# Install Postgres Exporter
POSTGRES_EXPORTER_VERSION="0.20.1"
wget https://github.com/prometheus-community/postgres_exporter/releases/download/v${POSTGRES_EXPORTER_VERSION}/postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xvf postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64.tar.gz

sudo mv postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64/postgres_exporter  /usr/local/bin/

sudo chown postgres_exporter:postgres_exporter /usr/local/bin/postgres_exporter

# --------------- 2. Create a PostgreSQL user for monitoring on each PostgreSQL node ----------------

# On every postgres node, connect to the database and run the following commands to create a user for monitoring:
CREATE USER postgres_exporter WITH PASSWORD 'CHANGE_ME';

# The user should have the following privileges to access the necessary metrics:
GRANT pg_monitor TO postgres_exporter;

# pg_monitor role is a good starting point for monitoring PostgreSQL, but some metrics/queries may require additional privileges. If you encounter permission issues, you may need to grant additional privileges to the postgres_exporter user.


# --------------------------- 3. Configure the Postgres Exporter to connect to the PostgreSQL database --------------------

# Set the DATA_SOURCE_NAME environment variable to specify the connection details for the PostgreSQL database. This variable should be set in the systemd service file for Postgres Exporter.
sudo tee /etc/postgres_exporter.env > /dev/null <<EOF
DATA_SOURCE_NAME="postgresql://postgres_exporter:CHANGE_ME@127.0.0.1:5432/postgres?sslmode=disable"
EOF

sudo chown root:postgres_exporter /etc/postgres_exporter.env
sudo chmod 640 /etc/postgres_exporter.env


# Create a systemd service file for Postgres Exporter
sudo tee /etc/systemd/system/postgres_exporter.service > /dev/null <<EOF
[Unit]
Description=PostgreSQL Exporter
After=network.target

[Service]
User=postgres_exporter
Group=postgres_exporter
EnvironmentFile=/etc/postgres_exporter.env

ExecStart=/usr/local/bin/postgres_exporter --web.listen-address=:9187

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the Postgres Exporter service
sudo systemctl daemon-reload
sudo systemctl enable --now postgres_exporter
sudo systemctl status postgres_exporter

# Clean up the downloaded Postgres Exporter files
sudo rm -rf postgres_exporter-${POSTGRES_EXPORTER_VERSION}.linux-amd64.tar.gz