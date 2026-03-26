# Storage Backends

Loki lab instances support two storage backends, selected at deploy time via `loki_storage_backend` (Ansible) or `LOKI_STORAGE_BACKEND` (shell).

**In both cases, Loki's backend type is `filesystem` and it writes to `/loki` inside the container.** Loki's native S3 client is not used. S3 is abstracted by `s3fs` on the host — Loki has no knowledge of S3, AWS credentials, or bucket structure.

---

## Local Mode (`loki_storage_backend: local`)

The simplest option. A named Podman volume is created on the container host. Data is stored on the host filesystem in Podman's volume directory (typically `~/.local/share/containers/storage/volumes/`).

**Setup:**
1. No host filesystem configuration required.
2. Ansible creates `podman volume create loki-{{ loki_instance_name }}` automatically.
3. The volume is mounted at `/loki` inside the container.

**Teardown:**
```bash
podman volume rm loki-<instance_name>
```

**Data persistence:** Data survives container restarts and upgrades as long as the Podman volume exists. Data is lost if the volume is explicitly removed.

**Use when:** Local storage is sufficient and durability beyond the host is not required.

---

## S3 Mode (`loki_storage_backend: s3`)

Log data is stored in an AWS S3 bucket, accessed via `s3fs` mounted on the host. Loki sees a local filesystem — no AWS SDK or credentials are ever present inside the container.

### Architecture

```
Loki container
  └── /loki  (volume mount)
        └── Podman bind-mount volume
              └── host path: loki_s3_mount_path
                    └── s3fs mount → AWS S3 bucket
```

### Operator Prerequisites

Before running the Ansible role or `deploy.sh`:

1. **Install s3fs** on the host:
   ```bash
   # RHEL 9 / AlmaLinux 9
   sudo dnf install -y s3fs-fuse
   ```

2. **Configure AWS credentials** for s3fs. Options:
   - `~/.passwd-s3fs`: `ACCESS_KEY_ID:SECRET_ACCESS_KEY` (mode `0600`)
   - IAM instance profile (recommended for EC2)
   - AWS credentials file (`~/.aws/credentials`)

3. **Mount the S3 bucket** before deploying:
   ```bash
   mkdir -p /mnt/loki-s3
   s3fs my-loki-bucket /mnt/loki-s3 \
     -o allow_other \
     -o use_cache=/tmp/s3fs-cache \
     -o umask=0022
   ```

4. **Verify the mountpoint**:
   ```bash
   mountpoint /mnt/loki-s3
   ```

5. **Set `loki_s3_mount_path`** to the s3fs mount path in your deployment.

The preflight task (`tasks/preflight.yml`) verifies the mountpoint exists and is mounted before any state changes.

### Required IAM Permissions

The AWS identity used by s3fs needs the following S3 permissions on the target bucket:

| Permission | Purpose |
|---|---|
| `s3:GetObject` | Read log chunks |
| `s3:PutObject` | Write log chunks |
| `s3:DeleteObject` | Compactor removes expired chunks |
| `s3:ListBucket` | Volume and chunk discovery |

Minimal IAM policy example:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ],
    "Resource": [
      "arn:aws:s3:::my-loki-bucket",
      "arn:aws:s3:::my-loki-bucket/*"
    ]
  }]
}
```

### Notes

- s3fs credential configuration is **out of scope** for this project.
- s3fs mount persistence across reboots requires a systemd unit or `/etc/fstab` entry — also out of scope.
- The S3 backend is **not tested in CI**. It requires a live s3fs mount and must be validated manually in a real environment.
- Multiple Loki instances on the same host sharing a single S3 bucket are supported — each instance has its own named volume and Loki prefix under `/loki`.
