#!/bin/bash
# Do a full redeploy of everything
ansible-playbook -i ansible/inventory/storage ansible/configurations/storage.yml --tags vms,kubernetes,metallb,apps,install -K