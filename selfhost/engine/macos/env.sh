# Source this; never add it to a shell profile. Keeps git, rust and depot_tools
# cspell:words VIRTUALENV
# state inside the work folder ($SHOREBIRD_ENGINE_DIR, default ~/shorebird-engine),
# so the build touches nothing else on a shared Mac.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
