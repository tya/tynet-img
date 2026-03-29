package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"
)

func newHandler(dir string) http.Handler {
	fs := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s %s", r.RemoteAddr, r.Method, r.URL.Path)
		fs.ServeHTTP(w, r)
	})
}

func defaultDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "cloud-init"
	}
	return filepath.Join(filepath.Dir(exe), "cloud-init")
}

func main() {
	dir := flag.String("dir", defaultDir(), "directory containing per-node seed data")
	addr := flag.String("addr", ":8000", "address to listen on")
	flag.Parse()

	log.Printf("serving %s on %s", *dir, *addr)
	log.Fatal(http.ListenAndServe(*addr, newHandler(*dir)))
}
