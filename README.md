# andusystems-storage

Infrastructure-as-code for the **storage cluster** -- a dedicated Kubernetes cluster providing persistent storage, S3-compatible object storage, and a full observability pipeline within a multi-cluster homelab environment.

## Purpose

This repository automates the full lifecycle of the storage cluster:

- **VM provisioning** via Terraform on Proxmox
- **Kubernetes bootstrap** via kubeadm with Flannel CNI
- **Application deployment** via Ansible roles that apply Helm values and Kubernetes manifests

The storage cluster sits on its own network segment, isolated from management, DMZ, and public-facing clusters. It acts as a **spoke** in a hub-spoke observability model -- telemetry backends run here, while the hub cluster provides the Grafana visualization layer.

## Components

| Component | Role | Namespace |
|---|---|---|
| **Longhorn** | Distributed block storage (default StorageClass, 3-replica) | `longhorn-system` |
| **MinIO** | S3-compatible object storage for logs and traces | `minio` |
| **Prometheus** (kube-prometheus-stack) | Metrics collection, alerting, remote-write receiver | `monitoring` |
| **Loki** | Log aggregation (single-binary mode, MinIO backend) | `loki` |
| **Tempo** | Distributed tracing (OTLP receivers, MinIO backend) | `tempo` |
| **Alloy** | Telemetry collector -- metrics, logs, traces, and events | `alloy` |
| **cert-manager** | TLS certificate automation via Let's Encrypt / Cloudflare DNS-01 | `cert-manager` |
| **MetalLB** | Bare-metal LoadBalancer (L2 advertisement) | `metallb` |
| **Pangolin Newt** | Tunnel agent for external connectivity | `newt` |

### Alloy

[Grafana Alloy](https://grafana.com/docs/alloy/) is deployed as four specialized instances, each handling a distinct telemetry signal:

| Instance | Mode | Function |
|---|---|---|
| `alloy-metrics` | DaemonSet | Scrapes kubelet, cAdvisor, kube-state-metrics, node-exporter, and annotated pods; remote-writes to Prometheus |
| `alloy-logs` | DaemonSet | Collects pod stdout/stderr via the Kubernetes API; pushes to Loki |
| `alloy-singleton` | Single replica | Watches Kubernetes events; pushes to Loki |
| `alloy-receiver` | Single replica | Accepts OTLP traces (gRPC :4317, HTTP :4318) and metrics from instrumented applications; forwards traces to Tempo and metrics to Prometheus |

The metrics and logs instances tolerate control-plane taints so every node is covered. Node-exporter and kube-state-metrics sub-charts are disabled in Alloy because kube-prometheus-stack already deploys them.

### Loki

[Grafana Loki](https://grafana.com/docs/loki/) runs in **single-binary mode** (all components in one process) with a MinIO S3 backend:

- **Schema**: TSDB v13 with 24h index period
- **Retention**: 30 days
- **Ingestion rate**: 8 MB/s (burst 16 MB/s)
- **Storage buckets**: `loki-data` (chunks), `loki-ruler` (ruler config)
- **Persistence**: 10Gi Longhorn PVC for WAL and local index

Auth is disabled (single-tenant). The service is exposed as a LoadBalancer so the hub Grafana cluster can query logs directly.

### Tempo

[Grafana Tempo](https://grafana.com/docs/tempo/) provides distributed tracing with OTLP receivers and a MinIO S3 backend:

- **Receivers**: OTLP gRPC (:4317) and HTTP (:4318)
- **Storage bucket**: `tempo-data`
- **Span metrics**: Enabled -- generates RED (rate, error, duration) metrics from traces and remote-writes them to Prometheus, giving service-level metrics without app-side instrumentation
- **Persistence**: 10Gi Longhorn PVC for WAL and local cache

Exposed as a LoadBalancer for cross-cluster trace queries.

### Prometheus (kube-prometheus-stack)

The [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) deploys Prometheus, Alertmanager, node-exporter, and kube-state-metrics:

- **Retention**: 7 days (15Gi Longhorn PVC)
- **Remote-write receiver**: Enabled -- Alloy and Tempo push metrics via the `/api/v1/write` endpoint
- **External labels**: `cluster: storage`, `vlan: "40"` for multi-cluster identification
- **Grafana**: Disabled -- this is a spoke cluster; Grafana runs on the hub

Prometheus selectors are set to nil, meaning ServiceMonitors and PodMonitors from all namespaces are scraped. The service is exposed as a LoadBalancer on port 9090.

### MinIO

[MinIO](https://min.io/) runs in **standalone mode** (single-node) providing S3-compatible object storage:

- **Persistence**: 20Gi Longhorn PVC (durability via Longhorn 3-replica replication)
- **Pre-created buckets**: `loki-data`, `loki-ruler`, `tempo-data`
- **Services**: API on port 9000 (LoadBalancer), Console on port 9001 (LoadBalancer)

Loki and Tempo connect to MinIO via the in-cluster endpoint `minio.minio.svc.cluster.local:9000`.

### Longhorn

[Longhorn](https://longhorn.io/) is the sole StorageClass, providing distributed block storage across all worker nodes:

- **Default replica count**: 3 (across 5 workers)
- **Storage overprovisioning**: 200% with a 15% minimum available threshold
- **Data path**: `/var/lib/longhorn`
- **UI**: Disabled (headless mode)

All stateful workloads (Prometheus, Alertmanager, Loki, Tempo, MinIO) use Longhorn PVCs.

### MetalLB

[MetalLB](https://metallb.universe.tf/) provides bare-metal LoadBalancer services using Layer 2 (ARP) advertisement:

- **IP pool**: Configured via vault (`metallb_ip_range`)
- **Exposed services**: Prometheus (:9090), Loki (:3100), Tempo (:4317/:4318), MinIO (:9000/:9001)

### cert-manager

[cert-manager](https://cert-manager.io/) automates TLS certificate issuance via Let's Encrypt with Cloudflare DNS-01 challenges:

- **ClusterIssuer**: Let's Encrypt production ACME
- **DNS solver**: Cloudflare API (token stored in vault)
- **Nameservers**: 1.1.1.1, 8.8.8.8 (DNS-01 only)

### Pangolin Newt

[Pangolin Newt](https://docs.fossorial.io/) is a tunnel agent that provides external connectivity to the storage cluster from the hub/management network. Credentials (endpoint, ID, secret) are injected from vault.

## Quick Start

### Prerequisites

- Ansible (with `kubernetes.core` collection)
- Terraform
- `kubectl`
- SSH access to target nodes
- An Ansible Vault file with secrets (see `ansible/inventory/storage/group_vars/all/vault.example`)

### 1. Install Ansible dependencies

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

### 2. Configure secrets

Copy the vault example and fill in your values:

```bash
cp ansible/inventory/storage/group_vars/all/vault.example \
   ansible/inventory/storage/group_vars/all/vault
```

Encrypt the vault file:

```bash
ansible-vault encrypt ansible/inventory/storage/group_vars/all/vault
```

### 3. Deploy the full stack

```bash
cd ansible/configurations
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass
```

This runs three stages in order:

1. **VMs** -- provisions virtual machines via Terraform on Proxmox
2. **Kubernetes** -- bootstraps the cluster with kubeadm and Flannel CNI
3. **Apps** -- deploys all applications in dependency order

### Deploy apps only (existing cluster)

```bash
ansible-playbook apps.yml -i ../inventory/storage/hosts.yml --ask-vault-pass
```

### Deploy individual components

Use Ansible tags to target specific roles:

```bash
# Infrastructure
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags vms
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags kubernetes

# Applications
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags cert-manager
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags pangolin-newt
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags kube-prometheus-stack
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags minio
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags loki
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags tempo
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags alloy
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags metallb
```

## Configuration Reference

All sensitive values are stored in Ansible Vault. Required configuration keys:

| Key | Description |
|---|---|
| `repo_root` | Absolute path to this repository on the Ansible controller |
| `ssh_user` | SSH username for node access |
| `ssh_key_path` | Path to the SSH private key |
| `control_plane_ip` | IP address of the control plane node |
| `worker_ips` | List of worker node IP addresses |
| `kubernetes_version` | Kubernetes version to install (e.g. `1.31`) |
| `pod_network_cidr` | CIDR for the Flannel pod network |
| `kubeconfig` | Path where kubeconfig will be written |
| `cloudflare_api_token` | Cloudflare API token for DNS-01 challenges |
| `letsencrypt_email` | Email for Let's Encrypt registration |
| `pangolin_endpoint` | Pangolin server endpoint |
| `newt_id` / `newt_secret` | Pangolin Newt authentication credentials |
| `metallb_ip_range` | IP range for MetalLB address pool |
| `grafana_admin_user` / `grafana_admin_password` | Grafana credentials (used by Prometheus stack) |
| `minio_root_user` / `minio_root_password` | MinIO root credentials |

## Architecture Summary

The cluster follows a layered design:

- **Infrastructure layer**: Terraform provisions Proxmox VMs; kubeadm bootstraps Kubernetes with Flannel CNI
- **Storage layer**: Longhorn provides block PVCs for all stateful workloads; MinIO provides S3 buckets for Loki and Tempo
- **Observability layer**: Alloy collects metrics, logs, traces, and events from the cluster and ships them to Prometheus, Loki, and Tempo respectively
- **Networking layer**: MetalLB exposes services via L2 LoadBalancer IPs; cert-manager handles TLS via Cloudflare DNS-01; Pangolin Newt provides tunnel connectivity

Grafana is **not** deployed on this cluster. The hub/monitoring cluster queries Prometheus via remote-write and accesses Loki/Tempo via their LoadBalancer endpoints.

## Repository Structure

```
.
├── ansible/
│   ├── ansible.cfg                     # Ansible configuration
│   ├── requirements.yml                # Galaxy collection dependencies
│   ├── configurations/
│   │   ├── storage.yml                 # Full-stack playbook (VMs -> K8s -> Apps)
│   │   ├── apps.yml                    # Apps-only playbook
│   │   └── roles/
│   │       ├── vms/                    # VM provisioning via Terraform
│   │       ├── kubernetes/             # kubeadm cluster bootstrap
│   │       ├── cert-manager/           # TLS certificate management
│   │       ├── pangolin-newt/          # Tunnel agent deployment
│   │       ├── kube-prometheus-stack/  # Prometheus, Alertmanager, exporters
│   │       ├── minio/                  # S3-compatible object storage
│   │       ├── loki/                   # Log aggregation
│   │       ├── tempo/                  # Distributed tracing
│   │       ├── alloy/                  # Telemetry collector
│   │       └── metallb/                # Bare-metal load balancer
│   └── inventory/
│       └── storage/
│           ├── hosts.yml               # Inventory (control plane + workers)
│           └── group_vars/all/
│               ├── vars.yml            # Variable definitions (references vault)
│               └── vault.example       # Template for secrets
├── apps/
│   ├── alloy/values.yml                # Grafana Alloy collector config
│   ├── cert-manager/                   # cert-manager values + ClusterIssuer
│   ├── kube-prometheus-stack/values.yml # Prometheus operator stack config
│   ├── loki/                           # Loki values + MinIO credentials
│   ├── longhorn/                       # Longhorn storage values
│   ├── metallb/                        # MetalLB IPAddressPool manifest
│   ├── minio/                          # MinIO values + credentials
│   ├── pangolin-newt/                  # Newt values + credentials
│   └── tempo/                          # Tempo values + MinIO credentials
└── docs/
    ├── architecture.md                 # Component diagram, data flows, design decisions
    └── development.md                  # Local setup, prerequisites, workflow
```

## Further Documentation

- [Architecture](docs/architecture.md) -- component diagram, data flows, and design decisions
- [Development Guide](docs/development.md) -- local setup, prerequisites, and workflow
- [Changelog](CHANGELOG.md) -- version history
