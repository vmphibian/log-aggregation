# Loki configuration — monolithic mode
# Shell fallback template — rendered via envsubst by scripts/deploy.sh
# Equivalent to ansible/roles/loki_lab/templates/loki.yaml.j2
#
# Syntax note: envsubst uses ${VARIABLE} notation. Jinja2 uses {{ variable }}.
# Keep this file in sync with loki.yaml.j2. The semantics must be identical.
#
# TLS NOTE: This file contains NO TLS configuration. Loki listens on plain
# HTTP only. TLS is terminated exclusively at Traefik. Do not add TLS
# certificates, HTTPS listeners, or tls: blocks to this file.

auth_enabled: false

target: all

server:
  http_listen_port: 3100
  grpc_listen_port: 9095

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: "2024-01-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/tsdb-index
    cache_location: /loki/tsdb-cache
    cache_ttl: 24h
  filesystem:
    directory: /loki/chunks

compactor:
  working_directory: /loki/compactor
  delete_request_store: filesystem
  retention_enabled: true

limits_config:
  ingestion_rate_mb: 4
  ingestion_burst_size_mb: 6
  max_streams_per_user: 10000
  retention_period: ${LOKI_RETENTION_PERIOD}
  max_query_length: 721h
  max_entries_limit_per_query: 50000

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

ruler:
  alertmanager_url: http://localhost:9093

analytics:
  reporting_enabled: false
