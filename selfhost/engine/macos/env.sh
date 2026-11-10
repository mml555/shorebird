# Source this from bash or zsh, in a terminal used only for the build; never
# add it to a shell profile. It points git (GIT_CONFIG_GLOBAL), Rust,
# depot_tools, caches and TMPDIR at the work folder ($SHOREBIRD_ENGINE_DIR,
# default ~/shorebird-engine) and this directory, so the build touches nothing
# else on a shared Mac.
# cspell:words VIRTUALENV
if [ -n "${BASH_SOURCE:-}" ]; then
  _env_sh="${BASH_SOURCE[0]}"
else
  # zsh: the file being sourced.
  _env_sh="$(eval 'echo ${(%):-%x}')"
fi
HERE="$(cd -- "$(dirname -- "$_env_sh")" && pwd)"
unset _env_sh
[ -f "$HERE/gitconfig" ] || { echo "env.sh: cannot find its own directory (got $HERE)" >&2; return 1; }
W="${SHOREBIRD_ENGINE_DIR:-$HOME/shorebird-engine}"
mkdir -p "$W/logs" "$W/tmp"
export W HERE
export GIT_CONFIG_GLOBAL="$HERE/gitconfig"
export CARGO_HOME="$W/cargo"
export RUSTUP_HOME="$W/rustup"
export DEPOT_TOOLS_UPDATE=0
export XDG_CACHE_HOME="$W/cache"
export TMPDIR="$W/tmp"
export VPYTHON_VIRTUALENV_ROOT="$W/vpython"
export CIPD_CACHE_DIR="$W/cipd-cache"
export PATH="$W/depot_tools:/opt/homebrew/opt/rustup/bin:$PATH:$W/flutter/third_party/ninja"
