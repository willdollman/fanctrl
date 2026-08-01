<?php
// FanCtrl PlusPlus save handler: saves ONE fan per request.
// All validation happens before anything is written; the cfg is written
// atomically (tmp + rename); other fans' cfg files are never touched.

$plugin  = 'fanctrlplusplus';
$docroot = $docroot ?? ($_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp');
$cfgpath = "/boot/config/plugins/$plugin";

require_once "$docroot/plugins/$plugin/include/OrderManager.php";

header('Content-Type: application/json');

function fail(string $msg): void {
  echo json_encode(['status' => 'error', 'message' => $msg]);
  exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') fail('POST required');

// ---------- read + validate everything ------------------------------------
$file = basename(trim($_POST['file'] ?? ''));
if ($file === '' || !preg_match('/^fanctrlplusplus_[\w.-]+\.cfg$/', $file)) fail('Bad file name');

$custom = trim($_POST['custom'] ?? '');
if (!preg_match('/^[A-Za-z0-9_]+$/', $custom)) {
  fail('Fan name may only contain letters, numbers, and underscores.');
}

$controller = trim($_POST['controller'] ?? '');
if ($controller === '') fail('Select a PWM output.');
if (!preg_match('#^/\S+/pwm\d+$#', $controller)) fail('Invalid PWM output path.');

$int = function (string $key, int $min, int $max, string $label) {
  $v = trim($_POST[$key] ?? '');
  if ($v === '' || !preg_match('/^-?\d+$/', $v)) fail("$label must be a number.");
  $v = intval($v);
  if ($v < $min || $v > $max) fail("$label must be between $min and $max.");
  return $v;
};

$min_pct  = $int('min_pct', 0, 100, 'Min speed');
$max_pct  = $int('max_pct', 0, 100, 'Max speed');
$idle_pct = $int('idle_pct', 0, 100, 'Idle speed');
$cap_pct  = $int('quiet_cap_pct', 0, 100, 'Quiet ceiling');
$interval = $int('interval', 1, 60, 'SMART poll interval');
$service  = ($_POST['service'] ?? '0') === '1' ? '1' : '0';
$quiet    = ($_POST['quiet'] ?? '0') === '1' ? '1' : '0';
$syslog   = ($_POST['syslog'] ?? '0') === '1' ? '1' : '0';

if ($min_pct > $max_pct)  fail('Min speed cannot exceed max speed.');
if ($idle_pct > $min_pct) fail('Idle speed cannot exceed min speed.');
if ($quiet === '1' && ($cap_pct < $min_pct || $cap_pct > $max_pct)) {
  fail('Quiet ceiling must be between min and max speed.');
}

// sources
$types = $_POST['src_type'] ?? [];
$disks = $_POST['src_disks'] ?? [];
$paths = $_POST['src_path'] ?? [];
$lows  = $_POST['src_low'] ?? [];
$highs = $_POST['src_high'] ?? [];
if (!is_array($types)) fail('Bad sources payload.');
if (count($types) > 8) fail('At most 8 temperature sources per fan.');

$sources = [];
foreach (array_values($types) as $i => $type) {
  $low  = trim($lows[$i] ?? '');
  $high = trim($highs[$i] ?? '');
  if (!preg_match('/^\d+$/', $low) || !preg_match('/^\d+$/', $high)) {
    fail('Source temperatures must be numbers.');
  }
  $low = intval($low); $high = intval($high);
  if ($low < 0 || $high > 120 || $low >= $high) {
    fail("Source temperature range $low–$high°C is invalid (low must be below high).");
  }
  if ($type === 'disks') {
    $ids = array_filter(array_map('trim', explode(',', $disks[$i] ?? '')));
    if (empty($ids)) fail('A disk source needs at least one disk selected.');
    foreach ($ids as $id) {
      if (!preg_match('/^[\w.:-]+$/', $id)) fail("Invalid disk id: $id");
    }
    $sources[] = ['type' => 'disks', 'disks' => implode(',', $ids), 'path' => '',
                  'low' => $low, 'high' => $high];
  } elseif ($type === 'temp') {
    $path = trim($paths[$i] ?? '');
    if (!preg_match('#^/\S*temp\d+_input$#', $path)) fail('Invalid sensor path.');
    $sources[] = ['type' => 'temp', 'disks' => '', 'path' => $path,
                  'low' => $low, 'high' => $high];
  } else {
    fail('Unknown source type.');
  }
}

// unique name across the OTHER cfg files
$new_file = "{$plugin}_{$custom}.cfg";
foreach (glob("$cfgpath/{$plugin}_*.cfg") ?: [] as $other) {
  if (basename($other) === $file) continue;
  $ini = @parse_ini_file($other);
  if ($ini && trim($ini['custom'] ?? '') === $custom) {
    fail("A fan named \"$custom\" already exists.");
  }
}
if ($new_file !== $file && is_file("$cfgpath/$new_file")) {
  fail("A config file for \"$custom\" already exists.");
}

// ---------- build content ---------------------------------------------------
$pwm      = (int)round($min_pct  * 255 / 100);
$max_pwm  = (int)round($max_pct  * 255 / 100);
$idle_pwm = (int)round($idle_pct * 255 / 100);
$cap_pwm  = (int)round($cap_pct  * 255 / 100);

// legacy mirror keys (older readers: dashboard tiles, downgrade safety)
$legacy_disks = ''; $legacy_low = '40'; $legacy_high = '60';
$legacy_cpu_en = '0'; $legacy_cpu_sensor = ''; $legacy_cpu_min = ''; $legacy_cpu_max = '';
foreach ($sources as $s) {
  if ($s['type'] === 'disks' && $legacy_disks === '') {
    $legacy_disks = $s['disks']; $legacy_low = (string)$s['low']; $legacy_high = (string)$s['high'];
  }
  if ($s['type'] === 'temp' && $legacy_cpu_sensor === '') {
    $legacy_cpu_en = '1'; $legacy_cpu_sensor = $s['path'];
    $legacy_cpu_min = (string)$s['low']; $legacy_cpu_max = (string)$s['high'];
  }
}

$kv = [
  'custom'       => $custom,
  'label'        => $custom,
  'service'      => $service,
  'controller'   => $controller,
  'pwm'          => (string)$pwm,
  'max'          => (string)$max_pwm,
  'idle'         => (string)$idle_pwm,
  'quiet'        => $quiet,
  'quiet_cap'    => (string)$cap_pwm,
  'interval'     => (string)$interval,
  'syslog'       => $syslog,
  'sources'      => (string)count($sources),
];
foreach ($sources as $i => $s) {
  $n = $i + 1;
  $kv["src{$n}_type"]  = $s['type'];
  $kv["src{$n}_disks"] = $s['disks'];
  $kv["src{$n}_path"]  = $s['path'];
  $kv["src{$n}_low"]   = (string)$s['low'];
  $kv["src{$n}_high"]  = (string)$s['high'];
}
$kv += [
  'disks'        => $legacy_disks,
  'low'          => $legacy_low,
  'high'         => $legacy_high,
  'cpu_enable'   => $legacy_cpu_en,
  'cpu_sensor'   => $legacy_cpu_sensor,
  'cpu_min_temp' => $legacy_cpu_min,
  'cpu_max_temp' => $legacy_cpu_max,
];

$content = '';
foreach ($kv as $k => $v) {
  $content .= $k . '="' . str_replace('"', '', $v) . "\"\n";
}

// ---------- write (atomic), then rename bookkeeping ------------------------
if (!is_file("$cfgpath/$file")) fail('Original config file not found; reload the page.');

$tmp = "$cfgpath/.$new_file.tmp";
if (file_put_contents($tmp, $content, LOCK_EX) === false) fail('Failed to write config.');
if (!rename($tmp, "$cfgpath/$new_file")) { @unlink($tmp); fail('Failed to write config.'); }

if ($new_file !== $file) {
  @unlink("$cfgpath/$file");
  OrderManager::replaceFileName($file, $new_file);
}

// restart the control daemon so changes take effect
$rc = '/etc/rc.d/rc.fanctrlplusplus';
if (is_executable($rc)) {
  exec("nohup $rc restart >/dev/null 2>&1 &");
}

echo json_encode(['status' => 'ok', 'file' => $new_file]);
