.DEFAULT_GOAL := help
.PHONY: help start stop kickstart node clean status provision test

help:
	@echo "Targets:"
	@echo "  start      start both kickstart and node VMs"
	@echo "  provision  run Ansible against the kickstart VM"
	@echo "  test       run integration tests from the node VM"
	@echo "  stop       stop both VMs"
	@echo "  kickstart  shell into kickstart VM"
	@echo "  node       shell into node VM"
	@echo "  status     list all Lima VMs"
	@echo "  clean      stop and delete both VMs"

start:
	limactl start kickstart.yaml
	limactl start node.yaml

provision:
	$(MAKE) -C ../../tynet-infra kickstart-vm

test:
	limactl shell node -- sudo bash -s < test.sh

stop:
	limactl stop kickstart || true
	limactl stop node || true

kickstart:
	limactl shell kickstart

node:
	limactl shell node

status:
	limactl list

clean: stop
	limactl delete kickstart || true
	limactl delete node || true
