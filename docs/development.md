# Development guide

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Ansible | 2.15+ | Orchestrates provisioning and application deployment |
| Terraform | 1.5+ | Provisions VMs on Proxmox |
| kubectl | 1.31+ | Kubernetes CLI for verification and debugging |
| Helm | 3.x | Used internally by Ansible roles via `kubernetes.core` |
| ansible-vault | — | Encrypts and decrypts the secrets file |

### Install Ansible collection dependencies

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

This installs `kubernetes.core`, used by all application roles to manage Kubernetes resources and Helm releases.

## Local setup

### 1. Clone the repository

```bash
git clone <repository-url>
cd andusystems-storage
```

### 2. Configure secrets

Copy the vault template and populate it with your environment values:

```bash
cp ansible/inventory/storage/group_vars/all/vault.example \
   ansible/inventory/storage/group_vars/all/vault
```

Edit `vault` and fill in all required fields. See the [Configuration](../README.md#configuration) section in the README for a full list of keys.

Encrypt the vault file before committing or storing it:

```bash
ansible-vault encrypt ansible/inventory/storage/group_vars/all/vault
```

To edit an encrypted vault:

```bash
ansible-vault edit ansible/inventory/storage/group_vars/all/vault
```

### 3. Verify SSH connectivity

Confirm Ansible can reach all target nodes:

```bash
ansible -i ansible/inventory/storage/hosts.yml all -m ping --ask-vault-pass
```

## Deployment commands

All playbook commands are run from `ansible/configurations/`.

### Full stack deployment

Provisions VMs, bootstraps Kubernetes, and deploys all applications in order:

```bash
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass
```

Stages run in sequence:

1. **VMs** — Terraform provisions Proxmox virtual machines
2. **Kubernetes** — kubeadm initialises the cluster; Flannel CNI is applied; worker nodes join
3. **Apps** — all applications are deployed in dependency order

### Apps only

Skips VM provisioning and Kubernetes bootstrap — deploys or updates applications on an existing cluster:

```bash
ansible-playbook apps.yml -i ../inventory/storage/hosts.yml --ask-vault-pass
```

### Individual components (tags)

Use Ansible tags to target a single role without running the rest of the playbook:

```bash
# Infrastructure
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags vms
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags kubernetes

# Networking
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags metallb
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags cert-manager
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags pangolin-newt

# Observability
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags kube-prometheus-stack
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags minio
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags loki
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags tempo
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags alloy

# Registry
ansible-playbook storage.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --tags nexus
```

### Dry run

Preview Ansible changes without applying them:

```bash
ansible-playbook apps.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --check --diff
```

Note: `--check` mode may not work correctly with all Kubernetes modules but is useful for catching Ansible-level issues before a real run.

## Deployment order

The `apps.yml` playbook deploys applications in a fixed order due to inter-component dependencies:

```
metallb → cert-manager → pangolin-newt → kube-prometheus-stack → minio → loki → tempo → alloy → nexus
```

- **MetalLB** must be first so that subsequent LoadBalancer services receive IPs
- **cert-manager** must precede any app that needs a TLS certificate
- **kube-prometheus-stack** must precede Alloy (Alloy remote-writes metrics to Prometheus)
- **MinIO** must precede Loki, Tempo, and Nexus (they all use MinIO for S3 storage)
- **Alloy** is near-last (depends on all telemetry backends being available)
- **Nexus** is last; the post-install role requires Prometheus to be running for health checks

## Nexus post-install

The Nexus role includes a post-install task that automates role, user, and realm configuration via the Nexus REST API. Before running the role for the first time, the `nexus-blobs` S3 blob store must be created manually in the Nexus UI (Settings → Repository → Blob Stores → Create S3). The automation will fail if the blob store does not exist.

After the blob store is created, the `nexus` tag can be re-run to complete the automated configuration.

## Project layout

### Ansible roles

Each role in `ansible/configurations/roles/` follows a consistent structure:

```
roles/<component>/
├── defaults/main.yml    # Default variables (usually empty — secrets come from vault)
├── tasks/
│   ├── main.yml         # Entry point — imports install.yml (and post_install.yml if present)
│   └── install.yml      # Namespace creation, manifest application, Helm install
```

The `roles/<component>.yml` file at the top level is the per-component playbook that includes the role.

### App configurations

Each directory in `apps/` contains:

- **`values.yml`** — Helm chart values (always present)
- **`manifest.yml`** (optional) — Additional Kubernetes manifests: secrets, CRDs, MetalLB IPAddressPool config

Manifests use Jinja2 templating and are rendered by Ansible at deploy time. Secret values reference Ansible Vault variables and are never stored in plaintext.

## Environment variables

No environment variables are needed on the developer workstation. All configuration is managed through Ansible Vault and the inventory. Ansible roles set `KUBECONFIG` at task level, pointing to the kubeconfig written during cluster bootstrap.

## Validation

This repository has no unit test framework. Validation is done through syntax checks, linting, and post-deployment verification.

### Pre-deployment

```bash
# Syntax check all playbooks
ansible-playbook apps.yml -i ../inventory/storage/hosts.yml --ask-vault-pass --syntax-check

# Lint (requires ansible-lint)
ansible-lint ansible/configurations/
```

### Post-deployment verification

```bash
export KUBECONFIG=<path-to-kubeconfig>

# Verify all pods are running
kubectl get pods -A

# Check Prometheus targets (port-forward, then open http://localhost:9090/targets)
kubectl -n monitoring port-forward svc/storage-kube-prometheus-prometheus 9090:9090

# Verify Loki is receiving logs
kubectl -n loki logs -l app.kubernetes.io/name=loki --tail=20

# Verify MinIO buckets exist (port-forward, then open http://localhost:9001)
kubectl -n minio port-forward svc/minio-console 9001:9001

# Check Nexus is healthy
kubectl -n nexus get pods
```

## Adding a new application

1. Create `apps/<app-name>/values.yml` with Helm chart values
2. Optionally create `apps/<app-name>/manifest.yml` for additional Kubernetes resources
3. Create the Ansible role at `ansible/configurations/roles/<app-name>/`:
   - `defaults/main.yml` — default variables (if any)
   - `tasks/main.yml` — imports `install.yml` with appropriate tags
   - `tasks/install.yml` — creates namespace, applies manifests, installs Helm chart
4. Create the role playbook at `ansible/configurations/roles/<app-name>.yml`
5. Import the playbook in `ansible/configurations/apps.yml` at the correct dependency position
6. If the app requires secrets, add vault variable keys to `vars.yml` and update `vault.example`

## Debugging

### Check pod status

```bash
export KUBECONFIG=<path-to-kubeconfig>
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
```

### View Ansible logs

Ansible logs are written to `ansible/ansible.log` (configured in `ansible.cfg`).

### Inspect Helm releases

```bash
export KUBECONFIG=<path-to-kubeconfig>
helm list -A
helm get values <release-name> -n <namespace>
```

### Common issues

| Issue | Cause | Fix |
|---|---|---|
| Alloy pods OOMKilled | Resource limits too low | Increase limits in `apps/alloy/values.yml` |
| Loki cannot write to MinIO | MinIO not ready or wrong credentials | Verify MinIO pods are running; check vault credentials |
| cert-manager solver fails | Cloudflare token invalid or DNS propagation delay | Verify token in vault; wait and retry the CertificateRequest |
| Worker nodes not joining | SSH connectivity or kubeadm token expired | Check SSH access; re-run the kubernetes role |
| Prometheus PVC pending | Longhorn not ready or no storage-capable nodes available | Verify Longhorn pods are running; check node disk availability |
| MinIO health check failing | Pod still starting or PVC not bound | Check pod events with `kubectl describe`; verify Longhorn volume |
| Nexus post-install fails | `nexus-blobs` S3 blob store not created | Create blob store via Nexus UI before re-running the nexus tag |
| MetalLB IP not assigned | IP pool exhausted or L2 advertisement not propagated | Check `metallb_ip_range` in vault; verify MetalLB speaker pods |
