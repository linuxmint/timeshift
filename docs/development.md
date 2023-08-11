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
meson setup -C build
meson compile -C build 
``` 

### Step 4. Install Timeshift

```bash
sudo meson install -C build
```
