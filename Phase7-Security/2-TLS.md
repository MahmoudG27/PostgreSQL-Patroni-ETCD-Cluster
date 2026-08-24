# TLS for PostgreSQL, Patroni and etcd

Closes the Scope of Work requirement:

```text
"Use of TLS for database and management traffic where feasible."
```

Today **nothing** in the platform is encrypted in transit. PostgreSQL client and replication traffic, the Patroni REST API, and etcd all run in cleartext — including the replication stream that crosses between the HQ and DR sites.

Do this **after** `1-Authentication-and-RBAC.md`. TLS is the more disruptive change and it is easier to debug once authentication is already correct.

---

# 1. Order of Work

Enable TLS in this order. Each layer is independent, and doing them one at a time means a failure is easy to isolate.

```text
1. PostgreSQL           lowest risk, biggest win (replication traffic)
2. Patroni REST API     needs a matching HAProxy change
3. etcd                 highest risk, requires a full cluster restart
```

---

# 2. Certificate Strategy — Decide First

Three options, in order of preference:

```text
1. The client's existing internal PKI
   Best. Ask for it in the first meeting. Certificates are issued and renewed by
   a process they already own.

2. A private CA created for this platform
   Good. One CA certificate distributed to every node, one server certificate
   per node. Full hostname verification works.

3. Self-signed certificates per node
   Acceptable only for the demo. Clients cannot verify the server identity, so
   sslmode=verify-full is impossible and you lose protection against
   man-in-the-middle.
```

The steps below build option 2, which is what you should demo.

> **Ask the client: do you have an internal CA?**
>
> If yes, everything below reduces to "submit a CSR and install the result", and
> you skip section 3 entirely.

---

# 3. Create a Private CA

Do this once, on a machine that is not a cluster node — the CA private key must not live on a database server.

```bash
mkdir -p ~/pgca && cd ~/pgca

# CA private key
openssl genrsa -out ca.key 4096
chmod 600 ca.key

# CA certificate, valid 10 years
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt \
  -subj "/C=EG/O=PostgreSQL HA Platform/CN=PostgreSQL Platform Root CA"
```

`ca.crt` is distributed to every node. `ca.key` never leaves this machine.

---

# 4. Issue a Certificate per Node

Repeat for each node, changing the name and IP.

```bash
NODE=hq-node-01
IP=10.0.0.4

# Key
openssl genrsa -out ${NODE}.key 2048
chmod 600 ${NODE}.key

# Signing request
openssl req -new -key ${NODE}.key -out ${NODE}.csr \
  -subj "/C=EG/O=PostgreSQL HA Platform/CN=${NODE}"

# Subject Alternative Names — required by modern clients.
# Include the hostname, the IP, and the HAProxy VIP that clients actually connect to.
cat > ${NODE}.ext <<EXT
subjectAltName = DNS:${NODE},IP:${IP},IP:10.0.0.100
extendedKeyUsage = serverAuth
EXT

# Sign
openssl x509 -req -in ${NODE}.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out ${NODE}.crt -days 825 -sha256 -extfile ${NODE}.ext
```

> **Include the HAProxy address in the SAN.**
>
> Applications connect to `10.0.0.100`, not to the node directly. Without that IP
> in the SAN, `sslmode=verify-full` fails on every client even though the
> certificate is otherwise valid.

Verify:

```bash
openssl x509 -in ${NODE}.crt -noout -text | grep -A1 "Subject Alternative Name"
openssl verify -CAfile ca.crt ${NODE}.crt
```

---

# 5. Install the Certificates

On each node:

```bash
sudo mkdir -p /etc/postgresql/ssl

sudo cp hq-node-01.crt /etc/postgresql/ssl/server.crt
sudo cp hq-node-01.key /etc/postgresql/ssl/server.key
sudo cp ca.crt         /etc/postgresql/ssl/root.crt

sudo chown -R postgres:postgres /etc/postgresql/ssl
sudo chmod 700 /etc/postgresql/ssl
sudo chmod 600 /etc/postgresql/ssl/server.key
sudo chmod 644 /etc/postgresql/ssl/server.crt /etc/postgresql/ssl/root.crt
```

> PostgreSQL refuses to start if `server.key` is group- or world-readable. This is
> the single most common TLS startup failure.

---

# 6. Enable TLS in PostgreSQL

Via `patronictl edit-config`, so the change reaches every node:

```yaml
postgresql:
  parameters:
    ssl: "on"
    ssl_cert_file: /etc/postgresql/ssl/server.crt
    ssl_key_file: /etc/postgresql/ssl/server.key
    ssl_ca_file: /etc/postgresql/ssl/root.crt
    ssl_min_protocol_version: "TLSv1.2"
    ssl_prefer_server_ciphers: "on"
```

`ssl` requires a **restart**, not a reload. Patroni will flag every node with `pending_restart` — the Patroni dashboard already tracks this.

Roll the restart, replicas first:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml restart pg_cluster_hq hq-node-02
# wait for streaming, then the next replica, then switchover and restart the old leader
```

Verify:

```sql
SHOW ssl;                       -- on
SELECT * FROM pg_stat_ssl;      -- one row per connection, ssl = t
```

---

# 7. Require TLS in `pg_hba`

TLS being *available* is not TLS being *used*. Until you change `pg_hba`, clients can still connect in cleartext.

Change `host` to `hostssl` via `edit-config`:

```yaml
postgresql:
  pg_hba:
    - local    all           all                     peer

    # Replication must be encrypted — this is the cross-site traffic
    - hostssl  replication   replicator  10.0.0.0/24 scram-sha-256
    - hostssl  replication   replicator  10.1.0.0/24 scram-sha-256

    - hostssl  all           monitoring  10.0.0.0/24 scram-sha-256
    - hostssl  all           app_user    10.0.0.0/24 scram-sha-256
    - hostssl  all           report_user 10.0.0.0/24 scram-sha-256
    - hostssl  all           postgres    10.0.0.0/24 scram-sha-256
```

> **Change `pg_hba` in two stages.**
>
> Switching every rule to `hostssl` at once will lock out any client that has not
> been updated. Add the `hostssl` rules first, leave the `host` rules in place,
> confirm from `pg_stat_ssl` that everything has moved to TLS, and only then
> remove the plaintext rules.

Check who is still connecting without TLS:

```sql
SELECT a.usename, a.client_addr, s.ssl, s.version
FROM pg_stat_ssl s
JOIN pg_stat_activity a USING (pid)
WHERE a.backend_type = 'client backend';
```

---

# 8. Client Verification Modes

Tell the client's application team which mode to use:

```text
sslmode=disable      no TLS at all
sslmode=require      encrypted, but the server identity is NOT checked
sslmode=verify-ca    encrypted, and the CA is verified
sslmode=verify-full  encrypted, CA verified, AND hostname matched  ← target
```

`verify-full` is the only mode that actually prevents man-in-the-middle. It requires `ca.crt` on the client and the connection host to appear in the certificate SAN — which is why section 4 includes the HAProxy IP.

```bash
psql "host=10.0.0.100 port=5432 dbname=appdb user=app_user \
      sslmode=verify-full sslrootcert=/etc/ssl/certs/pg-ca.crt"
```

To also require client certificates, add `clientcert=verify-ca` to the `pg_hba` line. Only do this if the client asks for mutual TLS — it adds real certificate distribution work.

---

# 9. TLS for the Patroni REST API

Add to `patroni.yml` on every node, alongside the authentication from `1-Authentication-and-RBAC.md`:

```yaml
restapi:
  listen: 10.0.0.4:8008
  connect_address: 10.0.0.4:8008
  certfile: /etc/patroni/ssl/patroni.crt
  keyfile: /etc/patroni/ssl/patroni.key
  cafile: /etc/patroni/ssl/ca.crt
  authentication:
    username: patroni
    password: "CHANGE_ME"

ctl:
  cacert: /etc/patroni/ssl/ca.crt
  authentication:
    username: patroni
    password: "CHANGE_ME"
```

The `ctl:` block is what `patronictl` itself uses. Without it, `patronictl list` fails once the API is on HTTPS.

Restart Patroni node by node, then verify:

```bash
curl -s --cacert /etc/patroni/ssl/ca.crt https://10.0.0.4:8008/primary
```

---

# 10. Update HAProxy After Enabling REST API TLS

**This breaks HAProxy if you forget it.** The health check is an HTTP GET against port 8008 — once that port is HTTPS, every check fails and HAProxy marks all servers DOWN.

In `/etc/haproxy/haproxy.cfg`, add `check-ssl verify none` to each server line:

```haproxy
backend postgres_primary
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions

    server hq-node-01 10.0.0.4:5432 check port 8008 check-ssl verify none
    server hq-node-02 10.0.0.5:5432 check port 8008 check-ssl verify none
    server hq-node-03 10.0.0.6:5432 check port 8008 check-ssl verify none
```

To verify the certificate properly instead of skipping it:

```haproxy
    server hq-node-01 10.0.0.4:5432 check port 8008 check-ssl \
           ca-file /etc/haproxy/ssl/ca.crt
```

Validate and reload:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl reload haproxy
```

Then confirm every server is UP again on the stats page and in the HAProxy dashboard:

```bash
curl -s http://10.0.0.100:8404/stats
```

---

# 11. TLS for etcd

The highest-risk step, because etcd holds the cluster state and every Patroni depends on it. Do this in a maintenance window, and practise it on the demo cluster first.

Issue certificates with **both** `serverAuth` and `clientAuth`, since etcd members are clients of each other:

```bash
NODE=hq-node-01
IP=10.0.0.4

cat > etcd-${NODE}.ext <<EXT
subjectAltName = DNS:${NODE},IP:${IP},IP:127.0.0.1
extendedKeyUsage = serverAuth,clientAuth
EXT
```

Install to `/etc/etcd/ssl/` owned by the etcd user, mode 600 on keys.

Update the etcd configuration on each node:

```yaml
listen-peer-urls: https://10.0.0.4:2380
listen-client-urls: https://10.0.0.4:2379,https://127.0.0.1:2379
initial-advertise-peer-urls: https://10.0.0.4:2380
advertise-client-urls: https://10.0.0.4:2379

initial-cluster: hq-node-01=https://10.0.0.4:2380,hq-node-02=https://10.0.0.5:2380,hq-node-03=https://10.0.0.6:2380

client-transport-security:
  cert-file: /etc/etcd/ssl/server.crt
  key-file: /etc/etcd/ssl/server.key
  trusted-ca-file: /etc/etcd/ssl/ca.crt
  client-cert-auth: true

peer-transport-security:
  cert-file: /etc/etcd/ssl/peer.crt
  key-file: /etc/etcd/ssl/peer.key
  trusted-ca-file: /etc/etcd/ssl/ca.crt
  peer-client-cert-auth: true
```

Note that `initial-cluster` changes from `http://` to `https://` — and it must be identical on all nodes.

Then point Patroni at the new endpoints in `patroni.yml`:

```yaml
etcd3:
  protocol: https
  cacert: /etc/etcd/ssl/ca.crt
  cert: /etc/etcd/ssl/client.crt
  key: /etc/etcd/ssl/client.key
  hosts:
    - 10.0.0.4:2379
    - 10.0.0.5:2379
    - 10.0.0.6:2379
```

And update the Prometheus scrape job, which currently uses plain HTTP:

```yaml
  - job_name: "etcd_hq"
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/ssl/ca.crt
      cert_file: /etc/prometheus/ssl/client.crt
      key_file: /etc/prometheus/ssl/client.key
    static_configs:
      - targets: ["10.0.0.4:2379", "10.0.0.5:2379", "10.0.0.6:2379"]
        labels:
          site: "hq"
```

Verify:

```bash
etcdctl --endpoints=https://10.0.0.4:2379 \
  --cacert=/etc/etcd/ssl/ca.crt \
  --cert=/etc/etcd/ssl/client.crt \
  --key=/etc/etcd/ssl/client.key \
  endpoint health --cluster
```

> **Order matters.**
>
> Bring all etcd members onto TLS together — a mixed HTTP/HTTPS cluster will not
> form quorum. Stop all etcd, change all configs, start all etcd, confirm quorum,
> and only then restart Patroni.

---

# 12. Certificate Expiry — Do Not Skip This

Certificates issued in section 4 last 825 days. A silently expired certificate takes the cluster down exactly as hard as a failed disk, and it will happen long after this project ends.

Hand the client:

```text
* The expiry date of every certificate issued
* The renewal procedure (re-run section 4, install, reload)
* A monitoring alert that fires well before expiry
```

The blackbox exporter can watch expiry, or a small textfile-collector script on each node — the same pattern already used for pgBackRest in `Phase6-Monitoring/11-monitoring-Backup.sh`:

```bash
CERT=/etc/postgresql/ssl/server.crt
EXP=$(date -d "$(openssl x509 -enddate -noout -in $CERT | cut -d= -f2)" +%s)
echo "ssl_cert_expiry_timestamp_seconds{path=\"$CERT\"} $EXP" \
  > /var/lib/node_exporter/textfile_collector/sslcert.prom
```

Then alert on it:

```yaml
- alert: TLSCertificateExpiringSoon
  expr: (ssl_cert_expiry_timestamp_seconds - time()) < 30 * 24 * 3600
  labels:
    severity: warning
  annotations:
    summary: "TLS certificate on {{ $labels.instance }} expires in under 30 days"
```

---

# 13. Checklist

```text
* [ ] CA strategy agreed with the client
* [ ] CA private key stored off the cluster nodes
* [ ] Every node has a certificate with correct SANs, including the HAProxy IP
* [ ] server.key is mode 600 and owned by postgres on every node
* [ ] ssl = on, rolling restart completed, pg_stat_ssl shows encrypted sessions
* [ ] hostssl rules added, plaintext host rules removed only after verification
* [ ] Replication confirmed still running after the pg_hba change
* [ ] Application team told which sslmode to use, and given ca.crt
* [ ] Patroni REST API on HTTPS, ctl: block added so patronictl still works
* [ ] HAProxy server lines updated with check-ssl, all servers UP again
* [ ] etcd on HTTPS with client-cert-auth, quorum confirmed
* [ ] Prometheus etcd job updated to scheme: https
* [ ] Certificate expiry dates documented and alerted on
```
