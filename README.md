# andusystems-storage

> IaC for the dedicated storage cluster — distributed block storage, S3-compatible object storage, and a full observability pipeline within the andusystems homelab.

## Purpose

This repository automates the full lifecycle of a dedicated storage cluster: VM provisioning on Proxmox via Terraform, Kubernetes bootstrap via kubeadm with Flannel CNI, and application deployment via Ansible roles. The cluster provides distributed block storage (Longhorn), S3-compatible object storage (MinIO), a Docker image registry (Nexus), and a complete observability pipeline (Prometheus, Loki, Tempo, Alloy). It acts as a spoke in a hub-spoke observability model — telemetry backends run here while the hub cluster hosts Grafana for visualization.

## At a glance

| Field | Value |
|---|---|
| Type | IaC cluster |
| Network | Dedicated storage network segment, isolated from management and public-facing clusters |
| Role | spoke |
| Primary stack | Terraform + Ansible + kubeadm |
| Deployed by | manual Ansible playbook run |
| Status | production |

## Components

| Component | Purpose | Namespace |
|---|---|---|
| Longhorn | Distributed block storage, default StorageClass, 3-replica replication | `longhorn-system` |
| MinIO | S3-compatible object storage backend for logs, traces, and the registry | `minio` |
| kube-prometheus-stack | Metrics collection, Alertmanager, node-exporter, kube-state-metrics | `monitoring` |
| Loki | Log aggregation (single-binary mode, MinIO backend, 30-day retention) | `loki` |
| Tempo | Distributed tracing — OTLP receivers plus span metrics generation | `tempo` |
| Alloy | Unified telemetry collector: metrics, logs, traces, and Kubernetes events | `alloy` |
| Nexus | Docker image registry and artifact store (MinIO S3 blob store backend) | `nexus` |
| MetalLB | Bare-metal L2 LoadBalancer for service exposure | `metallb` |
| cert-manager | TLS automation via Let's Encrypt and Cloudflare DNS-01 | `cert-manager` |
| Pangolin Newt | Tunnel agent for external connectivity to the hub network | `newt` |
| cluster-status | Health-check endpoint for cluster status monitoring | `cluster-status` |

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        Storage Cluster                           │
│                                                                  │
│  ┌─────────────┐   ┌─────────────┐   ┌──────────────────────┐   │
│  │ cert-manager │   │   MetalLB   │   │    Pangolin Newt     │   │
│  │  (TLS certs) │   │ (L2 LB IPs) │   │   (ext. tunnel)     │   │
│  └─────────────┘   └─────────────┘   └──────────────────────┘   │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Storage Layer                                             │  │
│  │  ┌──────────────────────┐  ┌──────────────────────────┐   │  │
│  │  │       Longhorn        │  │          MinIO            │   │  │
│  │  │  (block PVCs, 3-rep)  │  │  (loki/tempo/nexus S3)   │   │  │
│  │  └──────────────────────┘  └──────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Observability Pipeline                                    │  │
│  │  Alloy (metrics · logs · traces · events)                  │  │
│  │     │ metrics        │ logs         │ traces               │  │
│  │     ▼                ▼              ▼                      │  │
│  │  Prometheus        Loki           Tempo                   │  │
│  │  (exposed via MetalLB → hub Grafana queries remotely)      │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Registry: Nexus (Docker registry, MinIO blob store)       │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

Alloy collects telemetry from all cluster workloads and routes it to Prometheus, Loki, and Tempo. Durable data is stored in MinIO S3. MetalLB LoadBalancer IPs expose Prometheus, Loki, and Tempo so the hub Grafana cluster can query them remotely. See [docs/architecture.md](docs/architecture.md) for the full data flow and design decisions.

## Quick start

### Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Ansible | 2.15+ | Orchestrates provisioning and deployment |
| Terraform | 1.5+ | Provisions VMs on Proxmox |
| kubectl | 1.31+ | Kubernetes CLI for verification and debugging |
| ansible-vault | — | Encrypts and decrypts the secrets file |

### Deploy / run

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
cp inventory/storage/group_vars/all/vault.example \
   inventory/storage/group_vars/all/vault
# Populate vault with your values, then encrypt
ansible-vault encrypt inventory/storage/group_vars/all/vault
cd configurations
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass
```

See [docs/development.md](docs/development.md) for apps-only deployment, per-component tags, dry-run mode, and post-deployment verification.

## Configuration

| Key | Required | Description |
|---|---|---|
| `repo_root` | Yes | Absolute path to this repo on the Ansible controller |
| `ssh_user` | Yes | SSH username for node access |
| `ssh_key_path` | Yes | Path to the SSH private key |
| `control_plane_ip` | Yes | IP of the control plane node |
| `worker_ips` | Yes | List of worker node IPs |
| `kubernetes_version` | Yes | Kubernetes version to install (e.g. `1.31`) |
| `pod_network_cidr` | Yes | CIDR for the Flannel pod network |
| `kubeconfig` | Yes | Path where kubeconfig will be written after bootstrap |
| `metallb_ip_range` | Yes | IP range for the MetalLB address pool |
| `cloudflare_api_token` | Yes | Cloudflare API token for DNS-01 challenges |
| `letsencrypt_email` | Yes | Email for Let's Encrypt registration |
| `pangolin_endpoint` | Yes | Pangolin tunnel server endpoint |
| `newt_id` / `newt_secret` | Yes | Pangolin Newt authentication credentials |
| `minio_root_user` / `minio_root_password` | Yes | MinIO root credentials |
| `nexus_admin_password` | Yes | Initial Nexus admin password |
| `nexus_ci_pusher_user` / `nexus_ci_pusher_password` | Yes | CI/CD image push credentials |
| `nexus_cluster_puller_user` / `nexus_cluster_puller_password` | Yes | Read-only image pull credentials for consuming clusters |

All values live in Ansible Vault (`ansible/inventory/storage/group_vars/all/vault`). Use `vault.example` as a template — never commit the populated vault file.

## Repository layout

```
.
├── ansible/
│   ├── ansible.cfg                      # Ansible settings and log path
│   ├── requirements.yml                 # Galaxy collection dependencies
│   ├── configurations/
│   │   ├── storage.yml                  # Full-stack playbook (VMs → K8s → Apps)
│   │   ├── apps.yml                     # Apps-only playbook
│   │   └── roles/                       # Per-component Ansible roles
│   │       ├── vms/                     # Terraform VM provisioning on Proxmox
│   │       ├── kubernetes/              # kubeadm cluster bootstrap + Flannel
│   │       ├── metallb/                 # L2 bare-metal load balancer
│   │       ├── cert-manager/            # TLS certificate automation
│   │       ├── pangolin-newt/           # External tunnel agent
│   │       ├── kube-prometheus-stack/   # Prometheus operator stack
│   │       ├── minio/                   # S3-compatible object storage
│   │       ├── loki/                    # Log aggregation
│   │       ├── tempo/                   # Distributed tracing
│   │       ├── alloy/                   # Unified telemetry collector
│   │       └── nexus/                   # Docker registry + artifact store
│   └── inventory/storage/
│       ├── hosts.yml                    # Control plane and worker node inventory
│       └── group_vars/all/
│           ├── vars.yml                 # Variable definitions (references vault)
│           └── vault.example            # Secrets template
└── apps/                                # Helm values and Kubernetes manifests
    ├── alloy/values.yml                 # Grafana Alloy collector configuration
    ├── cert-manager/                    # cert-manager values + ClusterIssuer manifest
    ├── cluster-status/manifest.yml      # Health-check endpoint manifest
    ├── kube-prometheus-stack/values.yml # Prometheus operator stack configuration
    ├── loki/                            # Loki values + MinIO credential manifest
    ├── longhorn/values.yml              # Longhorn storage class configuration
    ├── minio/                           # MinIO values + bucket initialization
    └── tempo/                           # Tempo values + MinIO credential manifest
```

## Related repos

| Repo | Relation |
|---|---|
| andusystems-management | Hub cluster — Grafana queries Prometheus, Loki, and Tempo on this cluster |

## Further documentation

- [Architecture](docs/architecture.md) — component diagram, data flows, design decisions
- [Development](docs/development.md) — local setup, deployment commands, debugging
- [Changelog](CHANGELOG.md) — release history
