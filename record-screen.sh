#!/usr/bin/env bash

set -euo pipefail

# Configuration
OUTPUT_DIR="$HOME/Videos"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Declare global variables
declare -a CMD
declare -a VCODEC_OPTS
VIDEO_SIZE=""
OFFSET_X=""
OFFSET_Y=""
MIC_DEVICE=""
SYS_DEVICE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

# Check dependencies
check_dependencies() {
    local missing_deps=()
    for cmd in ffmpeg xrandr pactl fzf; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_info "Install them with: sudo apt install ffmpeg x11-xserver-utils pulseaudio-utils fzf"
        exit 1
    fi
}

# ===== SCREEN SELECTION =====
select_screen() {
    print_info "Detecting available screens..."

    # Get all connected screens with their geometry
    mapfile -t SCREEN_DATA < <(xrandr | grep " connected" | \
        awk '{
            screen=$1;
            for(i=2;i<=NF;i++) {
                if($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
                    print screen"|"$i;
                    break;
                } else if($i == "primary") {
                    continue;
                }
            }
        }')

    if [[ ${#SCREEN_DATA[@]} -eq 0 ]]; then
        print_error "No connected screens found!"
        exit 1
    fi

    # Create display options for fzf
    local display_options=()
    for entry in "${SCREEN_DATA[@]}"; do
        IFS='|' read -r screen_name geometry <<< "$entry"
        local resolution=$(echo "$geometry" | cut -d+ -f1)
        local is_primary=$(xrandr | grep "^$screen_name connected primary" &>/dev/null && echo " [PRIMARY]" || echo "")
        display_options+=("$screen_name${is_primary} - $resolution")
    done

    print_success "Found ${#SCREEN_DATA[@]} screen(s)"
    echo ""

    # Let user select screen
    local selected
    selected=$(printf '%s\n' "${display_options[@]}" | \
        fzf --prompt="Select screen to record ❯ " \
            --header="Use arrow keys to navigate, Enter to select" \
            --height=~40% \
            --border \
            --reverse)

    if [[ -z "$selected" ]]; then
        print_error "No screen selected. Exiting."
        exit 1
    fi

    # Extract screen name from selection
    local screen_name=$(echo "$selected" | awk '{print $1}')

    # Find geometry for selected screen
    for entry in "${SCREEN_DATA[@]}"; do
        IFS='|' read -r name geometry <<< "$entry"
        if [[ "$name" == "$screen_name" ]]; then
            VIDEO_SIZE=$(echo "$geometry" | cut -d+ -f1)
            OFFSET_X=$(echo "$geometry" | cut -d+ -f2)
            OFFSET_Y=$(echo "$geometry" | cut -d+ -f3)
            print_success "Selected: $screen_name ($VIDEO_SIZE at +$OFFSET_X+$OFFSET_Y)"
            return 0
        fi
    done

    print_error "Failed to get screen geometry"
    exit 1
}

# ===== AUDIO SOURCE SELECTION =====
select_audio_sources() {
    # Get microphone inputs
    mapfile -t MIC_INPUTS < <(pactl list short sources | grep -E "input|alsa_input" | awk '{print $2"|"$1}' || true)

    # Get system audio (monitor) sources
    mapfile -t SYS_INPUTS < <(pactl list short sources | grep monitor | awk '{print $2"|"$1}' || true)

    # Prepare audio selection menu
    local audio_options=()
    audio_options+=("No audio")

    [[ ${#MIC_INPUTS[@]} -gt 0 ]] && audio_options+=("Microphone only")
    [[ ${#SYS_INPUTS[@]} -gt 0 ]] && audio_options+=("System audio only")
    [[ ${#MIC_INPUTS[@]} -gt 0 && ${#SYS_INPUTS[@]} -gt 0 ]] && audio_options+=("Both (Microphone + System)")

    echo ""
    print_info "Audio source selection..."

    local audio_choice
    audio_choice=$(printf '%s\n' "${audio_options[@]}" | \
        fzf --prompt="Select audio source ❯ " \
            --header="Choose what audio to record" \
            --height=~30% \
            --border \
            --reverse || echo "No audio")

    if [[ -z "$audio_choice" ]]; then
        audio_choice="No audio"
    fi

    MIC_DEVICE=""
    SYS_DEVICE=""

    case "$audio_choice" in
        "No audio")
            print_info "Recording without audio"
            ;;
        "Microphone only")
            if ! MIC_DEVICE=$(select_specific_device "microphone" "${MIC_INPUTS[@]}"); then
                print_error "No microphone selected"
                exit 1
            fi
            ;;
        "System audio only")
            if ! SYS_DEVICE=$(select_specific_device "system audio" "${SYS_INPUTS[@]}"); then
                print_error "No system audio selected"
                exit 1
            fi
            ;;
        "Both (Microphone + System)")
            if ! MIC_DEVICE=$(select_specific_device "microphone" "${MIC_INPUTS[@]}"); then
                print_error "No microphone selected"
                exit 1
            fi
            if ! SYS_DEVICE=$(select_specific_device "system audio" "${SYS_INPUTS[@]}"); then
                print_error "No system audio selected"
                exit 1
            fi
            ;;
    esac
}

# Select specific audio device
select_specific_device() {
    local device_type=$1
    shift
    local devices=("$@")

    if [[ ${#devices[@]} -eq 0 ]]; then
        print_warning "No $device_type devices found" >&2
        return 1
    fi

    if [[ ${#devices[@]} -eq 1 ]]; then
        local device_name=$(echo "${devices[0]}" | cut -d'|' -f1)
        print_success "Auto-selected $device_type: $device_name" >&2
        echo "$device_name"
        return 0
    fi

    # Multiple devices - let user choose
    local display_options=()
    for entry in "${devices[@]}"; do
        IFS='|' read -r name idx <<< "$entry"
        display_options+=("$name")
    done

    echo "" >&2
    local selected
    selected=$(printf '%s\n' "${display_options[@]}" | \
        fzf --prompt="Select $device_type ❯ " \
            --header="Choose which $device_type device to use" \
            --height=~30% \
            --border \
            --reverse || true)

    if [[ -n "$selected" ]]; then
        print_success "Selected $device_type: $selected" >&2
        echo "$selected"
        return 0
    else
        return 1
    fi
}

# ===== QUALITY SELECTION =====
select_quality() {
    echo ""
    print_info "Quality selection..."

    local quality_options=(
        "Low - Fast encoding, larger file (CRF 35, ultrafast preset)"
        "Medium - Balanced quality and speed (CRF 28, veryfast preset)"
        "High - Best quality, slower encoding (CRF 18, slow preset)"
    )

    local selected
    selected=$(printf '%s\n' "${quality_options[@]}" | \
        fzf --prompt="Select quality ❯ " \
            --header="Higher quality = better video but slower encoding" \
            --height=~30% \
            --border \
            --reverse || echo "Medium - Balanced quality and speed (CRF 28, veryfast preset)")

    local quality=$(echo "$selected" | awk '{print $1}')
    quality=${quality:-Medium}

    case $quality in
        "Low")
            VCODEC_OPTS=(-c:v libx264 -preset ultrafast -crf 35 -pix_fmt yuv420p)
            ;;
        "Medium")
            VCODEC_OPTS=(-c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p)
            ;;
        "High")
            VCODEC_OPTS=(-c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p)
            ;;
    esac

    print_success "Quality set to: $quality"
}

# ===== BUILD FFMPEG COMMAND =====
build_ffmpeg_command() {
    local output_file="$OUTPUT_DIR/recording_${TIMESTAMP}.mp4"

    # Start with video input
    CMD=(ffmpeg -y -loglevel warning -stats)
    CMD+=(-video_size "$VIDEO_SIZE" -framerate 30 -f x11grab -i ":0.0+$OFFSET_X,$OFFSET_Y")

    # Add audio inputs
    local audio_input_count=0

    if [[ -n "${MIC_DEVICE:-}" ]]; then
        CMD+=(-f pulse -i "$MIC_DEVICE")
        audio_input_count=$((audio_input_count + 1))
    fi

    if [[ -n "${SYS_DEVICE:-}" ]]; then
        CMD+=(-f pulse -i "$SYS_DEVICE")
        audio_input_count=$((audio_input_count + 1))
    fi

    # Add video codec options
    CMD+=("${VCODEC_OPTS[@]}")

    # Handle audio encoding based on number of inputs
    if [[ $audio_input_count -eq 2 ]]; then
        # Both mic and system audio - mix them
        CMD+=(-filter_complex "[1:a][2:a]amix=inputs=2:duration=longest:normalize=0[aout]")
        CMD+=(-map 0:v -map "[aout]" -c:a aac -b:a 192k)
    elif [[ $audio_input_count -eq 1 ]]; then
        # Single audio source
        CMD+=(-map 0:v -map 1:a -c:a aac -b:a 192k)
    else
        # No audio
        CMD+=(-map 0:v)
    fi

    # Output file
    CMD+=("$output_file")
}

# ===== DISPLAY SUMMARY =====
display_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    print_success "Recording Configuration"
    echo "═══════════════════════════════════════════════════════"
    echo -e "${BLUE}Screen:${NC}        $VIDEO_SIZE at offset +$OFFSET_X+$OFFSET_Y"
    echo -e "${BLUE}Quality:${NC}       ${VCODEC_OPTS[3]} (CRF ${VCODEC_OPTS[5]})"
    echo -e "${BLUE}Microphone:${NC}    ${MIC_DEVICE:-None}"
    echo -e "${BLUE}System Audio:${NC}  ${SYS_DEVICE:-None}"
    echo -e "${BLUE}Output:${NC}        $OUTPUT_DIR/recording_${TIMESTAMP}.mp4"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    print_warning "Press Ctrl+C to stop recording"
    echo ""
}

# ===== CLEANUP ON EXIT =====
cleanup() {
    echo ""
    print_success "Recording stopped"

    local output_file="$OUTPUT_DIR/recording_${TIMESTAMP}.mp4"
    if [[ -f "$output_file" ]]; then
        local file_size=$(du -h "$output_file" | cut -f1)
        print_success "Saved: $output_file ($file_size)"
    fi
}

trap cleanup EXIT

# ===== MAIN EXECUTION =====
main() {
    clear
    echo "═══════════════════════════════════════════════════════"
    echo -e "${GREEN}      Screen Recorder with Audio Support${NC}"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    check_dependencies
    select_screen
    select_audio_sources
    select_quality
    build_ffmpeg_command
    display_summary

    # Start recording
    "${CMD[@]}"
}

main
