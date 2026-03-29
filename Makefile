BINARY      = serve-cloud-init
CMD         = ./cmd/serve-cloud-init
BASE_IMG    = /exports/netboot/ubuntu-26.04
OVERLAY_DIR = /exports/overlay

.PHONY: build build-linux test clean provision-kickstart \
        update-base wipe-overlay-% wipe-all-overlays reboot-nodes

build:
	go build -o $(BINARY) $(CMD)

build-linux:
	GOOS=linux GOARCH=amd64 go build -o $(BINARY) $(CMD)

test:
	go test -v ./cmd/serve-cloud-init/...

clean:
	rm -f $(BINARY)

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
