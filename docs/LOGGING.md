# Archinfra Logging contract

## Responsibilities
- ECK manages Elasticsearch and Kibana; archinfra .run packages the ECK bootstrap and Elastic images.
- Fluent Bit is optional and is deployed as a single K8s node-level DaemonSet.
- Collector is OFF by default. Enable it only with --collector-secret pointing to an already provisioned Elasticsearch least-privilege writer.
- Never reuse the ECK-managed elastic superuser credentials for log collection.
- Collector Secret must have username and password fields, scoped for writing logs-k8s-* with appropriate index auto-create permissions.
- Fluent Bit reads ECK's HTTP public CA and verifies HTTPS connections.
- Per-node hostPath /var/lib/archinfra/fluent-bit persists buffer and tail offset database through pod restarts; it is NOT infinite durability.
- Logs use daily logs-k8s-* indices for this MVP. Templates, ILM and explicit retention must be added before production deployment.
- Add sensitive field redaction, retention and audit access control for real customer environments.
- Systemd/auditd/Windows collection is future work; phase 1 is Kubernetes container logs only.

## Acceptance criteria
1. Offline .run can be built for amd64 and arm64 (separately).
2. Cluster image loads and ECK watches ES/Kibana resources.
3. ES uses TLS and ClusterIP only; PVCs retained when CR is removed.
4. Kibana can access ES through the generated ECK association.
5. With dedicated writer Secret, Fluent Bit can ship container logs.
6. During ES outages, buffer growth and backpressure are measured; alerts are required.
7. HA deployment uses three different schedulable workers and verified StorageClass.

## Next work
- Index templates/ILM and Data Streams.
- Prometheus exporter / ServiceMonitor / PrometheusRule / Grafana dashboards.
- Snapshot repository configuration, restore drill and rolling upgrade checks.
- Per-architecture image digest pinning and provenance verification.
- Mixed-architecture multi-platform image manifest assembly in registry.
