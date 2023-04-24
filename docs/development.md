# Timeshift Development

This documentation provides instructions for developing Timeshift.

## Prerequisites 

- make 
- gettext 
- valac 
- libvte-2.91-dev 
- libgee-0.8-dev 
- libjson-glib-dev 

If you are using a Debian-based distribution, you can install these dependencies by running the following command in a terminal:

```bash 
sudo apt install make \
gettext \
valac \
libvte-2.91-dev \
libgee-0.8-dev \
libjson-glib-dev
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
make 
``` 

### Step 4. Install Timeshift

```bash
sudo make install
```