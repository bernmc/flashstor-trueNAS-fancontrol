#!/bin/bash

# Asustor Flashstor6 and Flashstor12 Pro fan control script for TrueNAS-SCALE
#
# Standing on the shoulders of giants: adapted from John Davis' original script at
#     https://gist.github.com/johndavisnz/06a5e1aabaf878add0ad95669b3a0b3d
#
# Updated version:
# - Dynamically handles any number of NVMe drives installed in the Flashstor 6 or 12
# - Removes reliance on installing extra packages (hddtemp, smartmontools, etc)
# - Uses mafredri's asustor-platform-driver (it87 branch) for the kernel platform driver
# - Linear fan curves for smoother response (replaces original squared curves)
# - Gradual fan speed adjustment to prevent sudden jumps
# - Temperature averaging over multiple readings for stability
# - Increased hysteresis to reduce fan speed hunting
#
# v1.0 05-08-2023 ( initial test version )
# v1.1 18-09-2023 ( updated curves and threshold variables )
# v1.2 24-09-2023 ( first publicly available version )
# v2.0 09-2025    ( linear curves, gradual adjustment, temp averaging, anti-hunting )

# depends on:
#
# custom asustor-it87 kmod to read/set fan speeds:
#    Needs to be compiled from source - see https://github.com/mafredri/asustor-platform-driver
#    as the debian/TrueNAS-supplied it87 doesn't support the IT8625E used in the asustor
#    IMPORTANT: must use the it87 branch


# =============================================================================
# GLOBAL VARIABLES - TUNE THESE TO YOUR PREFERENCES
# =============================================================================

# debug output level : 0 = disabled 1 = minimal 2 = verbose 3 = extremely verbose
debug=0

# enable email fan change alerts (1 = on, 0 = off)
# WARNING: with mailalerts=1, you may get an email every $frequency seconds!
# Useful for initial testing, but disable once you're happy.
mailalerts=0

# address we send email alerts to
mail_address=admin@localhost
# hostname we use to identify ourselves in email alerts
mail_hostname=truenas.local
if [ $debug -gt 1 ]; then
   echo "STARTUP: mail_address=" $mail_address " mail_hostname=" $mail_hostname
fi

# how often we check temps / set speed ( in seconds )
frequency=15

# ratio of how often we update system sensors vs hdd sensors
# sampling the sys sensors is lightweight. For NVMe drives (unlike spinning HDDs),
# there's no I/O disruption, so we check both at the same frequency.
ratio_sys_to_hdd=1

# the NVMe temperature above which we start to increase fan speed
hdd_threshold=50

# the system temperature above which we start to increase fan speed
sys_threshold=75

# minimum pwm value we ever want to set the fan to
# Some reference PWM-to-RPM values (approximate):
#   60 = ~1580 RPM    90 = ~2070 RPM    150 = ~2700 RPM    255 = max speed
min_pwm=150

# Maximum PWM change per cycle (prevents sudden fan speed jumps)
max_pwm_change=8

# How much of a temp change do we need before decreasing fan speed (hysteresis)
# Higher values prevent the fan from constantly changing speed ("hunting")
hdd_delta_threshold=5
sys_delta_threshold=10

# Temperature averaging - number of readings to average over for smoother response
temp_history_size=3


# =============================================================================
# DETERMINE /sys/class/hwmon MAPPINGS
# =============================================================================

# which /sys/class/hwmon symlink points to the asustor_it87 ( fan speed )
hwmon_it87="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i it87 | cut -d "\"" -f 2`
if [ $debug -gt 1 ]; then
   echo "STARTUP: hwmon_it87="  $hwmon_it87
fi

# which /sys/class/hwmon symlink points to the intel coretemp sensors
hwmon_coretemp="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i coretemp | cut -d "\"" -f 2`
if [ $debug -gt 1 ]; then
   echo "STARTUP: hwmon_coretemp=" $hwmon_coretemp
fi

# which /sys/class/hwmon symlink points to the acpi sensors ( board temperature sensor )
hwmon_acpi="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i thermal_zone0 | cut -d "\"" -f 2`
if [ $debug -gt 1 ]; then
   echo "STARTUP: hwmon_acpi=" $hwmon_acpi
fi

# Use an array to find which /sys/class/hwmon symlinks point to the NVMe drive sensors
# This finds all NVMe drives regardless of the number installed
hwmon_nvme=()
i=1
while read -r path; do
  hwmon_nvme[$i]="/sys/class/hwmon/$path"
  ((i++))
done < <(ls -lQ /sys/class/hwmon | grep -i nvme | cut -d "\"" -f 2)

# Assign all the paths stored in the hwmon_nvme array to sequential hwmon_nvme variables
for ((j=1; j<=i; j++)); do
  variable_name="hwmon_nvme$j"
  eval "$variable_name=\"${hwmon_nvme[$j]}\""
done

# Display the NVMe hardware monitoring devices found if debug is on
if [ $debug -gt 1 ]; then
  echo "STARTUP: NVMe hardware monitoring devices:"
  eval "declare -p hwmon_nvme{1..$((i-1))}"
fi

# Temperature history arrays for averaging
declare -a sys_temp_history
declare -a hdd_temp_history


# =============================================================================
# FUNCTIONS
# =============================================================================

# set fan speed to desired_pwm with gradual adjustment
function set_fan_speed() {
    local current_pwm=$(cat $hwmon_it87/pwm1)

    # Calculate the difference
    local pwm_diff=$((desired_pwm - current_pwm))

    # Limit the change per cycle
    if [ $pwm_diff -gt $max_pwm_change ]; then
        pwm_diff=$max_pwm_change
    elif [ $pwm_diff -lt -$max_pwm_change ]; then
        pwm_diff=-$max_pwm_change
    fi

    # Calculate new PWM
    local new_pwm=$((current_pwm + pwm_diff))

    # Ensure bounds
    if [ $new_pwm -lt $min_pwm ]; then
        new_pwm=$min_pwm
    elif [ $new_pwm -gt 255 ]; then
        new_pwm=255
    fi

    echo $new_pwm > $hwmon_it87/pwm1

    if [ $debug -gt 1 ]; then
        echo "SET_FAN_SPEED: current=$current_pwm desired=$desired_pwm new=$new_pwm (change: $pwm_diff)"
    fi
}


# query fan speed and set the global fan_rpm
function get_fan_speed() {
    fan_rpm=$(cat $hwmon_it87/fan1_input)
}


# Add temperature to history and return the average
function add_to_temp_history() {
    local temp=$1
    local history_array_name=$2

    # Get current array
    eval "local -a current_history=(\"\${$history_array_name[@]}\")"

    # Add new temp to beginning
    current_history=($temp "${current_history[@]}")

    # Keep only the last N entries
    if [ ${#current_history[@]} -gt $temp_history_size ]; then
        current_history=("${current_history[@]:0:$temp_history_size}")
    fi

    # Update the array
    eval "$history_array_name=(\"\${current_history[@]}\")"

    # Calculate average
    local sum=0
    local count=0
    for temp_val in "${current_history[@]}"; do
        sum=$((sum + temp_val))
        count=$((count + 1))
    done

    if [ $count -gt 0 ]; then
        echo $((sum / count))
    else
        echo $temp
    fi
}


# query all NVMe drive temperatures and set the global hdd_temp to the highest
function get_hdd_temp() {
    # Initialize the maximum NVMe temperature variable
    local raw_hdd_temp=-273

    # Each NVMe drive has multiple temp sensors, and there is no industry standard for
    #   the number of sensors or what each sensor monitors. So we check all
    #   temps and find the highest.
    for varname in ${!hwmon_nvme*}; do
      for temp_file in ${!varname}/temp[0-9]*_input; do
        if [ -e "$temp_file" ]; then
          temp=$(cat $temp_file)
          if (( $temp > $raw_hdd_temp )); then
            raw_hdd_temp=$temp
          fi
          if (( $debug > 1 )); then
            echo "Temperature value: $temp, NVMe variable: $varname, Temperature file: $temp_file"
          fi
        fi
      done
    done

    raw_hdd_temp=$(expr $raw_hdd_temp / 1000)

    # Add to history and get averaged temperature
    hdd_temp=$(add_to_temp_history $raw_hdd_temp hdd_temp_history)

    if [ $debug -gt 1 ]; then
       echo "GET_HDD_TEMP: raw=$raw_hdd_temp averaged=$hdd_temp"
    fi
}


# query system temperatures and set the global sys_temp with the highest
function get_sys_temp() {
    # read the system board temp sensor via acpi
    local acpi_temp=$(cat $hwmon_acpi/temp1_input)
    acpi_temp=$(expr $acpi_temp / 1000)

    # read all the temps available via coretemp ( pkg + core1..N ) and return the highest
    local cpu_temp=$(cat $hwmon_coretemp/temp?_input | sort -nr | head -1)
    cpu_temp=$(expr $cpu_temp / 1000)

    # choose the greatest of the core and system temps
    local raw_sys_temp=$(( $acpi_temp > $cpu_temp ? $acpi_temp : $cpu_temp ))

    # Add to history and get averaged temperature
    sys_temp=$(add_to_temp_history $raw_sys_temp sys_temp_history)

    if [[ $debug -gt 1 ]] ; then
       echo "GET_SYS_TEMP: acpi=$acpi_temp cpu=$cpu_temp raw=$raw_sys_temp averaged=$sys_temp"
    fi
}


# map the current hdd_temp to a desired pwm value using linear curve
# Linear: each degree above threshold adds proportional PWM
# Range from hdd_threshold to 75 degrees maps min_pwm to 255
function map_hdd_temp() {
     if [[ $hdd_temp -le $hdd_threshold ]] ; then
          if [[ $debug -gt 1 ]]; then
             echo "MAP_HDD_TEMP: hdd temp=" $hdd_temp " and is under threshold"
          fi
          hdd_desired_pwm=$min_pwm
     else
          if [[ $debug -gt 1 ]] ; then
             echo "MAP_HDD_TEMP: hdd temp=" $hdd_temp " and is over threshold"
          fi

          local temp_range=$((75 - hdd_threshold))
          local pwm_range=$((255 - min_pwm))
          local temp_above_threshold=$((hdd_temp - hdd_threshold))

          # Linear calculation
          hdd_desired_pwm=$((min_pwm + (temp_above_threshold * pwm_range / temp_range)))
     fi

     if [[ $hdd_desired_pwm -gt 255 ]] ; then
          hdd_desired_pwm=255
     fi

     if [[ $debug -gt 1 ]] ; then
        echo "MAP_HDD_TEMP: hdd_desired_pwm=" $hdd_desired_pwm
     fi
}


# map the current sys_temp to a desired pwm value using linear curve
# Linear: each degree above threshold adds proportional PWM
# Range from sys_threshold to 95 degrees maps min_pwm to 255
function map_sys_temp() {
     if [[ $sys_temp -le $sys_threshold ]] ; then
          if [[ $debug -gt 1 ]] ; then
             echo "MAP_SYS_TEMP: sys_temp=" $sys_temp " and is under threshold"
          fi
          sys_desired_pwm=$min_pwm
     else
          if [[ $debug -gt 1 ]] ; then
             echo "MAP_SYS_TEMP: sys_temp=" $sys_temp " and is over threshold"
          fi

          local temp_range=$((95 - sys_threshold))
          local pwm_range=$((255 - min_pwm))
          local temp_above_threshold=$((sys_temp - sys_threshold))

          # Linear calculation
          sys_desired_pwm=$((min_pwm + (temp_above_threshold * pwm_range / temp_range)))
     fi

     if [[ $sys_desired_pwm -gt 255 ]] ; then
          sys_desired_pwm=255
     fi

     if [[ $debug -gt 1 ]] ; then
        echo "MAP_SYS_TEMP: sys_desired_pwm=" $sys_desired_pwm
     fi
}


# determine desired pwm based on both temp sources — use whichever is higher
function get_desired_pwm() {
    map_sys_temp
    map_hdd_temp

    if [[ $hdd_desired_pwm -gt $sys_desired_pwm ]] ; then
         desired_pwm=$hdd_desired_pwm
         if [[ $debug -gt 2 ]] ; then
            echo "GET_DESIRED_PWM: choosing hdd_pwm value - desired_pwm=" $desired_pwm " hdd_desired_pwm=" $hdd_desired_pwm " sys_desired_pwm=" $sys_desired_pwm
         fi
    else
         desired_pwm=$sys_desired_pwm
         if [[ $debug -gt 2 ]] ; then
            echo "GET_DESIRED_PWM: choosing sys_pwm value - desired_pwm=" $desired_pwm " hdd_desired_pwm=" $hdd_desired_pwm " sys_desired_pwm=" $sys_desired_pwm
         fi
    fi
}


# =============================================================================
# MAIN
# =============================================================================

# Initialize temperature history arrays
sys_temp_history=()
hdd_temp_history=()

# get initial temperatures
get_sys_temp
get_hdd_temp
get_fan_speed

last_sys_temp=$sys_temp
last_hdd_temp=$hdd_temp

# get initial pwm value
get_desired_pwm
last_pwm=$desired_pwm

# set initial fan speed
if [[ $debug -gt 1 ]] ; then
   echo "MAIN: initial fan pwm=" $desired_pwm
fi

set_fan_speed

# now loop forever monitoring and reacting
cycles=$ratio_sys_to_hdd

while true; do

    # update sensor readings
    get_fan_speed
    get_sys_temp

    if [[ $cycles -eq 1 ]] ; then
       if [[ $debug -gt 1 ]] ; then
          echo "MAIN: sampling hdd sensor"
       fi
       get_hdd_temp
       cycles=$ratio_sys_to_hdd
    else
       if [[ $debug -gt 1 ]] ; then
          echo "MAIN: skipping hdd sensor update"
       fi
       let cycles=$cycles-1
    fi

    # update target pwm value based on readings
    get_desired_pwm

    if [[ $debug -gt 1 ]] ; then
         echo "MAIN: desired_pwm=" $desired_pwm " last_pwm=" $last_pwm
         echo "MAIN: sys_temp=" $sys_temp " last_sys_temp=" $last_sys_temp
         echo "MAIN: hdd_temp=" $hdd_temp " last_hdd_temp=" $last_hdd_temp
         echo "MAIN: fan_rpm=" $fan_rpm
    fi

    # Apply fan speed changes (gradual adjustment in set_fan_speed prevents jumps)
    if [[ $desired_pwm -ne $last_pwm ]] ; then

        # Calculate deltas for hysteresis check
        let hdd_delta=$last_hdd_temp-$hdd_temp
        let sys_delta=$last_sys_temp-$sys_temp

        if [[ $debug -gt 1 ]] ; then
           echo "MAIN: current sys_delta=" $sys_delta " current hdd_delta=" $hdd_delta
        fi

        # For increases, react immediately (but gradual via set_fan_speed)
        # For decreases, apply hysteresis to prevent hunting
        if [[ $desired_pwm -gt $last_pwm ]] || [[ $hdd_delta -gt $hdd_delta_threshold ]] || [[ $sys_delta -gt $sys_delta_threshold ]]; then

           if [[ $desired_pwm -gt $last_pwm ]] ; then
              action="INCREASE"
           else
              action="DECREASE"
           fi

           if [[ $debug -ge 1 ]] ; then
              echo "!!!! fan speed $action : hdd_temp " $hdd_temp " sys_temp " $sys_temp " fan_rpm " $fan_rpm " - changing fan speed toward " $desired_pwm
           fi

           if [[ $mailalerts -ge 1 ]] && [[ $desired_pwm -gt $last_pwm ]] ; then
              echo "!!!! fan speed $action : hdd_temp " $hdd_temp " sys_temp " $sys_temp " fan_rpm " $fan_rpm " - changing fan speed toward" $desired_pwm | mail $mail_address -s "$mail_hostname - temperature alert"
           fi

           # set the fan speed (gradual adjustment happens inside set_fan_speed)
           set_fan_speed

           # Update state tracking variables
           last_pwm=$(cat $hwmon_it87/pwm1)
           last_sys_temp=$sys_temp
           last_hdd_temp=$hdd_temp

        else
           # not enough downward delta to trigger a change yet
           if [[ $debug -ge 1 ]] ; then
              echo "!!!! fan speed DECREASE desired: hdd_temp " $hdd_temp " sys_temp " $sys_temp " - but not enough delta (" $hdd_delta " " $sys_delta ") yet!"
           fi
        fi
    fi

    if [[ $debug -ge 1 ]] ; then
           echo "MAIN: sleeping for " $frequency " seconds"
    fi
    sleep $frequency

done
