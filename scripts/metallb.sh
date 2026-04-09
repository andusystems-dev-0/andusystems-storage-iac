#!/bin/bash
# Install Storage Apps for Kubernetes
ansible-playbook -i ansible/inventory/storage ansible/configurations/roles/metallb.yml --tags metallb,install -K