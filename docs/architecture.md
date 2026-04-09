# Architecture

## Overview

The storage cluster is a bare-metal Kubernetes cluster provisioned on Proxmox virtual machines. It serves two primary functions within the multi-cluster homelab:

1. **Persistent storage** -- Longhorn (distributed block storage) and MinIO (S3-compatible object storage)
2. **Observability pipeline** -- Prometheus, Loki, Tempo, and Alloy form a complete metrics/logs/traces stack

The cluster operates on a dedicated network segment, isolated from management, DMZ, and public-facing clusters. It follows a **spoke** model in a hub-spoke observability architecture -- telemetry backends run here, but Grafana lives on the hub cluster and queries these backends remotely.

## Component Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          Storage Cluster                                 │
│                                                                          │
│  ┌───────────────┐   ┌───────────────┐   ┌───────────────┐              │
│  │  cert-manager  │   │    MetalLB     │   │ Pangolin Newt │              │
│  │  (TLS certs)   │   │ (L2 LoadBal)  │   │   (tunnel)    │              │
│  └───────────────┘   └───────────────┘   └───────────────┘              │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                       Storage Layer                                │  │
│  │                                                                    │  │
│  │  ┌───────────────┐              ┌───────────────┐                  │  │
│  │  │    Longhorn    │              │     MinIO      │                  │  │
│  │  │  (block PVCs)  │              │  (S3 object)   │                  │  │
│  │  └───────┬───────┘              └───────┬───────┘                  │  │
│  │          │ StorageClass                 │ S3 API                    │  │
│  │          ▼                              ▼                           │  │
│  │  Used by: Prometheus,            Used by: Loki, Tempo               │  │
│  │  Alertmanager, Loki WAL,                                            │  │
│  │  Tempo WAL, MinIO                                                   │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                    Observability Pipeline                           │  │
│  │                                                                    │  │
│  │                  ┌──────────────────┐                               │  │
│  │                  │      Alloy       │                               │  │
│  │                  │   (collector)    │                               │  │
│  │                  └──┬────┬────┬──┘                                  │  │
│  │          metrics    │    │    │   traces                            │  │
│  │                     │    │logs│                                     │  │
│  │            ┌────────┘    │    └─────────┐                           │  │
│  │            ▼             ▼              ▼                            │  │
│  │    ┌────────────┐  ┌──────────┐  ┌──────────┐                      │  │
│  │    │ Prometheus  │  │   Loki   │  │  Tempo   │                      │  │
│  │    │  (metrics)  │  │  (logs)  │  │ (traces) │                      │  │
│  │    └─────┬──────┘  └────┬─────┘  └────┬─────┘                      │  │
│  │          │              │              │                             │  │
│  │          │    ┌─────────┴──────────────┘                            │  │
│  │          │    │  S3 storage                                         │  │
│  │          │    ▼                                                      │  │
│  │          │  MinIO (loki-data, loki-ruler, tempo-data)               │  │
│  │          │                                                          │  │
│  │          └──► Longhorn PVC (TSDB, 7-day retention)                  │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                    External Access (MetalLB)                        │  │
│  │                                                                    │  │
│  │  Prometheus ◄── remote-write queries from hub Grafana               │  │
│  │  Loki       ◄── log queries from hub Grafana                        │  │
│  │  Tempo      ◄── trace queries from hub Grafana                      │  │
│  │  MinIO      ◄── S3 API + console (cross-cluster access)            │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

## Data Flows

### Telemetry Collection (Alloy)

Alloy runs as four specialized instances within the cluster:

| Instance | Role | Targets |
|---|---|---|
| **alloy-metrics** | Scrapes Prometheus metrics from kubelets, cAdvisor, kube-state-metrics, node-exporter, and annotated pods | Prometheus remote-write |
| **alloy-logs** | Collects pod stdout/stderr via the Kubernetes API | Loki push API |
| **alloy-singleton** | Collects Kubernetes events (single replica, not per-node) | Loki push API |
| **alloy-receiver** | Receives OTLP traces and metrics from instrumented applications | Tempo (gRPC), Prometheus |

```
  Pods / Kubelets / K8s API
         │
         ▼
  ┌─────────────┐     remote write      ┌────────────┐
  │ alloy-metrics├─────────────────────►│ Prometheus  │
  └─────────────┘                       └────────────┘
  ┌─────────────┐     push              ┌────────────┐
  │  alloy-logs ├─────────────────────►│    Loki    │
  └─────────────┘                       └────────────┘
  ┌─────────────┐     push              ┌────────────┐
  │alloy-singlet├─────────────────────►│    Loki    │
  └─────────────┘                       └────────────┘
  ┌─────────────┐     gRPC (OTLP)      ┌────────────┐
  │alloy-receive├─────────────────────►│   Tempo    │
  └─────────────┘                       └────────────┘
```

The `alloy-metrics` and `alloy-logs` instances tolerate control-plane node taints to ensure cluster-wide collection. The `alloy-receiver` exposes OTLP gRPC and HTTP ports for application instrumentation.

### Span Metrics Generation

Tempo generates span metrics (request rates, error rates, duration histograms) from ingested traces and writes them to Prometheus via remote-write. This enables RED metrics without application-level instrumentation.

### Object Storage (MinIO)

MinIO runs in standalone (single-node) mode and provides S3-compatible storage for the observability backends:

| Bucket | Consumer | Purpose |
|---|---|---|
| `loki-data` | Loki | Log chunk storage |
| `loki-ruler` | Loki | Ruler configuration |
| `tempo-data` | Tempo | Trace data storage |

Loki and Tempo authenticate to MinIO using Kubernetes secrets injected via Ansible Vault at deploy time.

### Block Storage (Longhorn)

Longhorn is the default and only `StorageClass`, configured with 3-replica redundancy and 200% over-provisioning. It backs all stateful workloads:

| Consumer | Size | Purpose |
|---|---|---|
| Prometheus | 15 Gi | TSDB (7-day retention) |
| Alertmanager | 2 Gi | Alert state and silences |
| Loki | 10 Gi | WAL and local index |
| Tempo | 10 Gi | WAL and local cache |
| MinIO | 20 Gi | Object data directory |

### Network Access (MetalLB)

MetalLB provides Layer 2 load balancing, assigning IPs from a configured pool. Key services exposed as LoadBalancer type:

- **Prometheus** -- remote-write endpoint for cross-cluster metric federation
- **Loki** -- push and query API for hub Grafana
- **Tempo** -- OTLP receiver and query API
- **MinIO** -- S3 API and web console for cross-cluster access

### TLS Certificate Flow

```
cert-manager ClusterIssuer
  │
  ▼ (ACME DNS-01 challenge)
Cloudflare API
  │
  ▼ (DNS record creation + validation)
Let's Encrypt
  │
  ▼ (certificate issuance)
Kubernetes TLS Secret
```

cert-manager uses Cloudflare DNS-01 challenges exclusively. The Cloudflare API token is stored in Ansible Vault and injected as a Kubernetes secret.

## Key Design Decisions

### Spoke Cluster -- No Grafana

This is a "spoke" cluster in a hub-spoke observability model. Grafana runs on the hub/monitoring cluster, not here. The Prometheus stack has `grafana.enabled: false`. Prometheus exposes a remote-write receiver so the hub Grafana can query metrics. Loki and Tempo are accessible via their LoadBalancer endpoints for log and trace queries.

### Single-Binary Loki

Loki is deployed in single-binary mode (not microservices) to reduce resource overhead. This is appropriate for the homelab scale. The distributed components (`backend`, `read`, `write`) are explicitly set to 0 replicas. Loki uses TSDB v13 schema with a 30-day retention period.

### Flannel CNI

The cluster uses Flannel for pod networking, chosen for simplicity over alternatives like Calico or Cilium. This is a deliberate trade-off: Flannel lacks network policy support but has minimal resource overhead and configuration complexity.

### Terraform + Ansible Layered Provisioning

Infrastructure is provisioned in layers:

1. **Layer 1** (Terraform) -- VM creation on Proxmox
2. **Layer 2** (Terraform) -- Helm chart installations (MetalLB)
3. **Ansible roles** -- Kubernetes bootstrap and application deployment

This separation allows re-running application deployments without reprovisioning VMs, and re-deploying individual components via tags without affecting others.

### Secrets via Ansible Vault

All secrets (Cloudflare tokens, MinIO credentials, Newt credentials, etc.) are stored in Ansible Vault and rendered into Kubernetes secrets at deploy time via Jinja2 templating. No secrets are committed to the repository.

### MinIO Standalone Mode

MinIO runs in single-node mode rather than distributed/erasure-coded mode. This simplifies operations at the cost of S3-level redundancy -- durability is handled at the block storage layer by Longhorn's 3-replica replication.

### Alloy Over Prometheus Agent

Grafana Alloy is used as the telemetry collector instead of Prometheus agent mode. Alloy handles metrics, logs, traces, and events in a single deployment, reducing operational overhead. The kube-prometheus-stack still deploys node-exporter and kube-state-metrics as metric sources, but Alloy's own deployments of these exporters are disabled to avoid duplication.

## Cluster Topology

The cluster consists of a single control plane node and multiple worker nodes, all running as Proxmox virtual machines on bare-metal hardware. The inventory supports scaling by uncommenting additional worker entries. All nodes run on a dedicated network segment.

## Concurrency and Scheduling

- **Alloy metrics/logs** run as DaemonSet-like deployments with control-plane tolerations, ensuring every node is covered
- **Alloy singleton** runs as a single replica for Kubernetes event collection (events are cluster-wide, not per-node)
- **Alloy receiver** runs as a single replica, receiving OTLP data from instrumented applications
- **Loki single-binary** serializes all read/write operations in a single process -- appropriate for the current scale
- **Prometheus** uses a single replica with local TSDB storage (no Thanos/Cortex sharding)
- **Longhorn** manages replica scheduling across worker nodes, maintaining 3 copies of each volume

No horizontal pod autoscaling is configured. Resource limits are tuned for homelab-scale workloads.

## Invariants

- Longhorn is always the default and only `StorageClass`
- All observability long-term data flows through MinIO for durable S3 storage
- Prometheus must have `enableRemoteWriteReceiver: true` for cross-cluster federation
- The `cluster: storage` external label identifies this cluster's metrics in multi-cluster queries
- cert-manager uses Cloudflare DNS-01 challenges exclusively (no HTTP-01)
- Application deployment order must follow the dependency chain: cert-manager -> pangolin-newt -> kube-prometheus-stack -> minio -> loki -> tempo -> alloy
- Grafana is never deployed on this cluster (spoke model)
- MetalLB operates in L2 mode only (ARP advertisement, no BGP)
