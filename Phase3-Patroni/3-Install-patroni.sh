#!/bin/bash

set -e

# Install Patroni dependencies:
sudo apt install -y python3-pip python3-venv python3-dev gcc libpq-dev python3-psycopg2

# -------------------------- Install Patroni inside venv ---------------------------

# Create venv location:
sudo mkdir /opt/patroni
sudo python3 -m venv /opt/patroni

# Upgrade pip:
sudo /opt/patroni/bin/pip install --upgrade pip

# Install Patroni:
sudo /opt/patroni/bin/pip install "patroni[etcd3]" psycopg2

# Check the installed version of Patroni:
/opt/patroni/bin/patroni --version

# Update specific library (If needed): 
sudo /opt/patroni/bin/pip install --upgrade patroni

# Show installed libararies and versions:
/opt/patroni/bin/pip list

# To delete venv:
sudo rm -rf /opt/patroni

# Alias to avoid write the full path
echo "alias patronictl='/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml'" >> ~/.bashrc
source ~/.bashrc

# Create the configuration file for Patroni (different values for each VM)
# Important file. it will be a bit different between each node (but the principle is the same).
# Create the file at /etc/patroni/patroni.yml — change the name and IP for each node, example for node1:

sudo mkdir -p /etc/patroni

sudo tee /etc/patroni/patroni.yml <<EOF
scope: pg_cluster_hq
namespace: /db/
name: hq-node-01

restapi:
  listen: 10.0.0.4:8008
  connect_address: 10.0.0.4:8008

etcd3:
  hosts: 10.0.0.4:2379,10.0.0.5:2379,10.0.0.6:2379,10.0.0.7:2379,10.0.0.8:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    # Enable Synchronous Replication in HQ
    synchronous_mode: true
    synchronous_mode_strict: false      # Prefer "false" because even Replicas down the Primary one doesn't stop

    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 128MB

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host replication replicator 10.0.0.0/24 md5
    - host all all 10.0.0.0/24 md5
    - host all all 127.0.0.1/32 trust

postgresql:
  listen: 10.0.0.4:5432
  connect_address: 10.0.0.4:5432
  data_dir: /var/lib/postgresql/18/main
  bin_dir: /usr/lib/postgresql/18/bin
  authentication:
    replication:
      username: replicator
      password: replicator_password_CHANGE_ME
    superuser:
      username: postgres
      password: postgres_password_CHANGE_ME

  parameters:
    unix_socket_directories: '/var/run/postgresql'

tags:
    nofailover: false
    noloadbalance: false
    clonefrom: false
    nosync: false
EOF

# pg-node2, pg-node3, pg-node4, pg-node5, Same file but change the name and IP for each node:

# pg-node2:
name: hq-node-02
restapi:
  listen: 10.0.0.5:8008
  connect_address: 10.0.0.5:8008
postgresql:
  listen: 10.0.0.5:5432
  connect_address: 10.0.0.5:5432

# pg-node3:
name: hq-node-03
restapi:
  listen: 10.0.0.6:8008
  connect_address: 10.0.0.6:8008
postgresql:
  listen: 10.0.0.6:5432
  connect_address: 10.0.0.6:5432

# pg-node4:
name: hq-node-04
restapi:
  listen: 10.0.0.7:8008
  connect_address: 10.0.0.7:8008
postgresql:
  listen: 10.0.0.7:5432
  connect_address: 10.0.0.7:5432

# pg-node5:
name: hq-node-05
restapi:
  listen: 10.0.0.8:8008
  connect_address: 10.0.0.8:8008
postgresql:
  listen: 10.0.0.8:5432
  connect_address: 10.0.0.8:5432

# ⚠️ The etcd.hosts, scope, namespace, pg_hba, and passwords values must be identical across all 5 configuration files.


# Create systemd service for Patroni
# On all 5 VMs:

sudo tee /etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni PostgreSQL HA
After=network.target etcd.service

[Service]
Type=simple
User=postgres
ExecStart=/opt/patroni/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -s HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

# The user for the service is postgres (as we specified in the systemd file), so make sure to check the ownership:
sudo chown -R postgres:postgres /var/lib/postgresql/18/main
sudo chown postgres:postgres /etc/patroni/patroni.yml

# Start Patroni on all 5 VMs, but start with pg-node1 first, and don't start the others yet:
sudo systemctl enable --now patroni

# And check the status of the Patroni service:
sudo systemctl status patroni

# Then monitor the logs to see if it is running correctly:
sudo journalctl -u patroni -f

# Sould see the following logs in pg-node1 (the Primary node) after a few seconds:
# INFO: Selected new etcd server
# INFO: doing crash recovery أو INFO: initialized a new cluster
# INFO: postmaster pid=...

# After you make sure that pg-node1 is running and has become the Primary (without errors), start pg-node2:
sudo systemctl enable --now patroni

# And monitor the logs of pg-node2 to see if it is running correctly and has become a Replica of pg-node1 and make pg_basebackup from pg-node1:
sudo journalctl -u patroni -f

# Then same for pg-node3, pg-node4, and pg-node5. Start them one by one, and monitor the logs to make sure they are running correctly and have become Replicas of pg-node1.

# Test the cluster status from any node (for example, from pg-node1):
/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list

# ------------------------- Test the Failover -------------------------

# From another terminal, run the following command to monitor the cluster status continuously (from any node):
watch -n 1 '/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list'

# Then on the primary node (pg-node1), stop the Patroni service to simulate a failure:
sudo systemctl stop patroni

# Monitor the other terminal (the one running the list command) to see if one of the replicas (pg-node2, pg-node3, pg-node4, or pg-node5) has been promoted to Primary.


# Test the Primary (pg-node1):
curl -i http://10.0.0.4:8008/primary
# Expected: HTTP/1.1 200 OK

# Test Replicas (pg-node2, pg-node3, ...):
curl -i http://10.0.0.5:8008/primary
curl -i http://10.0.0.6:8008/primary
# Expected: HTTP/1.1 503 Service Unavailable