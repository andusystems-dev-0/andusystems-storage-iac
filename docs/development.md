# Development Guide

## Prerequisites

| Tool | Purpose |
|---|---|
| **Ansible** | Orchestrates provisioning and deployment |
| **Terraform** | Provisions VMs on Proxmox |
| **kubectl** | Kubernetes CLI for debugging and manual operations |
| **SSH** | Access to cluster nodes |
| **ansible-vault** | Encrypt/decrypt secrets |

### Install Ansible collection dependencies

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

This installs:

- `kubernetes.core` — used by all application roles to manage Kubernetes resources and Helm releases

## Local Development Setup

### 1. Clone the repository

```bash
git clone <repository-url>
cd andusystems-storage
```

### 2. Set up Ansible Vault

Copy the vault example and populate it with your environment values:

```bash
cp ansible/inventory/storage/group_vars/all/vault.example \
   ansible/inventory/storage/group_vars/all/vault
```

Edit the vault file and fill in all required fields. See the [Configuration Reference](../README.md#configuration-reference) in the README for a full list of keys.

Encrypt the vault:

```bash
ansible-vault encrypt ansible/inventory/storage/group_vars/all/vault
```

To edit an encrypted vault:

```bash
ansible-vault edit ansible/inventory/storage/group_vars/all/vault
```

### 3. Verify SSH connectivity

Ensure you can reach all target nodes:

```bash
ansible -i ansible/inventory/storage/hosts.yml all -m ping --ask-vault-pass
```

## Deployment Commands

All commands are run from `ansible/configurations/`.

### Full stack deployment

Provisions VMs, bootstraps Kubernetes, and deploys all applications:

```bash
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass
```

### Apps only

Skips VM provisioning and Kubernetes bootstrap — deploys applications to an existing cluster:

```bash
ansible-playbook apps.yml -i ../inventory/storage/hosts.yml --ask-vault-pass
```

### Individual roles

Target specific components using tags:

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
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags nexus
```

### Dry run

Preview changes without applying them:

```bash
ansible-playbook apps.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --check --diff
```

Note: `--check` mode may not work correctly with all Kubernetes modules, but it is useful for catching Ansible-level issues.

## Deployment Order

The `apps.yml` playbook deploys applications in a specific order due to dependencies:

```
cert-manager → pangolin-newt → kube-prometheus-stack → minio → loki → tempo → alloy → nexus
```

- **cert-manager** must be first (other apps may need TLS certificates)
- **pangolin-newt** sets up the tunnel for external access
- **kube-prometheus-stack** must precede Alloy (Alloy pushes metrics to Prometheus)
- **MinIO** must precede Loki, Tempo, and Nexus (they use MinIO for S3 storage)
- **Alloy** depends on all telemetry backends being available
- **Nexus** is last (depends on MinIO for blob storage and cert-manager for TLS)

## Project Layout

### Ansible roles

Each role in `ansible/configurations/roles/` follows a consistent pattern:

```
roles/<component>/
├── defaults/main.yml    # Default variables (usually empty — secrets come from vault)
├── tasks/
│   ├── main.yml         # Entry point — imports install.yml with tags
│   └── install.yml      # Actual installation logic
```

The top-level `roles/<component>.yml` is the playbook that includes the role.

### App configurations

Each app in `apps/` contains:

- **`values.yml`** — Helm chart values (required)
- **`manifest.yml`** (optional) — Additional Kubernetes manifests (secrets, CRDs, MetalLB config)
- **`manifests/`** (optional) — Directory of additional Kubernetes manifests (used by Nexus for deployment, ingress, TLS certs)

Manifests use Jinja2 templating and are rendered by Ansible at deploy time. Secrets reference Ansible Vault variables.

### Nexus role specifics

The Nexus role has a two-phase deployment model:

1. **Phase 1 (Bootstrap)** — Creates namespace, applies secrets (MinIO credentials, admin bootstrap password), and deploys the workload manifests
2. **Phase 2 (Post-install)** — Waits for the Nexus pod to become API-ready, then configures:
   - Docker Bearer Token realm activation
   - `andusystems-docker` hosted Docker repository with S3 blob store
   - Service account roles (`ci-pusher`, `cluster-puller`)
   - Service account users with vault-sourced passwords

All post-install API calls are idempotent — they check for existing resources before creating.

## Environment Variables

No environment variables are needed on the developer machine. All configuration is managed through Ansible Vault variables and the inventory.

The Ansible roles set `KUBECONFIG` at task level, pointing to the kubeconfig file generated during cluster bootstrap.

## Testing

This repository uses infrastructure-as-code with no unit test framework. Validation is done through:

### Pre-deployment validation

```bash
# Syntax check playbooks
ansible-playbook apps.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --syntax-check

# Lint playbooks (if ansible-lint is installed)
ansible-lint ansible/configurations/
```

### Post-deployment verification

```bash
export KUBECONFIG=<path-to-kubeconfig>

# Verify all pods are running
kubectl get pods -A

# Check Prometheus targets
kubectl -n monitoring port-forward svc/storage-kube-prometheus-prometheus <local-port>:<prometheus-port>
# Then open http://localhost:<local-port>/targets

# Verify Loki is receiving logs
kubectl -n loki logs -l app.kubernetes.io/name=loki --tail=20

# Verify MinIO buckets exist
kubectl -n minio port-forward svc/minio-console <local-port>:<console-port>
# Then open http://localhost:<local-port>

# Verify Nexus is running and responsive
kubectl -n nexus get pods
kubectl -n nexus port-forward svc/nexus <local-port>:<nexus-ui-port>
# Then open http://localhost:<local-port>

# Test Docker registry access
kubectl -n nexus port-forward svc/nexus-docker <local-port>:<docker-port>
docker login localhost:<local-port>
```

## Adding a New Application

1. Create a values file at `apps/<app-name>/values.yml`
2. Optionally create a `manifest.yml` for additional resources (secrets, CRDs)
3. Optionally create a `manifests/` directory for more complex deployments (workloads, ingress, TLS certs)
4. Create an Ansible role at `ansible/configurations/roles/<app-name>/`:
   - `defaults/main.yml` — default variables (if any)
   - `tasks/main.yml` — imports install.yml with appropriate tags
   - `tasks/install.yml` — creates namespace, applies manifests, installs Helm chart
5. Create the role playbook at `ansible/configurations/roles/<app-name>.yml`
6. Add the playbook import to `ansible/configurations/apps.yml` in the correct dependency position
7. If the app needs secrets, add vault variables to `vars.yml` and update `vault.example`

## Debugging

### Check pod status

```bash
export KUBECONFIG=<path-to-kubeconfig>
kubectl get pods -A
```

### View Ansible logs

Ansible logs are written to `ansible/ansible.log` (configured in `ansible.cfg`).

### Inspect Helm releases

```bash
export KUBECONFIG=<path-to-kubeconfig>
helm list -A
```

### Common issues

| Issue | Cause | Fix |
|---|---|---|
| Alloy pods OOMKilled | Resource limits too low | Increase limits in `apps/alloy/values.yml` |
| Loki can't write to MinIO | MinIO not ready or credentials wrong | Verify MinIO pods are running; check vault credentials |
| cert-manager solver fails | Cloudflare token invalid or DNS propagation delay | Verify token; wait and retry |
| Worker nodes not joining | SSH connectivity or kubeadm token expired | Check SSH access; re-run kubernetes role |
| Prometheus PVC pending | Longhorn not ready or no available nodes | Verify Longhorn pods are running; check node storage |
| MinIO health check failing | Pod still starting or persistence issue | Check pod events with `kubectl describe`; verify Longhorn volume |
| Nexus slow to start | JVM warmup takes several minutes | Wait for startup probe to pass (up to 5 min); check pod events |
| Nexus post-install fails | Pod not API-ready or stale admin password | Check Nexus pod logs; verify `nexus-admin-bootstrap` secret value |
| Docker push/pull fails | Docker realm not activated or ingress misconfigured | Re-run nexus tag; verify realm config via Nexus admin UI |
| Nexus Docker auth 401 | Bearer token realm not in active realm list | Re-run nexus role; check `/service/rest/v1/security/realms/active` |
