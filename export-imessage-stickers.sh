#!/usr/bin/env bash
# Export every sticker in the iMessage sticker drawer synced to this Mac into one folder, so the
# whole drawer can be imported into Big Time Stickers in a single "Import a Whole Folder" step.
#
# Requirements: a Mac signed into the same Apple Account as the iPhone, with Messages in iCloud on
# (System Settings → Apple Account → iCloud → Messages). The sticker daemon keeps the synced drawer
# in a Core Data store (stickers.stickerdb); each sticker's full-size image (900 px HEIC, or an
# animated HEICS for Live Stickers) is stored inline, and that is what this script writes out.
# The store is only ever read: it is copied to a temp folder first and the copy is queried.
#
# Usage: bash export-imessage-stickers.sh [destination-folder]
#   Download: https://lpelosi.github.io/big-time-stickers-site/export-imessage-stickers.sh
#   default destination: iCloud Drive/iMessage Stickers Export (shows up in Files on the iPhone),
#   falling back to ~/Desktop/iMessage Stickers Export when iCloud Drive is off.
#   Each run writes a fresh, date-stamped subfolder (iCloud Drive makes "sticker-NNN 2" conflict copies
#   when files of the same name are rewritten while it is still syncing) and removes older runs, so the
#   destination always holds exactly one current export.
set -euo pipefail

ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
if [[ $# -ge 1 ]]; then
  BASE="$1"
elif [[ -d "$ICLOUD" ]]; then
  BASE="$ICLOUD/iMessage Stickers Export"
else
  BASE="$HOME/Desktop/iMessage Stickers Export"
fi
RUN="$(date '+%Y-%m-%d %H.%M')"
DEST="$BASE/$RUN"

STORE="$HOME/Library/Group Containers/com.apple.stickersd.group/Stickers"
DB="$STORE/stickers.stickerdb"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"; mkdir -p "$STAGE"

uti_ext() {
  case "$1" in
    public.heic) echo heic ;; public.heics) echo heics ;; public.png) echo png ;;
    com.compuserve.gif) echo gif ;; public.jpeg) echo jpg ;; org.webmproject.webp) echo webp ;;
    public.tiff) echo tiff ;; *) echo "" ;;
  esac
}

mime_ext() {
  case "$(file -b --mime-type "$1" 2>/dev/null)" in
    image/png) echo png ;; image/heic|image/heif) echo heic ;; image/heic-sequence|image/heif-sequence) echo heics ;;
    image/gif) echo gif ;; image/webp) echo webp ;; image/jpeg) echo jpg ;; image/tiff) echo tiff ;; *) echo img ;;
  esac
}

drawer_total=0
raw=0

if [[ -f "$DB" ]]; then
  # Snapshot the store (main file plus WAL/SHM so uncommitted-to-main changes are included).
  if ! cp "$DB" "$WORK/" 2>/dev/null; then
    echo "macOS blocked access to the sticker store at:"
    echo "  $DB"
    echo "Give Terminal Full Disk Access (System Settings → Privacy & Security → Full Disk Access), then rerun."
    exit 1
  fi
  for suffix in -wal -shm; do [[ -f "$DB$suffix" ]] && cp "$DB$suffix" "$WORK/" || true; done
  SNAP="$WORK/$(basename "$DB")"

  drawer_total="$(sqlite3 "$SNAP" 'select count(*) from ZMANAGEDSTICKER;')"
  if [[ "$drawer_total" -eq 0 ]]; then
    echo "The sticker store is empty. Is Messages in iCloud on, and has it finished syncing?"
    exit 1
  fi

  # One file per sticker: its preferred representation (full-size still, or the animated sequence
  # for Live Stickers), in drawer order (newest first, as the sticker keyboard shows them).
  # The sticker's own name, when it has one, is kept in the file name.
  mkdir -p "$STAGE/raw"
  sqlite3 -batch -noheader -separator '|' "$SNAP" "
    select printf('%05d', row_number() over (order by s.ZLIBRARYINDEX desc, s.Z_PK desc)),
           coalesce(r.ZUTI, ''),
           replace(replace(coalesce(nullif(trim(s.ZNAME), ''), ''), '/', '-'), '|', '-'),
           writefile('$STAGE/raw/' || printf('%05d', row_number() over (order by s.ZLIBRARYINDEX desc, s.Z_PK desc)), r.ZDATA)
    from ZMANAGEDSTICKER s
    join ZMANAGEDREPRESENTATION r on r.ZSTICKER = s.Z_PK
    where r.ZISPREFERRED = 1
      and r.Z_PK = (select min(Z_PK) from ZMANAGEDREPRESENTATION where ZSTICKER = s.Z_PK and ZISPREFERRED = 1)
    order by s.ZLIBRARYINDEX desc, s.Z_PK desc;" > "$WORK/rows.txt"
  raw="$(wc -l < "$WORK/rows.txt" | tr -d ' ')"
else
  # Older macOS layouts: no database, so fall back to walking the known sticker caches and keeping
  # whatever is an image. Quality may be keyboard-size only.
  CANDIDATES=(
    "$HOME/Library/Group Containers/com.apple.stickersd.group"
    "$HOME/Library/Stickers"
    "$HOME/Library/Containers/com.apple.Stickers.UserGenerated.MessagesExtension/Data/Library/Caches/com.apple.StickersUI"
  )
  found_any_dir=false
  mkdir -p "$STAGE/raw"
  : > "$WORK/rows.txt"
  for dir in "${CANDIDATES[@]}"; do
    [[ -d "$dir" ]] || continue
    found_any_dir=true
    find "$dir" -type f \( -iname '*.png' -o -iname '*.apng' -o -iname '*.heic' -o -iname '*.heics' \
         -o -iname '*.heif' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.jpg' -o -iname '*.jpeg' \) \
         -size +1k 2>/dev/null | sort | while IFS= read -r f; do
      raw=$((raw + 1)); key="$(printf '%05d' "$raw")"
      cp -p "$f" "$STAGE/raw/$key"
      echo "$key||" >> "$WORK/rows.txt"
    done
  done
  if [[ "$found_any_dir" == false ]]; then
    echo "No sticker store found on this Mac."
    echo "Turn on Messages in iCloud on both devices (System Settings → Apple Account → iCloud → Messages),"
    echo "give it a few minutes to sync, then run this again."
    exit 1
  fi
  raw="$(wc -l < "$WORK/rows.txt" | tr -d ' ')"
  drawer_total="$raw"
  if [[ "$raw" -eq 0 ]]; then
    echo "The sticker store exists but holds no image files yet. Is Messages in iCloud on, and has it finished syncing?"
    exit 1
  fi
  echo "Note: no stickers.stickerdb on this Mac; exported from the sticker caches instead (may be keyboard-size copies)."
fi

# De-duplicate byte-identical stickers (iCloud sync sometimes stores the same sticker twice) and
# give the survivors their final names.
count=0; skipped=0; animated=0
: > "$WORK/seen"
while IFS='|' read -r key uti name _; do
  src="$STAGE/raw/$key"
  [[ -s "$src" ]] || continue
  hash="$(md5 -q "$src")"
  if grep -qx "$hash" "$WORK/seen"; then skipped=$((skipped + 1)); continue; fi
  echo "$hash" >> "$WORK/seen"
  ext="$(uti_ext "$uti")"
  [[ -n "$ext" ]] || ext="$(mime_ext "$src")"
  [[ "$ext" == heics || "$ext" == gif ]] && animated=$((animated + 1))
  count=$((count + 1))
  suffix=""
  if [[ -n "$name" ]]; then
    suffix="-$(printf '%s' "$name" | tr -cs 'A-Za-z0-9 _-' '_' | cut -c1-40)"
  fi
  mv "$src" "$STAGE/$(printf 'sticker-%03d' "$count")$suffix.$ext"
done < "$WORK/rows.txt"
rm -rf "$STAGE/raw"

# Older runs (and any loose files from the pre-1.4 layout) go away; the new run lands in one move so
# iCloud never sees a half-written folder and never has to reconcile rewritten file names.
mkdir -p "$BASE"
find "$BASE" -mindepth 1 -maxdepth 1 ! -name "$RUN" -exec rm -rf {} +
mv "$STAGE" "$DEST" 2>/dev/null || { mkdir -p "$DEST"; cp -p "$STAGE"/* "$DEST"/; }

echo "Exported $count sticker file(s) ($animated animated) to:"
echo "  $DEST"
[[ $skipped -gt 0 ]] && echo "  ($skipped byte-identical duplicate(s) skipped; the drawer lists $drawer_total entries)"
echo
if [[ "$DEST" == "$ICLOUD"* ]]; then
  echo "Give iCloud a minute to upload, then on the iPhone:"
  echo "  Big Time Stickers → + → Import a Whole Folder → iCloud Drive → iMessage Stickers Export → $RUN"
  echo "  (picking the top folder works too; it only ever holds this one run)."
else
  echo "AirDrop the folder to the iPhone (saves to Files), then: Big Time Stickers → + → Import a Whole Folder."
fi
open "$DEST" >/dev/null 2>&1 || true
