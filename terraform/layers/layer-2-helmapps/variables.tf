variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint (e.g. https://pve.example.com:8006/)"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token (format: user@realm!tokenid=secret). Create in Datacenter → Permissions → API Tokens. Needs Datastore.Audit, Datastore.AllocateSpace, Datastore.AllocateTemplate on storage, plus VM.* as needed."
  type        = string
  default     = null
  sensitive   = true
}

variable "proxmox_username" {
  description = "Proxmox username (e.g. root@pam). Used when API token is not set."
  type        = string
  default     = null
}

variable "proxmox_password" {
  description = "Proxmox password. Used when API token is not set."
  type        = string
  default     = null
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for Proxmox API"
  type        = bool
  default     = true
}

# SSH from your dev machine to the Proxmox nodes (required for VM disk creation when using API token)
variable "proxmox_ssh_username" {
  description = "SSH user for Proxmox nodes (e.g. root). Your public key must be in this user's authorized_keys on each node."
  type        = string
  default     = "root"
}

variable "proxmox_ssh_private_key_path" {
  description = "Path to SSH private key for Proxmox nodes. If set, used for SSH; otherwise the provider uses ssh-agent (run ssh-add)."
  type        = string
  default     = null
}

variable "proxmox_control_plane_node" {
  description = "Proxmox node name where the Kubernetes control plane VM will be created (e.g. worker0)"
  type        = string
}

variable "proxmox_worker_nodes" {
  description = "Proxmox node names for Kubernetes worker VMs, one per worker (e.g. [worker1, worker2, worker3])"
  type        = list(string)
}

variable "vm_network_bridge" {
  description = "Proxmox bridge for VM network (e.g. vmbr0)"
  type        = string
  default     = "vmbr0"
}

variable "vm_datastore_id" {
  description = "Datastore for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "vm_download_datastore_id" {
  description = "Datastore for downloaded cloud image"
  type        = string
  default     = "local"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for passwordless login (use absolute path in WSL, e.g. /home/you/.ssh/id_ed25519.pub)"
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "SSH public key content (alternative to ssh_public_key_path; e.g. set TF_VAR_ssh_public_key)"
  type        = string
  default     = null
  sensitive   = true
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key for deploy.sh (use absolute path in WSL). If unset, SSH uses default identity."
  type        = string
  default     = null
}

variable "ssh_username" {
  description = "Username to create on VMs for SSH (cloud image default)"
  type        = string
  default     = "ubuntu"
}

variable "control_plane_ip" {
  description = "Static IP for the control plane node (e.g. 192.168.1.11)"
  type        = string
}

variable "worker_ips" {
  description = "List of static IPs for worker nodes"
  type        = list(string)
}

variable "network_gateway" {
  description = "Default gateway for VM network"
  type        = string
}

variable "network_prefix" {
  description = "Network prefix length (e.g. 24 for /24)"
  type        = number
  default     = 24
}

variable "cluster_name" {
  description = "Prefix for VM names and Kubernetes cluster"
  type        = string
  default     = "dean"
}

variable "control_plane_memory" {
  description = "Memory in MiB for control plane node"
  type        = number
  default     = 2048
}

variable "control_plane_cores" {
  description = "CPU cores for control plane node"
  type        = number
  default     = 2
}

variable "worker_memory" {
  description = "Memory in MiB per worker node"
  type        = number
  default     = 2048
}

variable "worker_cores" {
  description = "CPU cores per worker node"
  type        = number
  default     = 2
}

variable "vm_cloud_image_url" {
  description = "URL of cloud image. Fetched on the dev machine (Terraform runner) then uploaded to Proxmox, so Ubuntu CDN works."
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "vm_cloud_image_content_type" {
  description = "Content type: 'iso' for .img (Ubuntu), 'import' for .qcow2 (Debian)."
  type        = string
  default     = "iso"
}

variable "vm_cloud_image_upload_timeout" {
  description = "Upload timeout in seconds for the cloud image (large file)."
  type        = number
  default     = 3600
}

# At least one of ssh_public_key or ssh_public_key_path must be set (enforced in main via try/coalesce).
variable "kubeconfig_path" {
  description = "Path to kubeconfig for the cluster (e.g. ../../../kubeconfig or $HOME/.kube/config)"
  type        = string
}

# Unused in this layer; declared so shared terraform.tfvars does not warn.
variable "namespace" {
  description = "Unused in layer-1; for layer-2."
  type        = string
  default     = "default"
}
variable "argocd_namespace" {
  description = "Unused in layer-1; for layer-2-gitops."
  type        = string
  default     = "argocd"
}

# MetalLB: IP range for LoadBalancer services (same L2 as cluster; avoid node IPs).
variable "metallb_address_pool" {
  description = "IP range for MetalLB LoadBalancer services (e.g. 10.0.0.20-10.0.0.30 or 10.0.0.20/28)"
  type        = string
  default     = "10.0.0.20-10.0.0.30"
}

variable "apps_dir" {
  description = "Path to apps directory (where manifests are stored)"
  type        = string
  default     = "/"
}
