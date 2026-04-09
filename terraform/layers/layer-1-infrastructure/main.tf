locals {
  ssh_public_key_content = (var.ssh_public_key != null && var.ssh_public_key != "") ? trimspace(var.ssh_public_key) : trimspace(file(var.ssh_public_key_path))
  all_worker_ips         = var.worker_ips
  # All Proxmox nodes that will host a VM (control plane + workers)
  proxmox_vm_nodes = concat([var.proxmox_control_plane_node], var.proxmox_worker_nodes)
}

# Cloud image: downloaded on the dev machine from URL, then uploaded to each Proxmox node (avoids 403 from Proxmox fetching Ubuntu CDN).
resource "proxmox_virtual_environment_file" "ubuntu_image" {
  for_each        = toset(local.proxmox_vm_nodes)
  content_type   = var.vm_cloud_image_content_type
  datastore_id   = var.vm_download_datastore_id
  node_name      = each.key
  timeout_upload = var.vm_cloud_image_upload_timeout
  source_file {
    path = var.vm_cloud_image_url
  }
}

# Control plane VM on first Proxmox node (e.g. worker0)
resource "proxmox_virtual_environment_vm" "control_plane" {
  name        = "${var.cluster_name}-ctrl"
  tags        = ["storage", "control-plane"]
  description = "Kubernetes control plane"
  node_name   = var.proxmox_control_plane_node
  vm_id       = 4053

  agent {
    enabled = true
  }
  stop_on_destroy = true

  cpu {
    cores = var.control_plane_cores
    type  = "x86-64-v2-AES"
  }
  memory {
    dedicated = var.control_plane_memory_max
    floating = var.control_plane_memory_min
  }

  disk {
    datastore_id = var.vm_datastore_id
    file_id      = proxmox_virtual_environment_file.ubuntu_image[var.proxmox_control_plane_node].id
    interface    = "scsi0"
    size         = 32
  }

  network_device {
    bridge = var.vm_network_bridge
    vlan_id = 40
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.control_plane_ip}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }
    user_account {
      username = var.ssh_username
      #password = "ubuntu" # Required by cloud-init but not used (SSH keys only); must meet cloud-init password complexity rules.
      keys     = [local.ssh_public_key_content]
    }
  }

  operating_system {
    type = "l26"
  }
}

# Worker VMs (one per Proxmox worker node: worker1, worker2, worker3)
resource "proxmox_virtual_environment_vm" "workers" {
  count         = length(var.worker_ips)
  tags          = ["storage", "worker"]
  name          = "${var.cluster_name}-wrkr-${count.index}" #If I want to add more than one worker node, I can add the index
  description   = "Kubernetes worker ${count.index}"
  node_name     = var.proxmox_worker_nodes[count.index]
  vm_id         = 4054 + count.index

  agent {
    enabled = true
  }
  stop_on_destroy = true

  cpu {
    cores = var.worker_cores
    type  = "x86-64-v2-AES"
  }
  memory {
    dedicated = var.worker_memory_max
    floating = var.worker_memory_min
  }

  disk {
    datastore_id = var.vm_datastore_id
    file_id      = proxmox_virtual_environment_file.ubuntu_image[var.proxmox_worker_nodes[count.index]].id
    interface    = "scsi0"
    size         = 100
  }

  network_device {
    bridge = var.vm_network_bridge
    vlan_id = 40
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.worker_ips[count.index]}/${var.network_prefix}"
        gateway = var.network_gateway
      }
    }
    user_account {
      username = var.ssh_username
      #password = "ubuntu" # Required by cloud-init but not used (SSH keys only); must meet cloud-init password complexity rules.
      keys     = [local.ssh_public_key_content]
    }
  }

  operating_system {
    type = "l26"
  }
}