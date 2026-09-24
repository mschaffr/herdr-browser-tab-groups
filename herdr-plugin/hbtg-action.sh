#!/bin/sh
# herdr runs plugin actions without your shell PATH; find hbtg explicitly.
# The target space comes from HERDR_PLUGIN_CONTEXT_JSON, which hbtg reads itself.
for bin in "$HOME/.local/bin/hbtg" "$HOME/Applications/HerdrBrowserTabGroups.app/Contents/MacOS/hbtg"; do
  if [ -x "$bin" ]; then
    [ "$1" = "choose-profile" ] && exec "$bin" choose-profile
    exec "$bin" group "$1"
  fi
done
echo "herdr-browser-tab-groups: hbtg not found; run scripts/bundle-app.sh" >&2
exit 127
