BINARY        = serve-cloud-init
CMD_DIR       = serve-cloud-init
BASE_IMG      = /exports/netboot/ubuntu-26.04
OVERLAY_DIR   = /exports/overlay
KICKSTART_IP  = 10.0.60.10

.PHONY: help build build-linux test clean provision-kickstart \
        update-base wipe-overlay-% wipe-all-overlays reboot-nodes \
        pi2 pi3

.DEFAULT_GOAL := help

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Build:"
	@echo "  build                  build serve-cloud-init for local machine"
	@echo "  build-linux            cross-compile serve-cloud-init for linux/amd64"
	@echo "  test                   run Go unit tests"
	@echo "  clean                  remove built binary"
	@echo ""
	@echo "Provisioning:"
	@echo "  provision-kickstart    run Ansible against the production kickstart host"
	@echo ""
	@echo "Image build (run on kickstart host):"
	@echo "  pi2                    build netboot image for pi2.tynet.us"
	@echo "  pi3                    build netboot image for pi3.tynet.us"
	@echo ""
	@echo "Maintenance (run on kickstart host):"
	@echo "  update-base            apply security patches to the shared base image"
	@echo "  wipe-overlay-<node>    wipe a single node's overlay (e.g. make wipe-overlay-pi2)"
	@echo "  wipe-all-overlays      wipe all nodes' overlays (requires CONFIRM=yes)"
	@echo "  reboot-nodes           drain and reboot all nodes via Ansible"

build:
	cd $(CMD_DIR) && go build -o ../$(BINARY) .

build-linux:
	cd $(CMD_DIR) && GOOS=linux GOARCH=amd64 go build -o ../$(BINARY) .

test:
	cd $(CMD_DIR) && go test -v .

clean:
	rm -f $(BINARY)

pi2:
	sudo ./customize-img $(KICKSTART_IP) 244634d3 pi2.tynet.us

pi3:
	sudo ./customize-img $(KICKSTART_IP) a43386be pi3.tynet.us

provision-kickstart:
	cd ansible && ansible-playbook playbooks/kickstart.yml


# Update the shared base image with security patches.
# Run wipe-all-overlays + reboot nodes afterward so no upper-layer shadows linger.
# Uses systemd-nspawn which handles /proc /dev /sys bind-mounts automatically.
update-base:
	sudo systemd-nspawn -D $(BASE_IMG) apt-get update
	sudo systemd-nspawn -D $(BASE_IMG) apt-get upgrade -y
	sudo systemd-nspawn -D $(BASE_IMG) apt-get autoremove -y

# Wipe one node's overlay: make wipe-overlay-pi1
# The node must be offline or rebooted after this.
wipe-overlay-%:
	@echo "Wiping overlay for $*"
	sudo rm -rf $(OVERLAY_DIR)/$*/upper $(OVERLAY_DIR)/$*/work
	sudo mkdir -p $(OVERLAY_DIR)/$*/upper $(OVERLAY_DIR)/$*/work

# Wipe all nodes' overlays at once (run on kickstart server; use before rebooting cluster after update-base).
# Requires CONFIRM=yes to prevent accidental data loss.
wipe-all-overlays:
	@[ "$(CONFIRM)" = "yes" ] || { echo "ERROR: set CONFIRM=yes to wipe all overlays"; exit 1; }
	@for d in $(OVERLAY_DIR)/*/; do \
		echo "Wiping $$d"; \
		sudo rm -rf "$$d/upper" "$$d/work"; \
		sudo mkdir -p "$$d/upper" "$$d/work"; \
	done

# Reboot all nodes via Ansible.
# Drains each node before rebooting so k8s workloads are evicted gracefully,
# then uncordons after the node comes back up.
reboot-nodes:
	cd ansible && ansible-playbook playbooks/reboot-nodes.yml
