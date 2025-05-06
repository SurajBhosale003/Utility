#!/bin/bash

# Ask for input video and title
read -p "Enter full path to the .mp4 file: " input_video
read -p "Enter video title (used for folder name): " title

# Start global timer
SECONDS=0
declare -A processing_times

# Create base folder
mkdir -p "$title/audio"

# Get original resolution
original_resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
                       -of csv=s=x:p=0 "$input_video")
original_width=$(echo "$original_resolution" | cut -d'x' -f1)
original_height=$(echo "$original_resolution" | cut -d'x' -f2)

# Define standard resolutions and bitrates (descending order)
resolutions=( "2560x1440" "1920x1080" "1280x720" "854x480" "640x360" )
bitrates=( "5000k" "3000k" "1500k" "800k" "500k" )
labels=( "v1440p" "v1080p" "v720p" "v480p" "v360p" )

# Filter only resolutions lower or equal to original
valid_indices=()
for i in "${!resolutions[@]}"; do
  res="${resolutions[$i]}"
  w=$(echo "$res" | cut -d'x' -f1)
  h=$(echo "$res" | cut -d'x' -f2)
  if (( w <= original_width && h <= original_height )); then
    valid_indices+=($i)
  fi
done

# Step 1: Extract and encode audio once
start_audio=$SECONDS
ffmpeg -i "$input_video" -map a -c:a aac -b:a 128k -ac 2 -f hls -hls_time 10 \
  -hls_list_size 0 \
  -hls_segment_filename "$title/audio/segment_%03d.ts" "$title/audio/audio.m3u8"
end_audio=$SECONDS
processing_times["Audio"]=$((end_audio - start_audio))
echo "✅ Audio HLS created"

# Step 2: Transcode video-only variants
for i in "${valid_indices[@]}"; do
  res="${resolutions[$i]}"
  br="${bitrates[$i]}"
  label="${labels[$i]}"
  out_dir="$title/$label"
  mkdir -p "$out_dir"

  start_res=$SECONDS
  ffmpeg -i "$input_video" -an -vf "scale=$res" -c:v libx264 -b:v "$br" \
         -f hls -hls_time 10 -hls_list_size 0 \
         -hls_segment_filename "$out_dir/segment_%03d.ts" \
         "$out_dir/${title}_${label}_player.m3u8"
  end_res=$SECONDS
  processing_times["$label"]=$((end_res - start_res))

  echo "✅ Created $label at resolution $res"
done

# Step 2.5: Fallback - Add original resolution if none matched
add_original_to_master=false
if [ ${#valid_indices[@]} -eq 0 ]; then
  echo "⚠️ No matching standard resolution. Using original resolution: $original_resolution"

  out_dir="$title/original"
  mkdir -p "$out_dir"

  start_orig=$SECONDS
  ffmpeg -i "$input_video" -an -c:v libx264 -b:v 300k \
         -f hls -hls_time 10 -hls_list_size 0 \
         -hls_segment_filename "$out_dir/segment_%03d.ts" \
         "$out_dir/${title}_original_player.m3u8"
  end_orig=$SECONDS
  processing_times["original"]=$((end_orig - start_orig))

  add_original_to_master=true
fi

# Step 3: Create master playlist with shared audio
master="$title/master.m3u8"
echo "#EXTM3U" > "$master"
echo "#EXT-X-VERSION:3" >> "$master"
echo "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"English\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio/audio.m3u8\"" >> "$master"

for i in "${valid_indices[@]}"; do
  res="${resolutions[$i]}"
  br="${bitrates[$i]//k/000}"
  label="${labels[$i]}"
  echo "#EXT-X-STREAM-INF:BANDWIDTH=$br,RESOLUTION=$res,AUDIO=\"audio\"" >> "$master"
  echo "$label/${title}_${label}_player.m3u8" >> "$master"
done

# Add original to master if needed
if [ "$add_original_to_master" = true ]; then
  echo "#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=$original_resolution,AUDIO=\"audio\"" >> "$master"
  echo "original/${title}_original_player.m3u8" >> "$master"
fi

echo "🎉 Master playlist created at: $master"

# Step 4: Create 15-sec previews in valid resolutions
preview_resolutions=( "1280x720" "854x480" "640x360" )
preview_labels=( "HDpreview" "SDpreview" "LDpreview" )
preview_audio_flags=( "-c:a aac -b:a 96k" "-c:a aac -b:a 64k" "-an" )

# Get video duration
duration=$(ffprobe -v error -show_entries format=duration \
                   -of default=noprint_wrappers=1:nokey=1 "$input_video")
duration=${duration%.*}

if (( duration > 30 )); then
  max_start=$((duration - 15))
  start=$((RANDOM % max_start))
else
  start=0
fi

for i in "${!preview_resolutions[@]}"; do
  res="${preview_resolutions[$i]}"
  label="${preview_labels[$i]}"
  audio_flag="${preview_audio_flags[$i]}"
  w=$(echo "$res" | cut -d'x' -f1)
  h=$(echo "$res" | cut -d'x' -f2)

  if (( w > original_width || h > original_height )); then
    echo "⏩ Skipping $label ($res) - higher than source resolution ($original_resolution)"
    continue
  fi

  out_dir="$title/preview/$label"
  mkdir -p "$out_dir"

  start_preview=$SECONDS
  ffmpeg -ss "$start" -i "$input_video" -t 15 \
         -vf "scale=$res" -c:v libx264 -preset veryfast -crf 28 \
         $audio_flag "$out_dir/${label}.mp4"
  end_preview=$SECONDS
  processing_times["$label Preview"]=$((end_preview - start_preview))

  echo "🎞️ Created $label preview at: $out_dir/${label}.mp4"
done

# Step 4.5: Add original resolution preview
out_dir="$title/preview/originalpreview"
mkdir -p "$out_dir"

start_preview_orig=$SECONDS
ffmpeg -ss "$start" -i "$input_video" -t 15 \
       -c:v libx264 -preset veryfast -crf 23 \
       -c:a aac -b:a 128k "$out_dir/original.mp4"
end_preview_orig=$SECONDS
processing_times["Original Preview"]=$((end_preview_orig - start_preview_orig))

echo "🎞️ Created Original resolution preview at: $out_dir/original.mp4"

# Final Summary
echo ""
echo "⏱️ Processing Time Summary:"
for key in "${!processing_times[@]}"; do
  duration=${processing_times[$key]}
  printf "   %s : %02d:%02d\n" "$key" $((duration/60)) $((duration%60))
done

echo ""
echo "🧮 Total Time: $(printf '%02d:%02d\n' $((SECONDS/60)) $((SECONDS%60)))"
