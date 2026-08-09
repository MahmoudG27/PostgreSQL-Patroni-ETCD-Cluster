# Grafana — Installation & Setup

Grafana will be installed on the Monitoring Server and used to visualize the metrics collected by Prometheus.

Architecture:

```text
PostgreSQL / Patroni / HAProxy / Linux
                │
                ▼
            Prometheus
             :9090
                │
                ▼
             Grafana
              :3000
```

---

# 1. Update the System

```bash
sudo apt update
sudo apt upgrade -y
```

---

# 2. Install Required Dependencies

```bash
sudo apt-get install -y \
  apt-transport-https \
  wget \
  gnupg
```

---

# 3. Add the Grafana Repository

Create the keyrings directory:

```bash
sudo mkdir -p /etc/apt/keyrings
```

Download the Grafana GPG key:

```bash
sudo wget -O /etc/apt/keyrings/grafana.asc \
  https://apt.grafana.com/gpg-full.key
```

Set the correct permissions:

```bash
sudo chmod 644 /etc/apt/keyrings/grafana.asc
```

Add the Grafana repository:

```bash
echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list
```

Update the package index:

```bash
sudo apt update
```

---

# 4. Install Grafana

```bash
sudo apt install -y grafana
```

---

# 5. Enable and Start Grafana

Enable Grafana at boot and start the service:

```bash
sudo systemctl enable --now grafana-server
```

Check the service status:

```bash
sudo systemctl status grafana-server
```

Expected:

```text
Active: active (running)
```

---

# 6. Access Grafana

Grafana uses port:

```text
3000
```

Access it from a browser:

```text
http://<MONITORING-SERVER-IP>:3000
```

For example:

```text
http://10.0.0.20:3000
```

---

# 7. Verify Grafana

Check that Grafana is listening:

```bash
sudo ss -lntp | grep 3000
```

Check logs if needed:

```bash
sudo journalctl -u grafana-server -f
```

---

# 8. Grafana + Prometheus

After Grafana is running, add Prometheus as a **Data Source**.

Prometheus URL:

```text
http://localhost:9090
```

or, if Prometheus is running on another server:

```text
http://<PROMETHEUS-SERVER-IP>:9090
```

The final monitoring flow will be:

```text
                    PostgreSQL
                    Patroni
                    HAProxy
                    Linux
                       │
                       ▼
                   Exporters
                       │
                       ▼
                  Prometheus
                    :9090
                       │
                       ▼
                    Grafana
                     :3000
                       │
                       ▼
                  Dashboards
```

---

# 9. Basic Verification Checklist

* [ ] Grafana repository added.
* [ ] Grafana installed.
* [ ] `grafana-server` service running.
* [ ] Grafana enabled at boot.
* [ ] Port `3000` accessible.
* [ ] Prometheus added as a Data Source.
* [ ] Grafana dashboards configured.