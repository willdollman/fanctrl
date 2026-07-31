#!/bin/bash
# One-time dev environment prep. Safe to re-run.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

# --- vendored webgui libs (Unraid normally provides these) ---------------
mkdir -p "$here/vendor"
dl() { [ -s "$here/vendor/$1" ] || curl -fsSL -o "$here/vendor/$1" "$2"; }
dl jquery.min.js        https://code.jquery.com/jquery-3.7.1.min.js
dl jquery-ui.min.js     https://code.jquery.com/ui/1.13.3/jquery-ui.min.js
dl font-awesome.min.css https://cdnjs.cloudflare.com/ajax/libs/font-awesome/4.7.0/css/font-awesome.min.css
# Unraid webgui pieces (dynamix.js provides $().dropdownchecklist etc.)
wg=https://raw.githubusercontent.com/unraid/webgui/master/emhttp/plugins/dynamix
dl dynamix.js            "$wg/javascript/dynamix.js"
dl default-base.css      "$wg/styles/default-base.css"
dl default-dynamix.css   "$wg/styles/default-dynamix.css"
dl theme-black.css       "$wg/styles/themes/black.css"
mkdir -p "$here/vendor/fonts"
[ -s "$here/vendor/fonts/fontawesome-webfont.woff2" ] || \
  curl -fsSL -o "$here/vendor/fonts/fontawesome-webfont.woff2" \
    https://cdnjs.cloudflare.com/ajax/libs/font-awesome/4.7.0/fonts/fontawesome-webfont.woff2

# --- fake sysfs tree ------------------------------------------------------
fs="$here/fakesys"
rm -rf "$fs"
# Super I/O chip with 3 PWM outputs + tachs (under devices/platform so both
# the find-based scan and the class/hwmon glob see it)
sio="$fs/sys/devices/platform/nct6775.656/hwmon/hwmon2"
mkdir -p "$sio"
echo nct6798 > "$sio/name"
for n in 1 2 3; do
  echo $((100 + n * 30)) > "$sio/pwm$n"
  echo $((600 + n * 250)) > "$sio/fan${n}_input"
done
echo 38000 > "$sio/temp1_input"; echo "SYSTIN" > "$sio/temp1_label"
echo 52000 > "$sio/temp2_input"; echo "CPUTIN" > "$sio/temp2_label"
# CPU temp chip
cpu="$fs/sys/devices/pci0000:00/k10temp/hwmon/hwmon0"
mkdir -p "$cpu"
echo k10temp > "$cpu/name"
echo 54250 > "$cpu/temp1_input"; echo "Tctl" > "$cpu/temp1_label"
echo 51000 > "$cpu/temp2_input"; echo "Tdie" > "$cpu/temp2_label"
# class/hwmon symlinks
mkdir -p "$fs/sys/class/hwmon"
ln -sfn "$cpu" "$fs/sys/class/hwmon/hwmon0"
ln -sfn "$sio" "$fs/sys/class/hwmon/hwmon2"

# --- fake disks (real /dev entries so realpath() works) -------------------
sudo mkdir -p /dev/disk/by-id
for d in sda sdb sdc sdd; do sudo touch "/dev/$d"; done
sudo touch /dev/nvme0n1
mklink() { sudo ln -sfn "$2" "/dev/disk/by-id/$1"; }
mklink ata-WDC_WD80EFAX-68KNBN0_VAG12345 /dev/sda
mklink ata-WDC_WD80EFAX-68KNBN0_VAG67890 /dev/sdb
mklink ata-ST8000VN004-2M2101_WSD34567  /dev/sdc
mklink ata-ST8000VN004-2M2101_WSD89012  /dev/sdd
mklink nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNX0M /dev/nvme0n1

# --- mdcmd stub (maps sdX -> array slots) ---------------------------------
sudo mkdir -p /usr/local/sbin
sudo tee /usr/local/sbin/mdcmd > /dev/null <<'EOF'
#!/bin/bash
cat <<LINES
rdevName.0=sda
rdevName.1=sdb
rdevName.2=sdc
rdevName.3=sdd
LINES
EOF
sudo chmod +x /usr/local/sbin/mdcmd

# --- emhttp docroot symlink + cfg fixtures --------------------------------
sudo mkdir -p /usr/local/emhttp/plugins /boot/config/plugins
sudo ln -sfn "$repo" /usr/local/emhttp/plugins/fanctrlplus
sudo mkdir -p /boot/config/plugins/fanctrlplus
sudo chmod 777 /boot/config/plugins/fanctrlplus
for f in "$here"/fixtures/*.cfg; do
  sed "s|@FAKESYS@|$fs|g" "$f" > "/boot/config/plugins/fanctrlplus/$(basename "$f")"
done

echo "OK. Start the UI with: $here/serve.sh 8080"
