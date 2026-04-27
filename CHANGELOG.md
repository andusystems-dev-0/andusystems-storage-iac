# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Added Nexus Docker registry with MinIO S3 blob store backend and automated post-install configuration (roles, users, Docker Bearer Token Realm)
- Added cluster-status health-check endpoint manifest
- Added Nexus to the components table in README and architecture diagram

### Changed
- Updated architecture diagram to include Nexus registry layer and nexus-blobs MinIO bucket
- Pinned MetalLB LoadBalancer IPs for Nexus registry and console services
- Enhanced Nexus Ingress configuration to support both HTTP and HTTPS entrypoints via Traefik websecure with TLS passthrough
- Updated MinIO values to pre-create `nexus-blobs` bucket on startup

### Fixed
- Fixed Nexus deployment security: curl credentials no longer written to disk; auth passed via command-line only
- Fixed Nexus post-install automation to use Kubernetes API-based scripting rather than shell exec

### Documentation
- Rewrote README to follow the andusystems standard section structure with strict format compliance
- Updated architecture.md to include Nexus data flow and nexus-blobs S3 bucket
- Updated development.md to document Nexus post-install prerequisites and the `nexus` tag
- Updated CHANGELOG with Nexus integration entries

## [0.3.1] - 2026-04-07

### Added
- Added detailed per-component documentation to README for Alloy, Loki, Tempo, Prometheus, MinIO, Longhorn, MetalLB, cert-manager, and Pangolin Newt
- Added architecture.md with ASCII component diagram, data flow tables, and design decision rationale
- Added development.md with local setup instructions, deployment commands, and debugging guide

### Fixed
- Fixed missing trailing newline in MetalLB IPAddressPool manifest
- Bumped Alloy resource limits to resolve OOMKilled pods

### Changed
- Updated MinIO service to LoadBalancer type for cross-cluster access
- Disabled Alloy-managed node-exporter and kube-state-metrics deployments (kube-prometheus-stack provides them)
- Updated Alloy values for OTLP port mapping
- Added inline comments to values.yml files explaining section purposes

## [0.3.0] - 2026-03-16

### Added
- Alloy telemetry collector with four specialized instances: metrics (DaemonSet), logs (DaemonSet), singleton (Deployment), receiver (Deployment)
- Loki log aggregation with MinIO S3 backend (single-binary mode, TSDB v13 schema, 30-day retention)
- Tempo distributed tracing with MinIO S3 backend and span metrics generation via Prometheus remote-write
- kube-prometheus-stack (Prometheus, Alertmanager, node-exporter, kube-state-metrics) with remote-write receiver enabled
- MinIO S3-compatible object storage with pre-created buckets (`loki-data`, `loki-ruler`, `tempo-data`)
- MetalLB bare-metal load balancer deployment to storage cluster
- Prometheus remote-write receiver for cross-cluster metric federation
- External labels `cluster: storage` on Prometheus for multi-cluster identification

### Changed
- Updated MinIO values to override names for Loki and Tempo in-cluster connectivity
- Disabled Grafana in kube-prometheus-stack (spoke cluster — hub provides Grafana)

## [0.2.0] - 2026-03-08

### Added
- Longhorn distributed block storage with 3-replica replication and 200% storage over-provisioning
- Longhorn values file with headless UI configuration

### Changed
- Migrated cluster to dedicated storage network segment
- Set Longhorn to headless mode (UI disabled)
- Fixed apps.yml playbook ordering
- Updated .gitignore to exclude Claude configuration files

## [0.1.0] - 2026-03-06

### Added
- Initial modular Ansible role structure with per-component roles
- cert-manager with Cloudflare DNS-01 challenge solver and Let's Encrypt ClusterIssuer
- Pangolin Newt tunnel agent integration
- VM provisioning via Terraform on Proxmox
- Kubernetes cluster bootstrap with kubeadm and Flannel CNI
- Ansible Vault-based secrets management
- Inventory with control plane and worker node definitions

### Changed
- Refactored from monolithic Ansible role to modular per-component roles
- Reorganized cert-manager role structure
- Removed deprecated cert-manager code and unused manifests

## [0.0.1] - 2026-02-24

### Added
- Initial repository setup
- Basic Kubernetes cluster provisioning with MetalLB and ArgoCD
- Homepage deployment via ArgoCD
- Traefik ingress controller with IngressRoute configuration
- Terraform configuration for VM creation on Proxmox
