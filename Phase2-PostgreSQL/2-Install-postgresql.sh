#!/bin/bash

set -e

# Add the official PostgreSQL APT repository
sudo apt update
sudo apt install -y curl ca-certificates gnupg lsb-release

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update


# Install PostgreSQL I use v18 for example, but you can change it to any version you want.
sudo apt install -y postgresql-18 postgresql-client-18

# ⚠️ previous command will start initdb service and we will disbale it.


# Stop the default PostgreSQL service Prevent it from running automatically. Because the Patroni will manage the PostgreSQL process later, not systemd:
sudo systemctl stop postgresql
sudo systemctl disable postgresql

# remove the data directory that created automatically. Because Patroni needs to start from a completely empty data directory and will initialize it itself later:
sudo rm -rf /var/lib/postgresql/18/main
sudo mkdir -p /var/lib/postgresql/18/main
sudo chown postgres:postgres /var/lib/postgresql/18/main
sudo chmod 700 /var/lib/postgresql/18/main

# Make sure the PostgreSQL binaries are installed correctly 
ls /usr/lib/postgresql/18/bin/

# Sould see the following binaries: pg_ctl, initdb, pg_basebackup and more.