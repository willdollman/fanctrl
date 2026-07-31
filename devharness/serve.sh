#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
port="${1:-8080}"
export FCP_SYS_ROOT="$here/fakesys"
exec php -S "0.0.0.0:$port" "$here/router.php"
