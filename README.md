# extract-img

Downlaod and extract ubuntu images for netboot process

## Usage
```bash
sudo ./extract-img https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.4-preinstalled-server-arm64+raspi.img.xz
```

## Usage with extract location
```bash
sudo ./extract-img https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.4-preinstalled-server-arm64+raspi.img.xz /some/extract/directory
```

## Output
extract-img will write human output to STDERR and program output to STDOUT.
Specifically the path for `boot` and `root` directories from the image wil be written to STDOUT.
