output "control_plane_ip" {
  description = "IP of the Kubernetes control plane node"
  value       = var.control_plane_ip
}

output "worker_ips" {
  description = "IPs of the worker nodes"
  value       = var.worker_ips
}

output "ssh_user" {
  description = "SSH username for all nodes"
  value       = var.ssh_username
}

output "ssh_private_key_path" {
  description = "SSH private key path for deploy.sh (from tfvars)"
  value       = coalesce(var.ssh_private_key_path, "")
}

output "control_plane_name" {
  description = "Proxmox VM name for control plane"
  value       = proxmox_virtual_environment_vm.control_plane.name
}

output "worker_names" {
  description = "Proxmox VM names for workers"
  value       = proxmox_virtual_environment_vm.workers[*].name
}
