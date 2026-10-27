# Back to the plain VESA driver.  Run:  sh revert.sh
rm -f /boot/home/config/add-ons/accelerants/intel_extreme.accelerant
rm -f /boot/home/config/settings/kernel/drivers/intel_extreme
sync
echo "removed - reboot"
