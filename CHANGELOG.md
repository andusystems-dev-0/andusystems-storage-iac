# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Nexus Repository OSS deployment with private Docker registry (`andusystems-docker` hosted repository)
- Nexus automated post-install configuration via REST API (Docker realm, repositories, roles, users)
- Nexus service accounts: `ci-pusher` (read/write for CI) and `cluster-puller` (read-only for clusters)
- Nexus S3 blob storage integration with MinIO (`nexus-blobs` bucket)
- Nexus Let's Encrypt TLS certificates for public hostnames via cert-manager DNS-01
- Nexus Traefik IngressRoutes for both public (Pangolin) and internal (direct HTTPS) access
- Nexus admin password bootstrap automation via postStart lifecycle hook
- MinIO pre-created `nexus-blobs` bucket for Nexus artifact storage
- Added detailed per-component documentation to README for Alloy, Loki, Tempo, Prometheus, MinIO, Longhorn, MetalLB, cert-manager, and Pangolin Newt (2026-04-07)

### Fixed
- Fixed missing trailing newline in MetalLB IPAddressPool manifest (2026-04-07)
- Bumped Alloy resource limits to resolve OOMKilled pods (2026-04-05)

### Changed
- Updated Nexus Ingress to support both HTTP and HTTPS entrypoints with X-Forwarded-Proto middleware
- Updated MinIO service to LoadBalancer type for cross-cluster access (2026-03-17)
- Disabled Alloy-managed node-exporter and kube-state-metrics deployments (using kube-prometheus-stack's instead) (2026-03-17)
- Updated Alloy values for OTLP port mapping (2026-03-17)

## [0.3.0] - 2026-03-16

### Added
- Alloy telemetry collector with metrics, logs, singleton, and receiver instances
- Loki log aggregation with MinIO S3 backend
- Tempo distributed tracing with MinIO S3 backend
- kube-prometheus-stack (Prometheus, Alertmanager, node-exporter, kube-state-metrics)
- MinIO S3-compatible object storage with pre-created buckets for Loki and Tempo
- MetalLB bare-metal load balancer deployment to storage cluster
- Prometheus remote-write receiver for cross-cluster federation

### Changed
- Updated MinIO values to override names for Loki and Tempo connectivity
- Added S3 storage variables to Grafana stack components

## [0.2.0] - 2026-03-08

### Added
- Longhorn distributed block storage with headless UI configuration
- Longhorn values file with 3-replica default and storage over-provisioning

### Changed
- Migrated cluster to dedicated storage network segment
- Changed Longhorn to headless mode (UI disabled)
- Fixed apps.yml playbook ordering
- Updated .gitignore to exclude [AI_ASSISTANT] configuration files

## [0.1.0] - 2026-03-06

### Added
- Initial Ansible role structure with modular per-component roles
- cert-manager with Cloudflare DNS-01 challenge solver and Let's Encrypt ClusterIssuer
- Pangolin Newt tunnel agent integration
- VM provisioning via Terraform on Proxmox (layer-1-infrastructure)
- Kubernetes cluster bootstrap with kubeadm and Flannel CNI
- Ansible Vault-based secrets management
- Inventory with control plane and worker node definitions

### Changed
- Refactored from monolithic Ansible role to modular per-component roles
- Reorganized ArgoCD and cert-manager roles
- Removed deprecated cert-manager code and unused manifests

## [0.0.1] - 2026-02-24

### Added
- Initial repository setup
- Basic Kubernetes cluster provisioning with MetalLB and ArgoCD
- Homepage deployment via ArgoCD
- Traefik ingress controller with IngressRoute configuration
- Terraform configuration for VM creation on Proxmox
