<?php
// Minimal Unraid webgui emulation for local UI development.
$here    = __DIR__;
$repo    = dirname($here);
$docroot = "/usr/local/emhttp";           // symlinked to $repo by setup.sh
$uri     = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

function serve_file(string $path): bool {
  if (!is_file($path)) return false;
  $ext  = strtolower(pathinfo($path, PATHINFO_EXTENSION));
  $mime = [
    'css' => 'text/css', 'js' => 'application/javascript',
    'png' => 'image/png', 'svg' => 'image/svg+xml',
    'woff' => 'font/woff', 'woff2' => 'font/woff2',
  ][$ext] ?? null;
  if ($ext === 'php') {
    $_SERVER['DOCUMENT_ROOT'] = '/usr/local/emhttp';
    chdir(dirname($path));
    include $path;
    return true;
  }
  if ($mime) header("Content-Type: $mime");
  readfile($path);
  return true;
}

// --- vendored libs Unraid normally provides -------------------------------
$vendor_map = [
  '/webGui/javascript/jquery.min.js'    => "$here/vendor/jquery.min.js",
  '/webGui/javascript/jquery-ui.min.js' => "$here/vendor/jquery-ui.min.js",
  '/webGui/javascript/dynamix.js'       => "$here/vendor/dynamix.js",
  '/webGui/styles/font-awesome.min.css' => "$here/vendor/font-awesome.min.css",
  '/webGui/styles/default-base.css'     => "$here/vendor/default-base.css",
  '/webGui/styles/default-dynamix.css'  => "$here/vendor/default-dynamix.css",
  '/webGui/styles/theme-black.css'      => "$here/vendor/theme-black.css",
];
if (isset($vendor_map[$uri])) { serve_file($vendor_map[$uri]); return true; }
if (preg_match('#^/webGui/fonts/(.+)$#', $uri, $m) || preg_match('#/fonts/(fontawesome-[^/]+)$#', $uri, $m)) {
  if (serve_file("$here/vendor/fonts/" . basename($m[1]))) return true;
}
if (str_starts_with($uri, '/webGui/')) { header('Content-Type: text/css'); return true; } // empty stub

// --- plugin files ----------------------------------------------------------
if (preg_match('#^/plugins/fanctrlplusplus/(.+)$#', $uri, $m)) {
  $path = realpath("$repo/{$m[1]}");
  if ($path && str_starts_with($path, $repo) && serve_file($path)) return true;
  http_response_code(404); return true;
}

// --- Unraid's /update.php: include the posted #include file ----------------
if ($uri === '/update.php') {
  $inc = $_POST['#include'] ?? '';
  $path = realpath("$docroot/" . ltrim($inc, '/'));
  if ($path && str_starts_with($path, realpath($docroot) . '/')) {
    chdir(dirname($path));
    include $path;
  } else {
    http_response_code(400); echo "bad #include";
  }
  return true;
}

// --- render a .page file ----------------------------------------------------
$pages = [
  '/'                   => "$repo/fanctrlplusplus.page",
  '/Settings/fanctrlplusplus'  => "$repo/fanctrlplusplus.page",
];
if (isset($pages[$uri])) {
  $page = file_get_contents($pages[$uri]);
  // strip .page header (leading Key="value" lines)
  $page = preg_replace('/^(?:[A-Za-z_]+="[^"]*"\n)+/', '', $page, 1);
  header('Content-Type: text/html; charset=utf-8');
  ?>
<!DOCTYPE html>
<html class="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FanCtrl PlusPlus — dev harness</title>
<link rel="stylesheet" href="/webGui/styles/font-awesome.min.css">
<link rel="stylesheet" href="/webGui/styles/default-base.css">
<link rel="stylesheet" href="/webGui/styles/default-dynamix.css">
<link rel="stylesheet" href="/webGui/styles/theme-black.css">
<script src="/webGui/javascript/jquery.min.js"></script>
<script src="/webGui/javascript/jquery-ui.min.js"></script>
<script src="/webGui/javascript/dynamix.js"></script>
<style>
  /* rough approximation of Unraid's dark theme page chrome */
  body { background:#1c1b1b; color:#e0e0e0; margin:0;
         font-family:clear-sans,helvetica,arial,sans-serif; font-size:14px; }
  #main { padding:20px 24px; max-width:1600px; margin:0 auto; }
  div.title { border-bottom:2px solid #e22828; margin:10px 0 16px;
              padding:6px 0; font-size:18px; }
  div.title span.left { color:#e0e0e0; }
  a { color:#ff8c2f; text-decoration:none; }
  input,select,button,textarea { background:#2b2a2a; color:#e0e0e0;
    border:1px solid #4a4948; border-radius:3px; padding:4px 6px; }
  input[type=button],button,input[type=submit] { cursor:pointer; background:#e22828;
    border:none; color:#fff; padding:6px 14px; border-radius:4px; }
  table { border-collapse:collapse; }
  td { padding:4px 8px; }
</style>
</head>
<body>
<div id="main">
<div class="title"><span class="left">FanCtrl PlusPlus</span></div>
<?php
  chdir($repo);
  eval('?>' . $page);
?>
</div>
<iframe name="progressFrame" style="display:none"></iframe>
</body>
</html>
<?php
  return true;
}

http_response_code(404);
echo "not found: $uri";
return true;
