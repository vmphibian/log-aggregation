# log-aggregation

Rootless Podman/Quadlet deployment of **Grafana Loki** (monolithic mode) for short-lived developer lab environments.

Each lab host runs one or more Loki instances managed by `systemd` via Quadlet. A single instantiated unit template (`loki@.container`) serves all instances — no per-instance unit file is needed. Logs are ingested by Grafana Alloy (out of scope). Storage is configurable between a local Podman volume and an S3-backed volume via `s3fs`.

**Pinned image version:** `docker.io/grafana/loki:3.5.0`

---

## TLS Architecture

> **Loki runs plain HTTP only. TLS is terminated exclusively at Traefik.**

| Path | Protocol | Who uses it |
|---|---|---|
| External (via Traefik) | HTTPS — TLS terminated at Traefik | Grafana, Alloy, export script, browsers, MCP servers |
| Container-internal | HTTP — plain, inside container only | Readiness probes via `podman exec` |

Do not add TLS configuration — certificates, HTTPS listeners, redirects, or otherwise — to `loki.yaml`, the Quadlet unit, the Ansible role, shell scripts, or any documentation example. This constraint is absolute.

---

## Quick Start

### Prerequisites

- Rootless Podman ≥ 4.4 (RHEL 9+)
- systemd user session: `loginctl enable-linger $USER`
- Traefik running with label-based routing configured

### Ansible (primary)

```bash
# Install the required collection
ansible-galaxy collection install containers.podman

# Deploy an instance
ansible-playbook -i inventory ansible/deploy-loki.yml
```

### Shell fallback

```bash
export LOKI_INSTANCE_NAME=lab-42
export LOKI_STORAGE_BACKEND=local
export LOKI_TRAEFIK_DOMAIN=example.internal

bash scripts/deploy.sh
```

---

## Variable Reference

| Ansible Variable | Shell Env Var | Required | Default | Description |
|---|---|---|---|---|
| `loki_instance_name` | `LOKI_INSTANCE_NAME` | Yes | — | Unique instance identifier. Must match `^[a-z0-9][a-z0-9-]*[a-z0-9]$`. |
| `loki_storage_backend` | `LOKI_STORAGE_BACKEND` | Yes | `local` | `local` or `s3`. |
| `loki_s3_mount_path` | `LOKI_S3_MOUNT_PATH` | If `s3` | — | Absolute path where s3fs has mounted the S3 bucket. |
| `loki_http_port` | `LOKI_HTTP_PORT` | No | `3100` | Loki HTTP port (container-internal only, not published to host). |
| `loki_grpc_port` | `LOKI_GRPC_PORT` | No | `9095` | Loki gRPC port (container-internal only, not published to host). |
| `loki_retention_period` | `LOKI_RETENTION_PERIOD` | No | `168h` | Log retention window (Go duration string). |
| `loki_traefik_domain` | `LOKI_TRAEFIK_DOMAIN` | Yes | — | Base domain. Instance reachable at `https://<name>.loki.<domain>` via Traefik. |
| `loki_image` | `LOKI_IMAGE` | No | `docker.io/grafana/loki:3.5.0` | Fully-qualified image. Never `latest`. |
| `loki_config_dir_base` | `LOKI_CONFIG_DIR_BASE` | No | `~/.config/loki` | Host base directory for rendered configs. |
| — | `LOKI_READY_TIMEOUT_SECONDS` | No | `180` | Seconds to wait for the `podman exec` readiness probe before dumping diagnostics and failing. |

Rendered `loki.yaml` is intentionally installed with mode `0644` inside a `0755`
instance directory. The Loki image runs as a non-root UID, and rootless Podman
bind-mounts the host config file directly into the container. These modes avoid
UID/GID mapping failures when Loki opens `/etc/loki/loki.yaml`.

---

## Ingestion Rate Limits

The following limits are tuned for lab use. Adjust for production workloads. See `ansible/roles/loki_lab/templates/loki.yaml.j2` for comments on each.

| Parameter | Default | Description |
|---|---|---|
| `ingestion_rate_mb` | `4` | Max ingestion rate per stream (MiB/s). |
| `ingestion_burst_size_mb` | `6` | Burst headroom above `ingestion_rate_mb`. |
| `max_streams_per_user` | `10000` | Max concurrent streams per tenant. |
| `max_query_length` | `721h` | Max time range for a single query. |
| `max_entries_limit_per_query` | `50000` | Max log entries returned per query. |
| `retention_period` | `loki_retention_period` | Per-tenant retention (mirrors deploy variable). |

---

## Log Export

```bash
export LOKI_INSTANCE_NAME=lab-42
export LOKI_TRAEFIK_DOMAIN=example.internal
bash scripts/export-logs.sh
```

Output: `./loki-export-<instance>-<timestamp>.ndjson`

The export file can be:
- **Reimported** via the Loki push API: `curl -X POST https://lab-42.loki.example.internal/loki/api/v1/push --data-binary @loki-export-*.ndjson`
- **Queried offline** with `logcli`: `logcli --addr=https://lab-42.loki.example.internal query '{job=~".*"}'`

---

## Multiple Instances

Deploy two instances with different names:

```bash
LOKI_INSTANCE_NAME=lab-42  LOKI_STORAGE_BACKEND=local LOKI_TRAEFIK_DOMAIN=example.internal bash scripts/deploy.sh
LOKI_INSTANCE_NAME=lab-43  LOKI_STORAGE_BACKEND=local LOKI_TRAEFIK_DOMAIN=example.internal bash scripts/deploy.sh
```

Both instances share the single `loki@.container` unit template. Traefik routes by subdomain (`lab-42.loki.example.internal`, `lab-43.loki.example.internal`). No port differentiation is needed.

---

## Compatibility Notes

**Podman version targets:**

| Environment | Version | Notes |
|---|---|---|
| Target host (RHEL 9) | 4.4+ | Minimum supported version for Quadlet |
| CI runner (ubuntu-latest) | 4.9.3 | Used for test workflows |

CI passes on Podman 4.9.3 on the GitHub Actions runner. This does **not** guarantee compatibility with features introduced after Podman 4.4. The following Quadlet features used in this project are verified as available in Podman 4.4:

- `[Container]` section with `Label=`, `Volume=`, `PublishPort=`, `Exec=`
- `[Service]` restart directives
- Instantiated unit templates (`loki@.container` → `loki@<name>.service`)

If you encounter compatibility issues on a Podman 4.4 system, open an issue with `podman --version` and `podman info` output.

---

## CI Notes

**GitHub Actions (ubuntu-latest, Podman 4.9.3):**

- The `test.yml` workflow uses `loginctl enable-linger $USER` to enable user systemd units on the runner. This is required for `systemctl --user` to function correctly outside an interactive session.
- The Molecule scenario uses `ubi9/ubi-init` with `cgroupns_mode: host`, `systemd: always`, and `seccomp=unconfined` to allow systemd inside a rootless Podman container on the runner. This combination is required for user unit testing to work in CI.
- The S3 backend is **not tested in CI**. It requires a live s3fs mount and must be validated manually in a real environment. See `docs/storage-backends.md`.
- `XDG_RUNTIME_DIR` is set explicitly in CI workflows to ensure rootless Podman can access the user runtime directory.

---

## Design Deviations

None. This project follows the repository structure, variable naming, and constraints defined in the project specification without deviation.

---

## License

MIT
