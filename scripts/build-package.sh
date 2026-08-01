#!/bin/bash
set -euo pipefail

[[ $# -ge 1 && $# -le 2 ]] || { echo "Usage: $0 VERSION [OUTPUT_DIR]" >&2; exit 2; }
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be semantic version X.Y.Z" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
out=${2:-$root/dist}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
dest="$stage/usr/local/emhttp/plugins/fanctrlplusplus"
mkdir -p "$dest" "$stage/install" "$out"

for path in css fonts icons images include js FanctrlPlusPlusDashboard.php FanctrlPlusPlus.Dashboard.page FcpAirflow.Dashboard.page fanctrlplusplus.page; do
  cp -a "$root/$path" "$dest/"
done
mkdir "$dest/scripts"
for script in array_monitor.sh fanctrl_algo.sh fanctrl_sensors.sh fanctrlplusplus_dashboard_update.sh fanctrlplusplus_loop.sh fanctrlplusplus_refresh_single.sh rc.fanctrlplusplus; do
  cp -a "$root/scripts/$script" "$dest/scripts/"
done
printf '%s\n' "$version" > "$dest/VERSION"
cat > "$stage/install/doinst.sh" <<'EOF'
#!/bin/bash
src=/usr/local/emhttp/plugins/fanctrlplusplus/scripts/rc.fanctrlplusplus
dst=/etc/rc.d/rc.fanctrlplusplus
ln -sf "$src" "$dst"
mkdir -p /boot/config/plugins/fanctrlplusplus /var/tmp/fanctrlplusplus
rm -f /var/tmp/fanctrlplusplus/*
"$dst" restart
EOF
chmod 755 "$stage/install/doinst.sh"
find "$stage" -print0 | xargs -0 touch -h -d '@0'
archive="$out/fanctrlplusplus-$version.txz"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$stage" -cJf "$archive" install usr
echo "$archive"
