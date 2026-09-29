#!/usr/bin/env bash
set -u

TARGET=/usr/local/bin/image
STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP="/usr/local/bin/image.backup.${STAMP}"

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Run this installer as root inside Debian."
  exit 1
fi

if [ -f "$TARGET" ]; then
  cp -a "$TARGET" "$BACKUP"
  echo "✅ Backed up existing image tool to: $BACKUP"
fi

cat > "$TARGET" <<'SCRIPT'
#!/usr/bin/env bash

set -u

TERMUX_BIN="/data/data/com.termux/files/usr/bin"
PICKER="$TERMUX_BIN/termux-storage-get"
URL_OPENER="$TERMUX_BIN/termux-open-url"
TERMUX_HOME="/data/data/com.termux/files/home"
PICKED="$TERMUX_HOME/selected-image"
REPORTS="$HOME/image-reports"
SEARCH_DIR="$TERMUX_HOME/storage/shared/Pictures/Image-Intelligence-Search"
IMG=""
CURRENT_REPORT=""
TMPDIR_IMAGE="${TMPDIR:-/tmp}/image-intelligence-$$"

mkdir -p "$REPORTS" "$TMPDIR_IMAGE"
trap 'rm -rf "$TMPDIR_IMAGE"' EXIT

hr(){ printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'; }

pause_screen(){
    echo
    read -r -p '⏸️  Press ENTER to return to the Image Intelligence menu...' _
}

have(){ command -v "$1" >/dev/null 2>&1; }

exif(){
    exiftool -s3 "$1" "$IMG" 2>/dev/null || true
}

head_ui(){
    clear
    echo
    echo '╔══════════════════════════════════════════════════════╗'
    echo '║ 🔎 IMAGE INTELLIGENCE                               ║'
    echo '║    Local Mobile Image Forensics                     ║'
    echo '╚══════════════════════════════════════════════════════╝'
    echo
    echo '🔐 Analysis: LOCAL     🚫 Uploads: NONE     🌐 Network: NONE'
    echo '📁 Folder scanning: DISABLED     ✏️ Original: NOT modified'
    echo '* Network is used only after you explicitly choose a search / external check.'
    echo
}

section(){
    echo
    echo "$1"
    hr
}

new_report(){
    local kind="$1"
    local safe
    safe=$(basename "${IMG:-selected-image}" | tr ' /:' '___' | tr -cd '[:alnum:]_.-')
    local dir="$REPORTS/${STAMP_NOW}_${kind}_${safe}"
    mkdir -p "$dir"
    CURRENT_REPORT="$dir/report.txt"
    {
        echo 'IMAGE INTELLIGENCE REPORT'
        echo '========================='
        echo "Generated: $(date -Is)"
        echo "Image: $IMG"
        echo
    } > "$CURRENT_REPORT"
}

pick_image(){
    local source="$PICKED"
    rm -f "$source" "$TMPDIR_IMAGE/picked"

    if [ ! -x "$PICKER" ] && ! have termux-storage-get; then
        echo '❌ Android picker not found.'
        return 1
    fi

    echo
    echo '📷 Choose ONE image from your phone...'
    echo

    if [ -x "$PICKER" ]; then
        "$PICKER" "$source" >/dev/null 2>&1 || true
    else
        termux-storage-get "$source" >/dev/null 2>&1 || true
    fi

    echo '⏳ Waiting for Android to finish importing...'

    local found=0 last=0 stable=0 size i
    for i in $(seq 1 120); do
        if [ -s "$source" ]; then found=1; break; fi
        sleep 1
    done

    if [ "$found" -ne 1 ]; then
        echo '❌ Image did not arrive within 2 minutes.'
        return 1
    fi

    for i in $(seq 1 30); do
        size=$(stat -c%s "$source" 2>/dev/null || echo 0)
        if [ "$size" -gt 0 ] && [ "$size" -eq "$last" ]; then
            stable=$((stable+1))
        else
            stable=0
        fi
        last="$size"
        [ "$stable" -ge 3 ] && break
        sleep 1
    done

    cp -f "$source" "$TMPDIR_IMAGE/picked" || return 1
    IMG="$TMPDIR_IMAGE/picked"
    echo '✅ Image imported locally.'
}

ai_state(){
    local raw
    raw=$(exiftool -a -u -g1 "$IMG" 2>/dev/null || true)

    if printf '%s\n' "$raw" | grep -Eqi \
      'JUMD Label[[:space:]]*:[[:space:]]*c2pa\.signature|JUMBF|Claim Generator Info|Actions Action[[:space:]]*:.*c2pa\.|Actions Digital Source Type|Actions Software Agent'; then
        echo C2PA
        return
    fi

    if printf '%s\n' "$raw" | grep -Eqi \
      'gpt-image|DALL-E|Midjourney|Stable Diffusion|FLUX|Firefly|Imagen|Gemini|SynthID'; then
        echo AI
        return
    fi

    echo NONE
}

ai_generator(){
    exiftool -a -u -g1 "$IMG" 2>/dev/null |
      grep -m1 -Ei 'Actions Software Agent Name|Claim Generator Info Name' |
      sed 's/^[^:]*:[[:space:]]*//' |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

ai_version(){
    exiftool -a -u -g1 "$IMG" 2>/dev/null |
      grep -m1 -Ei 'Actions Software Agent Version' |
      sed 's/^[^:]*:[[:space:]]*//' |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

ai_source(){
    exiftool -a -u -g1 "$IMG" 2>/dev/null |
      grep -m1 -Ei 'Actions Digital Source Type' |
      sed 's/^[^:]*:[[:space:]]*//' |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

ai_report(){
    section '🤖 AI / GENERATOR'
    local state gen ver src raw
    state=$(ai_state)
    gen=$(ai_generator)
    ver=$(ai_version)
    src=$(ai_source)
    raw=$(exiftool -a -u -g1 "$IMG" 2>/dev/null || true)

    case "$state" in
      C2PA)
        echo 'AI provenance : ✅ Embedded provenance found'
        echo 'C2PA          : ✅ Present'
        echo "Generator     : ${gen:-Unknown}"
        echo "Version       : ${ver:-Unknown}"
        [ -n "$src" ] && echo "Source marker : $src"
        ;;
      AI)
        echo 'AI metadata   : ✅ AI-related marker found'
        if printf '%s\n' "$raw" | grep -Eqi 'Gemini|SynthID'; then
            echo 'Generator     : Google / Gemini metadata'
        elif printf '%s\n' "$raw" | grep -Eqi 'gpt-image|DALL-E'; then
            echo 'Generator     : OpenAI metadata'
        elif printf '%s\n' "$raw" | grep -Eqi 'Midjourney'; then
            echo 'Generator     : Midjourney metadata'
        elif printf '%s\n' "$raw" | grep -Eqi 'Stable Diffusion'; then
            echo 'Generator     : Stable Diffusion metadata'
        elif printf '%s\n' "$raw" | grep -Eqi 'FLUX'; then
            echo 'Generator     : FLUX metadata'
        else
            echo 'Generator     : AI-related metadata'
        fi
        echo "Model         : ${gen:-Unknown}"
        [ -n "$ver" ] && echo "Version       : $ver"
        ;;
      NONE)
        echo 'AI provenance : ⚪ Not found'
        echo 'C2PA          : ❌ Not present'
        echo 'Generator     : Unknown'
        echo 'Model         : Unknown'
        echo 'SynthID       : ⚠️ Not checked locally'
        echo
        echo '⚠️ No local AI provenance was found.'
        echo 'This does NOT prove the image is human-created.'
        echo 'Metadata can be removed, altered, or never written.'
        ;;
    esac
}

basic_summary(){
    head_ui
    section '📸 IMAGE SUMMARY'

    local name type mime size width height mp make model lens software
    local original create modify lat lon alt state gen ver src

    name=$(exif -FileName)
    type=$(exif -FileType)
    mime=$(exif -MIMEType)
    size=$(stat -c%s "$IMG" 2>/dev/null || echo 0)
    width=$(exif -ImageWidth)
    height=$(exif -ImageHeight)
    mp=$(exif -Megapixels)
    make=$(exif -Make)
    model=$(exif -Model)
    lens=$(exif -LensModel)
    software=$(exif -Software)
    original=$(exif -DateTimeOriginal)
    create=$(exif -CreateDate)
    modify=$(exif -ModifyDate)
    lat=$(exif -GPSLatitude)
    lon=$(exif -GPSLongitude)
    alt=$(exif -GPSAltitude)
    state=$(ai_state)
    gen=$(ai_generator)
    ver=$(ai_version)
    src=$(ai_source)

    section '📁 FILE'
    printf '%-12s : %s\n' 'FileName' "${name:-selected-image}"
    printf '%-12s : %s\n' 'FileType' "${type:-Unknown}"
    printf '%-12s : %s\n' 'MIMEType' "${mime:-Unknown}"
    printf '%-12s : %s bytes\n' 'FileSize' "$size"

    section '🖼️ IMAGE'
    printf '%-12s : %s\n' 'Dimensions' "${width:-Unknown} × ${height:-Unknown}"
    printf '%-12s : %s\n' 'Megapixels' "${mp:-Unknown}"

    section '📷 CAMERA / DEVICE'
    if [ -n "${make}${model}${lens}${software}" ]; then
        [ -n "$make" ] && printf '%-12s : %s\n' 'Make' "$make"
        [ -n "$model" ] && printf '%-12s : %s\n' 'Model' "$model"
        [ -n "$lens" ] && printf '%-12s : %s\n' 'Lens' "$lens"
        [ -n "$software" ] && printf '%-12s : %s\n' 'Software' "$software"
    else
        echo 'Device       : Not recorded'
    fi

    section '🕐 CAPTURE'
    if [ -n "$original" ]; then
        printf '%-12s : %s\n' 'Taken' "$original"
    elif [ -n "$create" ]; then
        printf '%-12s : %s\n' 'Created' "$create"
    elif [ -n "$modify" ]; then
        printf '%-12s : %s\n' 'Modified' "$modify"
    else
        echo 'Timestamp    : Not recorded'
    fi

    section '📍 GPS'
    if [ -n "$lat" ] || [ -n "$lon" ]; then
        echo 'Status       : ✅ Coordinates present'
        [ -n "$lat" ] && echo "Latitude     : $lat"
        [ -n "$lon" ] && echo "Longitude    : $lon"
        [ -n "$alt" ] && echo "Altitude     : $alt"
    elif exiftool -a -u -g1 "$IMG" 2>/dev/null | grep -Eqi 'GPSLatitude|GPSLongitude'; then
        echo 'Status       : ⚠️ GPS fields present but empty'
    else
        echo 'Status       : ❌ No GPS coordinates'
    fi

    section '🤖 AI / PROVENANCE'
    case "$state" in
      C2PA)
        echo 'Detected     : ✅ Embedded provenance'
        echo "Generator    : ${gen:-Unknown}"
        echo "Version      : ${ver:-Unknown}"
        [ -n "$src" ] && echo "Source       : $src"
        ;;
      AI)
        echo 'Detected     : ✅ AI-related metadata'
        echo "Generator    : ${gen:-AI-related metadata}"
        [ -n "$ver" ] && echo "Version      : $ver"
        echo 'C2PA         : ❌ Not present'
        ;;
      NONE)
        echo 'Detected     : ⚪ No AI provenance found'
        echo 'Generator    : Unknown'
        echo 'Model        : Unknown'
        echo 'C2PA         : ❌ Not present'
        echo 'SynthID      : ⚠️ Not checked locally'
        ;;
    esac

    section '🔐 FINGERPRINT'
    echo "SHA256       : $(sha256sum "$IMG" | awk '{print $1}')"
}

metadata(){
    section '🧬 FULL RAW METADATA'
    exiftool -a -u -g1 "$IMG" 2>/dev/null
}

gps(){
    section '📍 GPS DIAGNOSTICS'
    local raw lat lon alt
    raw=$(exiftool -a -u -g1 "$IMG" 2>/dev/null || true)
    lat=$(exif -GPSLatitude)
    lon=$(exif -GPSLongitude)
    alt=$(exif -GPSAltitude)

    if [ -n "$lat" ] || [ -n "$lon" ]; then
        echo '✅ GPS coordinates are present.'
        [ -n "$lat" ] && echo "Latitude : $lat"
        [ -n "$lon" ] && echo "Longitude: $lon"
        [ -n "$alt" ] && echo "Altitude : $alt"
    elif printf '%s\n' "$raw" | grep -Eqi 'GPSLatitude|GPSLongitude'; then
        echo '⚠️ GPS fields exist in the file, but their coordinate values are empty.'
        echo 'This is different from a file with no GPS block at all.'
    else
        echo '❌ No GPS coordinate fields detected.'
    fi
}

c2pa(){
    section '📋 C2PA / PROVENANCE'
    local raw
    raw=$(exiftool -a -u -g1 "$IMG" 2>/dev/null || true)
    if printf '%s\n' "$raw" | grep -Eqi \
      'JUMD Label[[:space:]]*:[[:space:]]*c2pa\.signature|JUMBF|Claim Generator Info|Actions Action[[:space:]]*:.*c2pa\.|Actions Digital Source Type|Actions Software Agent'; then
        echo '✅ C2PA/JUMBF provenance detected.'
        echo
        printf '%s\n' "$raw" | grep -Ei \
          'JUMD Label|Actions Action|Actions When|Actions Software Agent|Actions Digital Source Type|Claim Generator Info|Spec Version|Signature|Instance ID|Title' |
          head -80
    else
        echo '❌ No C2PA/JUMBF provenance detected.'
        echo "Note: ICC colour-profile signatures such as 'acsp' are NOT C2PA."
    fi
}

perceptual_hashes(){
    if ! have python3; then
        echo '⚪ Python unavailable for perceptual hashes.'
        return
    fi

    python3 - "$IMG" <<'PY'
import sys, math
try:
    from PIL import Image, ImageOps
except Exception as e:
    print(f"Pillow unavailable: {e}")
    raise SystemExit(0)

path = sys.argv[1]
try:
    im = Image.open(path).convert('L')
except Exception as e:
    print(f"Could not decode image: {e}")
    raise SystemExit(0)

# aHash / dHash work without NumPy.
def bits_to_hex(bits):
    out=[]
    for i in range(0,len(bits),4):
        n=0
        for b in bits[i:i+4]: n=(n<<1)|int(b)
        out.append(format(n,'x'))
    return ''.join(out)

a = im.resize((8,8))
p = list(a.getdata())
avg = sum(p)/len(p)
ah = bits_to_hex([v >= avg for v in p])

d = im.resize((9,8))
p = list(d.getdata())
bits=[]
for y in range(8):
    for x in range(8):
        bits.append(p[y*9+x] > p[y*9+x+1])
dh = bits_to_hex(bits)

print(f"aHash  : {ah}")
print(f"dHash  : {dh}")

# True-ish pHash when NumPy is present.
try:
    import numpy as np
    small = im.resize((32,32))
    arr = np.asarray(small, dtype=float)
    n=32
    dct = np.zeros((n,n), dtype=float)
    c = math.pi/(2*n)
    for u in range(8):
        for v in range(8):
            s=0.0
            for x in range(n):
                cx=math.cos((2*x+1)*u*c)
                for y in range(n):
                    s += arr[x,y]*cx*math.cos((2*y+1)*v*c)
            au = math.sqrt(1/n) if u==0 else math.sqrt(2/n)
            av = math.sqrt(1/n) if v==0 else math.sqrt(2/n)
            dct[u,v]=s*au*av
    coeff=dct[:8,:8].flatten()
    med=float(np.median(coeff[1:]))
    bits=[x>=med for x in coeff]
    print(f"pHash  : {bits_to_hex(bits)}")
except Exception:
    print("pHash  : unavailable (install NumPy for DCT pHash)")

print("Note   : perceptual hashes are similarity fingerprints, not proof of identity.")
PY
}

hashes(){
    section '🔐 HASHES / FINGERPRINTS'
    printf 'MD5    : '; md5sum "$IMG" | awk '{print $1}'
    printf 'SHA1   : '; sha1sum "$IMG" | awk '{print $1}'
    printf 'SHA256 : '; sha256sum "$IMG" | awk '{print $1}'
    echo
    perceptual_hashes
}

timeline(){
    section '🕐 TIMELINE'
    exiftool -a -u "$IMG" 2>/dev/null |
      grep -Ei 'DateTimeOriginal|CreateDate|ModifyDate|DateCreated|DateTimeDigitized|OffsetTime|FileModifyDate|FileAccessDate|FileInodeChangeDate' |
      head -80 || true
}

anatomy(){
    section '🧱 FILE ANATOMY / INTEGRITY'
    echo "File command:"
    if have file; then file "$IMG"; else echo '⚪ file not installed'; fi
    echo
    echo 'Magic bytes:'
    if have xxd; then xxd -l 64 "$IMG"; else od -An -tx1 -N64 "$IMG" 2>/dev/null || true; fi
    echo
    if have binwalk; then
        echo 'Binwalk signatures:'
        binwalk "$IMG" 2>/dev/null | head -80
    else
        echo '⚪ binwalk not installed'
    fi
    echo
    if have zsteg; then
        local type
        type=$(exif -FileType)
        case "$type" in
          PNG|BMP) echo 'zsteg:'; zsteg "$IMG" 2>/dev/null | head -80 ;;
          *) echo 'zsteg skipped: not a PNG/BMP image.' ;;
        esac
    else
        echo '⚪ zsteg not installed'
    fi
}

ocr_and_artifacts(){
    section '🔗 SEARCHABLE ARTIFACTS'
    local strings_file="$TMPDIR_IMAGE/strings.txt"
    local ocr_file="$TMPDIR_IMAGE/ocr.txt"
    : > "$strings_file"
    : > "$ocr_file"

    if have strings; then
        strings -n 6 "$IMG" 2>/dev/null > "$strings_file" || true
    fi

    if have tesseract; then
        echo 'OCR:'
        tesseract "$IMG" stdout 2>/dev/null | tee "$ocr_file" | head -80
        echo
    else
        echo 'OCR unavailable (tesseract not installed).'
    fi

    echo 'Web URLs:'
    cat "$strings_file" "$ocr_file" 2>/dev/null |
      grep -Eio 'https?://[^[:space:]"<>]+|www\.[A-Za-z0-9.-]+\.[A-Za-z]{2,}' |
      sort -u | head -50 || true
    echo

    echo 'Email addresses:'
    cat "$strings_file" "$ocr_file" 2>/dev/null |
      grep -Eio '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' |
      sort -u | head -50 || true
    echo

    echo 'IPv4 addresses:'
    cat "$strings_file" "$ocr_file" 2>/dev/null |
      grep -Eio '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' |
      sort -u | head -50 || true
    echo

    echo 'C2PA / provenance references:'
    exiftool -a -u -g1 "$IMG" 2>/dev/null |
      grep -Eio 'https?://[^[:space:]]+' |
      grep -Ei 'c2pa|contentauth|iptc\.org' |
      sort -u | head -50 || true
}

ela(){
    section '🧪 ERROR LEVEL ANALYSIS'
    if ! have python3; then
        echo '⚪ Python unavailable.'
        return
    fi

    python3 - "$IMG" <<'PY'
import sys, os
try:
    from PIL import Image, ImageChops, ImageEnhance
except Exception:
    print('⚪ Pillow unavailable.')
    raise SystemExit(0)

path=sys.argv[1]
try:
    im=Image.open(path).convert('RGB')
    out=os.path.join(os.path.dirname(path),'ela.jpg')
    # Re-save at a fixed JPEG quality, then amplify the difference.
    tmp=os.path.join(os.path.dirname(path),'ela_base.jpg')
    im.save(tmp,'JPEG',quality=90)
    base=Image.open(tmp).convert('RGB')
    diff=ImageChops.difference(im,base)
    amp=ImageEnhance.Brightness(diff).enhance(8.0)
    amp.save(out,'JPEG',quality=95)
    os.unlink(tmp)
    print(f'✅ ELA image created locally: {out}')
    print('Interpretation: bright regions show stronger recompression differences.')
    print('ELA is a clue only. It cannot by itself prove editing or AI generation.')
except Exception as e:
    print(f'❌ ELA failed: {e}')
PY
}

quick(){
    new_report quick
    {
        echo 'QUICK INVESTIGATION'
        echo
        basic_summary
        ai_report
        gps
        hashes
        ocr_and_artifacts
    } > "$CURRENT_REPORT" 2>&1
    basic_summary
    echo
    echo "📄 Quick report: $CURRENT_REPORT"
}

deep(){
    new_report deep
    echo
    echo '🧠 DEEP FORENSIC ANALYSIS'
    hr
    echo
    echo '[1/7] 🤖 AI / generator detection'
    ai_report >> "$CURRENT_REPORT" 2>&1
    echo '[2/7] 🧱 File anatomy / integrity'
    anatomy >> "$CURRENT_REPORT" 2>&1
    echo '[3/7] 🧪 Error Level Analysis'
    ela >> "$CURRENT_REPORT" 2>&1
    echo '[4/7] 🔗 OCR / searchable artifacts'
    ocr_and_artifacts >> "$CURRENT_REPORT" 2>&1
    echo '[5/7] 🔐 Hashes / perceptual fingerprints'
    hashes >> "$CURRENT_REPORT" 2>&1
    echo '[6/7] 🕐 Timeline'
    timeline >> "$CURRENT_REPORT" 2>&1
    echo '[7/7] 📋 C2PA / provenance details'
    c2pa >> "$CURRENT_REPORT" 2>&1

    echo
    echo '✅ DEEP ANALYSIS COMPLETE'
    echo "📄 Report saved: $CURRENT_REPORT"
    echo
    echo 'Nothing was automatically opened. Press F in the menu to read the report.'
}

full_scan(){
    new_report full
    echo
    echo '🧬 FULL INVESTIGATION'
    hr
    echo
    echo '[1/7] 🤖 AI / generator detection'; ai_report >> "$CURRENT_REPORT" 2>&1
    echo '[2/7] 🧬 Full raw metadata'; metadata >> "$CURRENT_REPORT" 2>&1
    echo '[3/7] 📍 GPS diagnostics'; gps >> "$CURRENT_REPORT" 2>&1
    echo '[4/7] 📋 C2PA / provenance'; c2pa >> "$CURRENT_REPORT" 2>&1
    echo '[5/7] 🕐 Timeline'; timeline >> "$CURRENT_REPORT" 2>&1
    echo '[6/7] 🔗 Artifacts / OCR'; ocr_and_artifacts >> "$CURRENT_REPORT" 2>&1
    echo '[7/7] 🔐 Hashes / fingerprints'; hashes >> "$CURRENT_REPORT" 2>&1
    echo
    echo '✅ FULL INVESTIGATION COMPLETE'
    echo "📄 Report saved: $CURRENT_REPORT"
}

view_report(){
    local f="$1" clean="$TMPDIR_IMAGE/readable.txt"
    [ -f "$f" ] || { echo '❌ Report not found.'; return; }
    tr -d '\000' < "$f" > "$clean"
    clear
    echo '📄 FULL REPORT'
    hr
    echo "$f"
    echo
    less -R "$clean"
}

latest_report_path(){
    find "$REPORTS" -type f -name report.txt -printf '%T@ %p\n' 2>/dev/null |
      sort -n | tail -1 | cut -d' ' -f2-
}

latest(){
    local f
    f=$(latest_report_path || true)
    if [ -n "$f" ] && [ -f "$f" ]; then
        view_report "$f"
    else
        echo '📄 No reports found.'
    fi
}

sanitize(){
    local outdir="$HOME/image-sanitized"
    mkdir -p "$outdir"
    local base ext stem out
    base=$(basename "$IMG")
    ext="${base##*.}"
    stem="${base%.*}"
    out="$outdir/${stem}_sanitized.${ext}"

    echo
    echo '🧼 SANITIZED COPY'
    echo 'Original file will NOT be modified.'
    echo "Output: $out"
    echo

    if have python3; then
        if python3 - "$IMG" "$out" <<'PY'
import sys
from PIL import Image
src,dst=sys.argv[1:]
im=Image.open(src)
fmt=im.format or 'JPEG'
# Deliberately omit EXIF/XMP/IPTC/ICC/C2PA metadata.
if fmt == 'JPEG':
    im.convert('RGB').save(dst, format='JPEG', quality=95, optimize=True)
elif fmt == 'PNG':
    im.save(dst, format='PNG', optimize=True)
else:
    im.save(dst, format=fmt)
print('Sanitized with Pillow by re-encoding without metadata.')
PY
        then
            echo "✅ Sanitized copy created: $out"
            echo '🔐 Original remains untouched.'
            return
        fi
    fi

    if have exiftool; then
        cp -f "$IMG" "$out"
        exiftool -overwrite_original -all= "$out" >/dev/null 2>&1 || true
        echo "✅ Metadata-stripped copy created: $out"
        echo '🔐 Original remains untouched.'
    else
        echo '❌ Neither Pillow nor exiftool is available.'
    fi
}

reverse_search(){
    echo
    echo '🔎 REVERSE IMAGE SEARCH'
    hr
    echo 'This is an EXPLICIT network action.'
    echo 'The image is NOT uploaded by this script.'
    echo 'It is only copied locally to shared storage so YOU can manually upload it.'
    echo
    echo '[1] Google Images / Lens'
    echo '[2] Bing Visual Search'
    echo '[3] TinEye'
    echo '[Q] Cancel'
    echo
    read -r -p 'Choose: ' r

    local url=''
    case "${r^^}" in
      1) url='https://images.google.com/' ;;
      2) url='https://www.bing.com/visualsearch' ;;
      3) url='https://tineye.com/' ;;
      *) echo 'Cancelled.'; return ;;
    esac

    mkdir -p "$SEARCH_DIR"
    local copy="$SEARCH_DIR/$(basename "$IMG")"
    cp -f "$IMG" "$copy"
    echo
    echo "✅ Search copy prepared locally: $copy"
    echo '🌐 Opening the chosen search site. Upload the image yourself.'

    if [ -x "$URL_OPENER" ]; then
        "$URL_OPENER" "$url" >/dev/null 2>&1 || true
    elif have termux-open-url; then
        termux-open-url "$url" >/dev/null 2>&1 || true
    else
        echo "Open this manually: $url"
    fi
}

compare(){
    echo
    echo '🆚 COMPARE TWO IMAGES'
    echo 'The first image is the one currently selected.'
    echo
    local second="$TERMUX_HOME/compare-image"
    rm -f "$second"
    if [ -x "$PICKER" ]; then
        "$PICKER" "$second" >/dev/null 2>&1 || true
    else
        echo '❌ Android picker unavailable.'
        return
    fi

    local ok=0 size last=0 stable=0 i
    for i in $(seq 1 120); do
        [ -s "$second" ] && { ok=1; break; }
        sleep 1
    done
    [ "$ok" -eq 1 ] || { echo '❌ Second image did not arrive.'; return; }
    for i in $(seq 1 30); do
        size=$(stat -c%s "$second" 2>/dev/null || echo 0)
        if [ "$size" -gt 0 ] && [ "$size" -eq "$last" ]; then stable=$((stable+1)); else stable=0; fi
        last="$size"
        [ "$stable" -ge 3 ] && break
        sleep 1
    done
    cp -f "$second" "$TMPDIR_IMAGE/compare" || return

    echo
    echo 'IMAGE A'
    echo "SHA256: $(sha256sum "$IMG" | awk '{print $1}')"
    echo "Size  : $(stat -c%s "$IMG" 2>/dev/null) bytes"
    echo "Dims  : $(exif -ImageWidth) × $(exif -ImageHeight)"
    echo
    echo 'IMAGE B'
    echo "SHA256: $(sha256sum "$TMPDIR_IMAGE/compare" | awk '{print $1}')"
    echo "Size  : $(stat -c%s "$TMPDIR_IMAGE/compare" 2>/dev/null) bytes"
    echo 'Dims  : '$(exiftool -s3 -ImageWidth -ImageHeight "$TMPDIR_IMAGE/compare" 2>/dev/null | tr '\n' ' × ' | sed 's/ × $//')

    if have python3; then
        python3 - "$IMG" "$TMPDIR_IMAGE/compare" <<'PY'
import sys, math
try:
    from PIL import Image, ImageChops, ImageStat
except Exception:
    print('Pixel similarity unavailable: Pillow missing.')
    raise SystemExit
try:
    a=Image.open(sys.argv[1]).convert('RGB')
    b=Image.open(sys.argv[2]).convert('RGB')
    a.thumbnail((512,512)); b.thumbnail((512,512))
    if a.size != b.size:
        b=b.resize(a.size)
    diff=ImageChops.difference(a,b)
    rms=math.sqrt(sum(v*v for v in ImageStat.Stat(diff).rms)/3)
    similarity=max(0.0,100.0*(1.0-rms/255.0))
    print(f'Pixel similarity estimate: {similarity:.1f}%')
    print('Note: resizing/cropping/compression can lower this; it is not proof of identity.')
except Exception as e:
    print(f'Comparison failed: {e}')
PY
    fi
}

doctor(){
    head_ui
    section '🩺 DOCTOR'
    for c in bash file exiftool strings xxd python3 tesseract binwalk zsteg less; do
        if have "$c"; then echo "✅ $c"; else echo "⚪ $c missing"; fi
    done
    if [ -x "$PICKER" ]; then echo '✅ Android picker'; else echo '⚪ Android picker missing'; fi
    if [ -x "$URL_OPENER" ]; then echo '✅ URL opener'; else echo '⚪ URL opener missing'; fi
    if have python3; then
        python3 - <<'PY'
try:
    import PIL
    print(f'✅ Pillow {PIL.__version__}')
except Exception:
    print('⚪ Pillow missing')
try:
    import numpy
    print(f'✅ NumPy {numpy.__version__}')
except Exception:
    print('⚪ NumPy missing')
PY
    fi
    echo
    echo "Reports: $REPORTS"
    echo "Search copies: $SEARCH_DIR"
    echo 'No packages are automatically installed by this tool.'
}

helpme(){
    head_ui
    section '📖 HELP / PRIVACY MODEL'
    echo '1  Quick investigation     Human-readable essentials + local artifacts'
    echo '2  Deep forensic           ELA, anatomy, OCR, hashes, timeline, C2PA'
    echo '3  Full metadata           Raw ExifTool metadata'
    echo '4  GPS diagnostics         Coordinates vs empty GPS fields'
    echo '5  AI / C2PA               Provenance and explicit AI markers only'
    echo '6  Hashes                  MD5/SHA + perceptual fingerprints'
    echo '7  Timeline                File and capture timestamps'
    echo '8  File anatomy            Magic bytes, binwalk, zsteg where applicable'
    echo '9  Sanitized copy          New metadata-stripped copy, original untouched'
    echo 'R  Reverse search          Explicit web action, manual upload only'
    echo 'C  Compare                 Select a second image and compare locally'
    echo 'F  Full report             Opens the current/latest report in less'
    echo 'D  Doctor                  Dependency check'
    echo 'L  Latest report           Opens the newest saved report'
    echo 'X  Delete search copy     Removes the optional shared search copy'
    echo
    echo 'PRIVACY:'
    echo '• One selected image at a time.'
    echo '• No folder scanning.'
    echo '• No automatic uploads.'
    echo '• No automatic network calls.'
    echo '• No automatic URL opening.'
    echo '• Original image is never modified.'
    echo '• Reports stay in Debian under ~/image-reports/.'
}

menu(){
    while true; do
        head_ui
        section 'CHOOSE OPERATION'
        echo '[1] ⚡ Quick investigation'
        echo '[2] 🧠 Deep forensic analysis'
        echo '[3] 🧬 Full raw metadata'
        echo '[4] 📍 GPS diagnostics'
        echo '[5] 🤖 AI / C2PA'
        echo '[6] 🔐 Hashes / fingerprints'
        echo '[7] 🕐 Timeline'
        echo '[8] 🧱 File anatomy / integrity'
        echo '[9] 🧼 Sanitized copy'
        echo
        echo '[R] 🔎 Reverse image search'
        echo '[C] 🆚 Compare two images'
        echo '[F] 📄 Open full report'
        echo '[D] 🩺 Doctor'
        echo '[L] 📋 Latest report'
        echo '[X] 🧹 Delete search copy'
        echo '[H] 📖 Help'
        echo '[Q] Quit'
        echo
        read -r -p 'Choice: ' choice
        echo

        case "${choice^^}" in
          1) quick; pause_screen ;;
          2) deep; pause_screen ;;
          3) new_report metadata; metadata >> "$CURRENT_REPORT" 2>&1; echo "📄 Report: $CURRENT_REPORT"; pause_screen ;;
          4) new_report gps; gps | tee -a "$CURRENT_REPORT"; echo "📄 Report: $CURRENT_REPORT"; pause_screen ;;
          5) new_report ai; ai_report | tee -a "$CURRENT_REPORT"; c2pa | tee -a "$CURRENT_REPORT"; echo "📄 Report: $CURRENT_REPORT"; pause_screen ;;
          6) new_report hashes; hashes | tee -a "$CURRENT_REPORT"; echo "📄 Report: $CURRENT_REPORT"; pause_screen ;;
          7) new_report timeline; timeline | tee -a "$CURRENT_REPORT"; echo "📄 Report: $CURRENT_REPORT"; pause_screen ;;
          8) new_report anatomy; anatomy | tee -a "$CURRENT_REPORT"; echo "📄 Report: $CURRENT_REPORT"; pause_screen ;;
          9) sanitize; pause_screen ;;
          R) reverse_search; pause_screen ;;
          C) compare; pause_screen ;;
          F)
             if [ -n "$CURRENT_REPORT" ] && [ -f "$CURRENT_REPORT" ]; then view_report "$CURRENT_REPORT"; else latest; fi
             ;;
          D) doctor; pause_screen ;;
          L) latest; pause_screen ;;
          X) rm -rf "$SEARCH_DIR"; echo '✅ Search copy deleted.'; pause_screen ;;
          H) helpme; pause_screen ;;
          Q|EXIT) return ;;
          *) echo '❌ Unknown choice.'; sleep 1 ;;
        esac
    done
}

main(){
    STAMP_NOW=$(date +%Y%m%d_%H%M%S)

    case "${1:-}" in
      --doctor|-d) doctor; exit ;;
      --latest|-l) latest; exit ;;
      --help|-h) helpme; exit ;;
      --quick|-q)
        pick_image || exit 1
        basic_summary
        quick
        pause_screen
        exit
        ;;
      --deep)
        pick_image || exit 1
        basic_summary
        deep
        pause_screen
        exit
        ;;
      --full)
        pick_image || exit 1
        basic_summary
        full_scan
        pause_screen
        exit
        ;;
    esac

    pick_image || exit 1
    basic_summary
    echo
    read -r -p 'Press ENTER for the forensic menu...' _
    menu
}

main "$@"
SCRIPT

chmod +x "$TARGET"

bash -n "$TARGET" || {
  echo "❌ New image script failed syntax check. Restoring backup."
  [ -f "$BACKUP" ] && cp -a "$BACKUP" "$TARGET"
  exit 1
}

echo
echo '✅ Image Intelligence v4 installed.'
echo "📦 Backup: $BACKUP"
echo '🩺 Test: image --doctor'
echo '🚀 Run:  image'
echo
echo 'No package installs, uploads, scans, or network calls were performed by this installer.'