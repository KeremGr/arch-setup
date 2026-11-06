#!/usr/bin/env bash
# arch-setup — stage 2: runs once at your first login (opened automatically in a window).
# Installs the desktop (Caelestia + apps + themes) inside your Hyprland session, sets the
# exact monitor modes, runs the system self-check and takes the GOLDEN snapshot.
SETUP_DIR=/opt/arch-setup
export SETUP_DIR
# shellcheck source=../lib.sh
source "$SETUP_DIR/lib.sh"
require_user
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/arch-setup
mkdir -p "$STATE"
LOG=$STATE/stage2-$(date +%F-%H%M%S).log
export WARN_LOG=$STATE/warnings.txt; : >"$WARN_LOG"

finish_fail() {
    printf '\n%s✗ Setup stopped: %s%s\n' "$c_err" "$1" "$c_off"
    echo "  Log: $LOG"
    echo "  Fix the problem (or ask for help with the log), then run again:"
    echo "      $SETUP_DIR/firstboot/finish-setup.sh"
    read -r -p "  Press Enter to close this window. " _ </dev/tty
    exit 1
}

if [[ -f $STATE/stage2-done ]]; then
    ok "The desktop setup already finished. (Report: $STATE/firstboot-report.txt)"
    read -r -p "  Press Enter to close. " _ </dev/tty; exit 0
fi

clear
printf '%s\n  arch-setup — finishing your desktop\n%s\n' "$c_info" "$c_off"
echo "  This installs the Caelestia desktop, apps and themes (about 10-20 minutes)."
echo "  It needs your password once."
echo
sudo -v || finish_fail "sudo failed"
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 30; done ) &
KEEPALIVE=$!
trap 'kill "$KEEPALIVE" 2>/dev/null || true' EXIT

for _ in {1..60}; do resolvectl query archlinux.org &>/dev/null && break; sleep 1; done
resolvectl query archlinux.org &>/dev/null || finish_fail "No internet connection (for Wi-Fi: nmtui)"

exec > >(tee -a "$LOG") 2>&1

run_user() { printf '\n%s╔══ %s ══%s\n' "$c_info" "$1" "$c_off"; bash "$SETUP_DIR/modules/$1.sh" || finish_fail "module $1"; }
run_root() {
    printf '\n%s╔══ %s ══%s\n' "$c_info" "$1" "$c_off"
    sudo env SETUP_DIR="$SETUP_DIR" SETUP_USER="$USER" WARN_LOG="$WARN_LOG" bash "$SETUP_DIR/modules/$1.sh" || finish_fail "module $1"
}

run_user 91-caelestia
run_user 92-apps
run_user 93-themes
run_root 95-desktop-root

section "Monitors: exact modes for the screens connected now"
HU=${XDG_CONFIG_HOME:-$HOME/.config}/caelestia/hypr-user.lua
if [[ -f $HU ]] && grep -q '^-- BEGIN arch-setup monitors' "$HU"; then
    rules=$(hyprctl monitors all -j | python3 -I -c '
import glob, json, re, sys
def native(name):
    # The kernel lists the monitor'"'"'s preferred (native) mode first
    for f in glob.glob("/sys/class/drm/card*-%s/modes" % name):
        first = open(f).readline().strip()
        if re.match(r"^\d+x\d+", first):
            return tuple(int(v) for v in re.match(r"^(\d+)x(\d+)", first).groups())
    return None
mons = sorted(json.load(sys.stdin), key=lambda m: m.get("x", 0))
x = 0
for m in mons:
    name = m["name"]
    modes = []
    for mode in m.get("availableModes", []):
        r = re.match(r"(\d+)x(\d+)@([\d.]+)", mode)
        if r:
            modes.append((int(r[1]), int(r[2]), float(r[3])))
    if not modes:
        continue
    res = native(name) or (m["width"], m["height"])
    same = [md for md in modes if (md[0], md[1]) == res] or modes
    w, h, hz = max(same, key=lambda md: (md[2], md[0] * md[1]))
    print("hl.monitor({ output = \"%s\", mode = \"%dx%d@%.2f\", position = \"%dx0\", scale = 1 })" % (name, w, h, hz, x))
    print("-- %s: %dx%d @ %.0f Hz (native resolution, highest refresh)" % (name, w, h, hz), file=sys.stderr)
    x += w
')
    if [[ -n $rules ]]; then
        python3 -I - "$HU" "$rules" <<'PY'
import re, sys
p, rules = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r"(-- BEGIN arch-setup monitors\n).*?(-- END arch-setup monitors)", lambda m: m[1] + rules + "\n" + m[2], s, flags=re.S)
open(p, "w").write(s)
PY
        ok "Monitor rules written (native resolution at its highest refresh rate, left to right)"
    else
        warn "No monitors reported — keeping the automatic 'highest refresh rate' rule"
    fi
fi

section "System self-check + GOLDEN snapshot"
if sudo /usr/local/lib/arch-setup/firstboot.sh; then
    touch "$STATE/stage2-done"
    passed=1
else
    passed=0
fi
sudo install -o "$USER" -m 0644 /var/lib/arch-setup/firstboot-report.txt "$STATE/firstboot-report.txt" 2>/dev/null || true

section "Done"
[[ -s $WARN_LOG ]] && { warn "Notes from the setup:"; cat "$WARN_LOG"; }
if (( passed )); then
    cat <<EOF

${c_ok}Your desktop is ready.${c_off}  Restart once so everything starts fresh.
  · SUPER opens the launcher — change scheme or wallpaper there, the other follows.
  · Change your password with:  sudo arch-setup-passwd   (keeps disk encryption + GRUB in sync)
  · Report: $STATE/firstboot-report.txt
EOF
else
    echo; warn "Some checks failed (see above). The golden snapshot was NOT taken."
    echo "  Fix them, then re-run:  sudo /usr/local/lib/arch-setup/firstboot.sh"
fi
read -r -p "  Press Enter to restart now (or close this window to restart later). " _ </dev/tty
systemctl reboot
