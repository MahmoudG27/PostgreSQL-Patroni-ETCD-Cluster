# PostgreSQL 18 Installation & Preparation for Patroni

This guide installs **PostgreSQL 18** from the official PostgreSQL APT repository and prepares the server for **Patroni**.

> **Note:** The commands below use PostgreSQL 18 as an example. You can replace `18` with another PostgreSQL version if needed.

---

## 1. Add the Official PostgreSQL APT Repository

First, update the system and install the required packages:

```bash
sudo apt update
sudo apt install -y curl ca-certificates gnupg lsb-release
```

Download and install the official PostgreSQL repository signing key:

```bash
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
```

Add the PostgreSQL APT repository:

```bash
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
```

Update the package lists:

```bash
sudo apt update
```

---

## 2. Install PostgreSQL 18

Install the PostgreSQL 18 server and client packages:

```bash
sudo apt install -y postgresql-18 postgresql-client-18
```

> **Important:** Installing PostgreSQL will automatically create a default PostgreSQL cluster and start the PostgreSQL service.

Since **Patroni** will manage the PostgreSQL process later, we need to stop and disable the default PostgreSQL service.

---

## 3. Drop the Default PostgreSQL Cluster

During installation, Debian/Ubuntu automatically creates a default PostgreSQL cluster named `main` and starts its `systemd` service.
Since **Patroni** will initialize and manage the cluster, we must remove this default cluster. 

The cleanest way to do this on Debian/Ubuntu is using the `pg_dropcluster` utility:

```bash
sudo pg_dropcluster 18 main --stop
```

---

## 4. Create an Empty Data Directory for Patroni

Patroni needs a clean, empty directory with the correct permissions to initialize the new cluster:

```Bash
sudo mkdir -p /var/lib/postgresql/18/main
sudo chown postgres:postgres /var/lib/postgresql/18/main
sudo chmod 700 /var/lib/postgresql/18/main
```

---

## 5. Verify PostgreSQL Binaries

Make sure the PostgreSQL 18 binaries were installed correctly:

```bash
ls /usr/lib/postgresql/18/bin/
```

You should see binaries such as:

```text
pg_ctl
initdb
pg_basebackup
psql
postgres
pg_dump
pg_restore
...
```

These binaries will later be used by **Patroni** to initialize and manage PostgreSQL.

---

## 6. Complete Installation Script

If you want to run all the steps together, you can use the following script:

```bash
#!/bin/bash
set -e

# PostgreSQL version
PG_VERSION=18

# Add the official PostgreSQL APT repository
sudo apt update
sudo apt install -y curl ca-certificates gnupg lsb-release

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update

# Install PostgreSQL
sudo apt install -y postgresql-${PG_VERSION} postgresql-client-${PG_VERSION}

# Stop and remove the default PostgreSQL cluster cleanly
sudo pg_dropcluster ${PG_VERSION} main --stop

# Create an empty data directory for Patroni
sudo mkdir -p /var/lib/postgresql/${PG_VERSION}/main
sudo chown postgres:postgres /var/lib/postgresql/${PG_VERSION}/main
sudo chmod 700 /var/lib/postgresql/${PG_VERSION}/main

# Verify PostgreSQL binaries
ls /usr/lib/postgresql/${PG_VERSION}/bin/
```

---

## 7. Expected Result

After completing these steps:

1. PostgreSQL 18 is installed.
2. The official PostgreSQL APT repository is configured.
3. The default PostgreSQL service is stopped.
4. PostgreSQL is disabled from starting automatically with `systemd`.
5. The default PostgreSQL data directory has been removed.
6. A clean data directory has been created for Patroni.
7. The directory is owned by `postgres:postgres` with permissions `700`.
8. PostgreSQL binaries such as `initdb`, `pg_ctl`, and `pg_basebackup` are available.

The server is now prepared for the next step: **configuring Patroni to initialize and manage PostgreSQL**.
