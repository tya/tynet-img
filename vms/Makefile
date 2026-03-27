.DEFAULT_GOAL := help
.PHONY: help start stop kickstart node clean status

help:
	@echo "Targets:"
	@echo "  start      start both kickstart and node VMs"
	@echo "  stop       stop both VMs"
	@echo "  kickstart  shell into kickstart VM"
	@echo "  node       shell into node VM"
	@echo "  status     list all Lima VMs"
	@echo "  clean      stop and delete both VMs"

start:
	limactl start kickstart.yaml
	limactl start node.yaml

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
