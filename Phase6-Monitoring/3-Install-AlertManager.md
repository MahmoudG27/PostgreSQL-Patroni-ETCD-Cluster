# Alertmanager — Installation & Setup

Alertmanager will be installed on the Monitoring Server and will work with Prometheus to handle alerts.

Architecture:

```text
PostgreSQL / Patroni / HAProxy / Linux
                │
                ▼
            Prometheus
                │
                │ Alerts
                ▼
           Alertmanager
              :9093
                │
                ▼
        Notification Channels
```

---

# 1. Update the System

```bash
sudo apt update
sudo apt upgrade -y
```

---

# 2. Create Alertmanager User

Create a dedicated system user:

```bash
sudo useradd \
  --no-create-home \
  --shell /bin/false \
  alertmanager
```

Alertmanager will run using this user instead of `root`.

---

# 3. Install Alertmanager

Set the Alertmanager version:

```bash
ALERTMANAGER_VERSION="0.33.1"
```

Download the release:

```bash
wget https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
```

Extract it:

```bash
tar xvf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
```

Move the binaries:

```bash
sudo mv \
  alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/alertmanager \
  /usr/local/bin/

sudo mv \
  alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/amtool \
  /usr/local/bin/
```

Set ownership:

```bash
sudo chown alertmanager:alertmanager /usr/local/bin/alertmanager
sudo chown alertmanager:alertmanager /usr/local/bin/amtool
```

Verify:

```bash
alertmanager --version
```

---

# 4. Create Alertmanager Configuration

Create the configuration directory:

```bash
sudo mkdir -p /etc/alertmanager
```

Create the configuration file:

```bash
sudo tee /etc/alertmanager/alertmanager.yml > /dev/null <<'EOF'
global:
  resolve_timeout: 5m

route:
  receiver: "default"

receivers:
  - name: "default"
EOF
```

Set ownership:

```bash
sudo chown -R alertmanager:alertmanager /etc/alertmanager
```

The configuration file is:

```text
/etc/alertmanager/alertmanager.yml
```

---

# 5. Create Alertmanager Systemd Service

Create:

```bash
sudo tee /etc/systemd/system/alertmanager.service > /dev/null <<'EOF'
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
WorkingDirectory=/etc/alertmanager/

ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --web.external-url=http://0.0.0.0:9093

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
```

---

# 6. Enable and Start Alertmanager

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Enable Alertmanager at boot and start it:

```bash
sudo systemctl enable --now alertmanager
```

Check the service:

```bash
sudo systemctl status alertmanager
```

Expected:

```text
Active: active (running)
```

---

# 7. Access Alertmanager

Alertmanager listens on port:

```text
9093
```

Access the Web UI:

```text
http://<MONITORING-SERVER-IP>:9093
```

For example:

```text
http://10.0.0.20:9093
```

Check that the port is listening:

```bash
sudo ss -lntp | grep 9093
```

---

# 8. Check Alertmanager Logs

Monitor the logs:

```bash
sudo journalctl -u alertmanager -f
```

Or view the latest logs:

```bash
sudo journalctl -u alertmanager --no-pager -n 100
```

---

# 9. Prometheus + Alertmanager

Prometheus is responsible for evaluating alert rules.

When an alert fires, Prometheus sends it to Alertmanager:

```text
                    Prometheus
                        │
                        │ Alert
                        ▼
                   Alertmanager
                        │
             ┌──────────┼──────────┐
             │          │          │
             ▼          ▼          ▼
           Email      Slack      Other
       Notifications Notifications Channels
```

Alertmanager handles:

* Alert grouping
* Deduplication
* Silencing
* Alert routing
* Notifications

---

# 10. Clean Up

After installation, remove the extracted files:

```bash
rm -rf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64
rm -f alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
```

---

# 11. Basic Verification Checklist

* [ ] Alertmanager user created.
* [ ] Alertmanager installed.
* [ ] `amtool` installed.
* [ ] `/etc/alertmanager/alertmanager.yml` created.
* [ ] Correct ownership configured.
* [ ] systemd service created.
* [ ] Alertmanager service running.
* [ ] Alertmanager enabled at boot.
* [ ] Port `9093` accessible.
* [ ] Prometheus configured to send alerts to Alertmanager.
* [ ] Notification receiver configured.