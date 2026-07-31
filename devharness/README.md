# Dev harness

Renders the plugin UI on a normal Linux dev machine (no Unraid needed) by
faking the environment the plugin expects:

- fake sysfs tree (`fakesys/`) exposed to PHP via the `FCP_SYS_ROOT` env var
  (see `fcp_sys_root()` in `include/Common.php`; empty in production)
- fake `/dev/sd*` + `/dev/disk/by-id` entries, `mdcmd` stub (needs sudo, once)
- fixture cfg files installed to `/boot/config/plugins/fanctrlplus`
- vendored copies of the libs Unraid's webgui normally provides
  (jQuery, jQuery UI, Font Awesome 4) — downloaded once by `setup.sh`

## Usage

```bash
./devharness/setup.sh        # one-time environment prep (uses sudo)
./devharness/serve.sh 8080   # start PHP dev server
# open http://localhost:8080/Settings/fanctrlplus
```

`router.php` emulates just enough of Unraid's webgui: it strips the .page
header, evals the page inside a minimal dark shell, serves `/plugins/...`
static/PHP files, and implements `/update.php` as "include the posted
#include file" like Unraid does.

Nothing in this directory ships in the plugin package.
