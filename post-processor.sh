#!/usr/bin/env bash

#
# Ultimate DVR Post-Processor (Atomic Writes + Dynamic Audio Normalize + Absolute Paths)
#

set -o errexit
set -o pipefail
set -o nounset

# Force the script to find its exact absolute physical path
__script_dir="$(dirname "$(realpath "$0")")"

# Core Paths
__ffmpeg=/usr/lib/jellyfin-ffmpeg/ffmpeg
__ffprobe=/usr/lib/jellyfin-ffmpeg/ffprobe
__comskip=/usr/bin/comskip
__comskip_ini="${__script_dir}/comskip.ini"

# Terminal Colors
GREEN='\033[0;32m'
NC='\033[0m'

__path="${1:-}"
PWD="$(pwd)"

die () {
        echo >&2 "$@"
        cd "${PWD}"
        exit 1
}

# Verify file exists
[ -n "$__path" ] || die "path is required"
[ -f "$__path" ] || die "path ($__path) is not a file"

__dir="$(dirname "${__path}")"
__file="$(basename "${__path}")"
__base="$(basename "${__path}" ".ts")"

# Set up temporary and final filenames using hidden dot-files to avoid Jellyfin's auto-scanner
__sanitized_ts="${__dir}/.${__base}_sanitized.ts"
__temp_mkv="${__dir}/.${__base}_working.mkv"
__final_mkv="${__dir}/${__base}.mkv"
__temp_srt="${__dir}/.${__base}.en.srt"
__final_srt="${__dir}/${__base}.en.srt"

# Use the OS temp directory for the symlinks/probes to keep the media folder clean
__safe_symlink="/tmp/temp_lavfi_input_${RANDOM}.ts"
__probe_file="/tmp/audio_probe_${RANDOM}.ts"

# Ensure comskip.ini exists so we are guaranteed to get .ffmeta output
if [ ! -f "$__comskip_ini" ]; then
    printf "[post-process.sh] %bWarning: comskip.ini missing! Auto-generating a replacement...%b\n" "$GREEN" "$NC"
    cat << 'EOF' > "$__comskip_ini"
detect_method=127
hardware_decode=1
output_ffmeta=1
output_edl=0
output_txt=0
EOF
fi

# Jump into the media folder to do the work
cd "${__dir}"

# 1. Extract Subtitles Atomically
printf "[post-process.sh] %bExtracting subtitles...%b\n" "$GREEN" "$NC"
ln -sf "${__path}" "${__safe_symlink}"
$__ffmpeg -y -v error -f lavfi -i movie="${__safe_symlink}[out+subcc]" -map 0:1 "${__temp_srt}" || true
rm -f "${__safe_symlink}"

# Validate, strip BOM, and atomically move the SRT
if [ -f "${__temp_srt}" ]; then
    if [ -s "${__temp_srt}" ]; then
        # Strip potential BOM (Byte Order Mark) that chokes Jellyfin's ffprobe
        sed -i '1s/^\xEF\xBB\xBF//' "${__temp_srt}"
        # Atomically rename so Jellyfin only scans a 100% completed file
        mv "${__temp_srt}" "${__final_srt}"
    else
        rm -f "${__temp_srt}"
    fi
fi

# 2. Dynamically Detect Audio Channels at 3 Minutes (180s)
printf "[post-process.sh] %bDetecting audio channels at 3-minute mark (10MB sample)...%b\n" "$GREEN" "$NC"

# Use ffmpeg to safely extract a 10MB sample of audio at the 3-minute mark
$__ffmpeg -y -v error -ss 180 -i "${__path}" -map 0:a:0 -c copy -fs 10M "${__probe_file}" || true

set +o errexit
if [ -f "${__probe_file}" ]; then
    __detected_channels=$("$__ffprobe" -v error -i "${__probe_file}" -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 | head -n 1)
    rm -f "${__probe_file}"
else
    __detected_channels=""
fi
set -o errexit

# Fallback to 2 channels if probe fails, returns empty, or returns non-numeric
if ! [[ "$__detected_channels" =~ ^[0-9]+$ ]]; then
    printf "[post-process.sh] %bDetection failed or file too short. Defaulting to 2 channels.%b\n" "$GREEN" "$NC"
    __detected_channels=2
else
    printf "[post-process.sh] %bDetected %s channels. Locking audio track to %s channels.%b\n" "$GREEN" "$__detected_channels" "$__detected_channels" "$NC"
fi

# 3. Sanitize Video, Strip Junk Data, and Normalize Audio
printf "[post-process.sh] %bSanitizing video and normalizing audio...%b\n" "$GREEN" "$NC"
$__ffmpeg -y -err_detect ignore_err -i "${__path}" -map 0:v -map 0:a -map 0:s? -c:v copy -c:a ac3 -ac "${__detected_channels}" -fflags +genpts "${__sanitized_ts}" -loglevel warning

# 4. Run Comskip to generate the .ffmeta chapter file
printf "[post-process.sh] %bAnalyzing commercials...%b\n" "$GREEN" "$NC"
$__comskip --ini="$__comskip_ini" "${__sanitized_ts}" || true

# 5. Inject Chapters and Remux to MKV
printf "[post-process.sh] %bInjecting chapters and creating MKV...%b\n" "$GREEN" "$NC"
__meta_file="${__dir}/.${__base}_sanitized.ffmeta"

if [ -f "${__meta_file}" ]; then
    $__ffmpeg -y -i "${__sanitized_ts}" -i "${__meta_file}" -map_metadata 1 -map 0:v -map 0:a -map 0:s? -c copy "${__temp_mkv}" -loglevel warning
else
    # Fallback
    $__ffmpeg -y -i "${__sanitized_ts}" -map 0:v -map 0:a -map 0:s? -c copy "${__temp_mkv}" -loglevel warning
fi

# Atomically move the completed MKV into place so Jellyfin scans it once
mv "${__temp_mkv}" "${__final_mkv}"

# 6. Clean up temporary files AND the original broken TS file
printf "[post-process.sh] %bCleaning up...%b\n" "$GREEN" "$NC"
rm -f "${__path}" "${__sanitized_ts}" "${__meta_file}" "${__dir}/.${__base}_sanitized.log" "${__dir}/.${__base}_sanitized.txt" "${__dir}/.${__base}_sanitized.logo.txt" "${__dir}/.${__base}_sanitized.edl"

cd "${PWD}"
