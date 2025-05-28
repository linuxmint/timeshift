# Timeshift Development

This documentation provides instructions for developing Timeshift.

## Prerequisites 

- meson
- help2man
- gettext 
- valac 
- libvte-2.91-dev 
- libgee-0.8-dev 
- libjson-glib-dev 
- libxapp-dev

If you are using a Debian-based distribution, you can install these
dependencies by running the following command in a terminal:

```bash 
sudo apt install meson \
help2man \
gettext \
valac \
scdoc \
libvala-dev \
libvte-2.91-dev \
libgee-0.8-dev \
libjson-glib-dev \
libxapp-dev
``` 

## Building and Installing 

### Step 1. Clone the Timeshift repository

```bash
git clone git@github.com:linuxmint/timeshift.git
``` 

### Step 2. Navigate to the Timeshift folder

```bash
cd timeshift
``` 

### Step 3. Build Timeshift

```bash
meson setup build
meson compile -C build 
``` 

### Step 4. Install Timeshift

Install
```bash
sudo meson install -C build
```
Uninstall
```
cd build
sudo ninja uninstall
```

### Step 5. Build the debian package

#### Package source code
```bash
tar czvf ../timeshift_24.02.1.orig.tar.gz --exclude='*.git' --exclude='.gitignore' --exclude='build' --exclude='*.swp' --exclude='*.orig' --exclude='*.rej' --exclude='*.bak' --exclude='*.gz' --exclude='*.xz' --exclude='*.bz2' --exclude='*.lzma' --exclude='debian' --exclude='archlinux' *
```

#### Add changelog
```
timeshift (24.02.1-1) unstable; urgency=medium

  * 24.02.1-1 unstable minor bug fixes

 -- Jiang Meng <jay@jay-PC>  Sun, 18 Aug 2024 20:51:22 +0800
```

#### Commit your code & merge to the source tree
```bash
git commit -a -m "fixed issues"
dpkg-source --commit
```

#### Package
```bash
dpkg-buildpackage -us -uc
```