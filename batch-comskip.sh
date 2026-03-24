#!/usr/bin/env bash

#
# Batch DVR Post-Processor
# Recursively finds all .ts files and runs them through the Jellyfin Comskip script.
#

# Force the script to find its exact absolute physical path
__script_dir="$(dirname "$(realpath "$0")")"
__processor="${__script_dir}/post-processor.sh"

# Check if a directory was provided as an argument
if [ -z "${1:-}" ]; then
    echo "Error: You must provide a target directory."
    echo "Usage: sudo ./batch-comskip.sh \"/path/to/media\""
    exit 1
fi

__target_dir="$1"

# Verify the directory exists
if [ ! -d "$__target_dir" ]; then
    echo "Error: Directory '$__target_dir' does not exist."
    exit 1
fi

echo "============================================================"
echo "Scanning '$__target_dir' for .ts files..."
echo "============================================================"

# Find all .ts files (ignoring hidden dot-files) and safely pipe them into a while loop
find "$__target_dir" -type f -not -path "*/\.*" -name "*.ts" -print0 | while IFS= read -r -d $'\0' file; do
    echo ""
    echo "▶ Processing: $file"
    
    # Execute the post-processor exactly as Jellyfin would (as the jellyfin user)
    # < /dev/null prevents ffmpeg from eating the while-loop pipe stream
    sudo -u jellyfin "$__processor" "$file" < /dev/null
    
    echo "✔ Finished: $file"
done

echo ""
echo "============================================================"
echo "Batch processing complete!"
echo "============================================================"
