#!/bin/bash

# ==============================
# FZF Interactive FFmpeg Screen Recorder
# ==============================

OUTPUT_DIR=~/Videos
mkdir -p "$OUTPUT_DIR"
OUTPUT="$OUTPUT_DIR/recording_$(date +%Y-%m-%d_%H-%M-%S).mp4"

# ------------------------------
# 1. Select Screen
# ------------------------------
echo "Select screen to record:"
SCREEN=$(xrandr | grep " connected" | awk '{print $1}' | fzf --prompt="Screen> ")

if [[ -z "$SCREEN" ]]; then
    echo "❌ No screen selected, exiting."
    exit 1
fi

SCREEN_INFO=$(xrandr | grep "^$SCREEN connected" | awk '{print $3}')
RESOLUTION=$(echo $SCREEN_INFO | cut -d'+' -f1)
POS_X=$(echo $SCREEN_INFO | cut -d'+' -f2)
POS_Y=$(echo $SCREEN_INFO | cut -d'+' -f3)

echo "👉 Screen: $SCREEN ($RESOLUTION at +$POS_X,$POS_Y)"

# ------------------------------
# 2. Select Audio Inputs
# ------------------------------
echo
echo "Select microphone input (or press ESC to skip):"
MIC_SRC=$(pactl list short sources | awk '{print $2}' | fzf --prompt="Microphone> " --exit-0)

if [[ -n "$MIC_SRC" ]]; then
    echo "👉 Mic: $MIC_SRC"
fi

echo
echo "Select system audio input (or press ESC to skip):"
SYS_SRC=$(pactl list short sources | awk '{print $2}' | fzf --prompt="System Audio> " --exit-0)

if [[ -n "$SYS_SRC" ]]; then
    echo "👉 System Audio: $SYS_SRC"
fi

# ------------------------------
# 3. Select Quality
# ------------------------------
echo
QUALITY=$(printf "High\nMedium\nLow" | fzf --prompt="Quality> ")

case $QUALITY in
    High)
        VIDEO_CODEC="-c:v libx264 -preset slow -crf 18"
        AUDIO_CODEC="-c:a aac -b:a 256k"
        ;;
    Medium)
        VIDEO_CODEC="-c:v libx264 -preset veryfast -crf 23"
        AUDIO_CODEC="-c:a aac -b:a 192k"
        ;;
    Low)
        VIDEO_CODEC="-c:v libx264 -preset ultrafast -crf 30"
        AUDIO_CODEC="-c:a aac -b:a 128k"
        ;;
    *)
        echo "❌ No quality selected, exiting."
        exit 1
        ;;
esac

echo "👉 Quality: $QUALITY"

# ------------------------------
# 4. Build ffmpeg command
# ------------------------------
CMD="ffmpeg -f x11grab -s $RESOLUTION -i :0.0+$POS_X,$POS_Y"

if [[ -n "$MIC_SRC" ]]; then
    CMD+=" -f pulse -i $MIC_SRC"
fi

if [[ -n "$SYS_SRC" ]]; then
    CMD+=" -f pulse -i $SYS_SRC"
fi

if [[ -n "$MIC_SRC" && -n "$SYS_SRC" ]]; then
    CMD+=" -filter_complex \"[1:a][2:a]amix=inputs=2:duration=longest[aout]\" -map 0:v -map \"[aout]\""
else
    CMD+=" -map 0:v"
    if [[ -n "$MIC_SRC" || -n "$SYS_SRC" ]]; then
        CMD+=" -map 1:a"
    fi
fi

CMD+=" $VIDEO_CODEC $AUDIO_CODEC $OUTPUT"

# ------------------------------
# 5. Run
# ------------------------------
echo
echo "🚀 Starting recording..."
echo "Output file: $OUTPUT"
echo
eval $CMD
