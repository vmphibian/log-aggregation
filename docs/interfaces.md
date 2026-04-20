# Interface Contracts

## TLS Architecture Summary

**Read this before integrating with Loki.**

This deployment routes all external access through Traefik. Understanding the architecture prevents the most common integration errors.

| Access path | URL pattern | TLS | Who uses it |
|---|---|---|---|
| **External** (via Traefik) | `https://<instance>.loki.<domain>` | ✅ TLS terminated at Traefik | Grafana, Alloy, MCP servers, browsers, export script |
| **Container-internal** | `http://localhost:3100` | ❌ Plain HTTP | Readiness probes via `podman exec` (not reachable from the host) |

**Loki itself never speaks TLS.** Loki's HTTP and gRPC listeners are plain HTTP/gRPC only. Do not configure TLS certificates, HTTPS listeners, or TLS-related options anywhere in this project or in any integration that talks to Loki directly.

Traefik decrypts HTTPS connections at the edge and forwards requests to Loki over plain HTTP on the container network. This is the correct and intentional architecture.

**Loki ports are not published to the host.** The Quadlet unit does not bind Loki's ports to `localhost`. All client access — including from the same host — must go through Traefik. Container-internal access (e.g. readiness probes) uses `podman exec`.

---

## Ingest Interfaces

### Grafana Alloy → Loki (HTTP Push)

**All Alloy instances (via Traefik TLS termination):**
```
POST https://<instance_name>.loki.<traefik_domain>/loki/api/v1/push
```

| Property | Value |
|---|---|
| Protocol | HTTP/1.1 |
| Content-Type | `application/json` or `application/x-protobuf` |
| Authentication | None |
| Expected response | `204 No Content` |

**Expected Alloy component:** `loki.write`

**Illustrative Alloy configuration snippet** (not deployed by this project):
```alloy
loki.write "loki_lab" {
  endpoint {
    // All Alloy instances — use the Traefik HTTPS endpoint.
    // Loki ports are not published to the host.
    url = "https://lab-42.loki.example.internal/loki/api/v1/push"
  }
}
```

**Recommended label conventions:**
Shippers must attach at minimum the following labels to all log streams:
- `job` — application name (e.g. `"nginx"`, `"my-service"`)
- `instance` — the `loki_instance_name` value (e.g. `"lab-42"`)

Additional labels (`host`, `env`, `container`) are encouraged for query flexibility.

---

## Query Interfaces

### Base URLs

| Access path | Base URL |
|---|---|
| External (via Traefik, HTTPS) | `https://<instance_name>.loki.<traefik_domain>` |
| Container-internal (via `podman exec`) | `http://localhost:3100` (not reachable from host) |

### LogQL HTTP API Endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| `/loki/api/v1/query` | GET | Instant LogQL query (single point in time) |
| `/loki/api/v1/query_range` | GET | Range LogQL query (time series or log stream) |
| `/loki/api/v1/labels` | GET | Discover all label keys |
| `/loki/api/v1/label/<name>/values` | GET | Discover values for a specific label key |
| `/loki/api/v1/series` | GET | Discover log streams matching a selector |
| `/ready` | GET | Readiness probe — returns `ready` with HTTP 200. **Container-internal only via `podman exec`.** |

All endpoints are unauthenticated in this deployment.

### `query_range` Response Envelope

`GET /loki/api/v1/query_range`

**Required parameters:**
| Parameter | Type | Description |
|---|---|---|
| `query` | string | LogQL selector (e.g. `{job="nginx"}`) |
| `start` | int | Start time as **nanosecond epoch integer** ⚠️ |
| `end` | int | End time as **nanosecond epoch integer** ⚠️ |
| `limit` | int | Maximum number of log entries to return |
| `direction` | string | `forward` (oldest first) or `backward` (newest first, default) |

> ⚠️ **Nanosecond epoch integers are required.** A common integration error is supplying millisecond or second epoch values. The correct unit is nanoseconds since Unix epoch (1970-01-01T00:00:00Z).
>
> Example: `1711324800000000000` = 2024-03-25T00:00:00Z in nanoseconds.
>
> In shell: `date +%s%N`
> In Python: `int(time.time() * 1e9)`
> In JavaScript: `Date.now() * 1e6`

**Response structure:**
```json
{
  "status": "success",
  "data": {
    "resultType": "streams",
    "result": [
      {
        "stream": {
          "job": "nginx",
          "instance": "lab-42"
        },
        "values": [
          ["1711324800000000000", "log line text here"],
          ["1711324801000000000", "another log line"]
        ]
      }
    ],
    "stats": { }
  }
}
```

`data.result` is an array of log streams. Each stream has:
- `stream` — label set (key/value map) identifying this log stream
- `values` — array of `[timestamp_ns, log_line]` pairs, where `timestamp_ns` is a **string** representation of the nanosecond epoch integer

---

## LLM / MCP Compatibility Notes

- The LogQL HTTP API is the intended integration surface for any future MCP server.
- **Target the Traefik HTTPS endpoint** (`https://`) for all access. Loki ports are not published to the host.
- **Loki does not speak TLS.** An MCP server must not attempt a TLS handshake directly with Loki — all TLS is handled by Traefik at the edge.
- Label discovery via `/labels` and `/label/<name>/values` enables dynamic context building for LLM prompts without hardcoding stream selectors.
- All responses are JSON — no custom serialization required.
- **Timestamp parameters use nanosecond epoch integers** — see query_range section above. This is the single most common integration error.
- A practical query workflow for an MCP server:
  1. `GET /loki/api/v1/labels` — discover available label keys
  2. `GET /loki/api/v1/label/job/values` — discover service names
  3. `GET /loki/api/v1/query_range?query={job="target"}&start=...&end=...` — fetch logs
