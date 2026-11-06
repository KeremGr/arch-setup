#!/bin/bash
# arch-setup: runs at every boot (in the background, after login is possible).
#  - Another OS appeared or disappeared (e.g. Windows installed later)? -> refresh the GRUB menu.
#  - Another OS is present? -> keep this system's GRUB first in the firmware boot order
#    (Windows setup puts itself first; this puts GRUB back, so you can still choose both).
set -u
STATE=/var/lib/arch-setup; mkdir -p "$STATE"
now=$(os-prober 2>/dev/null | sort)
if [[ $now != "$(cat "$STATE/os-prober.txt" 2>/dev/null)" ]]; then
    if grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; then
        printf '%s\n' "$now" >"$STATE/os-prober.txt"
        echo "GRUB menu refreshed: ${now:-no other systems}"
    fi
fi
[[ -n $now ]] || exit 0
ours_uuid=$(findmnt -no PARTUUID /boot 2>/dev/null)
[[ -n $ours_uuid ]] || exit 0
entries=$(efibootmgr 2>/dev/null) || exit 0
ours=$(grep -i "$ours_uuid" <<<"$entries" | sed -nE 's/^Boot([0-9A-Fa-f]{4})\*? .*/\1/p' | head -1)
order=$(awk -F': ' '/^BootOrder/{print $2}' <<<"$entries")
[[ -n $ours && -n $order && ${order%%,*} != "$ours" ]] || exit 0
rest=$(tr ',' '\n' <<<"$order" | grep -vix "$ours" | paste -sd, -)
efibootmgr -q -o "$ours${rest:+,$rest}" && echo "Boot order: this system's GRUB first again ($ours${rest:+,$rest})"
