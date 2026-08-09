# HAProxy Configuration — HQ PostgreSQL Cluster

This document describes the HAProxy setup for the **HQ PostgreSQL cluster**.

HAProxy acts as the stable PostgreSQL endpoint for applications.

Instead of connecting directly to a specific PostgreSQL node, applications connect to the HAProxy IP/VIP:

```text
Application
     │
     │ PostgreSQL :5432
     ▼
┌──────────────────────┐
│       HAProxy        │
│      HQ VIP/LB       │
└──────────┬───────────┘
           │
           │ Patroni health check
           ▼
     PostgreSQL Cluster
```

The most important responsibility of HAProxy is to ensure that PostgreSQL connections are sent **only to the current Patroni Primary**.

---

# 1. HQ Architecture

The HQ PostgreSQL cluster contains multiple Patroni-managed PostgreSQL nodes.

Example:

```text
HQ Network
10.0.0.0/24
```

PostgreSQL nodes:

```text
hq-node-01 → 10.0.0.4
hq-node-02 → 10.0.0.5
hq-node-03 → 10.0.0.6
```

HAProxy sits in front of the PostgreSQL cluster:

```text
                     HQ

              ┌───────────────┐
              │  Application  │
              └───────┬───────┘
                      │
                      │ TCP :5432
                      ▼
             ┌──────────────────┐
             │     HAProxy      │
             │   HQ VIP / LB    │
             └────────┬─────────┘
                      │
             Patroni /primary check
                      │
          ┌───────────┼───────────┐
          ▼           ▼           ▼
     hq-node-01  hq-node-02  hq-node-03
     10.0.0.4    10.0.0.5    10.0.0.6
          │           │           │
          ▼           ▼           ▼
       Primary      Replica      Replica
```

Only the node currently recognized by Patroni as the **Primary** should receive application write connections.

---

# 2. Install HAProxy

Update the system:

```bash
sudo apt update
sudo apt upgrade -y
```

Install HAProxy:

```bash
sudo apt install -y haproxy
```

Check the installed version:

```bash
haproxy -v
```

---

# 3. Enable and Start HAProxy

Enable HAProxy to start automatically after a reboot:

```bash
sudo systemctl enable --now haproxy
```

Check the service:

```bash
sudo systemctl status haproxy
```

---

# 4. Backup the Original Configuration

Before replacing the default HAProxy configuration:

```bash
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup
```

The original configuration is now available at:

```text
/etc/haproxy/haproxy.cfg.backup
```

---

# 5. HAProxy Configuration

The main configuration file is:

```text
/etc/haproxy/haproxy.cfg
```

Create the configuration:

```bash
sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 4096

defaults
    log global
    mode tcp

    timeout connect 5s
    timeout client 30m
    timeout server 30m

    option tcplog

frontend postgres_write
    bind *:5432
    default_backend postgres_primary

backend postgres_primary
    mode tcp

    option httpchk GET /primary
    http-check expect status 200

    server hq-node-01 10.0.0.4:5432 check port 8008
    server hq-node-02 10.0.0.5:5432 check port 8008
    server hq-node-03 10.0.0.6:5432 check port 8008

frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats refresh 10s
    stats show-legends
EOF
```

---

# 6. Understanding the Configuration

## 6.1 Global Configuration

```haproxy
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 4096
```

### Logging

HAProxy sends logs to the local syslog socket:

```text
/dev/log
```

using the `local0` and `local1` facilities.

Later, rsyslog will be configured to write the HAProxy logs to:

```text
/var/log/haproxy.log
```

### Maximum Connections

```haproxy
maxconn 4096
```

This limits HAProxy to a maximum of approximately 4096 concurrent connections.

This value should be adjusted according to:

* Application connection count
* PostgreSQL `max_connections`
* HAProxy resources
* Connection pooling architecture

---

# 7. Default TCP Configuration

```haproxy
defaults
    log global
    mode tcp

    timeout connect 5s
    timeout client 30m
    timeout server 30m

    option tcplog
```

HAProxy operates in:

```text
TCP mode
```

This is important because PostgreSQL traffic is TCP-based.

The timeouts are:

```text
Connection timeout: 5 seconds
Client timeout:     30 minutes
Server timeout:     30 minutes
```

HAProxy also enables TCP logging:

```haproxy
option tcplog
```

---

# 8. PostgreSQL Frontend

The PostgreSQL frontend is:

```haproxy
frontend postgres_write
    bind *:5432
    default_backend postgres_primary
```

This means HAProxy listens for PostgreSQL connections on:

```text
*:5432
```

Applications therefore connect to HAProxy using:

```text
<HAProxy-VIP>:5432
```

instead of connecting directly to:

```text
10.0.0.4:5432
10.0.0.5:5432
10.0.0.6:5432
```

---

# 9. PostgreSQL Backend

The backend contains all PostgreSQL nodes:

```haproxy
backend postgres_primary
    mode tcp

    option httpchk GET /primary
    http-check expect status 200

    server hq-node-01 10.0.0.4:5432 check port 8008
    server hq-node-02 10.0.0.5:5432 check port 8008
    server hq-node-03 10.0.0.6:5432 check port 8008
```

HAProxy knows about:

```text
hq-node-01 → 10.0.0.4
hq-node-02 → 10.0.0.5
hq-node-03 → 10.0.0.6
```

---

# 10. Patroni Health Check

This is the most important part of the HAProxy configuration:

```haproxy
option httpchk GET /primary
http-check expect status 200
```

Patroni exposes an HTTP REST API on port:

```text
8008
```

The endpoint:

```text
/primary
```

indicates whether the PostgreSQL node is currently the Primary.

HAProxy therefore performs a health check similar to:

```text
HAProxy
   │
   ├── GET http://10.0.0.4:8008/primary
   │
   ├── GET http://10.0.0.5:8008/primary
   │
   └── GET http://10.0.0.6:8008/primary
```

The expected response is:

```text
HTTP/1.1 200 OK
```

for the current Primary.

---

# 11. How HAProxy Detects the Primary

Imagine the current Patroni state is:

```text
hq-node-01 → Primary
hq-node-02 → Replica
hq-node-03 → Replica
```

HAProxy performs:

```text
hq-node-01:8008/primary
        ↓
     200 OK
        ↓
     PRIMARY
```

while:

```text
hq-node-02:8008/primary
        ↓
     503
        ↓
     REPLICA
```

and:

```text
hq-node-03:8008/primary
        ↓
     503
        ↓
     REPLICA
```

Therefore:

```text
Application
     │
     ▼
HAProxy
     │
     ├── hq-node-01 → ✅ Primary
     │
     ├── hq-node-02 → ❌ Replica
     │
     └── hq-node-03 → ❌ Replica
```

Application connections are sent to:

```text
hq-node-01
```

---

# 12. Automatic Failover

One of the major benefits of this design is that HAProxy does not need to know in advance which PostgreSQL node will become Primary.

Suppose:

```text
Before failure:

hq-node-01 → Primary
hq-node-02 → Replica
hq-node-03 → Replica
```

If `hq-node-01` fails, Patroni may promote:

```text
hq-node-02 → Primary
```

The topology becomes:

```text
hq-node-01 → Down
hq-node-02 → Primary
hq-node-03 → Replica
```

HAProxy continues checking:

```text
hq-node-01:8008/primary → ❌
hq-node-02:8008/primary → ✅ 200
hq-node-03:8008/primary → ❌
```

Therefore HAProxy automatically routes new PostgreSQL connections to:

```text
hq-node-02
```

The application continues using the same endpoint:

```text
HAProxy-VIP:5432
```

The application does not need to know which PostgreSQL node is currently Primary.

---

# 13. HAProxy + Patroni Failover Flow

The complete flow is:

```text
                Application
                     │
                     │ PostgreSQL :5432
                     ▼
              ┌──────────────┐
              │    HAProxy   │
              └──────┬───────┘
                     │
              Patroni /primary
                     │
          ┌──────────┼──────────┐
          ▼          ▼          ▼
       Node 01    Node 02    Node 03
       Primary    Replica    Replica
```

After a failure:

```text
       Node 01
        ❌ DOWN
          │
          ▼
       Patroni
          │
          ▼
       Node 02
       PRIMARY
          │
          ▼
       HAProxy
          │
          ▼
     Application
```

---

# 14. Important: HAProxy Does Not Perform Failover

HAProxy itself does **not** promote PostgreSQL.

The responsibilities are separated:

```text
Patroni
   │
   ├── Manages PostgreSQL
   ├── Detects failures
   ├── Performs leader election
   └── Promotes a Replica
```

while:

```text
HAProxy
   │
   ├── Checks Patroni
   ├── Detects the current Primary
   └── Routes connections to it
```

So:

```text
Patroni = PostgreSQL HA / Failover

HAProxy = Traffic Routing
```

---

# 15. HAProxy Statistics

The configuration also exposes an HAProxy statistics page:

```haproxy
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats refresh 10s
    stats show-legends
```

HAProxy statistics are available on:

```text
http://<HAProxy-IP>:8404/stats
```

The page can be used to monitor:

* HAProxy status
* Backend health
* PostgreSQL server status
* Active connections
* Session counts
* Server availability

---

# 16. Example HAProxy Statistics

Conceptually, the backend may look like:

```text
Backend: postgres_primary

Server          Status
--------------------------------
hq-node-01      UP
hq-node-02      DOWN
hq-node-03      UP
```

Or:

```text
Server          Health
--------------------------------
hq-node-01      UP / Primary
hq-node-02      UP / Replica
hq-node-03      UP / Replica
```

The exact information displayed depends on the HAProxy version and configuration.

---

# 17. Prometheus Monitoring

The HAProxy statistics endpoint can also be used as part of a monitoring architecture.

For example:

```text
HAProxy
   │
   │ :8404/stats
   ▼
Monitoring / Exporter
   │
   ▼
Prometheus
   │
   ▼
Grafana
```

This can be used to monitor:

* Active connections
* Backend health
* Server availability
* Connection rates
* HAProxy errors
* PostgreSQL backend status

---

# 18. Validate the HAProxy Configuration

Before restarting HAProxy, always validate the configuration:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

Expected result:

```text
Configuration file is valid
```

Do not restart HAProxy if the configuration validation fails.

---

# 19. Restart HAProxy

After a successful validation:

```bash
sudo systemctl restart haproxy
```

Check:

```bash
sudo systemctl status haproxy
```

---

# 20. Enable HAProxy at Boot

HAProxy should remain enabled:

```bash
sudo systemctl enable haproxy
```

Verify:

```bash
systemctl is-enabled haproxy
```

Expected:

```text
enabled
```

---

# 21. HAProxy Logging

The configuration uses:

```haproxy
log /dev/log local0
```

Ubuntu does not necessarily route `local0` HAProxy messages to a dedicated log file automatically.

Therefore, configure rsyslog.

Create:

```text
/etc/rsyslog.d/49-haproxy.conf
```

with:

```bash
sudo tee /etc/rsyslog.d/49-haproxy.conf > /dev/null <<'EOF'
local0.*    /var/log/haproxy.log
EOF
```

Restart rsyslog:

```bash
sudo systemctl restart rsyslog
```

---

# 22. Monitor HAProxy Logs

Follow the HAProxy log:

```bash
sudo tail -f /var/log/haproxy.log
```

You can use this to troubleshoot:

* Client connection problems
* Backend connection failures
* Health-check failures
* Server state changes
* HAProxy connection activity

---

# 23. Complete HQ HAProxy Architecture

The final architecture is:

```text
                         APPLICATIONS
                              │
                              │
                              ▼
                     ┌─────────────────┐
                     │  HQ HAProxy VIP │
                     │     :5432       │
                     └────────┬────────┘
                              │
                              │ TCP
                              ▼
                    ┌───────────────────┐
                    │ postgres_primary  │
                    └─────────┬─────────┘
                              │
                     Patroni /primary
                         Health Check
                              │
             ┌────────────────┼────────────────┐
             │                │                │
             ▼                ▼                ▼
       ┌──────────┐     ┌──────────┐     ┌──────────┐
       │hq-node-01│     │hq-node-02│     │hq-node-03│
       │10.0.0.4  │     │10.0.0.5  │     │10.0.0.6  │
       │  Primary │     │  Replica │     │  Replica │
       │ :5432    │     │ :5432    │     │ :5432    │
       │ :8008    │     │ :8008    │     │ :8008    │
       └──────────┘     └──────────┘     └──────────┘

                              │
                              │
                              ▼
                     ┌─────────────────┐
                     │ HAProxy Stats   │
                     │     :8404       │
                     │     /stats      │
                     └─────────────────┘
```

---

# 24. Failover Example

### Before Failure

```text
HAProxy
   │
   ├── hq-node-01 → 200 → PRIMARY ✅
   ├── hq-node-02 → 503 → REPLICA
   └── hq-node-03 → 503 → REPLICA

Application → hq-node-01
```

### hq-node-01 Fails

```text
hq-node-01 → ❌
```

Patroni promotes:

```text
hq-node-02 → PRIMARY
```

### After Failover

```text
HAProxy
   │
   ├── hq-node-01 → ❌ DOWN
   ├── hq-node-02 → 200 → PRIMARY ✅
   └── hq-node-03 → 503 → REPLICA

Application → hq-node-02
```

The application still connects to:

```text
HAProxy-VIP:5432
```

No PostgreSQL node IP needs to be changed in the application.

---

# 25. DR Consideration

During a complete HQ disaster, the application may be moved to the DR HAProxy/VIP.

The architecture then becomes:

```text
              APPLICATION
                   │
                   ▼
              DR HAProxy
                   │
                   ▼
              DR Primary
```

While HQ is unavailable:

```text
HQ = DOWN
DR = PRIMARY
```

When HQ returns, the HQ HAProxy must **not** expose an old HQ Primary to applications.

The recovery procedure should first make HQ a Standby of DR.

The safe state is:

```text
DR = Primary
HQ = Standby
```

Only after a controlled failback should application traffic be moved back to:

```text
HQ HAProxy VIP
```

---

# 26. Operational Checklist

After installing or modifying HAProxy, verify:

* [ ] HAProxy is installed.
* [ ] HAProxy service is enabled.
* [ ] `/etc/haproxy/haproxy.cfg` exists.
* [ ] Original configuration has been backed up.
* [ ] PostgreSQL backend IPs are correct.
* [ ] Patroni REST API uses port `8008`.
* [ ] `/primary` health check is configured.
* [ ] HAProxy configuration passes validation.
* [ ] HAProxy service is running.
* [ ] PostgreSQL port `5432` is reachable.
* [ ] HAProxy statistics are available on port `8404`.
* [ ] rsyslog configuration exists.
* [ ] `/var/log/haproxy.log` is receiving logs.
* [ ] Application connects to the HAProxy VIP instead of a PostgreSQL node directly.

---

# 27. Important Rules

### Rule 1 — Applications should use HAProxy

Do not configure applications with:

```text
10.0.0.4:5432
10.0.0.5:5432
10.0.0.6:5432
```

Instead:

```text
HQ-HAProxy-VIP:5432
```

---

### Rule 2 — HAProxy should use Patroni for Primary Detection

The health check should use:

```text
GET /primary
```

on:

```text
:8008
```

---

### Rule 3 — Do Not Route Writes to Replicas

A PostgreSQL Replica should return:

```text
503 Service Unavailable
```

from:

```text
/primary
```

Therefore HAProxy should not consider it eligible for the `postgres_primary` backend.

---

### Rule 4 — Patroni Performs the Failover

HAProxy does not decide which PostgreSQL node becomes Primary.

The responsibility is:

```text
Patroni → Failover
HAProxy → Routing
```

---

# 28. Final Result

The final HQ architecture provides:

```text
                    Application
                         │
                         ▼
                  HQ HAProxy VIP
                         │
                         ▼
                Patroni Health Check
                         │
              ┌──────────┼──────────┐
              │          │          │
              ▼          ▼          ▼
           Primary    Replica    Replica
              │
              ▼
          PostgreSQL
```

If the Primary fails:

```text
Patroni
   │
   ▼
Promotes Replica
   │
   ▼
HAProxy detects /primary = 200
   │
   ▼
Routes new connections to new Primary
```

This allows the application to use **one stable PostgreSQL endpoint** while Patroni manages PostgreSQL failover underneath it.
