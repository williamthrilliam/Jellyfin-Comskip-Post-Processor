# Jellyfin OTA Comskip Post-Processor (Zero-Transcode MKV)

A highly resilient, standalone commercial detection and post-processing pipeline for Jellyfin DVR. Designed specifically for bare-metal Ubuntu environments recording Over-The-Air (OTA) `.ts` broadcasts, this script effortlessly leverages hardware acceleration (perfect for integrated Intel GPUs) to process video without relying on CPU-heavy transcoding.

## The Problem This Solves

Recording OTA television is the wild west. Atmospheric interference, signal drops, and mid-stream audio layout changes result in heavily corrupted `.ts` files. 

When feeding these raw files into standard wrapper scripts (like `comchap`), you will inevitably encounter:
* **Comskip Segmentation Faults:** Corrupted video frames crash the analyzer, leaving you with unprocessed files.
* **The `lavfi` Apostrophe Bug:** FFmpeg fails to extract subtitles if the TV show has an apostrophe in its filename (e.g., *Mork & Mindy* or *Grey's Anatomy*).
* **The Inotify Race Condition:** Jellyfin's real-time folder monitor attempts to scan replacement files before FFmpeg finishes writing them, resulting in broken playback and missing chapters.
* **Audio Track Failures:** Simple 1-second probes fail to detect audio channels because MPEG-TS files interleave their stream headers periodically, not continuously.

## Script 1: `post-processor.sh` (The Deep Dive)

This script replaces your `.ts` files with pristine `.mkv` files containing embedded commercial chapters. It uses a lightning-fast "Stream Copy" to bypass transcoding entirely. Here is exactly how it works under the hood:

### 1. Atomic Subtitle Extraction & BOM Stripping
The script creates a temporary, randomized symlink (e.g., `temp_lavfi_input_12345.ts`) in the `/tmp/` directory that points to your media file. This strips out all spaces and punctuation, bypassing FFmpeg's fragile `lavfi` filter bugs so subtitles always extract perfectly. It also utilizes `sed` to strip out hidden Byte Order Marks (BOM) that occasionally cause Jellyfin's scanner to choke on `.srt` files.

### 2. Dynamic Audio Channel Detection (The 10MB Probe)
Instead of forcing all recordings to 2-channel stereo, the script dynamically detects the show's native audio layout. Because `.ts` audio headers are broadcast periodically, the script jumps 3 minutes into the recording (bypassing chaotic local intro commercials) and extracts a **10MB sample** using `-fs 10M`. This guarantees `ffprobe` captures the correct header and perfectly maps 5.1 surround sound or 2.channel stereo.

### 3. Stream Sanitization
Before Comskip even touches the file, FFmpeg performs a stream copy into a hidden temporary file. During this copy, FFmpeg drops corrupted packets, repairs broken `pts`/`dts` timestamps, and strips out incompatible SCTE-35 broadcast data. 

### 4. Hardware-Accelerated Comskip Analysis
Because the stream is now perfectly sanitized, Comskip can safely run at maximum speed using multi-threading and hardware decoding without encountering segmentation faults. (If `comskip.ini` is accidentally deleted, the script will self-heal and auto-generate a replacement to guarantee `.ffmeta` output).

### 5. MKV Chapter Injection & Atomic Renaming
The script injects the generated `.ffmeta` commercial markers into an MKV container. To prevent Jellyfin's scanner from reading an incomplete file, the script writes to a hidden file (e.g., `._working.mkv`). Once 100% complete, it performs an atomic `mv` command to reveal the final `.mkv` file to Jellyfin.

### 6. Clean Swap
The original corrupted `.ts` file and all temporary Comskip bloat files (`.log`, `.txt`, `.logo.txt`, `.edl`) are wiped, leaving a pristine folder.

---

## Script 2: `batch-comskip.sh` (Bulk Processing)

If you have an existing library of unprocessed `.ts` recordings, this script allows you to retroactively sanitize them, detect commercials, and remux them to MKV.

* **Absolute Pathing:** Uses `BASH_SOURCE[0]` to guarantee it never loses track of the post-processor script, regardless of the directory you execute it from.
* **Hidden File Exclusion:** Uses the `-not -path "*/\.*"` flag to strictly ignore hidden temporary files, preventing infinite loops or processing errors.
* **Stdin Protection:** Pipes `/dev/null` into the execution command, preventing FFmpeg from accidentally "eating" the `find` loop output.

**Usage:** `sudo ./batch-comskip.sh "/path/to/your/media/folder"`

---

## Requirements
* Bare-metal Ubuntu
* Jellyfin (Installed via `apt` so `/usr/lib/jellyfin-ffmpeg/ffmpeg` is present)
* Comskip (`sudo apt install comskip`)
* The official Jellyfin **Chapter Segments Provider** plugin.

## Installation & Configuration

1. Place `post-processor.sh`, `batch-comskip.sh`, and `comskip.ini` in a secure directory (e.g., `/opt/jellyfin-dvr-comskip/`).
2. Make the scripts executable: 
   `sudo chmod +x /opt/jellyfin-dvr-comskip/*.sh`
3. Give the jellyfin user ownership so it can read the INI file: 
   `sudo chown -R jellyfin:jellyfin /opt/jellyfin-dvr-comskip/`

### Jellyfin UI Setup
1. Navigate to **Dashboard > Live TV > Recording Post Processing**:
   * **Post-processing application:** `/opt/jellyfin-dvr-comskip/post-processor.sh`
   * **Post-processing command line arguments:** `"{path}"`
2. Navigate to **Dashboard > Plugins > Chapter Segments Provider**:
   * Change the **Commercials RegEx** field to: `(?i)commercial`
3. In your **User Profile > Playback**, ensure the **Commercial** segment action is set to **Ask to Skip**.
