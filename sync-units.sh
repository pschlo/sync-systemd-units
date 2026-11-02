#!/usr/bin/env bash
# Make systemd match this folder: link every unit file under units/<group>/ into
# /etc/systemd/system, enable exactly the units listed in ./enabled, and reload.
# "This folder" is where this script, or a symlink to it, sits.
# Safe to re-run. --dry-run prints the commands without running them.
# https://github.com/pschlo/sync-systemd-units
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ETC=/etc/systemd/system
UNITS="$ROOT/units"
LIST="$ROOT/enabled"
DRY=0
ACTED=0

case "${1:-}" in
    "") ;;
    -n|--dry-run) DRY=1 ;;
    -h|--help) echo "usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

die() { echo "error: $*" >&2; exit 1; }
run() { echo "+ $*"; ACTED=$((ACTED + 1)); ((DRY)) || "$@"; }
is_enabled() { systemctl is-enabled "$1" 2>/dev/null || true; }
stop_if_active() {
    if systemctl is-active -q "$1" 2>/dev/null; then run systemctl stop "$1"; fi
}
template_of() {
    if [[ $1 == *@?*.* ]]; then echo "${1%%@*}@.${1##*.}"; else echo "$1"; fi
}
# Remove every link named $1 that points at $2, at the top level or in a .wants
# folder. Used where systemctl disable would also take other links with it.
remove_links() {
    local l
    while IFS= read -r -d '' l; do
        [[ "$(readlink -- "$l")" == "$2" ]] && run rm -f -- "$l"
    done < <(find "$ETC" -maxdepth 2 -type l -name "$1" -print0)
}

# Unit files live in group folders under units/. Names must be unique across
# groups because they all end up side by side in $ETC.
declare -A path_of=()
[[ -d $UNITS ]] || die "missing $UNITS"
mapfile -d '' -t files < <(find "$UNITS" -mindepth 2 -type f -not -path '*/.*' \
    -regextype posix-extended -regex '.*\.(service|socket|timer|target|path|mount|automount|swap|slice)' \
    -print0 | sort -z)
for f in "${files[@]}"; do
    name="${f##*/}"
    [[ -z "${path_of[$name]:-}" ]] || die "unit name $name is used twice: ${path_of[$name]} and $f"
    path_of[$name]="$f"
done
names=()
((${#path_of[@]})) && mapfile -t names < <(printf '%s\n' "${!path_of[@]}" | sort)

# ./enabled: one unit per line, # starts a comment. Template instances such as
# foo@bar.service resolve to foo@.service.
declare -A want=() mentioned=()
if [[ -f $LIST ]]; then
    # Commented-out names count as mentioned: deliberately off.
    while IFS= read -r unit; do
        mentioned[$unit]=1
    done < <(grep -oE '[A-Za-z0-9@._:-]+\.(service|socket|timer|target|path|mount|automount|swap|slice)' "$LIST")
    while IFS= read -r line || [[ -n $line ]]; do
        unit="${line%%#*}"
        unit="${unit//[[:space:]]/}"
        [[ -n $unit ]] || continue
        file="$unit"
        [[ $unit == *@?*.* ]] && file="${unit%%@*}@.${unit##*.}"
        [[ -n "${path_of[$file]:-}" ]] || die "enabled lists $unit, but there is no $file in $UNITS"
        grep -Eq '^[[:space:]]*(WantedBy|RequiredBy|UpheldBy|Alias)=' "${path_of[$file]}" ||
            die "$unit has no [Install] section, so it cannot be enabled; list the timer or target that starts it instead"
        want[$unit]=1
    done < "$LIST"
fi

# Never take over a name that something else owns.
for name in "${names[@]}"; do
    dst="$ETC/$name"
    if [[ -L $dst ]]; then
        target="$(readlink -- "$dst")"
        [[ $target == "$ROOT"/* ]] || die "$dst already links to $target, which is not managed here"
    elif [[ -e $dst ]]; then
        die "$dst is a file that is not managed here; move it into a group folder or rename the unit"
    fi
    [[ ! -e /usr/lib/systemd/system/$name ]] ||
        die "$name would hide the packaged unit /usr/lib/systemd/system/$name; rename it, or use a drop-in"
done

verify=()
for name in "${names[@]}"; do
    [[ $name == *@.* ]] || verify+=("${path_of[$name]}")
done
if ((${#verify[@]})); then
    # Hide warnings about packaged units that ours merely reference.
    systemd-analyze verify "${verify[@]}" 2> >(grep -v '^/usr/lib/systemd/' >&2)
fi

# Remember which loaded units changed on disk, to point out restarts later.
changed=()
for name in "${names[@]}"; do
    [[ $name == *@.* ]] && continue
    [[ "$(systemctl show -P NeedDaemonReload "$name" 2>/dev/null)" == yes ]] && changed+=("$name")
done

# disable also deletes the unit's link, so every unit disabled below gets
# linked again further down.
declare -A unlinked=()

# Units deleted or moved: their link points into $ROOT but not at a current
# file. A deleted unit's file is gone, so remove its links directly.
while IFS= read -r -d '' link; do
    name="${link##*/}"
    target="$(readlink -- "$link")"
    [[ $target == "$ROOT"/* ]] || continue
    file="$(template_of "$name")"
    if [[ $file != "$name" && -n "${path_of[$file]:-}" ]]; then
        # An enabled template instance: keep it while listed and current.
        if [[ -z "${want[$name]:-}" ]]; then
            stop_if_active "$name"
            remove_links "$name" "$target"
        elif [[ $target != "${path_of[$file]}" ]]; then
            remove_links "$name" "$target"
        fi
    elif [[ -z "${path_of[$name]:-}" ]]; then
        stop_if_active "$name"
        while IFS= read -r -d '' l; do
            [[ "$(readlink -- "$l")" == "$target" || "$(readlink -- "$l")" == "$link" ]] && run rm -f -- "$l"
        done < <(find "$ETC" -mindepth 2 -maxdepth 2 -type l -print0)
        run rm -f -- "$link"
    elif [[ $target != "${path_of[$name]}" ]]; then
        run systemctl disable --no-reload "$name"
        unlinked[$name]=1
    fi
done < <(find "$ETC" -maxdepth 1 -type l -print0)

# Any other enablement links whose source file is gone.
while IFS= read -r -d '' link; do
    target="$(readlink -- "$link")"
    [[ $target == "$ROOT"/* && ! -e $target ]] && run rm -f -- "$link"
done < <(find "$ETC" -mindepth 2 -maxdepth 2 -type l -print0)

# Units taken off the list.
for name in "${names[@]}"; do
    [[ $name == *@.* || -n "${want[$name]:-}" || -n "${unlinked[$name]:-}" ]] && continue
    if [[ "$(is_enabled "$name")" == enabled ]]; then
        stop_if_active "$name"
        run systemctl disable --no-reload "$name"
        unlinked[$name]=1
    fi
done

for name in "${names[@]}"; do
    path="${path_of[$name]}"
    if [[ -n "${unlinked[$name]:-}" || ! -L $ETC/$name || "$(readlink -- "$ETC/$name")" != "$path" ]]; then
        run systemctl link --no-reload "$path"
    fi
done

# Reload only when links changed or a unit file differs from what systemd loaded.
((ACTED == 0 && ${#changed[@]} == 0)) || run systemctl daemon-reload

# Units added to the list, or enabled before but unlinked by a manual disable.
# Units that are already enabled keep their running state, so a temporary
# `systemctl stop` survives re-runs.
mapfile -t wanted < <(printf '%s\n' "${!want[@]}" | sort)
for unit in "${wanted[@]}"; do
    [[ -z $unit ]] && continue
    file="$(template_of "$unit")"
    if [[ -n "${unlinked[$file]:-}" || "$(is_enabled "$unit")" != enabled ]]; then
        run systemctl enable --now "$unit"
    fi
done

for name in "${names[@]}"; do
    [[ -d $ETC/$name.d ]] && echo "warning: $ETC/$name.d holds drop-ins outside this folder" >&2
done
missing=()
for name in "${names[@]}"; do
    [[ $name == *@.* || -n "${mentioned[$name]:-}" ]] && continue
    grep -Eq '^[[:space:]]*(WantedBy|RequiredBy|UpheldBy|Alias)=' "${path_of[$name]}" && missing+=("$name")
done
if ((${#missing[@]})); then
    echo "note: not in enabled yet; add each one, commented out if it should stay off:"
    printf '  %s\n' "${missing[@]}"
fi
for name in "${changed[@]}"; do
    if [[ "$(systemctl is-active "$name" 2>/dev/null)" == active ]]; then
        echo "note: $name changed on disk while running; if its settings changed, run: systemctl restart $name"
    fi
done

if ((ACTED == 0)); then echo "Already in sync; nothing to do."
elif ((DRY)); then echo "Dry run: nothing changed."
else echo "systemd matches $ROOT."; fi
