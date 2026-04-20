# Grafana Integration

## Datasource Type

Add a **Loki** datasource in Grafana for each deployed instance.

---

## URL Configuration

**All Grafana instances must use the Traefik HTTPS endpoint.**

Loki ports are not published to the host. All access — including from co-located Grafana — goes through Traefik.

```
https://<instance_name>.loki.<traefik_domain>
```

Example: `https://lab-42.loki.example.internal`

- HTTPS via Traefik TLS termination.
- Traefik decrypts the connection and forwards to Loki over plain HTTP internally.
- Works for both same-host and remote Grafana deployments.

---

## Authentication

None. This deployment does not configure Loki authentication.

---

## Datasource Provisioning YAML

```yaml
# grafana/provisioning/datasources/loki-lab-42.yaml
apiVersion: 1
datasources:
  - name: "Loki lab-42"
    type: loki
    access: proxy
    # HTTPS via Traefik TLS termination
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
    url: "https://lab-42.loki.example.internal"
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
