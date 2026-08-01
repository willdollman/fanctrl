<?php
error_reporting(E_ALL);
ini_set('display_errors', 1);

$plugin  = 'fanctrlplusplus';
$docroot = $docroot ?? $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
$cfg_dir = "/boot/config/plugins/$plugin";
$order_file = "$cfg_dir/order.cfg";
$label_file = "$cfg_dir/pwm_labels.cfg";

require_once "$docroot/plugins/$plugin/include/Common.php";
require_once "/usr/local/emhttp/plugins/fanctrlplusplus/include/OrderManager.php";

header('Content-Type: application/json');

$op = $_GET['op'] ?? $_POST['op'] ?? '';

if ($op === 'refresh_single' && !empty($_GET['custom'])) {
  $custom = escapeshellarg($_GET['custom']);
  shell_exec("/usr/local/emhttp/plugins/fanctrlplusplus/scripts/fanctrlplusplus_refresh_single.sh $custom > /dev/null 2>&1 &");
  exit('OK');
}

function json_response($data) {
  while (ob_get_level()) {
    ob_end_clean(); // 安全清除所有输出缓冲区，避免 notice 错误
  }
  header('Content-Type: application/json');
  echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
  exit;
}

function scan_dir($dir) {
  $out = [];
  foreach (array_diff(scandir($dir), ['.','..']) as $f) {
    $out[] = realpath($dir) . '/' . $f;
  }
  return $out;
}

function valid_history_name($custom) {
  return is_string($custom) && preg_match('/^[A-Za-z0-9_]+$/', $custom);
}

function read_fan_history($custom) {
  $samples = [];
  if (!valid_history_name($custom)) return $samples;
  $path = "/var/tmp/fanctrlplusplus/history_fanctrlplusplus_{$custom}.csv";
  $fh = @fopen($path, 'r');
  if (!$fh) return $samples;
  $cutoff = time() - 3600;
  while (($row = fgetcsv($fh, 0, ',', '"', '')) !== false) {
    if (count($row) !== 6 || !preg_match('/^\d+$/', $row[0])) continue;
    if ((int)$row[0] < $cutoff) continue;
    $malformed = false;
    foreach ([1, 3, 4, 5] as $index) {
      if ($row[$index] !== '' && !is_numeric($row[$index])) $malformed = true;
    }
    if ($malformed) continue;
    $number = function ($value, $integer = false) {
      if ($value === '' || !is_numeric($value)) return null;
      return $integer ? (int)$value : (float)$value;
    };
    $samples[] = [
      'timestamp' => (int)$row[0], 'temp_c' => $number($row[1]), 'source' => (string)$row[2],
      'pwm' => $number($row[3], true), 'pwm_percent' => $number($row[4], true),
      'rpm' => $number($row[5], true),
    ];
  }
  fclose($fh);
  return $samples;
}

const MANUAL_STATE = '/var/tmp/fanctrlplusplus/manual_override';
const MANUAL_LOCK = '/var/run/fanctrlplusplus_manual.lock';

function manual_recovery_read() {
  $lines = @file(MANUAL_STATE, FILE_IGNORE_NEW_LINES);
  if ($lines === false || count($lines) !== 6) return null;
  [$controller, $pwm, $percent, $originalPwm, $originalEnable, $expires] = $lines;
  if (!preg_match('#^/[^\s]*/pwm[0-9]+$#', $controller)) return null;
  if (!preg_match('/^[0-9]+$/', $originalPwm) || (int)$originalPwm > 255) return null;
  if ($originalEnable !== '-' && (!preg_match('/^[0-9]+$/', $originalEnable) || (int)$originalEnable > 255)) return null;
  return ['controller' => $controller, 'pwm_raw' => $pwm, 'percent_raw' => $percent,
    'original_pwm' => (int)$originalPwm,
    'original_enable' => $originalEnable === '-' ? '-' : (int)$originalEnable,
    'expires_raw' => $expires];
}

function manual_state_read() {
  $state = manual_recovery_read();
  if (!$state || !preg_match('/^[0-9]+$/', $state['pwm_raw']) || (int)$state['pwm_raw'] > 255 ||
      !preg_match('/^[0-9]+$/', $state['percent_raw']) || (int)$state['percent_raw'] < 10 || (int)$state['percent_raw'] > 100 ||
      !preg_match('/^[0-9]+$/', $state['expires_raw'])) return null;
  $state['pwm'] = (int)$state['pwm_raw']; $state['percent'] = (int)$state['percent_raw'];
  $state['expires_at'] = (int)$state['expires_raw'];
  unset($state['pwm_raw'], $state['percent_raw'], $state['expires_raw']);
  return $state;
}

function manual_restore($state = null) {
  if (!file_exists(MANUAL_STATE)) return [true, null];
  $state = $state ?? manual_recovery_read();
  if (!$state) return [false, 'Manual test state is corrupt and cannot be safely restored; state was retained'];
  $enable = $state['controller'] . '_enable';
  if (!is_writable($state['controller']) || ($state['original_enable'] !== '-' && !is_writable($enable)))
    return [false, 'Original PWM settings could not be restored because the controller is not writable; state was retained'];
  if (@file_put_contents($state['controller'], $state['original_pwm'] . "\n") === false ||
      ($state['original_enable'] !== '-' && @file_put_contents($enable, $state['original_enable'] . "\n") === false))
    return [false, 'Writing the original PWM settings failed; state was retained'];
  if (!@unlink(MANUAL_STATE)) return [false, 'Original PWM was restored but the manual state could not be removed; retry stop'];
  return [true, null];
}

function manual_write_state($state) {
  $dir = dirname(MANUAL_STATE);
  if (!is_dir($dir)) @mkdir($dir, 0755, true);
  $tmp = MANUAL_STATE . '.tmp.' . getmypid();
  $body = implode("\n", [$state['controller'], $state['pwm'], $state['percent'],
    $state['original_pwm'], $state['original_enable'], $state['expires_at']]) . "\n";
  if (@file_put_contents($tmp, $body, LOCK_EX) === false || !@rename($tmp, MANUAL_STATE)) {
    @unlink($tmp);
    return false;
  }
  return true;
}

function manual_status($state) {
  return $state ? ['status' => 'ok', 'active' => true, 'controller' => $state['controller'],
    'percent' => $state['percent'], 'expires_at' => $state['expires_at']]
    : ['status' => 'ok', 'active' => false];
}

function manual_error($message, $state = null) {
  $response = ['status' => 'error', 'active' => file_exists(MANUAL_STATE), 'message' => $message];
  if ($state && isset($state['percent'], $state['expires_at'])) {
    $response += ['controller' => $state['controller'], 'percent' => $state['percent'], 'expires_at' => $state['expires_at']];
  }
  return $response;
}

function manual_lock() {
  $lock = @fopen(MANUAL_LOCK, 'c');
  if (!$lock || !flock($lock, LOCK_EX)) json_response(['status' => 'error', 'message' => 'Could not lock manual test']);
  return $lock;
}

$op = $_GET['op'] ?? $_POST['op'] ?? '';

switch ($op) {
  case 'history':
    $custom = $_GET['custom'] ?? '';
    if (!valid_history_name($custom)) json_response(['status' => 'error', 'message' => 'Invalid fan name']);
    json_response(['fan' => $custom, 'samples' => read_fan_history($custom)]);
    break;

  case 'export_history':
    $custom = $_GET['custom'] ?? '';
    if (!valid_history_name($custom)) json_response(['status' => 'error', 'message' => 'Invalid fan name']);
    while (ob_get_level()) ob_end_clean();
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . $custom . '-fan-history.csv"');
    $out = fopen('php://output', 'w');
    fputcsv($out, ['timestamp', 'temp_c', 'source', 'pwm', 'pwm_percent', 'rpm'], ',', '"', '');
    foreach (read_fan_history($custom) as $sample) {
      fputcsv($out, [date('c', $sample['timestamp']), $sample['temp_c'], $sample['source'],
        $sample['pwm'], $sample['pwm_percent'], $sample['rpm']], ',', '"', '');
    }
    fclose($out);
    exit;

  case 'manual_status':
    $lock = manual_lock();
    $state = manual_state_read();
    if (file_exists(MANUAL_STATE) && (!$state || $state['expires_at'] <= time())) {
      [$ok, $error] = manual_restore($state ?: manual_recovery_read());
      $state = manual_state_read();
      if (!$ok) { flock($lock, LOCK_UN); fclose($lock); json_response(manual_error($error, $state)); }
    }
    $response = manual_status(manual_state_read());
    flock($lock, LOCK_UN); fclose($lock); json_response($response);
    break;

  case 'manual_stop':
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') json_response(['status' => 'error', 'active' => file_exists(MANUAL_STATE), 'message' => 'POST required']);
    $lock = manual_lock();
    $strict = manual_state_read();
    [$ok, $error] = manual_restore($strict ?: manual_recovery_read());
    $remaining = manual_state_read();
    flock($lock, LOCK_UN); fclose($lock);
    if (!$ok) json_response(manual_error($error, $remaining ?: $strict));
    json_response(manual_status(null));
    break;

  case 'manual_start':
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') json_response(['status' => 'error', 'active' => file_exists(MANUAL_STATE), 'message' => 'POST required']);
    $percentRaw = $_POST['percent'] ?? '';
    $controller = $_POST['controller'] ?? '';
    if (!is_string($percentRaw) || !preg_match('/^(?:[1-9][0-9]|100)$/', $percentRaw) || (int)$percentRaw < 10)
      json_response(['status' => 'error', 'message' => 'Speed must be an integer from 10 to 100']);
    $available = array_column(list_pwm(), 'sensor');
    if (!is_string($controller) || !in_array($controller, $available, true))
      json_response(['status' => 'error', 'message' => 'Invalid PWM controller']);
    $lock = manual_lock();
    $old = manual_state_read();
    if (file_exists(MANUAL_STATE) && (!$old || $old['expires_at'] <= time() || $old['controller'] !== $controller)) {
      [$ok, $error] = manual_restore($old ?: manual_recovery_read());
      if (!$ok) { $remaining = manual_state_read(); flock($lock, LOCK_UN); fclose($lock); json_response(manual_error($error, $remaining ?: $old)); }
      $old = null;
    }
    $enable = $controller . '_enable';
    if (!is_writable($controller) || (file_exists($enable) && !is_writable($enable))) {
      flock($lock, LOCK_UN); fclose($lock);
      json_response(['status' => 'error', 'message' => 'PWM controller is not writable']);
    }
    $originalPwm = $old ? $old['original_pwm'] : trim((string)@file_get_contents($controller));
    $originalEnable = $old ? $old['original_enable'] : (file_exists($enable) ? trim((string)@file_get_contents($enable)) : '-');
    if (!preg_match('/^[0-9]+$/', (string)$originalPwm) || (int)$originalPwm > 255 ||
        ($originalEnable !== '-' && (!preg_match('/^[0-9]+$/', (string)$originalEnable) || (int)$originalEnable > 255))) {
      flock($lock, LOCK_UN); fclose($lock);
      json_response(['status' => 'error', 'message' => 'PWM controller returned invalid values']);
    }
    $percent = (int)$percentRaw;
    $state = ['controller' => $controller, 'pwm' => (int)round($percent * 255 / 100), 'percent' => $percent,
      'original_pwm' => (int)$originalPwm, 'original_enable' => $originalEnable === '-' ? '-' : (int)$originalEnable, 'expires_at' => time() + 600];
    if (!manual_write_state($state)) {
      [$restored, $restoreError] = manual_restore($old ?: $state);
      flock($lock, LOCK_UN); fclose($lock);
      if (!$restored) json_response(manual_error('Could not save manual test state and restoration also failed: ' . $restoreError, manual_state_read() ?: ($old ?: $state)));
      json_response(['status' => 'error', 'active' => false, 'message' => 'Could not save manual test state; original settings were restored']);
    }
    if ((file_exists($enable) && @file_put_contents($enable, "1\n") === false) || @file_put_contents($controller, $state['pwm'] . "\n") === false) {
      [$restored, $restoreError] = manual_restore($state);
      flock($lock, LOCK_UN); fclose($lock);
      if (!$restored) json_response(manual_error('Could not apply manual PWM and restoration also failed: ' . $restoreError, manual_state_read() ?: $state));
      json_response(['status' => 'error', 'active' => false, 'message' => 'Could not write PWM controller; original settings were restored']);
    }
    flock($lock, LOCK_UN); fclose($lock);
    json_response(manual_status($state));
    break;

  case 'savelabel':
    $pwm = $_POST['pwm'] ?? '';
    $label = $_POST['label'] ?? '';

    $label_file = "/boot/config/plugins/fanctrlplusplus/pwm_labels.cfg";
    // 读取现有label
    $lines = is_file($label_file) ? file($label_file, FILE_IGNORE_NEW_LINES) : [];
    $found = false;

    if (!$pwm) {
      json_response(['status' => 'error', 'message' => 'Missing pwm']);
      break;
    }

    // 空label表示删除
    if ($label === '') {
      $new_lines = [];
      foreach ($lines as $line) {
        if (strpos($line, "$pwm=") !== 0) $new_lines[] = $line;
      }
      file_put_contents($label_file, implode("\n", $new_lines) . "\n");
      json_response(['status' => 'ok', 'message' => 'Label removed']);
      break;
    }

    // 正常写入label
    foreach ($lines as &$line) {
      if (strpos($line, "$pwm=") === 0) {
        $line = "$pwm=$label";
        $found = true;
        break;
      }
    }
    if (!$found) $lines[] = "$pwm=$label";
    file_put_contents($label_file, implode("\n", $lines) . "\n");
    json_response(['status' => 'ok', 'message' => 'Label saved']);
    break;
  
  case 'newtemp':
    $cfg_dir = "/boot/config/plugins/$plugin";

    // 找 temp_X.cfg 文件名，不重复
    $index_cfg = 0;
    while (file_exists("$cfg_dir/{$plugin}_temp_$index_cfg.cfg")) {
      $index_cfg++;
    }

    $temp_file = "$cfg_dir/{$plugin}_temp_$index_cfg.cfg";
    file_put_contents($temp_file, <<<INI
    custom=""
    service="1"
    controller=""
    pwm="102"
    max="255"
    idle="0"
    quiet="0"
    quiet_cap="150"
    interval="2"
    syslog="1"
    sources="0"
    disks=""
    low="40"
    high="60"
    cpu_enable="0"
    cpu_sensor=""
    cpu_min_temp=""
    cpu_max_temp=""
    INI
    );

    require_once "$docroot/plugins/$plugin/include/FanBlockRender.php";
    $cfg = parse_ini_file($temp_file);
    $cfg['file'] = basename($temp_file);

    $pwms = list_pwm();
    $disk_groups = list_valid_disks_by_id();
    $temp_sensors = list_temp_sensors();

    header('Content-Type: text/html; charset=utf-8');
    echo render_fan_card($cfg, $pwms, $disk_groups, $temp_sensors, $pwm_labels);
    exit;

  case 'setsyslog':
      $cfg_file = basename($_POST['cfg']);
      $enabled = isset($_POST['enabled']) && $_POST['enabled'] == 1 ? 1 : 0;

      $cfg_dir = "/boot/config/plugins/fanctrlplusplus";
      $cfg_path = "$cfg_dir/$cfg_file";

      if (file_exists($cfg_path)) {
          $lines = file($cfg_path, FILE_IGNORE_NEW_LINES);
          $found = false;
          foreach ($lines as &$line) {
              if (strpos($line, 'syslog=') === 0) {
                  $line = 'syslog="' . $enabled . '"';
                  $found = true;
              }
          }
          if (!$found) {
              $lines[] = 'syslog="' . $enabled . '"';
          }
          file_put_contents($cfg_path, implode("\n", $lines) . "\n");
          echo json_encode(['status' => 'ok']);
      } else {
          echo json_encode(['status' => 'error', 'msg' => 'Config file not found']);
      }
      exit;

  case 'delete':
    $file = basename($_POST['file'] ?? '');
    $cfgpath = "/boot/config/plugins/$plugin/$file";

    if (is_file($cfgpath)) {
      $old_cfg = @parse_ini_file($cfgpath);
      $old_custom = is_array($old_cfg) ? trim($old_cfg['custom'] ?? '') : '';
      $rc = '/etc/rc.d/rc.fanctrlplusplus';
      if (is_executable($rc)) {
        $output = []; $status = 0;
        exec(escapeshellarg($rc) . ' stop 2>&1', $output, $status);
        if ($status !== 0) json_response(['status' => 'error', 'message' => 'Could not safely stop fan control; manual PWM restoration failed. Nothing was deleted.']);
      }
      unlink($cfgpath);
      OrderManager::remove($file);
      if (valid_history_name($old_custom)) {
        foreach (['history', 'temp', 'rpm', 'pwm', 'status'] as $kind) {
          @unlink("/var/tmp/$plugin/{$kind}_{$plugin}_{$old_custom}" . ($kind === 'history' ? '.csv' : ''));
        }
        @unlink("/var/tmp/$plugin/.history_compact_{$old_custom}");
      }
      if (is_executable($rc)) exec(escapeshellarg($rc) . ' start');
    } else {
      OrderManager::remove($file);
    }

    json_response(['status' => 'ok', 'message' => "Deleted $file"]);
    break;

  case 'status':
    $pid_files = glob("/var/run/fanctrlplusplus_*.pid");
    $running = false;
    foreach ($pid_files as $pidfile) {
      $pid = trim(@file_get_contents($pidfile));
      if (is_numeric($pid) && posix_kill((int)$pid, 0)) {
        $running = true;
        break;
      }
    }
  
    json_response(['status' => $running ? 'running' : 'stopped']);
    break;

  case 'status_all':
    $cfg_dir = "/boot/config/plugins/$plugin";
    $result = [];

    foreach (glob("$cfg_dir/{$plugin}_*.cfg") as $file) {
      $cfg = parse_ini_file($file);
      $name = trim($cfg['custom'] ?? '');
      $enabled = trim($cfg['service'] ?? '0') === '1';

      // 保持和 rc.fanctrlplusplus 的一致性（自定义名 → pid 文件名）
      $name_trimmed = trim($name);
      $custom_safe = preg_replace('/\W+/', '_', $name_trimmed);
      $pid_file = "/var/run/{$plugin}_{$custom_safe}.pid";
      $running = false;

      if ($enabled && file_exists($pid_file)) {
        $pid = trim(@file_get_contents($pid_file));
        if (is_numeric($pid) && posix_kill((int)$pid, 0)) {
          $running = true;
        }
      }

      if ($name !== '') {
        $result[basename($file)] = $running ? 'running' : 'stopped';
      }
    }
  
    json_response($result);
    break;

  case 'saveorder':
    error_log("[fanctrlplusplus] 🔥 saveorder triggered");

    $order_raw = $_POST['order'] ?? [];

    if (!is_array($order_raw)) {
      error_log("[fanctrlplusplus] ⚠️ order is not array: " . print_r($order_raw, true));
      json_response(['status' => 'error', 'message' => 'Order not array']);
    }

    $output = "";

    foreach (['left', 'right'] as $side) {
      if (!isset($order_raw[$side]) || !is_array($order_raw[$side])) continue;

      $valid = array_values(array_filter($order_raw[$side], function ($f) use ($cfg_dir) {
        return is_string($f) && trim($f) !== '' && is_file("$cfg_dir/$f");
      }));

      foreach ($valid as $i => $file) {
        $output .= "{$side}{$i}=\"$file\"\n";
      }
    }

    if ($output !== "") {
      file_put_contents("$cfg_dir/order.cfg", $output);
      json_response(['status' => 'ok']);
    } else {
      error_log("[fanctrlplusplus] ❌ Blocked invalid saveorder: " . print_r($order_raw, true));
      json_response(['status' => 'error', 'message' => 'Invalid order']);
    }
    break;
    
  case 'start':
    shell_exec("/etc/rc.d/rc.fanctrlplusplus start");
    json_response(['status' => 'started']);
    break;
  
  case 'stop':
    $output = []; $status = 0;
    exec('/etc/rc.d/rc.fanctrlplusplus stop 2>&1', $output, $status);
    if ($status !== 0) {
      json_response(['status' => 'error', 'message' => 'Could not stop fan control because manual PWM restoration failed']);
    }
    json_response(['status' => 'stopped']);
    break;

  case 'getpwm':
    $pwms = list_pwm();
    $label_file = "/boot/config/plugins/fanctrlplusplus/pwm_labels.cfg";
    $labels = [];
    if (is_file($label_file)) {
      foreach (file($label_file, FILE_IGNORE_NEW_LINES) as $line) {
        if (preg_match('/^(.+?)=(.+)$/', $line, $m)) {
          $labels[$m[1]] = $m[2];
        }
      }
    }
    foreach ($pwms as &$pwm) {
      $pwm['label'] = $labels[$pwm['sensor']] ?? '';
    }
    json_response($pwms);
    break;

  case 'read_temp_rpm':
    $custom = $_GET['custom'] ?? '';
    $custom = basename($custom); // 安全过滤

    $plugin = 'fanctrlplusplus';
    $temp_file = "/var/tmp/{$plugin}/temp_{$plugin}_{$custom}";
    $rpm_file  = "/var/tmp/{$plugin}/rpm_{$plugin}_{$custom}";

    $temp = is_file($temp_file) ? trim(file_get_contents($temp_file)) : '*';
    $rpm  = is_file($rpm_file)  ? trim(file_get_contents($rpm_file))  : '?';

    echo "$temp|$rpm";  // 示例："48 (CPU)|1150"
    exit;

  case 'fcp_airflow_toggle':
    
      $cfg_dir     = "/boot/config/plugins/fanctrlplusplus";
      $labels_file = $cfg_dir.'/pwm_labels.cfg';

      $enabled = (($_POST['enabled'] ?? '0') === '1');
      $lines   = is_file($labels_file) ? file($labels_file, FILE_IGNORE_NEW_LINES) : [];
      $found   = false;

      foreach ($lines as &$ln) {
          $t = trim($ln);
          if ($t === '' || $t[0] === '#') continue;
          if (preg_match('/^__FCP_AIRFLOW__\s*=/', $t)) {
              $ln = "__FCP_AIRFLOW__=" . ($enabled ? '1' : '0');
              $found = true;
              break;
          }
      }
      unset($ln);

      if (!$found) $lines[] = "__FCP_AIRFLOW__=" . ($enabled ? '1' : '0');

      @mkdir($cfg_dir, 0777, true);
      file_put_contents($labels_file, implode("\n", $lines) . "\n");

      header('Content-Type: application/json; charset=utf-8');
      echo json_encode(['ok'=>1, 'enabled'=>$enabled ? 1 : 0]);
      exit;
}
?>
