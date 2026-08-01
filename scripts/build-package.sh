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
for script in array_monitor.sh fanctrl_algo.sh fanctrl_sensors.sh fanctrl_manual_override.sh fanctrlplusplus_dashboard_update.sh fanctrlplusplus_loop.sh fanctrlplusplus_refresh_single.sh rc.fanctrlplusplus; do
  cp -a "$root/scripts/$script" "$dest/scripts/"
done
printf '%s\n' "$version" > "$dest/VERSION"
cat > "$stage/install/doinst.sh" <<'EOF'
#!/bin/bash
src=/usr/local/emhttp/plugins/fanctrlplusplus/scripts/rc.fanctrlplusplus
dst=/etc/rc.d/rc.fanctrlplusplus
ln -sf "$src" "$dst"
mkdir -p /boot/config/plugins/fanctrlplusplus /var/tmp/fanctrlplusplus
if ! "$dst" stop; then
  echo "Cannot install: manual PWM restoration failed; existing state retained." >&2
  exit 1
fi
monitor=/usr/local/emhttp/plugins/fanctrlplusplus/scripts/array_monitor.sh
pkill -f "$monitor" 2>/dev/null || true
for _ in {1..20}; do
  pgrep -f "$monitor" >/dev/null || break
  sleep 0.1
done
if pgrep -f "$monitor" >/dev/null; then
  echo "Cannot install: previous array monitor did not stop." >&2
  exit 1
fi
find /var/tmp/fanctrlplusplus -mindepth 1 -maxdepth 1 -delete
"$dst" start
EOF
chmod 755 "$stage/install/doinst.sh"
find "$stage" -print0 | xargs -0 touch -h -d '@0'
archive="$out/fanctrlplusplus-$version.txz"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$stage" -cJf "$archive" install usr
echo "$archive"
