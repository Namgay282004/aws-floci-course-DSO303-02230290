#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <student-id> <file-path>" >&2
  exit 1
fi

STUDENT_ID="$1"
FILE_PATH="$2"

if [ ! -f "$FILE_PATH" ]; then
  echo "Error: File '$FILE_PATH' does not exist." >&2
  exit 1
fi

FILENAME=$(basename "$FILE_PATH")
BUCKET_NAME="${USMS_BUCKET_NAME:-usms-student-data}"

echo "Uploading $FILENAME for student $STUDENT_ID to s3://$BUCKET_NAME/transcripts/$STUDENT_ID/$FILENAME..."
aws s3 cp "$FILE_PATH" "s3://$BUCKET_NAME/transcripts/$STUDENT_ID/$FILENAME"
