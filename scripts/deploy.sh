#!/usr/bin/env bash
# deploy.sh — Shell fallback for deploying a Loki lab instance.
#
# This script is the secondary deployment path for operators without Ansible.
# It is functionally equivalent to the Ansible loki_lab role.
# The PRIMARY deployment mechanism is the Ansible role (ansible/deploy-loki.yml).
#
# Usage:
#   export LOKI_INSTANCE_NAME=lab-42
#   export LOKI_STORAGE_BACKEND=local
#   export LOKI_TRAEFIK_DOMAIN=example.internal
#   bash scripts/deploy.sh
#
# All configuration is via environment variables. See README.md for the full
# variable reference.
#
# Requirements:
#   - Rootless Podman (>= 4.4)
#   - systemd user session (loginctl enable-linger $USER)
#   - envsubst (gettext-base package)
#   - curl (for readiness check)
#   - quadlet/loki@.container present (installed from repo root)

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
LOKI_HTTP_PORT="${LOKI_HTTP_PORT:-3100}"
LOKI_GRPC_PORT="${LOKI_GRPC_PORT:-9095}"
LOKI_RETENTION_PERIOD="${LOKI_RETENTION_PERIOD:-168h}"
LOKI_IMAGE="${LOKI_IMAGE:-docker.io/grafana/loki:3.5.0}"
LOKI_CONFIG_DIR_BASE="${LOKI_CONFIG_DIR_BASE:-${HOME}/.config/loki}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Validation ────────────────────────────────────────────────────────────────
error() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${LOKI_INSTANCE_NAME:-}" ]]   || error "LOKI_INSTANCE_NAME is required."
[[ -n "${LOKI_STORAGE_BACKEND:-}" ]] || error "LOKI_STORAGE_BACKEND is required."
[[ -n "${LOKI_TRAEFIK_DOMAIN:-}" ]]  || error "LOKI_TRAEFIK_DOMAIN is required."

# Validate instance name format
if ! [[ "${LOKI_INSTANCE_NAME}" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
  error "LOKI_INSTANCE_NAME '${LOKI_INSTANCE_NAME}' is invalid. Must match ^[a-z0-9][a-z0-9-]*[a-z0-9]$"
fi

# Validate storage backend
if [[ "${LOKI_STORAGE_BACKEND}" != "local" && "${LOKI_STORAGE_BACKEND}" != "s3" ]]; then
  error "LOKI_STORAGE_BACKEND must be 'local' or 's3', got '${LOKI_STORAGE_BACKEND}'"
fi

# Refuse to run as root
if [[ "$(id -u)" -eq 0 ]]; then
  error "This script must not run as root. Rootless Podman requires a regular user account."
fi

# S3 backend: validate mountpoint
if [[ "${LOKI_STORAGE_BACKEND}" == "s3" ]]; then
  [[ -n "${LOKI_S3_MOUNT_PATH:-}" ]] || error "LOKI_S3_MOUNT_PATH is required when LOKI_STORAGE_BACKEND=s3"
  mountpoint -q "${LOKI_S3_MOUNT_PATH}" \
    || error "LOKI_S3_MOUNT_PATH '${LOKI_S3_MOUNT_PATH}' is not a mountpoint. Ensure s3fs is mounted first."
fi

echo "==> Deploying Loki instance: ${LOKI_INSTANCE_NAME}"
echo "    Storage backend : ${LOKI_STORAGE_BACKEND}"
echo "    Traefik domain  : ${LOKI_TRAEFIK_DOMAIN}"

# ── Config directory ──────────────────────────────────────────────────────────
CONFIG_DIR="${LOKI_CONFIG_DIR_BASE}/${LOKI_INSTANCE_NAME}"
mkdir -p "${CONFIG_DIR}"
chmod 750 "${CONFIG_DIR}"

# ── Render loki.yaml ──────────────────────────────────────────────────────────
echo "==> Rendering Loki configuration..."
export LOKI_INSTANCE_NAME LOKI_HTTP_PORT LOKI_GRPC_PORT LOKI_RETENTION_PERIOD \
       LOKI_IMAGE LOKI_TRAEFIK_DOMAIN LOKI_CONFIG_DIR_BASE

envsubst < "${REPO_ROOT}/config/loki.yaml.tpl" > "${CONFIG_DIR}/loki.yaml"
chmod 640 "${CONFIG_DIR}/loki.yaml"
echo "    Written: ${CONFIG_DIR}/loki.yaml"

# ── Podman volume ─────────────────────────────────────────────────────────────
VOLUME_NAME="loki-${LOKI_INSTANCE_NAME}"
echo "==> Ensuring Podman volume: ${VOLUME_NAME}"

if podman volume inspect "${VOLUME_NAME}" &>/dev/null; then
  echo "    Volume already exists — skipping creation."
else
  if [[ "${LOKI_STORAGE_BACKEND}" == "s3" ]]; then
    podman volume create \
      --opt type=none \
      --opt o=bind \
      --opt "device=${LOKI_S3_MOUNT_PATH}" \
      "${VOLUME_NAME}"
  else
    podman volume create "${VOLUME_NAME}"
  fi
  echo "    Created volume: ${VOLUME_NAME}"
fi

# ── Quadlet unit ──────────────────────────────────────────────────────────────
QUADLET_DIR="${HOME}/.config/containers/systemd"
QUADLET_DEST="${QUADLET_DIR}/loki@.container"
mkdir -p "${QUADLET_DIR}"

if [[ ! -f "${QUADLET_DEST}" ]]; then
  echo "==> Installing Quadlet unit template..."
  cp "${REPO_ROOT}/quadlet/loki@.container" "${QUADLET_DEST}"
  chmod 640 "${QUADLET_DEST}"
  echo "    Installed: ${QUADLET_DEST}"
else
  echo "==> Quadlet unit already installed — skipping."
fi

# ── systemd daemon-reload ────────────────────────────────────────────────────
echo "==> Reloading systemd user daemon..."
systemctl --user daemon-reload

# ── Enable and start service ──────────────────────────────────────────────────
SERVICE="loki@${LOKI_INSTANCE_NAME}.service"
echo "==> Starting ${SERVICE}..."
systemctl --user start "${SERVICE}"

# ── Readiness check ───────────────────────────────────────────────────────────
# Direct HTTP call to Loki — do not use the Traefik HTTPS endpoint here.
# Traefik may not be present in all environments (e.g. development, CI).
echo "==> Waiting for Loki readiness (http://localhost:${LOKI_HTTP_PORT}/ready)..."
READY_TIMEOUT=30
ELAPSED=0
until curl -sf "http://localhost:${LOKI_HTTP_PORT}/ready" -o /dev/null; do
  if [[ ${ELAPSED} -ge ${READY_TIMEOUT} ]]; then
    error "Loki did not become ready within ${READY_TIMEOUT}s. Check: journalctl --user -u ${SERVICE}"
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "✓ Loki instance '${LOKI_INSTANCE_NAME}' is ready."
echo ""
echo "  Instance name   : ${LOKI_INSTANCE_NAME}"
echo "  Storage backend : ${LOKI_STORAGE_BACKEND}"
echo "  Traefik HTTPS   : https://${LOKI_INSTANCE_NAME}.loki.${LOKI_TRAEFIK_DOMAIN}  (TLS terminated at Traefik)"
echo "  Direct HTTP     : http://localhost:${LOKI_HTTP_PORT}  (same-host only, bypasses Traefik)"
echo "  gRPC port       : ${LOKI_GRPC_PORT}  (localhost, for Grafana Alloy push)"
echo ""
echo "  Export logs     : bash scripts/export-logs.sh"
echo "  Stop service    : systemctl --user stop loki@${LOKI_INSTANCE_NAME}.service"
