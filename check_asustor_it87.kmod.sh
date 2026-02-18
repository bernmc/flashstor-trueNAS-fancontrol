#!/bin/sh

# Asustor Flashstor kernel module check/compile script for TrueNAS-SCALE
# Checks to see if the necessary it87 kmod exists, installs it if not, and runs the fan control script
# By Bernard Mc Clement, Sept 2023
# Updated Mar 2025 for Electric Eel / Fangtooth / Goldeye compatibility
#
# Add this as a post-init script so that it runs on every boot
#
# IMPORTANT NOTES:
# - This script must be located on a DataPool (not /home) — /home is mounted noexec on Electric Eel+
# - You must SSH in as root for the initial kmod compilation to work
# - After the initial install, this script handles recompilation after kernel updates

# =============================================================================
# CONFIGURATION - CHANGE THESE TO MATCH YOUR SETUP
# =============================================================================

# Set this to the correct path of YOUR fan control script.
# It must start with /mnt/ followed by your pool/dataset path.
# Example: /mnt/MyPool/SystemTools/temp_monitor.sh
FAN_CONTROL_SCRIPT_PATH="/mnt/<YourPool>/SystemTools/temp_monitor.sh"

# =============================================================================

# Check if the kmod exists and is installed
if ! modinfo asustor-it87 >/dev/null 2>&1; then
    echo "asustor-it87 kmod not found or not installed. Compiling and installing..."

    # Get the directory this script is in (for cloning the driver alongside it)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    cd "$SCRIPT_DIR"

    # Clone the repository if it doesn't already exist
    if [ ! -d "asustor-platform-driver" ]; then
        git clone https://github.com/mafredri/asustor-platform-driver
    fi

    cd asustor-platform-driver

    # Checkout the it87 branch
    git checkout it87

    # Pull latest changes
    git pull origin it87

    # Compile the kmod
    make

    # Install the kmod
    make install

    # Update module dependencies
    depmod -a

    # Load the module
    modprobe -a asustor_it87

    echo "asustor-it87 kmod compiled, installed, and loaded successfully."
else
    # Module exists but may not be loaded — ensure it's loaded
    modprobe -a asustor_it87

    echo "asustor-it87 kmod is already installed."
fi

# Run the fan control script
nohup $FAN_CONTROL_SCRIPT_PATH >/dev/null 2>&1 &
