#!/usr/bin/env bash
# Registers `hbtg` as native messaging host for every installed Chromium browser (Chrome, Chrome Beta/Canary,
# Chromium, Brave, Edge), allowing only our extension (ID derived from the key in extensions/chromium/manifest.json).
# Called by bundle-app.sh; honours $HOME, so the tests can run it against a temporary home.
set -euo pipefail
cd "$(dirname "$0")/.."

host_name="io.github.herdr_browser_tab_groups"
ext_id="$(python3 -c 'import base64,hashlib,json; k=json.load(open("extensions/chromium/manifest.json"))["key"]; print("".join("abcdefghijklmnop"[int(c,16)] for c in hashlib.sha256(base64.b64decode(k)).hexdigest()[:32]))')"
support="$HOME/Library/Application Support"
installed=0
for browser in "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Canary" "Chromium" "BraveSoftware/Brave-Browser" "Microsoft Edge"; do
  [[ -d "$support/$browser" ]] || continue
  mkdir -p "$support/$browser/NativeMessagingHosts"
  # json.dump escapes the path correctly whatever characters $HOME contains.
  python3 - "$support/$browser/NativeMessagingHosts/$host_name.json" "$host_name" "$ext_id" <<'PY'
import json, os, sys
out, name, ext_id = sys.argv[1:4]
json.dump({
    "name": name,
    "description": "herdr Browser Tab Groups bridge",
    "path": os.path.join(os.environ["HOME"], "Applications/HerdrBrowserTabGroups.app/Contents/MacOS/hbtg"),
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{ext_id}/"],
}, open(out, "w"), indent=2)
PY
  installed=$((installed + 1))
done
echo "Registered native messaging host for $installed browser(s) (extension id $ext_id)"
