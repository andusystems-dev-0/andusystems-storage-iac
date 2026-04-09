provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  username  = var.proxmox_api_token != null ? null : var.proxmox_username
  password  = var.proxmox_api_token != null ? null : var.proxmox_password
  insecure  = var.proxmox_insecure

  # Required for VM disk creation when using API token (provider SSHs to Proxmox nodes)
  ssh {
    username   = var.proxmox_ssh_username
    agent      = var.proxmox_ssh_private_key_path == null
    private_key = var.proxmox_ssh_private_key_path != null ? file(var.proxmox_ssh_private_key_path) : null
  }
}

# Configure the Kubernetes provider (assumes a local kubeconfig file is present)
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  # Optional: specify a context if not using the default
  # config_context = "my-cluster-context"
}

# Configure the Helm provider to use the Kubernetes provider's configuration
provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

# Configure the kubectl provider
provider "kubectl" {
  config_path = var.kubeconfig_path
  apply_retry_count = 3
}