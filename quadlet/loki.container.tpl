# Quadlet container unit template for a Loki lab instance (shell path).
# Rendered by scripts/deploy.sh via envsubst to:
#   ~/.config/containers/systemd/loki-${LOKI_INSTANCE_NAME}.container
#
# This file is the shell-fallback counterpart to
# ansible/roles/loki_lab/templates/loki.container.j2 — the two must stay in
# sync. The Ansible role is the primary deployment path.
#
# Why a concrete per-instance file (not an instantiated loki@.container):
# Quadlet resolves Volume= references at generator time and cannot expand the
# systemd %i specifier. An instantiated template would be silently dropped by
# the generator. Rendering one file per instance avoids that entirely and is
# still multi-instance safe — each deploy renders its own filename.
#
# envsubst uses ${VARIABLE} notation. Only variables exported by deploy.sh are
# substituted; no other shell expansion occurs.
#
# Podman compatibility: Podman 4.4+ (RHEL 9 target).
#
# TLS NOTE: Loki listens on plain HTTP only. TLS is terminated at Traefik.
# Do not add TLS configuration to this unit.

[Unit]
Description=Loki log aggregation instance ${LOKI_INSTANCE_NAME}
After=network-online.target

[Container]
Image=${LOKI_IMAGE}
ContainerName=loki-${LOKI_INSTANCE_NAME}
Network=${LOKI_PODMAN_NETWORK}

# Per-instance Podman volume (created by deploy.sh before the unit is started).
Volume=loki-${LOKI_INSTANCE_NAME}:/loki:Z
# Per-instance rendered config file (read-only inside the container).
Volume=${LOKI_CONFIG_DIR_BASE}/${LOKI_INSTANCE_NAME}/loki.yaml:/etc/loki/loki.yaml:ro,Z

# Ports bound to localhost only. Emitted only when LOKI_PUBLISH_PORTS=true —
# Traefik reaches Loki over the container network by default, so host ports
# are not required. Set LOKI_PUBLISH_PORTS=true for co-located tooling (e.g.
# Grafana Alloy) that needs direct 127.0.0.1 access.
${LOKI_PUBLISHPORT_HTTP_LINE}
${LOKI_PUBLISHPORT_GRPC_LINE}

Exec=-config.file=/etc/loki/loki.yaml

# Traefik routing labels — subdomain per instance, TLS terminated at Traefik.
# Router and service names include the instance name to prevent label
# collisions across instances. loadbalancer.server.port=3100 is the
# container-internal HTTP port — Traefik communicates with Loki over plain HTTP.
Label=traefik.enable=true
Label=traefik.http.routers.loki-${LOKI_INSTANCE_NAME}.rule=Host(`${LOKI_INSTANCE_NAME}.loki.${LOKI_TRAEFIK_DOMAIN}`)
Label=traefik.http.routers.loki-${LOKI_INSTANCE_NAME}.entrypoints=${LOKI_TRAEFIK_ENTRYPOINT}
${LOKI_TLS_LABEL_LINE}
Label=traefik.http.services.loki-${LOKI_INSTANCE_NAME}.loadbalancer.server.port=3100

[Service]
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
