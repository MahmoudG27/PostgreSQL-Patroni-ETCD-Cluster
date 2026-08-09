# The PostgreSQL Apt repository supports the current versions of Ubuntu:

resolute (26.04, LTS)
noble (24.04, LTS)
jammy (22.04, LTS)

# To change hostname
# bash:
sudo hostnamectl set-hostname nodex
ping node2

# -------------------------- Install Patroni inside venv ---------------------------

# Create venv location:
sudo mkdir /opt/patroni
sudo python3 -m venv /opt/patroni

# Install Patroni:
sudo /opt/patroni/bin/pip install --upgrade pip

# Then:
sudo /opt/patroni/bin/pip install "patroni[etcd]" psycopg2

# Make sure:
/opt/patroni/bin/patroni --version

# Check the tool works coorectly:
/opt/patroni-venv/bin/patronictl -c /etc/patroni/patroni.yml list

# Update spesific libarary: 
sudo /opt/patroni-venv/bin/pip install --upgrade patroni

# Show installed libararies and versions:
/opt/patroni-venv/bin/pip list

# To delete venv:
sudo rm -rf /opt/patroni-venv

# Connect with systemd:
[Service]
ExecStart=/opt/patroni-venv/bin/patroni /etc/patroni/patroni.yml

# Alias to avoid write the full path
echo "alias patronictl='/opt/patroni-venv/bin/patronictl -c /etc/patroni/patroni.yml'" >> ~/.bashrc
source ~/.bashrc

# Cluster Server
    ├── PostgreSQL :5432
    ├── Patroni :8008
    └── Node Exporter :9100

# Monitoring Server
    ├── Prometheus :9090
    ├── Alertmanager :9093
    └── Grafana :3000


قائمة الـ Exporters الكاملة اللي محتاجينها في HQ

خليني ألخصلك كل حاجة في جدول واحد، لأن كل exporter بيراقب طبقة مختلفة تمامًا:

# The Exporters
    ├── node_exporter:      for OS (CPU, RAM, Disk, Network) on all VMs
    ├── postgres_exporter:  for PostgreSQL (connections, transactions, locks, table sizes) on the PostgreSQL nodes 5 only
    ├── Patroni /metrics:   for Cluster situation (who is Primary and node situation, replication lag) No installation required - it's already built into Patroni itself
    ├── etcd /metrics:      for ETCD health (quorum, leader election) No installation required - it's already built into ETCD itself
    └── haproxy_exporter:   for reads Stats page from HAproxy

# Monitoring the Backup (Backup Status)
# Dashboards required "Backup job status (success/failure, last successful backup timestamp)" but there is no exporter for pgBackRest

## Common solution: node_exporter + Textfile Collector

# node_exporter has a feature called Textfile Collector – it lets you write any information as simple text in a file, and node_exporter reads it and automatically converts it to metric format. In other words:
1. Run a simple script after each backup (on the Backup VM) and write the result to a text file:
echo "pgbackrest_last_backup_success 1" > /var/lib/node_exporter/textfile_collector/pgbackrest.prom
echo "pgbackrest_last_backup_timestamp $(date +%s)" >> /var/lib/node_exporter/textfile_collector/pgbackrest.prom

2. Enable this feature in the node_exporter of the Backup VM only (flag --collector.textfile.directory)
# Note: This is not a new, separate exporter - it is an additional use of the same node_exporter that already exists on the Backup VM.