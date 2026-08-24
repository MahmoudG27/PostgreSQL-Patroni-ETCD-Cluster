# Authentication & Role-Based Access Control

Closes two Scope of Work requirements:

```text
* "Least-privilege access model for DBAs, system administrators, and support personnel"
* Proposal 4.5 — SCRAM-SHA-256 authentication and role-based access control
```

Do this **before** TLS. It is quick, it is low risk, and it fixes the most serious findings in the cluster as it stands today.

---

# 1. What Is Wrong Today

`Phase3-Patroni/patroni.yml` currently contains:

```yaml
pg_hba:
  - host replication replicator 10.0.0.0/24 md5
  - host replication replicator 10.1.0.0/24 md5
  - host all all 10.0.0.0/24 md5
  - local all all trust
```

Two problems:

```text
md5     Deprecated since PostgreSQL 10. The hash is unsalted per-session and
        replayable. The proposal explicitly promises SCRAM-SHA-256.

trust   Any operating system user on a database node can connect as ANY
        PostgreSQL role, including postgres, with no password at all.
        A shell account on the box is a full database compromise.
```

There is also no role model — every connection would use the `postgres` superuser, including postgres_exporter.

---

# 2. How to Change `pg_hba` in a Patroni Cluster

This is the part people get wrong.

The `pg_hba` block inside `bootstrap:` in `patroni.yml` is **only read once**, when the cluster is first initialised. Editing that file afterwards changes nothing.

After bootstrap, `pg_hba` lives in the DCS (etcd) and is edited with `patronictl`:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml edit-config
```

This opens an editor with the live cluster configuration. Patroni writes the change to etcd, pushes it to every node, rewrites each node's `pg_hba.conf`, and issues a reload — no restart, no downtime.

To confirm what the cluster currently believes:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml show-config
```

---

# 3. Step 1 — Enable SCRAM-SHA-256

Run `edit-config` and set the parameter:

```yaml
postgresql:
  parameters:
    password_encryption: scram-sha-256
```

`password_encryption` is a reloadable parameter, so no restart is needed.

Verify on any node:

```bash
sudo -u postgres psql -c "SHOW password_encryption;"
```

---

# 4. Step 2 — Re-Set Every Password

**This is the step everyone forgets.** Changing `password_encryption` only affects passwords set *from now on*. Existing passwords keep their old md5 hashes and will keep working with md5 — and will stop working the moment you change `pg_hba` to `scram-sha-256`.

Check what you have:

```sql
SELECT rolname,
       CASE
         WHEN rolpassword LIKE 'SCRAM-SHA-256%' THEN 'scram-sha-256'
         WHEN rolpassword LIKE 'md5%'           THEN 'md5'
         WHEN rolpassword IS NULL               THEN 'none'
         ELSE 'other'
       END AS method
FROM pg_authid
ORDER BY rolname;
```

Re-set every role that shows `md5`, on the **leader** — it replicates to the replicas:

```sql
ALTER ROLE postgres    WITH PASSWORD 'NEW_SUPERUSER_PASSWORD';
ALTER ROLE replicator  WITH PASSWORD 'NEW_REPLICATION_PASSWORD';
```

Re-run the query above and confirm every row now says `scram-sha-256`.

---

# 5. Step 3 — Update Patroni's Own Credentials

Patroni connects to PostgreSQL with the superuser and replication passwords from `patroni.yml`. If you changed them in section 4, update the file on **every node** to match:

```yaml
postgresql:
  authentication:
    replication:
      username: replicator
      password: "NEW_REPLICATION_PASSWORD"
    superuser:
      username: postgres
      password: "NEW_SUPERUSER_PASSWORD"
```

Also update `/var/lib/postgresql/.pgpass` on the DR nodes, which authenticate to HQ.

Then restart Patroni one node at a time, replicas first:

```bash
sudo systemctl restart patroni
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list
```

---

# 6. Step 4 — Fix `pg_hba`

Now change the rules. Via `edit-config`:

```yaml
postgresql:
  pg_hba:
    # Local Unix socket — peer maps the OS user to the database role.
    # pgBackRest and Patroni maintenance run as the postgres OS user, so this works.
    - local   all           all                     peer

    # Replication inside HQ and from DR
    - host    replication   replicator  10.0.0.0/24 scram-sha-256
    - host    replication   replicator  10.1.0.0/24 scram-sha-256

    # Monitoring — restricted to the exporter role only
    - host    all           monitoring  10.0.0.0/24 scram-sha-256

    # Application traffic through HAProxy
    - host    all           app_user    10.0.0.0/24 scram-sha-256
    - host    all           report_user 10.0.0.0/24 scram-sha-256

    # Administrative access — narrow this to the jump host, not the whole subnet
    - host    all           postgres    10.0.0.0/24 scram-sha-256

    # Everything else is rejected by PostgreSQL's implicit final rule
```

Key changes from the original:

```text
* local ... trust  →  local ... peer
* every md5        →  scram-sha-256
* one blanket "host all all" rule  →  one rule per role
```

> **Careful with `local ... peer`**
>
> `peer` means the OS user name must equal the database role name. Running
> `sudo -u postgres psql` works. Running `psql -U postgres` as a different OS
> user over the socket will now fail — which is the point.

---

# 7. Step 5 — Verify Before You Walk Away

```bash
# Reload was applied
sudo -u postgres psql -c "SELECT pg_reload_conf();"
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;"
```

`pg_hba_file_rules` shows parse errors without you having to restart anything. It must return zero rows.

Then confirm the cluster is still healthy and replication still works:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list
sudo -u postgres psql -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"
```

---

# 8. The Role Model

The proposal promises separate roles for application access, DBA access, read-only reporting, and monitoring. None exist today.

The pattern is: **group roles carry the privileges, login roles carry the passwords.** Adding a person or an application then means granting membership, not re-granting privileges.

```text
  app_rw        ─── app_user       application read/write
  app_ro        ─── report_user    reporting, read-only
  dba_role      ─── <person>       DBA, one login role per human
  monitoring                       postgres_exporter, pg_monitor only
```

---

# 9. Create the Roles

Run on the **leader**. Everything here replicates.

```sql
-- ---------------------------------------------------------------
-- Group roles: hold privileges, cannot log in
-- ---------------------------------------------------------------
CREATE ROLE app_rw   NOLOGIN;
CREATE ROLE app_ro   NOLOGIN;
CREATE ROLE dba_role NOLOGIN;

-- ---------------------------------------------------------------
-- Login roles
-- ---------------------------------------------------------------
CREATE ROLE app_user    LOGIN PASSWORD 'CHANGE_ME' IN ROLE app_rw;
CREATE ROLE report_user LOGIN PASSWORD 'CHANGE_ME' IN ROLE app_ro;

-- One login role per human DBA. Never a shared account —
-- the audit trail is worthless if three people share one login.
CREATE ROLE mahmoud     LOGIN PASSWORD 'CHANGE_ME' IN ROLE dba_role;

-- ---------------------------------------------------------------
-- Monitoring role for postgres_exporter
-- pg_monitor is a built-in role: read access to all statistics
-- views without any data access at all.
-- ---------------------------------------------------------------
CREATE ROLE monitoring LOGIN PASSWORD 'CHANGE_ME';
GRANT pg_monitor TO monitoring;
```

---

# 10. Grant Privileges

```sql
-- Remove the default open access first.
-- PostgreSQL grants CONNECT on every database to PUBLIC by default.
REVOKE ALL ON DATABASE appdb FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Connection
GRANT CONNECT ON DATABASE appdb TO app_rw, app_ro, dba_role;
GRANT USAGE   ON SCHEMA public  TO app_rw, app_ro;

-- Read/write
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO app_rw;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO app_rw;

-- Read-only
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_ro;

-- DBA
GRANT ALL PRIVILEGES ON DATABASE appdb TO dba_role;
```

---

# 11. Default Privileges — The Step That Makes It Stick

The grants above only cover tables that exist **right now**. A table created next week by a migration is invisible to `app_ro` again.

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO app_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
```

> **`ALTER DEFAULT PRIVILEGES` applies per grantor.**
>
> It only affects objects created by the role that ran the statement. If your
> migrations run as `app_user`, run these statements as `app_user` too — or add
> `FOR ROLE app_user`.

---

# 12. Point postgres_exporter at the Monitoring Role

The exporter currently has no dedicated role. Update its connection string:

```bash
sudo systemctl edit postgres_exporter
```

```ini
[Service]
Environment="DATA_SOURCE_NAME=postgresql://monitoring:CHANGE_ME@10.0.0.4:5432/postgres?sslmode=disable"
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart postgres_exporter
```

Verify the exporter can now actually read:

```bash
curl -s http://10.0.0.4:9187/metrics | grep "^pg_up"
```

`pg_up 1` means the connection works. The PostgreSQL dashboard in `Phase6-Monitoring/Dashboards/` already assumes this role exists.

---

# 13. Superuser Discipline

```text
* postgres is used by Patroni and pgBackRest. Nothing else should use it.
* No application ever connects as postgres.
* No human connects as postgres for routine work — use a dba_role login.
* Do not grant SUPERUSER to dba_role. Grant the specific built-in roles instead:
```

```sql
GRANT pg_read_all_data  TO dba_role;   -- read everything, write nothing
GRANT pg_signal_backend TO dba_role;   -- cancel/terminate other sessions
GRANT pg_monitor        TO dba_role;   -- full statistics access
```

That covers almost everything a DBA does day to day without handing over the ability to bypass every permission check.

---

# 14. Protect the Credential Files

Patroni and pgBackRest configuration files contain plaintext passwords.

```bash
sudo chown postgres:postgres /etc/patroni/patroni.yml
sudo chmod 600              /etc/patroni/patroni.yml

sudo chown postgres:postgres /var/lib/postgresql/.pgpass
sudo chmod 600              /var/lib/postgresql/.pgpass

sudo chown postgres:postgres /etc/pgbackrest.conf
sudo chmod 640              /etc/pgbackrest.conf
```

Confirm the real files are never committed:

```bash
cat .gitignore
```

The repository should hold a `patroni.yml.example` with placeholders, never a file with live credentials.

> **Open question for the client**
>
> If they run HashiCorp Vault or a cloud KMS, credential injection should be
> scoped as a separate item — proposal 4.5 already says so. The file permissions
> above are the minimum baseline either way.

---

# 15. Secure the Patroni REST API

The `restapi` block has no authentication today. Anyone who can reach port 8008 can trigger a failover:

```bash
curl -s -XPOST http://10.0.0.4:8008/failover -d '{"leader":"hq-node-01","candidate":"hq-node-02"}'
```

That is an unauthenticated, cluster-wide, privileged action — directly against the Scope of Work requirement for change control over failover.

Add to `patroni.yml` on every node:

```yaml
restapi:
  listen: 10.0.0.4:8008
  connect_address: 10.0.0.4:8008
  authentication:
    username: patroni
    password: "CHANGE_ME"

ctl:
  authentication:
    username: patroni
    password: "CHANGE_ME"
```

> **This only protects the write endpoints.**
>
> Patroni requires authentication for `POST`, `PATCH` and `DELETE` but leaves
> `GET` open. HAProxy health checks use `GET /primary` and `GET /replica`, so the
> connectivity layer keeps working with no change.

Restart Patroni one node at a time and verify:

```bash
# should be rejected
curl -s -XPOST http://10.0.0.4:8008/switchover -d '{}'

# should still work
curl -s http://10.0.0.4:8008/primary
```

---

# 16. Checklist

```text
* [ ] password_encryption = scram-sha-256
* [ ] Every role in pg_authid shows scram-sha-256
* [ ] patroni.yml and .pgpass updated with the new passwords on every node
* [ ] local ... trust replaced with local ... peer
* [ ] Every pg_hba rule uses scram-sha-256
* [ ] pg_hba_file_rules returns no errors
* [ ] Group roles and login roles created
* [ ] PUBLIC revoked from the application database
* [ ] ALTER DEFAULT PRIVILEGES set for future tables
* [ ] postgres_exporter uses the monitoring role, pg_up is 1
* [ ] No application or human uses the postgres superuser
* [ ] patroni.yml is 600, pgbackrest.conf is 640, both owned by postgres
* [ ] Patroni REST API requires authentication for write endpoints
* [ ] HAProxy health checks still pass after the API change
* [ ] Replication still running: pg_stat_replication shows all replicas
```
