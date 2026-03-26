BINARY = serve-cloud-init
CMD    = ./cmd/serve-cloud-init

.PHONY: build build-linux test clean

build:
	go build -o $(BINARY) $(CMD)

build-linux:
	GOOS=linux GOARCH=amd64 go build -o $(BINARY) $(CMD)

test:
	go test -v ./cmd/serve-cloud-init/...

clean:
	rm -f $(BINARY)
