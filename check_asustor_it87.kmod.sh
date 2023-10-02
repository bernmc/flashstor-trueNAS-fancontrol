#!/bin/sh

# Asustor Flashstor kernel module check/compile script for TrueNAS-SCALE
# Checks to see if the necessary it87 kmod exists, installs it if not, and runs the fan control script
# By Bernard Mc Clement, Sept 2023

# Add this as a post-init script so that it runs on every boot

# Check if the kmod exists and is installed
if ! modinfo asustor-it87 >/dev/null 2>&1; then
    echo "asustor-it87 kmod not found or not installed. Compiling and installing..."

    # Clone the repository
    git clone https://github.com/mafredri/asustor-platform-driver
    cd asustor-platform-driver

    # Checkout the it87 branch
    git checkout it87

    # Compile the kmod
    sudo make

    # Install the kmod
    sudo make install

    # Update module dependencies
    sudo depmod -a

    # Load the module
    sudo modprobe -a asustor_it87

    echo "asustor-it87 kmod compiled, installed, and loaded successfully."
else
    # Load the module
    sudo modprobe -a asustor_it87

    echo "asustor-it87 kmod is already installed."
fi

# Run the fan control script
nohup /home/admin/temp_monitor.sh >/dev/null 2>&1 &