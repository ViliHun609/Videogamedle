#!/usr/bin/env bash
# =============================================================================
#  tools/optimize-images.sh  —  MANUAL ONLY
#
#  Not loaded, imported, bundled or called by any HTML/JS file, and it refuses
#  to run inside CI. Run it yourself when you add or replace screenshots.
#
#  Requires: ImageMagick 7 (`magick` + `identify`) and coreutils.
#  Optional: python3, only for --check.
#
#  Quick reference
#    ./tools/optimize-images.sh --check
#        Audit only, encodes nothing: which JSON entries have images, which
#        are missing, folders with no JSON entry, legacy .jpg references,
#        leftover fat .jpg files.
#
#    ./tools/optimize-images.sh
#        Dry run. Encodes into a temp dir and prints a real before/after
#        table. Writes nothing to the project.
#
#    ./tools/optimize-images.sh --only my-game --apply --inplace --format webp --prune --rewrite-paths
#        Add or replace ONE game's pictures. Only files under the game's
#        folder are touched.
#
#    ./tools/optimize-images.sh --apply --inplace --format webp --prune --rewrite-paths
#        Everything. Also fine to run repeatedly: sources that were already
#        converted are gone, so only new/changed files get encoded.
#
#    ./tools/optimize-images.sh --apply --inplace --format jpeg
#        Zero-code-change mode: writes real JPEGs under the canonical .jpg
#        names. Nothing in JSON/HTML/JS has to change.
#
#  Accepted source names / extensions
#    assets/games/<id>/gameplay.{jpg,jpeg,png,JPG,...}
#    assets/games/<id>/preview.{jpg,jpeg,png,...}
#    assets/games/<id>/2gameplay.{jpg,jpeg,png,...}
#    assets/background/*.{jpg,jpeg,png}
#    images/**/*.png
#  Anything else is ignored. A file called screenshot1.png will NOT be picked
#  up — rename it to gameplay.jpg/png or preview.jpg/png.
#
#  Why gameplay images are NOT downscaled:
#    #gamepic uses scale(10), so at 10x zoom only 1/10 of the image width is
#    visible. A 3840px source shows 384 source pixels across ~640 CSS px
#    (1.7x upscale, acceptable). At 1920px it would be 3.3x, visibly mushy.
#    So gameplay keeps its native resolution and only changes codec.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
INPLACE=0
FORCE=0
PRUNE=0
REWRITE=0
CHECK=0
ONLY=""
FORMAT="webp"                 # webp | jpeg | both
OUT_DIR="assets-optimized"
STAMP="$(date +%Y%m%d-%H%M%S)"
# Deliberately OUTSIDE the repo: TMP/ is part of the deployed site, so backups
# there would add ~150 MB to every Netlify upload.
BACKUP_DIR="$ROOT/../Videogamedle-originals-$STAMP"
REPORT=""

GAMEPLAY_MAX=3840             # keep 4K: the 10x zoom needs the pixels
PREVIEW_MAX=320               # shown at <=300px, 320 covers retina
EXTRA_MAX=2560                # backgrounds / unused 2gameplay shots
ICON_MAX=256                  # logo + category icons (displayed 28-80px)
LOADING_MAX=1280
Q_GAMEPLAY=80
Q_PREVIEW=82
Q_EXTRA=72
Q_ICON=86

usage() {
  cat <<'EOF'
Usage: tools/optimize-images.sh [options]

  (default)          dry run: encodes to a temp dir, prints a size table,
                     writes nothing
  --apply            actually write the results
  --inplace          overwrite originals in place / write next to them
                     (implies --apply); originals are copied to
                     ../Videogamedle-originals-<date>/
  --only PATTERN     only process sources whose path contains PATTERN
                     e.g. --only my-game  or  --only assets/background/3
  --format webp      WebP output (default; best size, ~97% browser support)
  --format jpeg      JPEG output under the canonical .jpg name
                     (zero code changes needed)
  --format both      WebP + optimized JPEG fallback
  --prune            move the source file out of the repo once its output is
                     written. Requires --inplace. Not allowed with --format both
                     unless the source is not one of the outputs (e.g. a .png).
  --rewrite-paths    rewrite .jpg -> .webp in JSON/games.json, the HTML pages
                     and shared_background_chooser.js (always global and
                     idempotent). Refuses to run if the anchors are missing.
  --check            audit the image data and exit; encodes nothing
  --out DIR          output dir for --apply without --inplace
                     (default: assets-optimized)
  --quality N        override the quality for every class
  --force            re-encode even if the output is newer / bigger
  --report FILE      also write a Markdown report
  -h, --help         this text

Nothing here is wired into the site. This script is manual-only on purpose.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)    APPLY=1 ;;
    --inplace)  INPLACE=1 ;;
    --force)    FORCE=1 ;;
    --prune)    PRUNE=1 ;;
    --rewrite-paths) REWRITE=1 ;;
    --check)    CHECK=1 ;;
    --only)     ONLY="${2:?--only needs a pattern}"; shift ;;
    --format)   FORMAT="${2:?--format needs a value}"; shift ;;
    --webp)     FORMAT=webp ;;
    --jpeg)     FORMAT=jpeg ;;
    --both)     FORMAT=both ;;
    --out)      OUT_DIR="${2:?--out needs a value}"; shift ;;
    --quality)  Q_GAMEPLAY="${2:?}"; Q_PREVIEW="$2"; Q_EXTRA="$2"; Q_ICON="$2"; shift ;;
    --report)   REPORT="${2:?--report needs a value}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$FORMAT" in webp|jpeg|both) ;; *) echo "bad --format: $FORMAT" >&2; exit 2 ;; esac
[ "$INPLACE" = 1 ] && APPLY=1
if [ "$PRUNE" = 1 ] && [ "$INPLACE" = 0 ]; then
  echo "--prune needs --inplace (otherwise the sources are not what ships)." >&2
  exit 2
fi
if [ -n "${CI:-}" ] && [ "$FORCE" != 1 ]; then
  echo "Refusing to run inside CI. This script is manual-only (use --force to override)." >&2
  exit 1
fi

bytes() { stat -c%s "$1"; }
mb()    { LC_ALL=C awk -v b="$1" 'BEGIN { printf "%.2f", b/1048576 }'; }
pct()   { LC_ALL=C awk -v a="$1" -v c="$2" 'BEGIN{ if (a>0) printf "%.0f%%", (1-c/a)*100; else print "0%" }'; }

# ---------------------------------------------------------------------------
# --check: audit, no encoding
# ---------------------------------------------------------------------------
run_check() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "--check needs python3." >&2
    return 1
  fi
  python3 - <<'PY'
import glob, json, os, re

games = json.load(open('JSON/games.json'))['games']
ok, missing = 0, []
for g in games:
    for kind, p in (g.get('images') or {}).items():
        if not p:
            continue
        if os.path.exists('.' + p):
            ok += 1
        else:
            missing.append((g['id'], kind))

dirs = {os.path.basename(d) for d in glob.glob('assets/games/*') if os.path.isdir(d)}
ids = {g['id'] for g in games}

print("=== IMAGE AUDIT ===")
print(f"JSON entries      : {len(games)} games, {ok} image paths OK, {len(missing)} missing")
for gid, kind in missing[:20]:
    print(f"  missing         : {gid} ({kind})")
if len(missing) > 20:
    print(f"  ... and {len(missing) - 20} more")

print(f"Folders, no JSON  : {len(dirs - ids)}")
for d in sorted(dirs - ids):
    print(f"  extra folder    : assets/games/{d}")
print(f"JSON, no folder   : {len(ids - dirs)}")
for d in sorted(ids - dirs):
    print(f"  no folder       : {d}")

fat = []
for pat in ('assets/games/*/gameplay.*', 'assets/games/*/preview.*',
            'assets/games/*/2gameplay.*', 'assets/background/*'):
    for p in glob.glob(pat):
        if os.path.isfile(p) and os.path.splitext(p)[1].lower() in ('.jpg', '.jpeg', '.png'):
            fat.append(p)
webp = glob.glob('assets/**/*.webp', recursive=True)
print(f"Sources left      : {len(fat)} unoptimized, {len(webp)} .webp")
if fat:
    total = sum(os.path.getsize(f) for f in fat)
    print(f"  unoptimized     : {total / 1048576:.1f} MB — run with --apply --prune")
    for f in sorted(fat)[:10]:
        print(f"    {f} ({os.path.getsize(f) / 1048576:.1f} MB)")
    if len(fat) > 10:
        print(f"    ... and {len(fat) - 10} more")

legacy = []
for f in sorted(glob.glob('*.html')) + sorted(glob.glob('scripts/*.js')) + ['JSON/games.json']:
    if not os.path.exists(f):
        continue
    hits = len(re.findall(r'\.(?:jpg|jpeg)"', open(f, encoding='utf-8', errors='ignore').read()))
    if hits:
        legacy.append((f, hits))
print("Legacy .jpg refs  :", "none" if not legacy else f"{sum(n for _, n in legacy)}")
for f, n in legacy:
    print(f"  {f}: {n}")

bg = sorted(os.path.basename(p) for p in glob.glob('assets/background/*.webp'))
if bg:
    print(f"Backgrounds       : {bg[0]} .. {bg[-1]} ({len(bg)} files)")
PY
}

if [ "$CHECK" = 1 ]; then
  run_check
  exit 0
fi

command -v magick >/dev/null 2>&1 || {
  echo "ERROR: ImageMagick 7 is required (the 'magick' binary)." >&2; exit 1; }
command -v identify >/dev/null 2>&1 || {
  echo "ERROR: ImageMagick 'identify' not found." >&2; exit 1; }
if [ "$FORMAT" != jpeg ] && ! magick -list format 2>/dev/null | grep -qiE '^ *WEBP'; then
  echo "ERROR: this ImageMagick has no WebP delegate. Use --format jpeg." >&2; exit 1
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/imgopt.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# collect inputs (any of .jpg/.jpeg/.png, case-insensitive)
# ---------------------------------------------------------------------------
declare -a ITEMS=()
while IFS= read -r -d '' f; do ITEMS+=("gameplay|$f"); done < <(
  find assets/games -mindepth 2 -maxdepth 2 \
    \( -iname 'gameplay.jpg' -o -iname 'gameplay.jpeg' -o -iname 'gameplay.png' \) \
    -print0 | sort -z)
while IFS= read -r -d '' f; do ITEMS+=("preview|$f"); done < <(
  find assets/games -mindepth 2 -maxdepth 2 \
    \( -iname 'preview.jpg' -o -iname 'preview.jpeg' -o -iname 'preview.png' \) \
    -print0 | sort -z)
while IFS= read -r -d '' f; do ITEMS+=("extra|$f"); done < <(
  find assets/games -mindepth 2 -maxdepth 2 \
    \( -iname '2gameplay.jpg' -o -iname '2gameplay.jpeg' -o -iname '2gameplay.png' \) \
    -print0 | sort -z)
while IFS= read -r -d '' f; do ITEMS+=("background|$f"); done < <(
  find assets/background -maxdepth 1 \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) \
    -print0 | sort -z)
while IFS= read -r -d '' f; do ITEMS+=("icon|$f"); done < <(
  find images/logo images/categories -maxdepth 2 -name '*.png' -print0 | sort -z)
while IFS= read -r -d '' f; do ITEMS+=("loading|$f"); done < <(
  find images/loading -maxdepth 1 -name '*.png' -print0 | sort -z)

if [ -n "$ONLY" ]; then
  declare -a FILTERED=()
  for item in "${ITEMS[@]}"; do
    case "${item#*|}" in *"$ONLY"*) FILTERED+=("$item") ;; esac
  done
  if [ "${#FILTERED[@]}" -eq 0 ]; then
    echo "ERROR: --only '$ONLY' matched no source files." >&2
    echo "       Accepted names: gameplay/preview/2gameplay.(jpg|jpeg|png), assets/background/*, images/**/*.png" >&2
    exit 1
  fi
  ITEMS=(${FILTERED[@]+"${FILTERED[@]}"})
  echo "Filtered to ${#ITEMS[@]} source file(s) matching '$ONLY'."
  echo
fi

# ---------------------------------------------------------------------------
# encoder
# ---------------------------------------------------------------------------
encode() {  # $1=src $2=dst $3=class $4=fmt(webp|jpeg|png)
  local src=$1 dst=$2 cls=$3 fmt=$4 q
  local -a rz=()
  case "$cls" in
    gameplay)        rz=(-resize "${GAMEPLAY_MAX}x${GAMEPLAY_MAX}>"); q=$Q_GAMEPLAY ;;
    preview)         rz=(-resize "${PREVIEW_MAX}x${PREVIEW_MAX}>");   q=$Q_PREVIEW ;;
    extra|background) rz=(-resize "${EXTRA_MAX}x${EXTRA_MAX}>");      q=$Q_EXTRA ;;
    icon)            rz=(-resize "${ICON_MAX}x${ICON_MAX}>");         q=$Q_ICON ;;
    loading)         rz=(-resize "${LOADING_MAX}x${LOADING_MAX}>");   q=$Q_ICON ;;
  esac
  case "$fmt" in
    webp)
      magick "$src" -auto-orient -strip -colorspace sRGB "${rz[@]}" \
        -define webp:method=6 -define webp:image-hint=photo \
        -quality "$q" "$dst" ;;
    jpeg)
      magick "$src" -auto-orient -strip -colorspace sRGB "${rz[@]}" \
        -sampling-factor 4:2:0 -interlace Plane \
        -quality "$q" "$dst" ;;
    png)
      magick "$src" -auto-orient -strip -colorspace sRGB "${rz[@]}" \
        -colors 256 -define png:compression-level=9 "PNG8:$dst" ;;
  esac
}

# Already a small PNG8? Then re-encoding adds nothing but generation loss.
already_optimized() {  # $1=src $2=class
  local src=$1 cls=$2 info type w h max
  case "$cls" in icon) max=$ICON_MAX ;; loading) max=$LOADING_MAX ;; *) return 1 ;; esac
  info="$(identify -format '%[type]|%w|%h' "$src" 2>/dev/null)" || return 1
  [ -n "$info" ] || return 1
  IFS='|' read -r type w h <<<"$info"
  case "$type" in Palette|PaletteAlpha) ;; *) return 1 ;; esac
  [ "$w" -le "$max" ] && [ "$h" -le "$max" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# main loop
# ---------------------------------------------------------------------------
[ "$APPLY" = 1 ] && mkdir -p "$OUT_DIR"

printf '%-11s %9s %9s %7s  %s\n' CLASS BEFORE AFTER SAVED FILE
printf '%-11s %9s %9s %7s  %s\n' ---------- --------- --------- ------- ----

total_before=0
total_after=0
count=0
skipped=0
pruned=0
declare -a REPORT_LINES=()

for item in "${ITEMS[@]}"; do
  cls="${item%%|*}"
  src="${item#*|}"
  [ -f "$src" ] || continue

  if [ "$FORCE" = 0 ] && already_optimized "$src" "$cls"; then
    echo "already optimized, skipped: $src"
    skipped=$((skipped+1))
    continue
  fi

  b="$(bytes "$src")"

  # Which outputs does this class produce?
  declare -a outs=()
  case "$cls" in
    icon|loading)
      outs+=("png|$src") ;;
    *)
      { [ "$FORMAT" = webp ] || [ "$FORMAT" = both ]; } && outs+=("webp|${src%.*}.webp")
      { [ "$FORMAT" = jpeg ] || [ "$FORMAT" = both ]; } && outs+=("jpeg|${src%.*}.jpg") ;;
  esac

  declare -a outs_real=()
  out_ok=0
  best=$b

  for o in "${outs[@]}"; do
    ofmt="${o%%|*}"
    opath="${o#*|}"

    if [ "$APPLY" = 1 ] && [ "$INPLACE" = 1 ]; then
      real_dst="$opath"
    else
      real_dst="$OUT_DIR/$opath"
    fi
    outs_real+=("$real_dst")

    if [ "$APPLY" = 1 ]; then
      dst="$real_dst"
    else
      dst="$TMPD/$(printf '%s' "$opath" | tr '/' '_')"
    fi

    if [ "$FORCE" = 0 ] && [ -f "$dst" ] && [ "$dst" -nt "$src" ]; then
      s="$(bytes "$dst")"
      best=$(( s < best ? s : best ))
      out_ok=1
      skipped=$((skipped+1))
      continue
    fi

    mkdir -p "$(dirname "$dst")"
    # ImageMagick picks the encoder from the extension, so the temp name MUST
    # end in the real extension (.webp/.jpg/.png), never in .tmp.
    tmpout="$dst.tmp.$$.${ofmt}"
    encode "$src" "$tmpout" "$cls" "$ofmt"
    s="$(bytes "$tmpout")"

    if [ "$s" -ge "$b" ] && [ "$FORCE" = 0 ]; then
      echo "WARN: $ofmt output not smaller, keeping original: $src" >&2
      rm -f "$tmpout"
      s=$b
    else
      if [ "$APPLY" = 1 ]; then
        if [ "$dst" = "$src" ]; then
          bak="$BACKUP_DIR/$src"
          mkdir -p "$(dirname "$bak")"
          [ -f "$bak" ] || cp -p "$src" "$bak"
        fi
        mv -f "$tmpout" "$dst"
      else
        rm -f "$tmpout"
      fi
      out_ok=1
      best=$(( s < best ? s : best ))
      REPORT_LINES+=("| \`$src\` | $cls | $(mb "$b") MB | $(mb "$s") MB | $ofmt |")
    fi
  done

  # Move the source out of the deploy tree, unless it IS one of the outputs
  # (e.g. --format both turns gameplay.jpg into its own JPEG fallback).
  src_is_output=0
  for p in "${outs_real[@]}"; do
    [ "$p" = "$src" ] && src_is_output=1
  done
  if [ "$PRUNE" = 1 ] && [ "$src_is_output" = 0 ] && [ "$out_ok" = 1 ]; then
    if [ "$APPLY" = 1 ]; then
      bak="$BACKUP_DIR/$src"
      mkdir -p "$(dirname "$bak")"
      [ -f "$bak" ] || cp -p "$src" "$bak"
      rm -f "$src"
    fi
    pruned=$((pruned+1))
  fi

  printf '%-11s %8sM %8sM %7s  %s\n' "$cls" "$(mb "$b")" "$(mb "$best")" "$(pct "$b" "$best")" "$src"
  total_before=$((total_before + b))
  total_after=$((total_after + best))
  count=$((count+1))
done

echo
printf 'TOTAL: %d files, %s MB -> %s MB  (saved %s MB, %s)\n' \
  "$count" \
  "$(mb "$total_before")" \
  "$(mb "$total_after")" \
  "$(mb $((total_before - total_after)))" \
  "$(pct "$total_before" "$total_after")"

[ "$skipped" -gt 0 ] && echo "Skipped $skipped already-optimized output(s)."
if [ "$PRUNE" = 1 ]; then
  if [ "$APPLY" = 1 ]; then
    echo "Pruned $pruned source file(s) (moved to $BACKUP_DIR)."
  else
    echo "Dry run: would prune $pruned source file(s) into $BACKUP_DIR."
  fi
fi
if [ "$APPLY" = 0 ]; then
  echo "DRY RUN — nothing written. Re-run with --apply when the numbers look right."
elif [ "$INPLACE" = 1 ]; then
  echo "Originals backed up to: $BACKUP_DIR"
fi
if [ "$INPLACE" = 1 ] && [ "$FORMAT" = webp ] && [ "$PRUNE" = 0 ]; then
  echo "NOTE: --prune not set, so the old sources are still on disk and will still be deployed."
fi

# ---------------------------------------------------------------------------
# Report: files that lie about their format (PNG data in a .jpg file).
# This is why an "11 MB jpg" is really a 4K PNG.
# ---------------------------------------------------------------------------
mismatch=0
declare -a mislabeled=()
while IFS= read -r -d '' f; do
  real="$(identify -format '%m' "$f" 2>/dev/null || echo '?')"
  case "$f" in
    *.jpg|*.JPG|*.jpeg|*.JPEG)
      [ "$real" = "JPEG" ] && continue ;;
    *) continue ;;
  esac
  mismatch=$((mismatch+1))
  mislabeled+=("$f (actual: $real)")
done < <(find assets images -type f \( -iname '*.jpg' -o -iname '*.jpeg' \) -print0)
echo "Files named .jpg that are not JPEG: $mismatch"
if [ "$mismatch" -gt 0 ]; then
  shown=0
  for m in "${mislabeled[@]}"; do
    [ "$shown" -ge 8 ] && break
    echo "  $m"
    shown=$((shown+1))
  done
  [ "$mismatch" -gt "$shown" ] && echo "  ... and $((mismatch - shown)) more (PNG data saved with a .jpg name — that's why they're huge)"
fi

# ---------------------------------------------------------------------------
# --rewrite-paths
# ---------------------------------------------------------------------------
rewrite_paths() {
  local -a anchors=(
    "assets/games/assetto-corsa-evo/gameplay.webp"
    "assets/games/satisfactory/preview.webp"
    "assets/games/terraria/preview.webp"
    "assets/background/1.webp"
  )
  local a
  for a in "${anchors[@]}"; do
    if [ ! -f "$a" ]; then
      echo "ERROR: $a missing — refusing to rewrite paths (the site would break)." >&2
      echo "       Run with --apply --format webp first." >&2
      return 1
    fi
  done

  local -a targets=(
    "JSON/games.json"
    "index.html" "register.html" "gamelist.html" "gametipp.html"
    "howtoplay.html" "picturegame.html" "profile.html"
    "scripts/shared_background_chooser.js"
  )
  local bakdir="$BACKUP_DIR/paths"
  local f
  for f in "${targets[@]}"; do
    [ -f "$f" ] || continue
    mkdir -p "$bakdir/$(dirname "$f")"
    cp -p "$f" "$bakdir/$f"
  done

  # games.json: all .jpg occurrences are exactly the gameplay/preview paths,
  # so this is safe and complete. Idempotent.
  [ -f JSON/games.json ] && \
    sed -i 's#\.jpg"#.webp"#g; s#\.jpeg"#.webp"#g' JSON/games.json

  # HTML: <img src=".../preview.jpg"> and ".../gameplay.jpg"
  local -a html_targets=()
  for f in index.html register.html gamelist.html gametipp.html \
           howtoplay.html picturegame.html profile.html; do
    [ -f "$f" ] && html_targets+=("$f")
  done
  if [ "${#html_targets[@]}" -gt 0 ]; then
    sed -i -E 's#(preview|gameplay)\.(jpg|jpeg)#\1.webp#g' "${html_targets[@]}"
  fi

  # shared_background_chooser.js: url("/assets/background/${seed}.jpg")
  if [ -f scripts/shared_background_chooser.js ]; then
    sed -i -E 's#(assets/background/\$\{seed\})\.(jpg|jpeg)#\1.webp#' \
      scripts/shared_background_chooser.js
  fi

  echo "Rewrote image paths (.jpg -> .webp). Backups: $bakdir"

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import json, os
ok = miss = 0
missing = []
for g in json.load(open('JSON/games.json'))['games']:
    for kind, p in (g.get('images') or {}).items():
        if not p:
            continue
        if os.path.exists('.' + p):
            ok += 1
        else:
            miss += 1
            missing.append(f"{g['id']}:{kind}")
print(f"JSON image paths: {ok} exist, {miss} missing "
      f"(expected for games whose images you haven't added yet)")
if missing:
    print("  missing: " + ", ".join(missing[:12]) + (" ..." if len(missing) > 12 else ""))
PY
  fi
  echo "Remember to rebuild the CSS if you changed input.css:"
  echo "  npx @tailwindcss/cli -i input.css -o output.css --minify"
}

if [ "$REWRITE" = 1 ]; then
  echo
  if [ "$APPLY" = 1 ]; then
    rewrite_paths
  else
    echo "DRY RUN: would rewrite .jpg -> .webp in JSON/games.json, 7 HTML files and"
    echo "         scripts/shared_background_chooser.js (backups kept outside the repo)."
  fi
fi

# ---------------------------------------------------------------------------
# optional Markdown report
# ---------------------------------------------------------------------------
if [ -n "$REPORT" ]; then
  mkdir -p "$(dirname "$REPORT")"
  {
    echo "# Image optimization report"
    echo
    echo "Generated: $(date -Is)  |  format: $FORMAT  |  mode: $([ "$APPLY" = 1 ] && echo apply || echo dry-run)"
    echo
    echo "| File | Class | Before | After | Output |"
    echo "|---|---|---:|---:|---|"
    printf '%s\n' "${REPORT_LINES[@]}"
    echo
    echo "**Total: $(mb "$total_before") MB -> $(mb "$total_after") MB**"
  } > "$REPORT"
  echo "Report written to $REPORT"
fi
