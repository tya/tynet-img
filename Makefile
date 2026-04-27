BINARY      = serve-cloud-init
CMD_DIR     = serve-cloud-init
OVERLAY_DIR = /exports/overlay
ENV_FILE   ?= tynet.env

.PHONY: help build build-linux test clean \
        pi2 pi3 pi \
        update-base wipe-overlay-% wipe-all-overlays wipe-tftp wipe-tftp-% wipe-release-% reboot-nodes \
        logs status check-boot-config console cycle-pi2 cycle-pi3

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
	@echo "Image build (run on kickstart — one per release, node-agnostic):"
	@echo "  ubuntu-<ver>           extract + customize shared base image (e.g. make ubuntu-26.04)"
	@echo "                         To add a new release, add its URL to IMAGE_URLS in extract-img"
	@echo ""
	@echo "Node provisioning (run on kickstart — per node):"
	@echo "  pi2                    provision pi2.tynet.us TFTP dir and overlay dirs"
	@echo "  pi3                    provision pi3.tynet.us TFTP dir and overlay dirs"
	@echo "  pi                     provision all nodes"
	@echo "  ENV_FILE=vm.env make pi2   use alternate env file (default: tynet.env)"
	@echo ""
	@echo "Image maintenance (run on kickstart):"
	@echo "  update-base            apply security patches to the shared base image"
	@echo "  wipe-release-<name>    wipe a netboot release dir (e.g. make wipe-release-ubuntu-22.04)"
	@echo "  wipe-tftp              wipe all per-node TFTP dirs (re-run pi to repopulate)"
	@echo "  wipe-tftp-<mac>        wipe a single node's TFTP dir (e.g. make wipe-tftp-dc-a6-32-8d-f3-ca)"
	@echo ""
	@echo "Node maintenance (run on kickstart):"
	@echo "  wipe-overlay-<node>    wipe a single node's overlay (e.g. make wipe-overlay-pi2)"
	@echo "  wipe-all-overlays      wipe all nodes' overlays (requires CONFIRM=yes)"
	@echo "  reboot-nodes           drain and reboot all nodes (via tynet-infra)"
	@echo "  cycle-pi2              power-cycle pi2 via Unifi PoE (via tynet-infra)"
	@echo "  cycle-pi3              power-cycle pi3 via Unifi PoE (via tynet-infra)"
	@echo "  check-boot-config      validate TFTP + NFS config before rebooting (permissions, cmdline, exports)"
	@echo "  status                 show per-node status (release, overlay, SSH key, last sync)"
	@echo "  console                listen for netconsole messages from booting nodes"
	@echo "  logs                   show recent build log files"

build:
	cd $(CMD_DIR) && go build -o ../$(BINARY) .

build-linux:
	cd $(CMD_DIR) && GOOS=linux GOARCH=amd64 go build -o ../$(BINARY) .

test:
	cd $(CMD_DIR) && go test -v .

clean:
	rm -f $(BINARY)

# Pattern rule: works for any release (e.g. make ubuntu-28.04).
# Add the new release's image URL to IMAGE_URLS in extract-img first.
ubuntu-%:
	sudo ./extract-img ubuntu-$* && sudo ./customize-img ubuntu-$*

pi2:
	TYNET_ENV=$(ENV_FILE) sudo ./build-node pi2.tynet.us

pi3:
	TYNET_ENV=$(ENV_FILE) sudo ./build-node pi3.tynet.us

pi: pi2 pi3


# Update the shared base image with security patches.
# Run wipe-all-overlays + reboot nodes afterward so no upper-layer shadows linger.
# Uses systemd-nspawn which handles /proc /dev /sys bind-mounts automatically.
# Specify RELEASE to target a different base image (default: ubuntu-22.04).
RELEASE ?= ubuntu-22.04
update-base:
	sudo systemd-nspawn -D /exports/netboot/$(RELEASE) apt-get update
	sudo systemd-nspawn -D /exports/netboot/$(RELEASE) apt-get upgrade -y
	sudo systemd-nspawn -D /exports/netboot/$(RELEASE) apt-get autoremove -y

# Wipe a netboot release directory: make wipe-release-ubuntu-22.04
# Removes /exports/netboot/<name>. Does NOT touch TFTP dirs or NFS exports —
# run 'make wipe-tftp' and 'make provision' afterward if also removing the active release.
wipe-release-%:
	@[ -d /exports/netboot/$* ] || { echo "ERROR: /exports/netboot/$* does not exist"; exit 1; }
	@echo "Wiping /exports/netboot/$*"
	sudo rm -rf /exports/netboot/$*

# Wipe all per-node TFTP dirs — removes stale/mixed files from prior image builds.
# Run 'make provision' afterward to repopulate from the current base image.
wipe-tftp:
	@echo "Wiping all per-node TFTP directories under /srv/tftpboot/"
	sudo rm -rf /srv/tftpboot/*/
	sudo mkdir -p /srv/tftpboot

# Wipe a single node's TFTP dir: make wipe-tftp-244634d3
wipe-tftp-%:
	@[ -d /srv/tftpboot/$* ] || { echo "ERROR: /srv/tftpboot/$* does not exist"; exit 1; }
	@echo "Wiping /srv/tftpboot/$*"
	sudo rm -rf /srv/tftpboot/$*
	sudo mkdir -p /srv/tftpboot/$*

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

# Reboot all nodes via tynet-infra (k8s drain + reboot + uncordon)
reboot-nodes:
	$(MAKE) -C ../../tynet-infra reboot-nodes

# Power-cycle targets delegate to tynet-infra (Unifi PoE + 1Password, not netboot-specific)
cycle-pi2:
	$(MAKE) -C ../../tynet-infra cycle-pi2

cycle-pi3:
	$(MAKE) -C ../../tynet-infra cycle-pi3

check-boot-config:
	TYNET_ENV=$(ENV_FILE) ./check-boot-config

status:
	TYNET_ENV=$(ENV_FILE) ./check-status

# Listen for netconsole UDP messages from booting nodes.
# Nodes send kernel log (including overlayroot-nfs hook output) to kickstart:6666.
console:
	@echo "Listening for netconsole messages on UDP 6666 (Ctrl-C to stop)..."
	socat UDP-RECV:6666 STDOUT

# Show recent build logs with outcome (SUCCESS/FAILED) and duration.
logs:
	@ls -t /var/log/tynet-img/customize-img-*.log 2>/dev/null | head -20 | while read f; do \
		result=$$(grep -o 'SUCCESS\|FAILED' "$$f" | tail -1); \
		result=$${result:-INCOMPLETE}; \
		node=$$(grep 'hostname:' "$$f" | head -1 | awk '{print $$NF}'); \
		ts=$$(basename "$$f" | sed 's/customize-img-\([0-9-]*\)-.*/\1/'); \
		echo "$$ts  $$node  $$result  $$f"; \
	done
