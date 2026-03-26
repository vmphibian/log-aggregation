# Grafana Integration

## Datasource Type

Add a **Loki** datasource in Grafana for each deployed instance.

---

## URL Configuration

**Use the correct URL based on where Grafana is running.**

### Same-host Grafana (recommended for co-located deployments)

```
http://localhost:<loki_http_port>
```

Example: `http://localhost:3100`

- Plain HTTP, direct to Loki, bypasses Traefik entirely.
- Preferred when Grafana and Loki run on the same host — avoids a Traefik round-trip.
- **Do not configure TLS client certificates or HTTPS** on this path. Grafana communicating with Loki over `http://localhost` is correct and expected.

### Remote Grafana (different host)

```
https://<instance_name>.loki.<traefik_domain>
```

Example: `https://lab-42.loki.example.internal`

- HTTPS via Traefik TLS termination.
- Traefik decrypts the connection and forwards to Loki over plain HTTP internally.
- Use when Grafana is on a different host from Loki.

---

## Authentication

None. This deployment does not configure Loki authentication.

---

## Datasource Provisioning YAML

### Same-host Grafana

```yaml
# grafana/provisioning/datasources/loki-lab-42.yaml
apiVersion: 1
datasources:
  - name: "Loki lab-42"
    type: loki
    access: proxy
    # Plain HTTP direct to Loki — bypasses Traefik, no TLS
    url: "http://localhost:3100"
    isDefault: false
    editable: true
    jsonData:
      maxLines: 1000
```

### Remote Grafana (via Traefik)

```yaml
# grafana/provisioning/datasources/loki-lab-42.yaml
apiVersion: 1
datasources:
  - name: "Loki lab-42"
    type: loki
    access: proxy
    # HTTPS via Traefik TLS termination — use when Grafana is on a remote host
    url: "https://lab-42.loki.example.internal"
    isDefault: false
    editable: true
    jsonData:
      maxLines: 1000
```

Each Loki instance requires its own datasource entry, identified by `loki_instance_name`. Use a descriptive `name` so operators can distinguish instances in the Grafana UI.

---

## Multiple Instances

Deploy one Loki datasource per instance. Use the instance name in both the datasource `name` and the URL to keep them distinct:

```yaml
apiVersion: 1
datasources:
  - name: "Loki lab-42"
    type: loki
    url: "http://localhost:3100"   # if co-located
    # url: "https://lab-42.loki.example.internal"  # if remote
  - name: "Loki lab-s3-01"
    type: loki
    url: "https://lab-s3-01.loki.example.internal"
```

---

## Recommended Usage

- Use Grafana's **Explore** view (`/explore`) with the Loki datasource for ad-hoc log querying via LogQL. This is the fastest path for engineering staff unfamiliar with log analysis.
- Example LogQL queries to start with:
  ```logql
  # All logs from a specific job
  {job="nginx"}

  # Error-level entries from a service
  {job="my-service"} |= "ERROR"

  # Rate of log entries per minute
  rate({job="my-service"}[1m])
  ```
- Use label filters (`{instance="lab-42"}`) to scope queries to a specific Loki instance when multiple instances feed the same Grafana.
