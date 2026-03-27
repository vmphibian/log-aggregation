# mattgagliardi.loki_lab

Deploys **Grafana Loki** (monolithic mode) as a rootless, systemd-managed Podman container via [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) on RHEL 9 / EL 9 hosts.

Each invocation manages one named Loki instance. A single instantiated systemd unit template (`loki@.container`) serves all instances — no per-instance unit file is needed. Log ingestion is handled by Grafana Alloy (out of scope). Storage supports a local Podman volume or an S3-backed volume via s3fs. TLS is terminated upstream at Traefik; Loki runs plain HTTP only.

**Pinned image:** `docker.io/grafana/loki:3.5.0`

---

## Requirements

- RHEL 9 / EL 9 (or compatible derivative)
- Rootless Podman ≥ 4.4
- [`containers.podman`](https://galaxy.ansible.com/ui/repo/published/containers/podman/) collection: `ansible-galaxy collection install containers.podman`
- systemd user session with linger enabled: `loginctl enable-linger $USER`
- Traefik running with label-based routing configured (for external TLS termination)

---

## Role Variables

### Required (no defaults — must be supplied)

| Variable | Description |
|---|---|
| `loki_instance_name` | Unique name for this Loki instance. Must match `^[a-z0-9][a-z0-9-]*[a-z0-9]$` (e.g. `lab-42`). Used as the systemd service instance and Podman volume name. |
| `loki_traefik_domain` | Domain Traefik routes to this instance (e.g. `loki.example.internal`). |
| `loki_s3_mount_path` | Absolute path of a live s3fs mountpoint. **Required only when `loki_storage_backend: s3`.** |

### Optional

| Variable | Default | Description |
|---|---|---|
| `loki_storage_backend` | `local` | Storage backend: `local` (named Podman volume) or `s3` (bind-mounted s3fs path). |
| `loki_http_port` | `3100` | Host port for Loki's HTTP listener (localhost only). |
| `loki_grpc_port` | `9095` | Host port for Loki's gRPC listener (localhost only). |
| `loki_retention_period` | `168h` | Log retention as a Go duration string (e.g. `24h`, `168h`). |
| `loki_image` | `docker.io/grafana/loki:3.5.0` | Fully-qualified container image reference. Pin to a specific version. |
| `loki_config_dir_base` | `{{ ansible_user_dir }}/.config/loki` | Base directory for rendered Loki configuration files on the host. |
| `loki_allow_root_for_testing` | `false` | Bypass the non-root preflight check. **For CI/testing only — never set `true` in production.** |

---

## Dependencies

- Collection: [`containers.podman`](https://galaxy.ansible.com/ui/repo/published/containers/podman/)

---

## Example Playbook

```yaml
- name: Deploy Loki
  hosts: lab_hosts
  remote_user: lokiuser
  roles:
    - role: mattgagliardi.loki_lab
      vars:
        loki_instance_name: lab-42
        loki_traefik_domain: loki.lab.example.internal
        loki_storage_backend: local
        loki_retention_period: 168h
```

---

## TLS Architecture

> **Loki runs plain HTTP only. TLS is terminated exclusively at Traefik.**

| Path | Protocol | Who uses it |
|---|---|---|
| External (via Traefik) | HTTPS — TLS terminated at Traefik | Grafana, browsers, remote clients |
| Same-host (direct) | HTTP — plain, bypasses Traefik | Readiness probes, co-located Alloy/Grafana |

Do not add TLS configuration to `loki.yaml`, the Quadlet unit, or any deployment script.

---

## License

MIT

---

## Author

[mattgagliardi](https://galaxy.ansible.com/ui/namespaces/mattgagliardi/)
