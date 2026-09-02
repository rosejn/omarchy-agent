#!/usr/bin/env bash
# Install from a source checkout. The package manager path can use the same
# manifest directly; this is for contributors and early testers.
set -euo pipefail

source_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
plugin_id="org.omarchy.agent"
plugins_root="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
target="$plugins_root/$plugin_id"

if [[ $(readlink -f "$source_dir") != $(readlink -f "$target" 2>/dev/null || true) ]]; then
  mkdir -p "$target"
  rsync -a --delete --exclude=.git --exclude='*.tmp' "$source_dir/" "$target/"
fi
chmod +x "$target/bin/omarchy-agent-ensure" "$target/install.sh"
"$target/bin/omarchy-agent-ensure"
systemctl --user restart omarchy-agent.service
omarchy-shell shell rescanPlugins
omarchy plugin enable "$plugin_id" --section center --yes 2>/dev/null || omarchy plugin enable "$plugin_id"
echo "Installed. Click ☻ in the center of the bar to choose a provider."
