#!/bin/bash
# Install Storage Apps for Kubernetes
ansible-playbook -i ansible/inventory/storage ansible/configurations/apps.yml --tags apps,install -K
