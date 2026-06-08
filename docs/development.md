# Timeshift Development

This documentation provides instructions for developing Timeshift.

## Prerequisites 

- meson
- help2man
- gettext 
- valac 
- libgee-0.8-dev 
- libjson-glib-dev 

Optional (for GTK frontend):

- libgtk-3-dev
- libvte-2.91-dev
- libxapp-dev

If you are using a Debian-based distribution, you can install these
dependencies by running the following command in a terminal:

```bash 
sudo apt install meson \
help2man \
gettext \
valac \
libgee-0.8-dev \
libjson-glib-dev

# Optional GUI dependencies
sudo apt install libgtk-3-dev \
libvte-2.91-dev \
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

### Building command-line-only

To build only the `timeshift` command-line tool (without GTK/VTE dependencies):

```bash
meson setup build-cli -Dgtk=false
meson compile -C build-cli
```

### Step 4. Install Timeshift

```bash
sudo meson install -C build
```
