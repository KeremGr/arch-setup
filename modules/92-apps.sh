#!/usr/bin/env bash
# Apps wired into Caelestia's live theming:
#   LibreWolf (CaelestiaFox add-on + native host), Spotify (spotify-launcher +
#   Spicetify), Vesktop, plus privacy fixes for night-light and weather.
source "$(dirname "$0")/../lib.sh"
require_user
CFG=${XDG_CONFIG_HOME:-$HOME/.config}
DOTS=${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/dots
[[ -d $DOTS ]] || die "Caelestia dots not found at $DOTS (did 91-caelestia run?)"

# Location from the system timezone (no network lookup): the timezone's main city, rounded
TZNAME=$(readlink /etc/localtime | sed "s|.*/zoneinfo/||")
read -r LAT LON < <(awk -v tz="$TZNAME" -F'\t' '$3==tz {c=$2; n=match(c,/[+-][0-9]+$/); la=substr(c,1,n-1); lo=substr(c,n);
    printf "%.2f %.2f\n", (substr(la,1,1)=="-"?-1:1)*(substr(la,2,2)+substr(la,4,2)/60), (substr(lo,1,1)=="-"?-1:1)*(substr(lo,2,3)+substr(lo,5,2)/60)}' \
    /usr/share/zoneinfo/zone1970.tab) || true
CITY=${WEATHER_CITY:-${TZNAME##*/}}; CITY=${CITY//_/ }

section "Night light without location tracking"
install -d "$CFG/gammastep"
cat >"$CFG/gammastep/config.ini" <<CONF
[general]
location-provider=manual
adjustment-method=wayland
temp-day=6500
temp-night=4000
fade=1

[manual]
lat=${LAT:-0}
lon=${LON:-0}
CONF
ok "gammastep uses fixed coordinates ($LAT, $LON) — geoclue not installed, nothing is sent anywhere"
[[ -n ${LAT:-} ]] || warn "No coordinates for timezone '$TZNAME' — set lat/lon in $CFG/gammastep/config.ini for correct night-light times"

section "Weather (fixed city, no IP geolocation) + idle: lock after 10 min, no auto-sleep"
SHELLCFG=$CFG/caelestia/shell.json
python3 -I - "$SHELLCFG" "$CITY" <<'PY'
import json, sys, pathlib
p, city = pathlib.Path(sys.argv[1]), sys.argv[2]
d = json.loads(p.read_text()) if p.exists() and p.read_text().strip() else {}
d.setdefault("services", {})["weatherLocation"] = city
# Idle: lock after 10 minutes; never turn screens off or sleep on its own
# (some monitors don't come back from standby). Closing a laptop lid still sleeps.
idle = d.setdefault("general", {}).setdefault("idle", {})
idle.update({"lockBeforeSleep": True, "inhibitWhenAudio": True,
             "timeouts": [{"timeout": 600, "idleAction": "lock"}]})
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(d, indent=4))
PY
ok "Weather city: $CITY (change in Caelestia settings or $SHELLCFG)"

section "LibreWolf + CaelestiaFox"
find_profile_root() { for r in "$HOME/.librewolf" "$CFG/librewolf/librewolf" "$CFG/librewolf"; do [[ -f $r/profiles.ini ]] && { echo "$r"; return; }; done; }
ROOT=$(find_profile_root || true)
if [[ -z $ROOT ]]; then
    librewolf --headless --no-remote about:blank &>/dev/null & pid=$!
    for _ in {1..60}; do ROOT=$(find_profile_root || true); [[ -n $ROOT ]] && break; sleep 0.5; done
    sleep 2; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
fi
[[ -n $ROOT ]] || die "Could not create a LibreWolf profile"
PROFILE=$(awk -F= '/^\[Install/{i=1} i&&/^Default=/{print $2; exit}' "$ROOT/profiles.ini")
[[ -n $PROFILE ]] || PROFILE=$(awk -F= '/^Path=/{print $2; exit}' "$ROOT/profiles.ini")
P=$ROOT/$PROFILE
[[ -d $P ]] || die "LibreWolf profile dir $P not found"
ok "Profile: $P"

install -D -m 0644 "$DOTS/firefox/userChrome.css" "$P/chrome/userChrome.css"
set_block "$P/user.js" caelestia <<'CONF'
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
// Let the profile-installed CaelestiaFox add-on enable itself (profile scope only)
user_pref("extensions.autoDisableScopes", 14);
CONF
set_block "$P/user.js" perf <<'CONF'
// GPU video decoding on NVIDIA (libva-nvidia-driver); content sandbox stays on
user_pref("media.ffmpeg.vaapi.enabled", true);
user_pref("media.hardware-video-decoding.force-enabled", true);
user_pref("widget.dmabuf.force-enabled", true);
user_pref("gfx.webrender.all", true);
// Smoother, physics-based scrolling at high refresh rates
user_pref("general.smoothScroll.msdPhysics.enabled", true);
CONF

# Native host: streams the current Caelestia colours to the add-on (local only, no network)
install -D -m 0755 "$DOTS/firefox/native_app/app.fish" "$HOME/.local/lib/caelestia/caelestiafox"
for d in "$ROOT/native-messaging-hosts" "$HOME/.librewolf/native-messaging-hosts" "$HOME/.mozilla/native-messaging-hosts" \
         "$CFG/librewolf/native-messaging-hosts" "$CFG/mozilla/native-messaging-hosts"; do
    install -d "$d"
    cat >"$d/caelestiafox.json" <<JSON
{
    "name": "caelestiafox",
    "description": "Native app for CaelestiaFox extension.",
    "path": "$HOME/.local/lib/caelestia/caelestiafox",
    "type": "stdio",
    "allowed_extensions": ["caelestiafox@caelestia.org"]
}
JSON
done

# Add-on from addons.mozilla.org (Mozilla-signed); verify the published SHA-256
XPI=$P/extensions/caelestiafox@caelestia.org.xpi
if [[ ! -f $XPI ]]; then
    read -r URL HASH < <(curl -sf --proto '=https' "https://addons.mozilla.org/api/v5/addons/addon/caelestiafox@caelestia.org/" \
        | python3 -I -c 'import json,sys; f=json.load(sys.stdin)["current_version"]["file"]; print(f["url"], f["hash"].split(":",1)[1])')
    install -d "$P/extensions"
    curl -sfL --proto '=https' "$URL" -o "$XPI.tmp"
    echo "$HASH  $XPI.tmp" | sha256sum -c --quiet || { rm -f "$XPI.tmp"; die "CaelestiaFox download failed verification"; }
    mv "$XPI.tmp" "$XPI"
fi
ok "CaelestiaFox add-on installed and verified (browser recolours live with your scheme)"
xdg-settings set default-web-browser librewolf.desktop 2>/dev/null && ok "LibreWolf is the default browser"

section "Spotify + Spicetify (recolours with your scheme)"
install -D -m 0644 "$DOTS/spicetify/Themes/caelestia/user.css" "$CFG/spicetify/Themes/caelestia/user.css"
install -D -m 0755 /dev/stdin "$HOME/.local/bin/spotify-themed" <<'SH'
#!/usr/bin/env bash
# Launch Spotify with the Caelestia theme applied (re-applies after Spotify updates).
set -u
SP=$HOME/.local/share/spotify-launcher/install/usr/share/spotify
STAMP=${XDG_STATE_HOME:-$HOME/.local/state}/spicetify-applied
apply() {
    spicetify -q config spotify_path "$SP" prefs_path "$HOME/.config/spotify/prefs" \
        current_theme caelestia color_scheme caelestia custom_apps marketplace inject_css 1 replace_colors 1
    spicetify -q -n backup apply 2>/dev/null || spicetify -q -n restore backup apply
    # Dev mode lets Ctrl+Shift+R reload the UI, so scheme changes show live (no restart, music keeps playing)
    spicetify -q enable-devtools 2>/dev/null || true
    stat -c %Y "$SP/spotify" >"$STAMP"
}
if [[ ! -x $SP/spotify || ! -f $HOME/.config/spotify/prefs ]]; then
    # First run: spotify-launcher downloads Spotify; theme it once prefs exist, then restart it.
    spotify-launcher "$@" &
    for _ in $(seq 120); do [[ -f $HOME/.config/spotify/prefs ]] && break; sleep 1; done
    sleep 3; apply && spicetify -q apply
    exit 0
fi
[[ -f $STAMP && $(cat "$STAMP") == $(stat -c %Y "$SP/spotify") ]] || apply
exec spotify-launcher "$@"
SH
install -d "$HOME/.local/share/applications"
sed -e "s|^Exec=.*|Exec=$HOME/.local/bin/spotify-themed %U|" /usr/share/applications/spotify-launcher.desktop \
    >"$HOME/.local/share/applications/spotify-launcher.desktop"
ok "Spotify opens through spotify-themed (first launch downloads Spotify, then restarts themed)"

section "Vesktop (Discord)"
VS=$CFG/vesktop/settings/settings.json
if [[ ! -f $VS ]]; then
    install -D -m 0644 /dev/stdin "$VS" <<'JSON'
{ "enabledThemes": ["caelestia.theme.css"] }
JSON
    ok "Caelestia theme enabled in Vesktop (live recolour)"
else
    python3 -I - "$VS" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
t = d.setdefault("enabledThemes", [])
if "caelestia.theme.css" not in t: t.append("caelestia.theme.css")
json.dump(d, open(p, "w"), indent=4)
PY
    ok "Caelestia theme enabled in existing Vesktop settings"
fi

section "Shortcuts to the HDD"
[[ -d /data/storage ]] && ln -sfn /data/storage "$HOME/Storage" && ok "~/Storage -> encrypted HDD"
[[ -d /mnt/bridge ]] && ln -sfn /mnt/bridge "$HOME/Bridge" && ok "~/Bridge -> Windows share"
true
