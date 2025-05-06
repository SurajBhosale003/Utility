#!/bin/bash

# Ask for the destination path in GCS
read -p "Enter the GCS path (e.g., XXXXXgns/1XXX01/X1Xcontent/Cartoons): " DEST_BUCKET

# Folders to exclude
EXCLUDE=("royal_wedding" "iron_mask")

# Log file
LOG_FILE="upload.log"

# Create log file if it doesn't exist
touch "$LOG_FILE"

echo "📦 Starting upload to $DEST_BUCKET"
echo "Using log: $LOG_FILE"
echo "---------------------------------------"

total_start=$(date +%s)

# Function to upload a folder
upload_folder() {
  local dir=$1
  local name=$2

  echo "⬆️  Uploading: $name ..."
  start_time=$(date +%s)

  if gsutil -m cp -r "$dir" "$DEST_BUCKET/"; then
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$name | ✅ Done | ${duration}s | $timestamp" >> "$LOG_FILE"
    echo "✅ Upload successful: $name (Time: ${duration}s)"
  else
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$name | ❌ Failed | $timestamp" >> "$LOG_FILE"
    echo "❌ Upload failed: $name"
  fi
}

# Function to check if folder exists in GCS
check_folder_exists() {
  local folder=$1
  if gsutil -q stat "$DEST_BUCKET/$folder"; then
    return 0  # Folder exists
  else
    return 1  # Folder does not exist
  fi
}

# Loop through all folders in the current directory
for dir in */; do
  name="${dir%/}"

  # Skip if in exclude list
  skip=false
  for ex in "${EXCLUDE[@]}"; do
    if [[ "$name" == "$ex" ]]; then
      echo "⏭️  Skipping excluded folder: $name"
      skip=true
      break
    fi
  done

  # Check if the folder already exists in GCS
  if check_folder_exists "$name"; then
    echo "✅ Folder already exists in GCS: $name (skip: alreadyIn)"
    echo "$name | ⏭️ Skipped (alreadyIn) | $(date "+%Y-%m-%d %H:%M:%S")" >> "$LOG_FILE"
    continue
  fi

  # Skip if already uploaded successfully (from the log file)
  if grep -Fq "$name | ✅ Done" "$LOG_FILE"; then
    echo "✅ Already uploaded: $name (skip: alreadyIn)"
    echo "$name | ⏭️ Skipped (alreadyIn) | $(date "+%Y-%m-%d %H:%M:%S")" >> "$LOG_FILE"
    continue
  fi

  # Upload folder if it's not excluded and not already uploaded
  upload_folder "$dir" "$name"
  echo "---------------------------------------"
done

# Retry failed uploads from the log
echo "📋 Retrying failed uploads..."
while IFS= read -r line; do
  folder=$(echo "$line" | cut -d'|' -f1)
  if ! grep -Fq "$folder | ✅ Done" "$LOG_FILE"; then
    echo "⬆️  Retrying upload for: $folder ..."
    dir="${folder}/"
    upload_folder "$dir" "$folder"
    echo "---------------------------------------"
  fi
done < <(grep "❌ Failed" "$LOG_FILE")

total_end=$(date +%s)
total_duration=$((total_end - total_start))
echo "🎉 All uploads attempted in ${total_duration}s"
echo "✅ Successful uploads: $(grep -c "✅ Done" "$LOG_FILE")"
echo "❌ Failed uploads: $(grep -c "❌ Failed" "$LOG_FILE")"
echo "⏭️ Skipped uploads: $(grep -c "⏭️ Skipped" "$LOG_FILE")"
