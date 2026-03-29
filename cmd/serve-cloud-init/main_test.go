package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestServeCloudInit(t *testing.T) {
	server := httptest.NewServer(newHandler("../../cloud-init"))
	defer server.Close()

	tests := []struct {
		name     string
		path     string
		wantCode int
		wantBody string
	}{
		{
			name:     "pi2 meta-data",
			path:     "/244634d3/meta-data",
			wantCode: http.StatusOK,
			wantBody: "instance-id: 244634d3",
		},
		{
			name:     "pi2 meta-data hostname",
			path:     "/244634d3/meta-data",
			wantCode: http.StatusOK,
			wantBody: "local-hostname: pi2.tynet.us",
		},
		{
			name:     "pi2 user-data",
			path:     "/244634d3/user-data",
			wantCode: http.StatusOK,
			wantBody: "#cloud-config",
		},
		{
			name:     "pi2 user-data ssh key",
			path:     "/244634d3/user-data",
			wantCode: http.StatusOK,
			wantBody: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEA9fmxTmPKwxfGw4WJtnJhGI+S1LxTe41sR3rKnZ1LC",
		},
		{
			name:     "pi2 user-data microk8s",
			path:     "/244634d3/user-data",
			wantCode: http.StatusOK,
			wantBody: "snap install microk8s",
		},
		{
			name:     "pi2 user-data metallb",
			path:     "/244634d3/user-data",
			wantCode: http.StatusOK,
			wantBody: "metallb:10.0.60.1-10.0.60.254",
		},
		{
			name:     "pi3 meta-data",
			path:     "/a43386be/meta-data",
			wantCode: http.StatusOK,
			wantBody: "instance-id: a43386be",
		},
		{
			name:     "pi3 meta-data hostname",
			path:     "/a43386be/meta-data",
			wantCode: http.StatusOK,
			wantBody: "local-hostname: pi3.tynet.us",
		},
		{
			name:     "pi3 user-data",
			path:     "/a43386be/user-data",
			wantCode: http.StatusOK,
			wantBody: "#cloud-config",
		},
		{
			name:     "pi3 user-data ssh key",
			path:     "/a43386be/user-data",
			wantCode: http.StatusOK,
			wantBody: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEA9fmxTmPKwxfGw4WJtnJhGI+S1LxTe41sR3rKnZ1LC",
		},
		{
			name:     "pi3 user-data microk8s",
			path:     "/a43386be/user-data",
			wantCode: http.StatusOK,
			wantBody: "snap install microk8s",
		},
		{
			name:     "testnode meta-data",
			path:     "/testnode/meta-data",
			wantCode: http.StatusOK,
			wantBody: "instance-id: testnode",
		},
		{
			name:     "testnode meta-data hostname",
			path:     "/testnode/meta-data",
			wantCode: http.StatusOK,
			wantBody: "local-hostname: testnode.local",
		},
		{
			name:     "testnode user-data",
			path:     "/testnode/user-data",
			wantCode: http.StatusOK,
			wantBody: "#cloud-config",
		},
		{
			name:     "testnode user-data ssh key",
			path:     "/testnode/user-data",
			wantCode: http.StatusOK,
			wantBody: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEA9fmxTmPKwxfGw4WJtnJhGI+S1LxTe41sR3rKnZ1LC",
		},
		{
			name:     "unknown serial",
			path:     "/00000000/meta-data",
			wantCode: http.StatusNotFound,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := http.Get(server.URL + tt.path)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != tt.wantCode {
				t.Errorf("got status %d, want %d", resp.StatusCode, tt.wantCode)
			}

			if tt.wantBody != "" {
				body, err := io.ReadAll(resp.Body)
				if err != nil {
					t.Fatal(err)
				}
				if !strings.Contains(string(body), tt.wantBody) {
					t.Errorf("body %q does not contain %q", string(body), tt.wantBody)
				}
			}
		})
	}
}
