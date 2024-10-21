#!/bin/sh

: <<'EOF' #Introductory comment block:
Asustor Flashstor kernel module check/compile script for TrueNAS-SCALE
Checks to see if the necessary it87 kmod exists, installs it if not, and runs the fan control script
By Bernard Mc Clement, Sept 2023. 
Updated 10/2024 to support Dragonfish

Note that you can check if the asustor-it87 kmod is installed by running the following command in the truenas shell:
 if lsmod | grep -q asustor_it87; then
    echo "asustor-it87 kmod is already installed."
  else
    echo "asustor-it87 kmod not found or not installed."
 fi
EOF


# Add this as a post-init script so that it runs on every boot

# Check if the kmod exists and is installed
if ! lsmod | grep -q asustor_it87; then
    echo "asustor-it87 kmod not found or not installed. Compiling and installing..."

    # Clone the repository
    git clone https://github.com/mafredri/asustor-platform-driver
    cd asustor-platform-driver

    # Install dkms
    sudo apt install -y dkms

    # Compile the kmod
    sudo make

    # Install the kmod using dkms
    sudo make dkms

    echo "asustor-it87 kmod compiled and installed successfully."
else
    echo "asustor-it87 kmod is already installed."
fi

# Run the fan control script
nohup /home/admin/temp_monitor.sh >/dev/null 2>&1 &