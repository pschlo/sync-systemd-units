#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

SRC_DIR="$SCRIPT_DIR/units"
INSTALL_DIR="/etc/systemd/system"
LOG_FILE="$SCRIPT_DIR/units.log"

[[ -d "$SRC_DIR" ]] || { echo "Missing units dir: $SRC_DIR" >&2; exit 1; }

# Step 1: Delete previously copied files
if [[ -f "$LOG_FILE" ]]; then
    echo "🗑️ Deleting previously installed files..."
    while IFS= read -r filename; do
        [[ -n "$filename" ]] || continue
        file_path="$INSTALL_DIR/$filename"
        if [[ -f "$file_path" ]]; then
            rm -f -- "$file_path"
            echo "Deleted: $filename"
        else
            echo "Skipping (not found): $filename"
        fi
    done < "$LOG_FILE"

    # Clear the log file
    : > "$LOG_FILE"
    echo "✅ Log cleared."
else
    echo "ℹ️ No previous log found. Skipping deletion."
fi

# Step 2: Copy new files and log them
echo "📂 Installing new files..."
shopt -s nullglob
for file in "$SRC_DIR"/*; do
    # Skip if not a file
    [[ -f "$file" ]] || continue

    # Extract filename
    filename="$(basename -- "$file")"

    # Copy file to destination
    install -m 0644 -o root -g root -- "$file" "$INSTALL_DIR/$filename"
    echo "$filename" >> "$LOG_FILE"
    echo "Installed: $filename"
done

echo "✅ All unit files processed. Log updated: $LOG_FILE"

systemctl daemon-reload
echo "✅ systemd reloaded."
