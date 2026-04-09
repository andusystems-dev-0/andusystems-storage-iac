#!/bin/bash
# Create VMs on Proxmox
ansible-playbook -i ansible/inventory/storage ansible/configurations/roles/vms.yml --tags vms -K