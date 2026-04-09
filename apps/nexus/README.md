# Nexus Repository OSS — storage cluster

Sonatype Nexus Repository Manager 3 deployed as bare Kubernetes manifests on
the storage cluster (VLAN 40), managed by the management cluster's ArgoCD.
Hosts in-house container images and other artifact formats (Maven, npm, PyPI,
raw, Helm, etc.) for andusystems projects.

## Why bare manifests instead of a Helm chart

| Chart | Status | Why we don't use it |
|-------|--------|---------------------|
| `sonatype/nexus-repository-manager` | Archived 2023-10 | Deprecated; pinned to old image |
| `sonatype/nxrm-ha` | Supported | Pro-only — requires a paid license file + external PostgreSQL |

For an OSS, single-instance, homelab deployment we own the YAML in
`apps/nexus/manifests/` instead. No upstream chart drift, no surprise
breakages.

## Layout — split between Ansible bootstrap and ArgoCD workload

This app follows the same split as loki/tempo/minio: a small Ansible-rendered
bootstrap layer creates secrets and the namespace, then management ArgoCD
takes ownership of the actual workload.

| File | Owner | Purpose |
|------|-------|---------|
| `apps/nexus/manifest.yml` | local Ansible role | Jinja2-templated bootstrap **Secrets** only: `nexus-minio-credentials` and `nexus-admin-bootstrap`. Applied by `ansible-playbook ... --tags nexus,install`. |
| `apps/nexus/manifests/nexus.yml` | management ArgoCD | Plain YAML for the **workload**: PVC, Deployment, two LoadBalancer Services. Synced by the `storage-nexus` Application defined in `andusystems-management/apps/andusystems-storage/manifest.yml`. |

The bootstrap secrets MUST exist before ArgoCD syncs the workload — otherwise
the pod is stuck on a missing secret volume mount. The Ansible step is what
gates this.

## Architecture

- **Image**: `sonatype/nexus3:3.74.0` (bump in `manifests/nexus.yml` as desired)
- **Database**: embedded H2 (default in Nexus 3.71+), stored on Longhorn PVC
- **Blob storage**: MinIO via an S3 blob store, bucket `nexus-blobs`,
  configured **post-install** (Nexus has no declarative config for blob stores)
- **Persistence**: 30 Gi Longhorn PVC for `/nexus-data` (H2 db, indexes,
  config, logs only — image blobs go to MinIO)
- **Exposure**: two MetalLB LoadBalancer Services + two Traefik IngressRoutes
  - `nexus`        → port 8081 (UI / REST API) → `nexus.andusystems.com` via Pangolin
  - `nexus-docker` → port 8082 (Docker hosted-repo connector — bound to a real
    Docker repo only after you complete the post-install steps below) →
    `registry.andusystems.com` via Pangolin
- **TLS**: terminated externally by Pangolin. Internal traffic from Pangolin
  to Traefik to nexus is plain HTTP. The Traefik Middleware
  `nexus-forwarded-proto-https` injects `X-Forwarded-Proto: https` so Nexus
  knows the original client request was HTTPS — required for Docker registry
  auth challenges to work.
- **Initial admin password**: set automatically on first boot via a postStart
  lifecycle hook reading `/etc/nexus-bootstrap/admin-password` from the
  `nexus-admin-bootstrap` secret. Default value comes from
  `vault_nexus_admin_password` (currently `admin123!`). **Change this via the
  Nexus UI immediately after first login** — see step 3 below.

## How the admin password gets set

The Nexus container starts with `NEXUS_SECURITY_RANDOMPASSWORD=true`, which
makes Nexus generate a random password on first boot and write it to
`/nexus-data/admin.password`. A `lifecycle.postStart` hook on the container
runs alongside the main process: it polls `localhost:8081` until the API
is reachable, then calls
`PUT /service/rest/v1/security/users/admin/change-password` using the random
password to log in and the value from `/etc/nexus-bootstrap/admin-password`
(mounted from the `nexus-admin-bootstrap` Secret) as the new password. After
success it removes `/nexus-data/admin.password`.

The hook is **idempotent across restarts**: subsequent boots find no
`admin.password` file and exit cleanly. The hook is **not** an ongoing
password sync — editing the bootstrap secret on a running pod will not change
the live admin password. To change it later, use the Nexus UI.

The hook also runs in a backgrounded subshell with `exit 0` for the foreground
process, so a stuck pod boot can never wedge readiness on a postStart timeout.

## First-time setup

After ArgoCD shows `storage-nexus` as Synced + Healthy and the pod is ready,
do these steps **once**.

### 1. Log in and change the admin password

Browse to `https://nexus.andusystems.com` (the URL configured via the Pangolin
private resource pointing at the storage cluster's Traefik). Log in as `admin`
with the password from `vault_nexus_admin_password` (default `admin123!`).
The setup wizard will prompt you for a few preferences — recommend
**disabling anonymous access**.

> **Important:** `admin123!` is committed to the vault file and is a known
> default. **Change it immediately** via **Settings → Security → Users →
> admin → Change password** and store the new password in your password
> manager.

If `https://nexus.andusystems.com` doesn't resolve or returns a Pangolin
"resource down" page, check the order of operations in the **Pangolin setup**
section below.

### 2. Create the S3 blob store on MinIO

In the UI: **Settings (gear icon) → Repository → Blob Stores → Create blob
store**.

| Field | Value |
|-------|-------|
| Type | S3 |
| Name | `nexus-blobs` |
| Bucket name | `nexus-blobs` (pre-created by `apps/minio/values.yml`) |
| Prefix | *(leave blank)* |
| Region | `us-east-1` (MinIO ignores this but the field is required) |
| Endpoint URL | `http://minio.minio.svc.cluster.local:9000` |
| Use path-style access | **enabled** (required for MinIO) |
| Authentication → Access Key | `kubectl -n nexus get secret nexus-minio-credentials -o jsonpath='{.data.rootUser}' \| base64 -d` |
| Authentication → Secret Key | `kubectl -n nexus get secret nexus-minio-credentials -o jsonpath='{.data.rootPassword}' \| base64 -d` |

Click **Save blob store**. Nexus will validate by writing a test object to the
bucket — failures here are almost always wrong endpoint or path-style access
not enabled.

### 3. Create the Docker hosted repository

**Settings → Repository → Repositories → Create repository → docker (hosted)**

| Field | Value |
|-------|-------|
| Name | `andusystems-docker` |
| Online | enabled |
| HTTP connector port | `8082` |
| HTTPS connector | leave disabled (TLS is terminated by future ingress, not Nexus itself) |
| Allow anonymous docker pull | disabled |
| Storage → Blob store | `nexus-blobs` |
| Hosted → Deployment policy | `Allow redeploy` (for `:latest` tags) or `Disable redeploy` (stricter) |

Click **Create repository**. Once saved, Nexus binds port 8082 inside the pod
and the `nexus-docker` Service starts routing traffic.

### 4. (Optional) Create other repositories

Same flow, for the other artifact formats you want to host:

- **maven (hosted)** → name `andusystems-maven`, blob store `nexus-blobs`
- **npm (hosted)** → name `andusystems-npm`, blob store `nexus-blobs`
- **raw (hosted)** → name `andusystems-raw`, blob store `nexus-blobs`
- **helm (hosted)** → name `andusystems-helm`, blob store `nexus-blobs`

All Docker repositories share port 8082 if you only have one. If you add a
proxy or group, you'll need additional ports + matching K8s Services.

### 5. Create roles and users for CI / cluster pulls

**Security → Roles → Create role → Nexus role**

Create two roles:

| Role | Privileges (search and add) |
|------|------|
| `andusystems-ci-pusher` | `nx-repository-view-docker-andusystems-docker-*` (read, edit, add — all three) |
| `andusystems-cluster-puller` | `nx-repository-view-docker-andusystems-docker-read`, `nx-repository-view-docker-andusystems-docker-browse` |

**Security → Users → Create local user**

| User | Password | Roles |
|------|----------|-------|
| `ci-pusher` | *(generate strong, store somewhere durable)* | `andusystems-ci-pusher` |
| `cluster-puller` | *(generate strong, store somewhere durable)* | `andusystems-cluster-puller` |

Store the generated passwords in your password manager — they aren't recoverable
from Nexus. The `cluster-puller` password will be referenced by an
`imagePullSecret` in each consuming cluster (separate work, not in this repo).

## Pangolin setup

Pangolin handles external DNS, TLS termination, and the public hostname. You
need two **private resources** in Pangolin, both pointing at the storage
cluster's Traefik LoadBalancer IP (`{{ storage_traefik_server_ip }}` in the
management vault, currently `10.238.40.21`):

| Pangolin resource | Public hostname | Internal target |
|---|---|---|
| Nexus UI | `nexus.andusystems.com` | `http://10.238.40.21` |
| Nexus Docker registry | `registry.andusystems.com` | `http://10.238.40.21` |

The IngressRoutes in `apps/nexus/manifests/ingress.yml` handle the Host-header
routing inside the storage cluster — Traefik dispatches to the right Service
based on the `Host` header that Pangolin forwards.

**Order of operations** for a fresh deploy:

1. ArgoCD applies the `storage-nexus` Application → workload + IngressRoutes land
2. Pod becomes Ready, postStart hook sets the admin password (`admin123!`)
3. You configure the Pangolin **`nexus.andusystems.com`** resource → UI is live
4. You log in via the UI, change the password, create the S3 blob store and
   the Docker hosted repo (steps 1–3 of the post-install section)
5. Once the Docker hosted repo binds port 8082 inside the pod, you configure
   the Pangolin **`registry.andusystems.com`** resource → Docker is live

The Pangolin resource for the Docker hostname will show as down until step 5
completes — that's expected, the connector port doesn't open until you create
the hosted repo.

## Verification

```sh
# 1. UI loads, admin login works
curl -sI https://nexus.andusystems.com/ | head -1   # → HTTP/2 200

# 2. Docker push round-trip — no `insecure-registries` config needed,
#    Pangolin gives you a real Let's Encrypt cert.
docker login registry.andusystems.com -u ci-pusher -p '<password>'
docker pull alpine:3.20
docker tag alpine:3.20 registry.andusystems.com/andusystems-docker/test:1
docker push registry.andusystems.com/andusystems-docker/test:1

# 3. Confirm blob landed in MinIO, NOT on the local PVC.
KUBECONFIG=./kubeconfig kubectl -n minio exec deploy/minio -- \
  mc ls --recursive local/nexus-blobs/ | head
```

If the `mc ls` step shows objects under `nexus-blobs/`, the S3 blob store is
working. If the bucket is empty after a successful push, you configured a
different blob store on the repository — check
**Repositories → andusystems-docker → Storage → Blob store**.

### If `docker login` fails with redirect-to-HTTP

The Traefik `nexus-forwarded-proto-https` Middleware should be injecting
`X-Forwarded-Proto: https` into requests reaching Nexus. If you see the
classic Docker auth-challenge redirect loop (`http://...` URLs in the
WWW-Authenticate header), check that:

1. The Middleware is applied — `kubectl -n nexus get middleware`
2. The IngressRoute references it — `kubectl -n nexus get ingressroute nexus-docker -o yaml | grep middlewares -A2`
3. Pangolin is preserving the original Host header (it should by default)

## Operations

### Restarting / upgrading

Two paths depending on what changed:

**Bootstrap secrets only** (e.g. you rotated the admin password vault var):

```sh
# Re-render and re-apply just the bootstrap secrets.
ansible-playbook -i ansible/inventory/storage \
  ansible/configurations/storage.yml --tags nexus,install
# Then on the management cluster, force a restart of the nexus pod so the
# postStart hook re-runs against a fresh /nexus-data/admin.password — but
# only if you also wiped the PVC, since the hook is a no-op once the file
# is gone.
```

Note: editing `vault_nexus_admin_password` and re-running Ansible **does not
change the live admin password**. The bootstrap hook only runs on first boot
of a fresh PVC. To change the live password, use the Nexus UI.

**Workload changes** (image bump, resource limits, probes, etc.):

```sh
# Bump apps/nexus/manifests/nexus.yml on the storage repo, push to Forgejo.
# Management ArgoCD picks it up automatically (selfHeal=true, prune=true).
# Monitor in the ArgoCD UI as storage-nexus.
```

The Deployment uses `strategy: Recreate`, so the old pod is fully terminated
before the new one starts. Expect ~1-2 minutes of downtime per upgrade.

### Backups

The `/nexus-data` PVC contains the H2 database and config — Longhorn snapshots
of the `nexus-data` PVC are the primary backup mechanism. Image blobs live in
MinIO and are backed up via whatever MinIO backup strategy applies (currently
nothing — see follow-ups).

For belt-and-suspenders: use Nexus's built-in **Admin → System → Tasks →
Create task → Export configuration & metadata for backup** scheduled task to
dump the H2 db to a path under `/nexus-data/backup/` nightly. Combined with
Longhorn snapshots that survives accidental deletes inside Nexus.

### Cleanup tasks

Nexus accumulates dangling blobs over time as tags are deleted or replaced.
Schedule these in **Admin → System → Tasks**:

| Task type | Schedule | Notes |
|-----------|----------|-------|
| Admin - Compact blob store | weekly, off-hours | Reclaims space from deleted blobs |
| Admin - Cleanup repositories using their associated policies | weekly | Requires cleanup policies on each repo |
| Repair - Rebuild repository search | monthly | Keeps Lucene index healthy |

Define a **Cleanup Policy** under **Repository → Cleanup Policies** (e.g.
"delete images older than 90 days, keep latest 10") and attach it to each
hosted repository under **Repositories → \<name\> → Cleanup**.

## Follow-ups (intentionally not in this PR)

- **MinIO bucket scoped service account** for Nexus's blob store, instead of
  reusing root credentials. Requires `mc admin user svcacct add` against the
  MinIO instance — a one-time manual or scripted step.
- **imagePullSecret distribution** to consuming clusters (management,
  fleetdock, monitoring) — handled in those clusters' repos using the
  `cluster-puller` credentials and `registry.andusystems.com` as the registry
  hostname.
- **Postgres migration** if Nexus ever shows db corruption symptoms or load
  outgrows the embedded H2. Requires migrating to the supported `nxrm-ha`
  chart, which also requires a Pro license.
