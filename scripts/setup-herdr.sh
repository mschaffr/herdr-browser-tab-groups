#!/usr/bin/env bash
# Configures herdr for herdr Browser Tab Groups. Safe to run repeatedly: everything it writes lives between
# "# >>> herdr-browser-tab-groups" markers and is replaced on the next run. Settings you wrote yourself are never
# changed; if one conflicts, the script skips its own version and warns.
#
#   scripts/setup-herdr.sh [--width N] [--no-reload]
#
# --width N    fixed herdr sidebar width, needed to right-align the "● browser" label (default 36, 0 = off)
# --no-reload  don't reload the running herdr server / app
set -euo pipefail
cd "$(dirname "$0")/.."

WIDTH=36
RELOAD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --width)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "--width needs a number (columns, 0 = off)" >&2; exit 2; }
      WIDTH="$2"; shift 2 ;;
    --no-reload) RELOAD=0; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

HERDR_BIN="$(command -v herdr || true)"
[[ -n "$HERDR_BIN" ]] || { echo "herdr not found on PATH" >&2; exit 1; }
HBTG_BIN="$HOME/.local/bin/hbtg"
[[ -x "$HBTG_BIN" ]] || { echo "hbtg not installed; run scripts/bundle-app.sh first" >&2; exit 1; }

HERDR_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"
HBTG_CONFIG="${HBTG_CONFIG_DIR:-$HOME/.config/herdr-browser-tab-groups}/config.json"

# 1. Plugin (provides the browser-open / browser-close actions).
"$HERDR_BIN" plugin link "$PWD/herdr-plugin" >/dev/null
echo "✓ herdr plugin linked ($PWD/herdr-plugin)"

# 2. herdr config.toml
mkdir -p "$(dirname "$HERDR_CONFIG")"
touch "$HERDR_CONFIG"
# Timestamped, so re-running never overwrites the backup of your original config.
BACKUP_BASE="$HERDR_CONFIG.bak-hbtg-$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_BASE"
n=1
while [[ -e "$BACKUP" ]]; do BACKUP="$BACKUP_BASE.$n"; n=$((n + 1)); done   # two runs within one second
cp "$HERDR_CONFIG" "$BACKUP"
WIDTH_FILE="$(mktemp)"
python3 - "$HERDR_CONFIG" "$HERDR_BIN" "$HBTG_BIN" "$WIDTH" "$WIDTH_FILE" <<'PY'
import re, sys

path, herdr, hbtg, width, width_file = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
UI_BEGIN, UI_END = "# >>> herdr-browser-tab-groups ui >>>", "# <<< herdr-browser-tab-groups ui <<<"
BEGIN, END = "# >>> herdr-browser-tab-groups >>>", "# <<< herdr-browser-tab-groups <<<"

text = open(path).read()
# Drop previous managed blocks.
for b, e in ((UI_BEGIN, UI_END), (BEGIN, END)):
    text = re.sub(rf"\n?{re.escape(b)}.*?{re.escape(e)}\n?", "\n", text, flags=re.S)
text = text.rstrip("\n") + "\n"

def has_table(name):
    return re.search(rf"^\s*\[{re.escape(name)}\]\s*$", text, re.M) is not None

def user_keys():
    return set(re.findall(r'^\s*key\s*=\s*"([^"]+)"', text, re.M))

warnings = []
tail = []

# Fixed sidebar width (keys must live inside the [ui] table).
if width > 0:
    if re.search(r"^\s*sidebar_(min_|max_)?width\s*=", text, re.M):
        # Respect the user's width; it only works for alignment if it's fixed (all three equal).
        vals = {k: int(v) for k, v in re.findall(r"^\s*(sidebar_(?:min_|max_)?width)\s*=\s*(\d+)", text, re.M)}
        fixed = {vals.get("sidebar_width"), vals.get("sidebar_min_width"), vals.get("sidebar_max_width")}
        if len(fixed) == 1 and None not in fixed:
            width = fixed.pop()
            warnings.append(f"using your fixed sidebar width {width}")
        else:
            width = 0
            warnings.append("your sidebar width isn't fixed (sidebar_width/min/max differ); right alignment turned off")
    else:
        ui = (f"{UI_BEGIN}\n# Fixed width so herdr Browser Tab Groups can right-align the browser label.\n"
              f"sidebar_width = {width}\nsidebar_min_width = {width}\nsidebar_max_width = {width}\n{UI_END}\n")
        m = re.search(r"^\s*\[ui\]\s*$\n?", text, re.M)
        if m:
            text = text[:m.end()] + ui + text[m.end():]
        else:
            tail.append("[ui]\n" + ui.replace(UI_BEGIN + "\n", "").replace(UI_END + "\n", ""))

# "● browser" marker on space rows.
if has_table("ui.sidebar.spaces"):
    warnings.append('[ui.sidebar.spaces] already exists; add { token = "$browser", fg = "#89b4fa" } to one of its rows yourself')
else:
    tail.append('[ui.sidebar.spaces]\n'
                'rows = [["state_icon", "workspace", { token = "$browser", fg = "#89b4fa" }], ["branch", "git_status"]]\n')

def sh(p):  # quote for the shell command herdr runs
    return "'" + p.replace("'", "'\\''") + "'"

bindings = [
    ("prefix+shift+o", "browser group picker", "popup", f"{sh(hbtg)} pick", "width = 50\nheight = 20\n"),
    ("prefix+shift+b", "open browser group", "shell",
     f"{sh(herdr)} plugin action invoke browser-open --plugin herdr-browser-tab-groups", ""),
    ("prefix+alt+b", "close browser group", "shell",
     f"{sh(herdr)} plugin action invoke browser-close --plugin herdr-browser-tab-groups", ""),
]
taken = user_keys()
for key, desc, kind, cmd, extra in bindings:
    if key in taken:
        warnings.append(f"{key} is already bound in your config; skipped '{desc}'")
        continue
    cmd_toml = cmd.replace("\\", "\\\\").replace('"', '\\"')
    tail.append(f'[[keys.command]]\nkey = "{key}"\ndescription = "{desc}"\ntype = "{kind}"\n'
                f'command = "{cmd_toml}"\n{extra}')

if tail:
    text += f"\n{BEGIN}\n" + "\n".join(tail) + f"{END}\n"
text = text.lstrip("\n")
open(path, "w").write(text)
open(width_file, "w").write(str(width))
for w in warnings:
    print(f"! {w}")
PY
echo "✓ herdr config updated ($HERDR_CONFIG, backup: $BACKUP)"
if ! "$HERDR_BIN" config check | grep -q "config: ok"; then
  "$HERDR_BIN" config check
  echo "herdr reported config issues (see above); restore the backup if needed" >&2
fi

WIDTH="$(cat "$WIDTH_FILE")"; rm -f "$WIDTH_FILE"

# 3. App config: same sidebar width, so the label padding matches.
python3 - "$HBTG_CONFIG" "$WIDTH" <<'PY'
import json, os, sys
path, width = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
os.chmod(os.path.dirname(path), 0o700)
config = json.load(open(path)) if os.path.exists(path) else {}
config["sidebarWidth"] = width
# Owner-only from creation: the file holds the auth token.
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(config, f, indent=2, sort_keys=True)
os.chmod(path, 0o600)
PY
echo "✓ app sidebarWidth = $WIDTH ($HBTG_CONFIG)"

# 4. Apply.
if [[ "$RELOAD" == 1 ]]; then
  "$HERDR_BIN" server reload-config >/dev/null 2>&1 && echo "✓ herdr config reloaded" || echo "  herdr server not running; config applies on next start"
  if out="$("$HBTG_BIN" reload-config 2>&1)"; then echo "✓ app config reloaded"
  else echo "  app config not reloaded (${out#hbtg: }); it applies on next app start"; fi
fi

cat <<EOF

herdr shortcuts:
  ctrl+b, shift+O   browser group picker (click / Enter = open, x = close)
  ctrl+b, shift+B   open the current space's browser group
  ctrl+b, alt+b     close it
EOF
