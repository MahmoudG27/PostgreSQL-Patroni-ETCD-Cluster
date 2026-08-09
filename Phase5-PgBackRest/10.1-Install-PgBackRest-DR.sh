#------------------- 1. Install pgBackRest & Set Up SSH Access -------------------

# Install pgBackRest on all 5 PostgreSQL nodes (the tool only):
sudo apt install -y pgbackrest

# Install pgBackRest and create the backup directory on the Backup VM
sudo apt install -y pgbackrest jq
sudo mkdir -p /var/lib/pgbackrest

# On the Backup VM, create a new user called "postgres" (if it doesn't already exist) and set up SSH access for the postgres user on all 5 PostgreSQL nodes. This is necessary for pgBackRest to perform backups over SSH.
sudo useradd -r -m -d /var/lib/postgresql postgres
sudo -u postgres mkdir -p /var/lib/postgresql/.ssh
sudo -u postgres chmod 700 /var/lib/postgresql/.ssh

# On all 5 PostgreSQL nodes Generate SSH key for the postgres user (without passphrase) 
sudo -u postgres ssh-keygen -t ed25519 -N "" -f /var/lib/postgresql/.ssh/id_ed25519
sudo -u postgres cat /var/lib/postgresql/.ssh/id_ed25519.pub

# On Backup node Generate SSH key for the postgres user (without passphrase) 
sudo -u postgres ssh-keygen -t ed25519 -N "" -f /var/lib/postgresql/.ssh/id_ed25519
sudo -u postgres cat /var/lib/postgresql/.ssh/id_ed25519.pub

# On the Backup VM, add the public keys from all 5 PostgreSQL nodes to the authorized_keys file for the postgres user. This allows the Backup VM to connect to each PostgreSQL node via SSH without a password.
# Repeat the following line 5 times (once for each node):
echo "<public-key-from-specific-node>" | sudo -u postgres tee -a /var/lib/postgresql/.ssh/authorized_keys

# On the 5 PostgreSQL nodes, add the public keys from the Backup node to the authorized_keys file for the postgres user.
# Run the following command on each PostgreSQL node (replace `<public-key-from-backup-node>` with the actual public key from the Backup node):
echo "<public-key-from-backup-node>" | sudo -u postgres tee -a /var/lib/postgresql/.ssh/authorized_keys

# Make sure the permissions are correct on the authorized_keys file on any PostgreSQL node:
sudo -u postgres ssh postgres@10.1.0.30 "echo Connected successfully"

# Make sure the permissions are correct on the authorized_keys file on the Backup VM:
sudo -u postgres ssh postgres@10.1.0.4 "echo Connected successfully"
sudo -u postgres ssh postgres@10.1.0.5 "echo Connected successfully"
sudo -u postgres ssh postgres@10.1.0.6 "echo Connected successfully"

#------------------- 2. Create the pgBackRest configuration file -------------------

# Create the configuration file for pgBackRest on the Backup VM.
sudo mkdir -p /var/lib/pgbackrest
sudo chown postgres:postgres /var/lib/pgbackrest

# Note: The above configuration is for the Backup VM only.
sudo tee /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-path=/var/lib/pgbackrest
backup-standby=y  # Take the heavy data from any Replica (Standby) you find, not from the Primary

[pg_cluster_dr]
pg1-host=10.1.0.4  # IP DR Node 1
pg1-path=/var/lib/postgresql/18/main

pg2-host=10.1.0.5  # IP DR Node 2
pg2-path=/var/lib/postgresql/18/main

pg3-host=10.1.0.6  # IP DR Node 3
pg3-path=/var/lib/postgresql/18/main
EOF

# Create the configuration file for the PostgreSQL cluster on all 5 PostgreSQL nodes.
sudo tee /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-host=10.1.0.30  # IP DR Backup Server
repo1-host-user=postgres

[pg_cluster_dr]
pg1-path=/var/lib/postgresql/18/main
EOF

# Create the stanza for the PostgreSQL cluster on the Backup VM. This is done by running the following command on the Backup VM:
sudo -u postgres pgbackrest --stanza=pg_cluster_dr stanza-create

# Configure Patroni to use pgBackRest for WAL archiving. This is done by adding the following lines to the Patroni configuration file (/etc/patroni/patroni.yml) on each PostgreSQL node:
postgresql:
  parameters:
    archive_mode: "on"
    archive_command: "pgbackrest --stanza=pg_cluster_dr archive-push %p"


# ------------------- 3. Set Up a Weekly Full Backup -------------------

# Set up a cron job on the Backup VM to perform a full backup of the PostgreSQL cluster every Sunday at 2:00 AM. This can be done by adding the following line to the crontab for the postgres user: 
0 2 * * 0 pgbackrest --stanza=pg_cluster_dr --type=full backup


# Test the backup by running the following command on the Backup VM. This will create a full backup of the PostgreSQL cluster and display information about the backup.
sudo -u postgres pgbackrest --stanza=pg_cluster_dr --type=full backup
sudo -u postgres pgbackrest --stanza=pg_cluster_dr info

# If you see the backup details (date, size, WAL range), then everything is working correctly from both sides.