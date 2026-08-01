<?php
// Card renderer for the FanCtrl Plus v2 UI.
// Each card is self-contained: it saves independently (no shared form),
// so fields are identified by class, not by indexed names.

$label_file = "/boot/config/plugins/fanctrlplus/pwm_labels.cfg";
$pwm_labels = [];
if (is_file($label_file)) {
  foreach (file($label_file, FILE_IGNORE_NEW_LINES) as $line) {
    if (preg_match('/^(.+?)=(.+)$/', $line, $m)) {
      $pwm_labels[$m[1]] = $m[2];
    }
  }
}

// Normalize a cfg into a list of sources:
//   [ ['type'=>'disks','disks'=>'id1,id2','low'=>38,'high'=>48],
//     ['type'=>'temp','path'=>'/sys/...','low'=>45,'high'=>80], ... ]
// Falls back to legacy keys (disks/low/high + cpu_*) when `sources` is absent.
function fcp_cfg_sources(array $cfg): array {
  $n = intval($cfg['sources'] ?? -1);
  if (($cfg['sources'] ?? '') !== '' && $n >= 0) {
    $out = [];
    for ($i = 1; $i <= min($n, 8); $i++) {
      $type = $cfg["src{$i}_type"] ?? '';
      if ($type !== 'disks' && $type !== 'temp') continue;
      $out[] = [
        'type'  => $type,
        'disks' => $cfg["src{$i}_disks"] ?? '',
        'path'  => $cfg["src{$i}_path"] ?? '',
        'low'   => intval($cfg["src{$i}_low"] ?? 40),
        'high'  => intval($cfg["src{$i}_high"] ?? 60),
      ];
    }
    return $out;
  }
  // legacy synthesis (matches scripts/fanctrl_sensors.sh configure_sources)
  $out = [];
  if (trim($cfg['disks'] ?? '') !== '') {
    $out[] = ['type' => 'disks', 'disks' => $cfg['disks'], 'path' => '',
              'low' => intval($cfg['low'] ?? 40), 'high' => intval($cfg['high'] ?? 60)];
  }
  if (($cfg['cpu_enable'] ?? '0') === '1' && trim($cfg['cpu_sensor'] ?? '') !== '') {
    $lo = is_numeric($cfg['cpu_min_temp'] ?? '') ? intval($cfg['cpu_min_temp']) : 40;
    $hi = is_numeric($cfg['cpu_max_temp'] ?? '') ? intval($cfg['cpu_max_temp']) : 70;
    $out[] = ['type' => 'temp', 'disks' => '', 'path' => $cfg['cpu_sensor'],
              'low' => $lo, 'high' => $hi];
  }
  return $out;
}

function fcp_render_disk_menu(array $disk_groups, array $selected): string {
  ob_start(); ?>
  <div class="fcp2-diskmenu">
    <?php foreach ($disk_groups as $group => $entries): ?>
      <div class="grp"><?= htmlspecialchars($group) ?></div>
      <?php foreach ($entries as $d): ?>
        <label title="<?= htmlspecialchars($d['title']) ?>">
          <input type="checkbox" class="f-src-disk" value="<?= htmlspecialchars($d['id']) ?>"
                 <?= in_array($d['id'], $selected, true) ? 'checked' : '' ?>>
          <span><?= htmlspecialchars($d['label']) ?></span>
        </label>
      <?php endforeach; ?>
    <?php endforeach; ?>
    <?php if (empty($disk_groups)): ?><div class="grp">No disks found</div><?php endif; ?>
  </div>
  <?php return ob_get_clean();
}

function fcp_render_source(array $src, array $disk_groups, array $temp_sensors): string {
  $low = $src['low']; $high = $src['high'];
  ob_start();
  if ($src['type'] === 'disks'):
    $selected = array_filter(array_map('trim', explode(',', $src['disks'])));
    $count = count($selected); ?>
  <div class="fcp2-src" data-type="disks">
    <div class="fcp2-srchead">
      <span class="fcp2-srckind disks">Disks</span>
      <details class="fcp2-disksel sel">
        <summary class="f-disk-summary"><?= $count ?> disk<?= $count == 1 ? '' : 's' ?> selected</summary>
        <?= fcp_render_disk_menu($disk_groups, $selected) ?>
      </details>
      <button type="button" class="rm" title="Remove source">×</button>
    </div>
    <div class="fcp2-srcrange">
      <span class="lbl">Min speed at</span>
      <span class="fcp2-num"><input type="number" class="f-src-low" value="<?= $low ?>" min="0" max="99" required><span class="unit">°C</span></span>
      <span class="arrow">→ max at</span>
      <span class="fcp2-num"><input type="number" class="f-src-high" value="<?= $high ?>" min="1" max="100" required><span class="unit">°C</span></span>
    </div>
  </div>
  <?php else: ?>
  <div class="fcp2-src" data-type="temp">
    <div class="fcp2-srchead">
      <span class="fcp2-srckind temp">Sensor</span>
      <select class="f-src-path sel">
        <?php if ($src['path'] !== '' && !isset($temp_sensors[$src['path']])): ?>
          <option value="<?= htmlspecialchars($src['path']) ?>" selected>
            <?= htmlspecialchars($src['path']) ?> (not found)
          </option>
        <?php endif; ?>
        <?php foreach ($temp_sensors as $path => $label): ?>
          <option value="<?= htmlspecialchars($path) ?>" <?= $src['path'] === $path ? 'selected' : '' ?>>
            <?= htmlspecialchars($label) ?>
          </option>
        <?php endforeach; ?>
      </select>
      <button type="button" class="rm" title="Remove source">×</button>
    </div>
    <div class="fcp2-srcrange">
      <span class="lbl">Min speed at</span>
      <span class="fcp2-num"><input type="number" class="f-src-low" value="<?= $low ?>" min="0" max="119" required><span class="unit">°C</span></span>
      <span class="arrow">→ max at</span>
      <span class="fcp2-num"><input type="number" class="f-src-high" value="<?= $high ?>" min="1" max="120" required><span class="unit">°C</span></span>
    </div>
  </div>
  <?php endif;
  return ob_get_clean();
}

function render_fan_card(array $cfg, array $pwms, array $disk_groups,
                         array $temp_sensors, array $pwm_labels): string {
  $file    = $cfg['file'];
  $name    = $cfg['custom'] ?? '';
  $enabled = ($cfg['service'] ?? '0') === '1';
  $minPct  = (int)round(intval($cfg['pwm'] ?? 102) * 100 / 255);
  $maxPct  = (int)round(intval($cfg['max'] ?? 255) * 100 / 255);
  $idlePct = (int)round(intval($cfg['idle'] ?? 0) * 100 / 255);
  $quiet   = ($cfg['quiet'] ?? '0') === '1';
  $capPct  = (int)round(intval($cfg['quiet_cap'] ?? 150) * 100 / 255);
  $interval = max(1, intval($cfg['interval'] ?? 2));
  $syslog  = ($cfg['syslog'] ?? '1') === '1';
  $sources = fcp_cfg_sources($cfg);

  ob_start(); ?>
<div class="fcp2-card <?= $enabled ? '' : 'is-disabled' ?>" data-file="<?= htmlspecialchars($file) ?>">
  <div class="fcp2-cardhead">
    <div class="fcp2-namewrap">
      <input type="text" class="fcp2-name f-custom" value="<?= htmlspecialchars($name) ?>"
             placeholder="Fan name (e.g. HDD_Bay)" pattern="[A-Za-z0-9_]+" required
             title="Letters, numbers and underscores only">
      <div class="fcp2-outrow">
        <select class="f-controller" required>
          <option value="">— Select PWM output —</option>
          <?php foreach ($pwms as $pwm):
            $display = $pwm['chip'] . ' · ' . $pwm['name'];
            $lbl = $pwm_labels[$pwm['sensor']] ?? '';
            if ($lbl) $display .= " — " . $lbl; ?>
            <option value="<?= htmlspecialchars($pwm['sensor']) ?>"
              <?= ($cfg['controller'] ?? '') === $pwm['sensor'] ? 'selected' : '' ?>>
              <?= htmlspecialchars($display) ?>
            </option>
          <?php endforeach; ?>
        </select>
      </div>
    </div>
    <div class="fcp2-live">
      <div class="rpm"><span class="f-live-rpm">–</span> <small>RPM</small></div>
      <div class="now f-live-now">–</div>
    </div>
    <label class="tgl" title="Enable or disable this fan controller">
      <input type="checkbox" class="f-service" <?= $enabled ? 'checked' : '' ?>>
      <span class="tr"></span>
    </label>
  </div>

  <div class="fcp2-cardbody">
    <div class="fcp2-sect">
      <div class="fcp2-secthead">Response curve <span class="spacer"></span>
        <span class="f-curve-legend" style="font-weight:400;text-transform:none;letter-spacing:0"></span>
      </div>
      <svg class="fcp2-curve f-curve" viewBox="0 0 420 130" preserveAspectRatio="xMidYMid meet"></svg>
    </div>

    <div class="fcp2-sect">
      <div class="fcp2-secthead">Temperature sources</div>
      <div class="f-sources">
        <?php foreach ($sources as $src) echo fcp_render_source($src, $disk_groups, $temp_sensors); ?>
      </div>
      <div class="fcp2-addsrc">
        <button type="button" class="btn f-add-disks">+ Disks</button>
        <button type="button" class="btn f-add-temp">+ Sensor</button>
      </div>
      <p class="fcp2-help">Each source maps its temperature range onto the fan speed range below.
        The fan follows whichever source demands the most.</p>
    </div>

    <div class="fcp2-sect">
      <div class="fcp2-secthead">Fan speed</div>
      <div class="fcp2-sliderrow"><label>Min</label>
        <input type="range" class="f-min-r" min="0" max="100" value="<?= $minPct ?>">
        <span class="fcp2-num"><input type="number" class="f-min" min="0" max="100" value="<?= $minPct ?>" required><span class="unit">%</span></span>
      </div>
      <div class="fcp2-sliderrow"><label>Max</label>
        <input type="range" class="f-max-r" min="0" max="100" value="<?= $maxPct ?>">
        <span class="fcp2-num"><input type="number" class="f-max" min="0" max="100" value="<?= $maxPct ?>" required><span class="unit">%</span></span>
      </div>
      <div class="fcp2-sliderrow" title="Speed when no temperature source has data (e.g. all disks spun down)">
        <label>Idle</label>
        <input type="range" class="f-idle-r" min="0" max="100" value="<?= $idlePct ?>">
        <span class="fcp2-num"><input type="number" class="f-idle" min="0" max="100" value="<?= $idlePct ?>" required><span class="unit">%</span></span>
      </div>
    </div>

    <div class="fcp2-sect">
      <div class="fcp2-secthead">Quiet mode <span class="spacer"></span>
        <label class="tgl"><input type="checkbox" class="f-quiet" <?= $quiet ? 'checked' : '' ?>><span class="tr"></span></label>
      </div>
      <div class="fcp2-quietbody f-quietbody" <?= $quiet ? '' : 'hidden' ?>>
        <div class="fcp2-sliderrow"><label>Ceiling</label>
          <input type="range" class="f-cap-r" min="0" max="100" value="<?= $capPct ?>">
          <span class="fcp2-num"><input type="number" class="f-cap" min="0" max="100" value="<?= $capPct ?>" required><span class="unit">%</span></span>
        </div>
        <p class="fcp2-help">Short heat spikes stay at or below the ceiling. Sustained heat
          (several minutes) unlocks the full range. Critical temperatures always force full speed.</p>
      </div>
    </div>
  </div>

  <div class="fcp2-cardfoot">
    <span class="meta" title="How often disk (SMART) temperatures are polled. Sensors and the fan itself update every 5 seconds.">
      SMART poll <input type="number" class="f-interval" min="1" max="60" value="<?= $interval ?>" required> min
    </span>
    <span class="meta" title="Log fan speed changes to syslog">
      Syslog <label class="tgl"><input type="checkbox" class="f-syslog" <?= $syslog ? 'checked' : '' ?>><span class="tr"></span></label>
    </span>
    <span class="spacer"></span>
    <button type="button" class="btn-link f-runnow">Run now</button>
    <button type="button" class="btn-link danger f-delete">Delete</button>
  </div>

  <div class="fcp2-applybar">
    <button type="button" class="btn btn-accent f-apply">Apply</button>
    <button type="button" class="btn f-revert">Revert</button>
    <span class="err f-err"></span>
  </div>
</div>
<?php
  return ob_get_clean();
}
