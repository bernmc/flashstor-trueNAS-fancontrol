## INSTALLING TRUENAS SCALE WITH FANCONTROL ON ASUSTOR FLASHSTOR DEVICES

14/10/23 - confirmed this mod survives the upgrade to TrueNAS-SCALE-22.12.4.2

**UPDATE: TrueNAS-SCALE Cobia (23.10.0):** Note that the following guide was written for TrueNAS-SCALE 22.x (Bluefin). With the release of 23.x, iX have further locked down the appliance. If you upgrade from 22.x, the shell and post-init scripts will survive, but the kmod will not 'make' and install as these commands are no longer available. At the moment, the only way I know to bypass this is to enable developer mode with `install-dev-tools`

You should note that enabling developer mode will mean that iX will automatically delete any support requests you generate - ie, you're on your own buddy! It's not meant to be used for deployed TrueNAS systems, but if you're using unsupported hardware, it's the only way I know of being able to install the necessary kmods etc.

---

This project describes installing TrueNAS on Asustor's Flashstor 6 and 12 Pro devices, and enabling temperature monitoring and fan control on these devices under TrueNAS SCALE 22.12.3.3. It is built on the original ideas in[ John Davis&#39; gist describing Installing Debian on the Nimbustor4/2 devices.](https://gist.github.com/johndavisnz/bae122274fc6f0e006fdf0bc92fe6237 "view John's gist")

While not officially supported, Asustor appear to quietly endorse installing TrueNAS on their devices - they even have a howto video in their youtube Asustor College: [https://youtu.be/YytWFtgqVy0] (TrueNAS Core Asustor install)]

The issue with installing TrueNAS on the Asustors is that there is no native support for temperature monitoring and fan control. Additionally, iXsystems (TrueNAS developer) actively discourages tinkering with the innards of their system.

And if that's not enough, the NVMe drives in the Flashstors need to be handled differently from traditional HDDs and SDDs. There's no convention as to how many temp sensors there are on an NVME drive, or what temperatures they monitor. The script therefor needs to deal with any number of temp sensors on anything up to 12 NVME drives.

None of the existing fan control methods and scripts I found would work under these circumstances, so it was necessary to adapt them. And here we are!

---

# Why Install TrueNAS?

Because: ZFS!

> *Disks are the physical manifestation of storage. Disks are evil. They lie about their characteristics and layout, they hide errors, and they fail in unexpected ways. ZFS means no longer having to fear that your disks are secretly plotting against you. Yes, your disks **are** plotting against you, but ZFS exposes their treachery and puts a stop to it.*
>
> *~ Alan Jude*

---

## CAVEATS

* TrueNAS is an appliance. This is nerdspeak for 'don't be tinkering under the hood'. It's not a traditional Debian install, and trying to apt-get or update may break the system. The method detailed below does not need any additional packages to be installed, but it does use a custom kernel module, and some tinkering as root. (If you're on TrueNAS-SCALE 23.x, please see the note above)
* Tinkering with GPIO input/outputs can be dangerous and lead to instability, corrupted data or a broken system.
* I am an enthusiastic amateur. Not a programmer. I can Do My Research, copy and paste, and (revelation!) use generative AI to write code. So, I probably won't be able to answer your complex questions. I also can't guarantee that this will work on your system
* In short, PMD (People May Die), the world might end etc. Do this stuff **at your own risk**, and don't come whining if something breaks. Don't install it on a Mission Critical System. Back up your data. Test it extensively before trusting it. In short, be a Grown Up.

---

## Steps

Here's a basic outline of what you will need to do to get TrueNAS SCALE working with fan control on your Flashstor:

1. Install TrueNAS SCALE on your Flashstor
2. Access the shell through the TrueNAS web interface (or via SSH) using a user with sufficient permissions to play at being root.
3. If you are on TrueNAS-SCALE 23.x (Cobia), enable Developer Mode
4. Compile and install the it87 branch of mafredri's asustor-platform-driver kernel module (kmod)
5. Install the check_asustor_it87.kmod.sh script - checks that the kmod exists at every reboot, and recompiles it if not
6. Add the check_asustor_it87.kmod.sh script to TrueNAS' init scripts so that it runs after every boot.
7. Install the custom fan control script - modified from John Davis' original script

---

## 1. Install TrueNAS SCALE and access the shell

* Installing SCALE is not covered here - see youtube link above, and find tutorials on the internets. There are several.
* Once you've installed, log in to the TrueNas web interface, and make sure your user has sudo permissions:  this tutorial assumes you're using the default admin user set up during install.
* You can edit other users through **Credentials --> Local Users --> select the user** and hit **EDIT.**  Scroll down to the bottom of the user edit box, and make sure the checkbox for "**Allow all sudo commands**" is checked. Optionally, check the "**Allow all sudo commands without password**" box. I'd recommend going back and unchecking that one when you're done - basic security. **Save** to get back to the main screen.
* Select **System Settings --> Shell** from the side menu and you should find yourself inside TrueNAS' terminal
* [You could also do all of this by SSH and use a fancy AI-enabled editor like [Warp](https://app.warp.dev/referral/EJGN8D).]
* You now have the option of prefacing all/most of the commands that follow with "**sudo**", or just go for god-mode with **`sudo su`**. I'm going to assume you're god for the rest of this guide.
* If your `sudo su` was succesful, your shell prefix should change to **`root@truenas`** . Unleash hell
* [Note that if you opt for the safer option of sudo -ing each command individually, you may have to get a bit smart with some commands as linux will only apply sudo to the first part of a two part command (because: Reasons). eg: 	`echo 155 > /sys/class/hwmon/hwmon10/pwm1 `  will change the fan speed (if it's on hwmon10 )if you've sudo su 'd (ie god mode), but you will need to use  `echo 155 | sudo tee /sys/class/hwmon/hwmon10/pwm1` if you're not root, and sudo'ing each command individually.]

---

## 1.5 Enable Developer Mode

Only necessary for **TrueNAS-SCALE 23.x** (Cobia): Execute `install-dev-tools` from your root prompt. This will download and install a bunch of missing packages. It takes a few minutes. Once you've done this, don't bother trying to contact iX for help - they'll automatically delete any support requests.

---

## 2. Check the status of your current temp sensors

First, it's useful to check which sensors your system is seeing so that you'll know that things have changed when you install the asustor kernel module.

Execute the following commands in sequence (copy & paste each line and hit enter)

`sudo su`

enter your admin password, and you should be in root@truenas[/home/admin]

`sensors`

You should see a long list of sensors, but no reference to an it8625 or fan speed. (See below for what this wil look like when the kmod is installed)

---

## 3. Compile and install the it87 kmod

For reference, the link to mafredri's patched version of the mainline it87 kernel platform driver is here: [Asustor-platform-driver](https://github.com/mafredri/asustor-platform-driver/blob/it87/README.md).

This guide assumes you're logged in as the default admin user - you'll need to modify directory paths if you're someone else.

Execute the following commands in sequence (copy & paste each line and hit enter)

- Clone the kmod repository and change to its directory

`git clone https://github.com/mafredri/asustor-platform-driver`

`cd asustor-platform-driver`

- Check out the it87 branch

`git checkout it87`

- Compile the kmod

`make`

- Install the kmod

`make install`

*(Note - occasionally the system seems to get stuck on this command. If nothing happens for a few minutes, `<ctrl-c>`  to interrupt the command, and then issue it again - it usually works the 2nd time)*

- Update module dependencies

`depmod -a`

- Load the module

`modprobe -a asustor_it87`

- Change back to the admin home directory

`cd ..`

Now, if you execute `sensors` again, you should see (amongst others) a new section that looks something like this:

```
it8625-isa-0a30
Adapter: ISA adapter
in0:           1.59 V  (min =  +1.53 V, max =  +1.97 V)
in1:           1.62 V  (min =  +2.64 V, max =  +2.39 V)  ALARM
in2:           2.06 V  (min =  +1.46 V, max =  +1.20 V)  ALARM
in3:           2.02 V  (min =  +0.60 V, max =  +0.58 V)  ALARM
in4:           2.00 V  (min =  +1.98 V, max =  +2.25 V)
in5:           1.99 V  (min =  +0.73 V, max =  +2.00 V)
in6:           1.96 V  (min =  +0.46 V, max =  +1.03 V)  ALARM
3VSB:          3.32 V  (min =  +5.13 V, max =  +1.80 V)  ALARM
Vbat:          3.06 V  
+3.3V:         3.30 V  
fan1:        1433 RPM  (min =   11 RPM)
fan2:           0 RPM  (min =   10 RPM)  ALARM
fan3:           0 RPM  (min =   28 RPM)  ALARM
temp1:       -128.0°C  (low  = +30.0°C, high =  +1.0°C)
temp2:       -128.0°C  (low  = +59.0°C, high = +28.0°C)
temp3:       -128.0°C  (low  = +86.0°C, high = +125.0°C)
intrusion0:  ALARM
```

The  `fan1 1433 RPM`  line is your asustor's fan, running at the default low speed setting.

---

## 4. Create the check_asustor_it87.kmod.sh script

The kmod will need to be re-installed whenever the TrueNAS kernel is altered - eg with a TrueNAS update. The following script will run at each boot and check whether the kmod exists and re-install it if not. It then runs the fan control script.

The easiest way to create the two necessary scripts to enable fan control is to use `nano` to create the scripts, and then just copy and paste the contents of the scripts in this repository into `nano`:

Make sure you're in the `/home/admin` directory

`nano check_asustor_it87.kmod.sh`

This will open up a blank file, with the check_asustor filename at the top

Copy the contents of the `check_asustor_it87.kmod.sh` script in thisrepository, and paste them into your new file in nano.

Hit `<ctrl-o>` and `enter` to save the file, then `<ctrl-x>` to exit

Make the script executable with

`chmod +x check_asustor_it87.kmod.sh`

---

## 5. Create the temp_monitor.sh script

There are a number of variables in this script that you may want to modify, depending on your personal preferences and circumstances. See the section below for a brief description, although they're all commented in the script and should be self-explanatory.

Make sure you're in the `/home/admin` directory

`nano temp_monitor.sh`

This will open up a blank file, with the temp_monitor filename at the top

Copy the contents of the `temp_monitor.sh` script in this repository, and paste them into your new file in nano.

Modify any variables you want to

Hit `<ctrl-o>` and `enter` to save the file, then `<ctrl-x>` to exit

Make the script executable with

`chmod +x temp_monitor.sh`

---

## 6. Add the check script as a TrueNAS init script

In the TrueNAS web console, go to **System Settings** --> **Advanced**

Go to the **Init/Shutdown** **Scripts** box, and hit the **ADD** button. Say ok to the popup warning.

Enter/select the following in the **Edit Init/Shutdown Script** dialogue box:

**Description**: Start Asustor temp monitoring (or anything you'd like to name it)

**Type**: Script

**Script path**: /home/admin/check_asustor_it87.kmod.sh

**When**: Post init

Make sure **Enabled** is ticked

**Timeout**: 20

Hit the **Save** button

---

## 7. Reboot baby!

Your work is done. Reboot your Flashstor. When it comes back online, you should hear the fan speed change.

Try stressing the NAS - copy some files, run speed test etc and see if the fan speed changes. Remember that if you've used the defaults, nothing will happen until the CPU gets hotter than 50C, or any of the NVMe's get hotter than 35C.

You can go back to the shell at any point and enter `sensors` at the command line to check the fan speed (you don't need to use sudo or be root for this. )

---

## 8. Tweaking the script

There are a number of variables in the script that you can use to customise the fan/temperature response. How you do this will depend on your circumstances, and how tolerant you are of fan noise versus chip temperatures.

Also, remember that a constant noise is less intrusive than a variable noise - so a fan running at a constant 3000rpm may disturb you less than a fan that constantly varies between 2000 and 2500 rpm.

The main tweak varaibles are towards the beginning of the script - they are all commented so should be self-explanatory, as is most of the script:

**frequency** **= 10** : How often the script updates temps and potentially responds them. Default is 10 seconds. Change this if you want to increase or reduce the frequency of fan speed changes

**ratio_sys_to_hdd =** **1** : The script queries and responds to system and NVME temps differently. The original script had this set to 12 (ie check hdd's once for every 12 system checks) as HDD queries interrupt I/O. I don't think this applies to NVMe's (but I may be wrong), so I've set it to 1, figuring silicon is silicon. We're not dealing with spinning rust here.

HDD and System temp thresholds - these are the temps (in degrees celsius) above which the script will start to ramp up fan speed:

**hdd_threshold=35**

**sys_threshold=50**

Minimum Fan speed  - sets the minimum fan speed using pwm (Pulse Width Modulation) values. It is set to 60 which is 1580 rpm. Here are some pwm values for different fan speeds. A pwm of 255 is maximum fan speed.

60 = 1580

70 = 1757

80 = 1970

90 = 2070

**min_pwm=60**

Temperature deltas: You don't want the fan responding to every tiny temp change or it'll drive you scatty. The delta variables set the temp change (in deg celsius) the script looks for before altering the fan speed.

**hdd_delta_threshold=2**

**sys_delta_threshold=4**

### Fan curves:

You may want to play with these. The script uses slightly different exponential curves for system and NVMe temps to ramp the fan speed up gradually at first, and then more rapidly the more the temp rises.

**For the NVMe's**, the curve is *temp squared / 1.8*. I used 1.8 as a fudge factor because this will set the fan speed to maximum when the drives hit 60 degrees (most NVMe data sheets specify operating temps of around 35-70 degrees.) Change the fudge factor if you want the fan to hit max speed at a different temp.

*Note that in bash, you can't divide by a non integer number: (temp * temp) / 1.8 will give an error, so you have to be a smartarse and use something like (temp * temp) * 10/18*

**The system temp curve** is *temp squared / 2*. This is what John's original script used and I can't see any reason to change it for the flashstors.
