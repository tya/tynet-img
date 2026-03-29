BINARY = serve-cloud-init
CMD    = ./cmd/serve-cloud-init

.PHONY: build build-linux test clean provision-kickstart provision-certbot

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

provision-certbot:
	cd ansible && ansible-playbook playbooks/certbot.yml \
		-e godaddy_api_key=$$(op read "op://Private/OTE Dev Godaddy Key/username") \
		-e godaddy_api_secret=$$(op read "op://Private/OTE Dev Godaddy Key/password")
