# Installs the patched native Intel accelerant. Run from this folder:  sh install.sh
cd "`dirname "$0"`" || exit 1
if [ ! -f intel_extreme.accelerant ]; then echo "intel_extreme.accelerant not found next to install.sh - nothing installed"; exit 1; fi
mkdir -p /boot/home/config/settings/kernel/drivers /boot/home/config/add-ons/accelerants
echo "hardware_cursor false" > /boot/home/config/settings/kernel/drivers/intel_extreme
# An older test script appended a line to UserBootscript that DELETES the driver 60 seconds after
# every boot. Remove any line that mentions it.
if [ -f /boot/home/config/boot/UserBootscript ]; then
  grep -v 'intel_extreme.accelerant' /boot/home/config/boot/UserBootscript > /tmp/ub.$$
  cp /tmp/ub.$$ /boot/home/config/boot/UserBootscript
  rm -f /tmp/ub.$$
fi
cp intel_extreme.accelerant /boot/home/config/add-ons/accelerants/intel_extreme.accelerant || { echo "copy FAILED"; exit 1; }
sync
echo "installed - reboot, and at the boot menu just choose Continue booting"
