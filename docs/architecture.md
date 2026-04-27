# Architecture

## Overview

The storage cluster is a bare-metal Kubernetes cluster provisioned on Proxmox virtual machines. It serves two primary functions within the multi-cluster homelab:

1. **Persistent storage** — Longhorn (distributed block storage) and MinIO (S3-compatible object storage)
2. **Observability pipeline** — Prometheus, Loki, Tempo, and Alloy form a complete metrics/logs/traces stack

The cluster operates on a dedicated network segment, isolated from management, DMZ, and public-facing clusters. It follows a **spoke** model in a hub-spoke observability architecture — telemetry backends run here, but Grafana lives on the hub cluster and queries these backends remotely.

## Component diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           Storage Cluster                                │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐  │
│  │  cert-manager    │  │    MetalLB      │  │     Pangolin Newt       │  │
│  │  (TLS via ACME)  │  │  (L2 LB IPs)   │  │  (tunnel to hub net)    │  │
│  └─────────────────┘  └────────┬────────┘  └─────────────────────────┘  │
│                                │ LoadBalancer IPs                        │
│  ┌─────────────────────────────▼──────────────────────────────────────┐  │
│  │  Storage Layer                                                     │  │
│  │                                                                    │  │
│  │  ┌───────────────────────┐     ┌──────────────────────────────┐   │  │
│  │  │       Longhorn         │     │             MinIO             │   │  │
│  │  │  distributed block     │     │  S3-compatible object store   │   │  │
│  │  │  storage (3-replica)   │     │  buckets: loki-data,          │   │  │
│  │  │  default StorageClass  │     │  loki-ruler, tempo-data,      │   │  │
│  │  └──────────┬────────────┘     │  nexus-blobs                  │   │  │
│  │             │ PVC              └──────────────┬───────────────┘   │  │
│  │             ▼                                 │ S3 API             │  │
│  │  Prometheus PVC (15 Gi)                       ▼                   │  │
│  │  Alertmanager PVC (2 Gi)       Loki, Tempo, Nexus consume S3      │  │
│  │  Loki WAL PVC (10 Gi)                                             │  │
│  │  Tempo WAL PVC (10 Gi)                                            │  │
│  │  MinIO data PVC (20 Gi)                                           │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Observability Pipeline                                            │  │
│  │                                                                    │  │
│  │  ┌──────────────────────────────────────────────────────────────┐  │  │
│  │  │  Alloy (four specialized instances)                          │  │  │
│  │  │  alloy-metrics (DaemonSet) — scrapes kubelets, cAdvisor,    │  │  │
│  │  │    kube-state-metrics, node-exporter, annotated pods        │  │  │
│  │  │  alloy-logs (DaemonSet) — pod stdout/stderr via K8s API     │  │  │
│  │  │  alloy-singleton (Deployment) — Kubernetes cluster events   │  │  │
│  │  │  alloy-receiver (Deployment) — OTLP gRPC + HTTP ingest      │  │  │
│  │  └──────┬────────────────┬────────────────────┬───────────────┘  │  │
│  │         │ remote-write   │ push               │ gRPC/HTTP         │  │
│  │         ▼                ▼                    ▼                   │  │
│  │  ┌────────────┐  ┌────────────┐  ┌───────────────────────────┐   │  │
│  │  │ Prometheus  │  │    Loki    │  │          Tempo             │   │  │
│  │  │  metrics    │  │   logs     │  │  traces + span metrics     │   │  │
│  │  │  7-day ret. │  │  30-day    │  │  remote-writes to Prom.   │   │  │
│  │  └─────┬──────┘  └─────┬──────┘  └────────────┬──────────────┘   │  │
│  │        │               │ S3 backend             │                  │  │
│  │        │               └──────────┬─────────────┘                 │  │
│  │        │                          ▼                                │  │
│  │        │                   MinIO (S3 buckets)                      │  │
│  │        └─► Longhorn PVC (local TSDB)                               │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Registry                                                          │  │
│  │  Nexus — Docker registry + artifact store                          │  │
│  │  backed by MinIO blob store (nexus-blobs S3 bucket)               │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘

         ▲ MetalLB LoadBalancer IPs reachable from hub cluster
         │  Prometheus ◄── remote metric queries from hub Grafana
         │  Loki       ◄── log queries from hub Grafana
         │  Tempo      ◄── trace queries from hub Grafana
         │  MinIO      ◄── S3 API + console (cross-cluster)
```

## Data flows

### Telemetry collection (Alloy)

Alloy runs as four specialized instances, each handling a distinct signal:

| Instance | Mode | Sources | Destination |
|---|---|---|---|
| `alloy-metrics` | DaemonSet (all nodes) | kubelet, cAdvisor, kube-state-metrics, node-exporter, annotated pods | Prometheus remote-write |
| `alloy-logs` | DaemonSet (all nodes) | Pod stdout/stderr via Kubernetes API | Loki push API |
| `alloy-singleton` | Single replica | Kubernetes cluster events | Loki push API |
| `alloy-receiver` | Single replica | OTLP gRPC and HTTP from instrumented apps | Tempo (traces), Prometheus (metrics) |

The `alloy-metrics` and `alloy-logs` instances tolerate control-plane node taints to ensure every node is covered. The `alloy-receiver` accepts OTLP from external instrumented services on the cluster network.

### Span metrics generation

Tempo generates RED (rate, error, duration) metrics from ingested traces and remote-writes them to Prometheus. This provides service-level metrics without requiring application-side metric instrumentation.

### Object storage (MinIO)

MinIO runs in standalone mode and provides S3-compatible storage for the observability backends:

| Bucket | Consumer | Content |
|---|---|---|
| `loki-data` | Loki | Log chunk storage |
| `loki-ruler` | Loki | Ruler configuration |
| `tempo-data` | Tempo | Distributed trace data |
| `nexus-blobs` | Nexus | Docker image layers and artifacts |

Loki, Tempo, and Nexus authenticate via Kubernetes secrets injected from Ansible Vault at deploy time. The in-cluster S3 endpoint is used for all backend writes.

### Block storage (Longhorn)

Longhorn is the sole `StorageClass`, with 3-replica redundancy and 200% over-provisioning. It backs all stateful workloads:

| Consumer | PVC size | Purpose |
|---|---|---|
| Prometheus | 15 Gi | Local TSDB (7-day retention) |
| Alertmanager | 2 Gi | Alert state and silences |
| Loki | 10 Gi | WAL and local index |
| Tempo | 10 Gi | WAL and local block cache |
| MinIO | 20 Gi | S3 object data directory |

### Network access (MetalLB)

MetalLB provides Layer 2 load balancing via ARP advertisement, assigning IPs from the configured pool. The following services are exposed as `LoadBalancer` type for cross-cluster access:

- **Prometheus** — remote-write receiver endpoint for hub Grafana
- **Loki** — push and query API for hub Grafana log datasource
- **Tempo** — OTLP receiver and trace query API
- **MinIO** — S3 API and web console

### TLS certificate flow

```
cert-manager ClusterIssuer (letsencrypt)
  │
  ▼ ACME DNS-01 challenge
Cloudflare API  →  DNS TXT record created
  │
  ▼ Let's Encrypt validates DNS record
Certificate issued  →  stored as Kubernetes TLS Secret
  │
  ▼ mounted by Ingress / IngressRoute
```

cert-manager uses Cloudflare DNS-01 challenges exclusively, enabling wildcard certificate support without requiring HTTP-reachable endpoints.

### Nexus registry access

```
CI/CD pipeline (hub network)
  │ docker push (ci-pusher credentials)
  ▼
Nexus Docker registry (andusystems-docker repo)
  │ stores layers in MinIO nexus-blobs bucket
  ▼
Consuming clusters
  │ docker pull (cluster-puller credentials via imagePullSecret)
  ▼
Workload containers
```

Two service accounts are provisioned automatically: `ci-pusher` (read/write) for build pipelines and `cluster-puller` (read-only) for consuming clusters.

## Key design decisions

### Spoke cluster — no Grafana

This is a spoke cluster in a hub-spoke observability model. Grafana runs on the hub/monitoring cluster, not here. The kube-prometheus-stack chart has `grafana.enabled: false`. Prometheus exposes a remote-write receiver; Loki and Tempo are accessible via LoadBalancer IPs. The `cluster: storage` external label identifies this cluster's metrics in multi-cluster Grafana queries.

### Single-binary Loki

Loki is deployed in single-binary mode (not microservices) to reduce resource overhead. The distributed components (`backend`, `read`, `write`) are explicitly set to 0 replicas. This trade-off is appropriate for homelab scale. Loki uses TSDB v13 schema with a 30-day retention period and 8 MB/s ingestion rate limit (burst 16 MB/s).

### Flannel CNI

The cluster uses Flannel for pod networking, chosen for simplicity over Calico or Cilium. Flannel has minimal resource overhead and configuration complexity at the cost of lacking network policy support — an acceptable trade-off for this isolated, single-purpose cluster.

### Terraform + Ansible layered provisioning

Infrastructure is provisioned in layers:

1. **Terraform** — VM creation on Proxmox
2. **Ansible roles** — Kubernetes bootstrap and application deployment

This separation allows re-running application deployments without reprovisioning VMs, and re-deploying individual components via tags without affecting others.

### Secrets via Ansible Vault

All secrets (Cloudflare tokens, MinIO credentials, Newt credentials, Nexus passwords) are stored in Ansible Vault and rendered into Kubernetes secrets at deploy time via Jinja2 templating. No secrets are committed to the repository.

### MinIO standalone mode

MinIO runs in single-node mode rather than distributed/erasure-coded mode. Simplicity of operations is prioritized; durability is handled at the block storage layer by Longhorn's 3-replica replication of the MinIO PVC.

### Alloy over Prometheus agent

Grafana Alloy is used as the unified telemetry collector instead of Prometheus agent mode. A single Alloy deployment handles metrics, logs, traces, and events. The kube-prometheus-stack still provides node-exporter and kube-state-metrics as metric sources; Alloy's own sub-chart deployments of these exporters are disabled to avoid duplication.

### Nexus with MinIO blob store

Nexus uses MinIO as its blob store backend (S3 protocol), keeping all artifact data in the same durable S3 layer as the observability backends. The blob store must be created via the Nexus UI before the post-install automation runs; subsequent role, user, and realm configuration is fully automated via the Kubernetes API.

## Cluster topology

The cluster consists of a single control plane node and multiple worker nodes, all running as Proxmox virtual machines. The inventory supports scaling by uncommenting additional worker entries. All nodes run on the same dedicated network segment. kubeadm bootstraps the cluster with a single control plane; no high-availability control plane is configured (single-purpose homelab trade-off).

## Concurrency and scheduling

- **Alloy metrics/logs** run as DaemonSets with control-plane tolerations, ensuring every node is covered
- **Alloy singleton** runs as a single replica — Kubernetes events are cluster-wide, not per-node
- **Alloy receiver** runs as a single replica accepting OTLP from instrumented applications
- **Loki single-binary** serializes all read/write operations in a single process — appropriate for current scale
- **Prometheus** uses a single replica with local TSDB storage (no Thanos or Cortex sharding)
- **Longhorn** manages replica scheduling across worker nodes, maintaining 3 copies of each volume

No horizontal pod autoscaling is configured. Resource limits are tuned for homelab-scale workloads.

## Invariants

- Longhorn is always the default and only `StorageClass`
- All observability long-term data flows through MinIO S3 buckets for durable storage
- Prometheus must have `enableRemoteWriteReceiver: true` for cross-cluster metric federation
- The `cluster: storage` external label identifies this cluster's metrics in multi-cluster queries
- cert-manager uses Cloudflare DNS-01 challenges exclusively (no HTTP-01)
- Application deployment order must follow: MetalLB → cert-manager → pangolin-newt → kube-prometheus-stack → minio → loki → tempo → alloy → nexus
- Grafana is never deployed on this cluster (spoke model)
- MetalLB operates in L2 mode only (ARP advertisement, no BGP)
- The `nexus-blobs` S3 blob store must be created manually in the Nexus UI before the post-install automation role runs
