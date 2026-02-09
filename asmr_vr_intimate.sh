#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# Intimate VR Presence 20–50cm — Stereo → pseudo-binaurale ultra-ravvicinata (2026)
#
# Ottimizzato per contenuti intimi/sexy:
# • Distanza simulata 20-50cm (sussurri all'orecchio, respiro)
# • Loudnorm soft per preservare dinamica dei sussurri
# • Crossfeed moderato per presenza frontale naturale
# • EQ ottimizzata per warmth + breath sounds + intimacy
# • ITD configurabile (centrale/near/whisper)
# • Boost selettivo su frequenze "calore corporeo" (80-150Hz)
# • De-essing delicato per sibilanti naturali ma non aggressive
# • Pseudo-LFO "breathing" opzionale per effetto ipnotico
#
# Uso:
#   ./asmr_vr_intimate.sh file1.mp4 file2.mkv ...
#   ./asmr_vr_intimate.sh -d whisper -l input.mkv    # distanza sussurro + LFO
#   ./asmr_vr_intimate.sh -o OUTDIR -k *.mp4
# ────────────────────────────────────────────────────────────────────────────────

OUTDIR=""
KEEP_ORIG=0
OVERWRITE=0
USE_LFO=0
DISTANCE_MODE="whisper"  # whisper (20-30cm) | near (30-50cm) | center (frontale)

die()  { echo "ERRORE: $*" >&2; exit 1; }
log()  { echo "• $*" >&2; }
warn() { echo "⚠ $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Comando mancante: $1"; }
need_cmd ffmpeg
need_cmd ffprobe

show_help() {
  cat >&2 <<'EOF'
Intimate VR Presence 20–50cm — Stereo → pseudo-binaurale ultra-ravvicinata (2026)

Uso:
  asmr_vr_intimate.sh [opzioni] <file1> [file2 ...]

Opzioni:
  -o <dir>      Cartella di output (default: stessa del file)
  -d <mode>     Distanza simulata: whisper|near|center (default: whisper)
                  whisper = 20-30cm (sussurro all'orecchio, massima intimità)
                  near    = 30-50cm (conversazione ravvicinata)
                  center  = frontale centrale (VR chat)
  -k            Mantieni traccia audio originale come seconda traccia
  -f            Forza overwrite
  -l            Attiva pseudo-LFO "breathing" (effetto ipnotico lento)
  -h            Questo help

Note:
  • Ottimizzato per contenuti intimi/sexy con voce sussurrata
  • EQ calibrata per warmth, breath sounds, intimacy
  • Progettato per cuffie chiuse o semi-aperte
  • LFO simula "respirazione" dello spazio (5-8 sec ciclo)
EOF
}

# ── Parse args ────────────────────────────────────────────────────────────────
while getopts ":o:d:kfhl" opt; do
  case "$opt" in
    o) OUTDIR="$OPTARG" ;;
    d) DISTANCE_MODE="$OPTARG" ;;
    k) KEEP_ORIG=1 ;;
    f) OVERWRITE=1 ;;
    l) USE_LFO=1 ;;
    h) show_help; exit 0 ;;
    \?) die "Opzione non valida: -$OPTARG (usa -h)" ;;
    :) die "Opzione -$OPTARG richiede argomento (usa -h)" ;;
  esac
done
shift $((OPTIND-1))

[[ $# -ge 1 ]] || { show_help; exit 1; }

# Validate distance mode
case "$DISTANCE_MODE" in
  whisper|near|center) ;;
  *) die "Modalità distanza non valida: '$DISTANCE_MODE' (usa whisper|near|center)" ;;
esac

# ── ffprobe per trovare la traccia audio migliore ─────────────────────────────
probe_audio() {
  local f="$1" line best=""
  mapfile -t _A_LINES < <(
    ffprobe -v error -select_streams a \
      -show_entries stream=index,channels,channel_layout:stream_disposition=default:stream_tags=language \
      -of csv=p=0 "$f" 2>/dev/null || true
  )

  [[ ${#_A_LINES[@]} -gt 0 ]] || return 1

  for line in "${_A_LINES[@]}"; do
    IFS=',' read -r idx ch layout def lang <<<"$line"
  # priorità: stereo default
    [[ "$ch" -eq 2 && "$def" == "1" ]] && { best="$line"; break; }
  # fallback: stereo non-default
    [[ "$ch" -eq 2 && -z "$best" ]] && best="$line"
  done
  
  [[ -z "$best" ]] && return 1
  IFS=',' read -r AIDX ACH ALAYOUT ADEF ALANG <<<"$best"
  ACH="${ACH:-0}"
  ALAYOUT="${ALAYOUT:-unknown}"
  ALANG="${ALANG:-}"
}

# ── Filtri audio per distanza ─────────────────────────────────────────────────
# WHISPER (20-30cm) - Massima intimità, sussurro all'orecchio
FILTER_WHISPER=$(cat <<'EOF'
highpass=f=60:order=2,
lowpass=f=15000,
loudnorm=I=-20:TP=-2.0:LRA=13,
aresample=48000,
crossfeed=strength=0.42:range=0.35:level_in=0.95:level_out=0.95,
stereotools=balance_in=0:slev=0.75:mlev=1.12:phase=0,
pan=stereo|c0=1.08*c0 + 0.15*c1|c1=0.15*c0 + 1.08*c1,
equalizer=f=85:t=q:w=1.6:g=2.2,
equalizer=f=140:t=q:w=1.4:g=1.6,
equalizer=f=320:t=q:w=1.2:g=-1.2,
equalizer=f=1200:t=q:w=1.0:g=0.6,
equalizer=f=2800:t=q:w=1.8:g=1.8,
equalizer=f=5800:t=q:w=2.0:g=-1.8,
equalizer=f=9000:t=q:w=1.2:g=1.4,
equalizer=f=12000:t=q:w=1.0:g=0.8,
alimiter=limit=0.96:attack=2:release=40:asc=1
EOF
)

# NEAR (30-50cm) - Conversazione ravvicinata intima
FILTER_NEAR=$(cat <<'EOF'
highpass=f=70:order=2,
lowpass=f=14500,
loudnorm=I=-19:TP=-1.8:LRA=12,
aresample=48000,
crossfeed=strength=0.50:range=0.40:level_in=0.94:level_out=0.94,
stereotools=balance_in=0:slev=0.70:mlev=1.08:phase=0,
pan=stereo|c0=1.10*c0 + 0.12*c1|c1=0.12*c0 + 1.10*c1,
equalizer=f=100:t=q:w=1.5:g=1.8,
equalizer=f=280:t=q:w=1.2:g=-1.0,
equalizer=f=3200:t=q:w=1.6:g=1.4,
equalizer=f=6200:t=q:w=2.0:g=-1.6,
equalizer=f=9500:t=q:w=1.3:g=1.2,
alimiter=limit=0.97:attack=2.5:release=45:asc=1
EOF
)

# CENTER - Frontale centrale (meno intimo, più conversazionale)
FILTER_CENTER=$(cat <<'EOF'
highpass=f=80:order=2,
lowpass=f=14000,
loudnorm=I=-18:TP=-1.5:LRA=11,
aresample=48000,
crossfeed=strength=0.55:range=0.45:level_in=0.93:level_out=0.93,
stereotools=balance_in=0:slev=0.65:mlev=1.05:phase=0,
pan=stereo|c0=1.12*c0 + 0.10*c1|c1=0.10*c0 + 1.12*c1,
equalizer=f=120:t=q:w=1.4:g=1.4,
equalizer=f=280:t=q:w=1.2:g=-0.9,
equalizer=f=3200:t=q:w=1.8:g=1.1,
equalizer=f=6200:t=q:w=2.2:g=-1.5,
equalizer=f=9500:t=q:w=1.5:g=1.0,
alimiter=limit=0.97:attack=3:release=50:asc=1
EOF
)

# ── ITD (Interaural Time Difference) per distanza ────────────────────────────
# whisper: 380µs asimmetrico = sussurro leggermente spostato (più naturale/intimo)
# near: 200µs simmetrico = presenza frontale bilanciata
# center: 0µs = perfettamente centrale
ITD_WHISPER="adelay=0|0.38"
ITD_NEAR="adelay=0|0.20"
ITD_CENTER="adelay=0|0.00"

# ── Pseudo-LFO "breathing" (effetto ipnotico intimo) ─────────────────────────
# Chorus più delicato + modulazione pan lenta per simulare respiro ravvicinato
# Frequenza 0.10–0.16 Hz → ciclo ogni 6–10 secondi (ritmo respiratorio naturale)
LFO_PART=$(cat <<'EOF'
chorus=0.6:0.8:50|65:0.30|0.25:0.20|0.35:decay=0.7,
pan=stereo|c0=1.0*c0 + 0.06*c1*sin(2*PI*0.12*t)|c1=1.0*c1 + 0.06*c0*sin(2*PI*0.12*t + PI/3)
EOF
)

# ── Main loop ─────────────────────────────────────────────────────────────────
for IN in "$@"; do
  [[ -f "$IN" ]] || { warn "File non trovato: $IN"; continue; }

  base="$(basename "$IN")"
  dir="$(dirname "$IN")"
  name="${base%.*}"

  # Output filename based on distance mode
  case "$DISTANCE_MODE" in
    whisper) OUT="${name}_Intimate_Whisper20-30cm.mkv" ;;
    near)    OUT="${name}_Intimate_Near30-50cm.mkv" ;;
    center)  OUT="${name}_Intimate_Center.mkv" ;;
  esac
  [[ -n "$OUTDIR" ]] && { mkdir -p "$OUTDIR"; OUT="$OUTDIR/$OUT"; } || OUT="$dir/$OUT"

  [[ -f "$OUT" && "$OVERWRITE" -eq 0 ]] && {
    warn "Output già esistente, salto: $OUT (usa -f per forzare)"
    continue
  }

  probe_audio "$IN" || { warn "Nessuna traccia audio valida, salto"; continue; }

  log "Input:     $IN"
  log "Audio:     stream #$AIDX • ${ACH}ch • layout=$ALAYOUT${ALANG:+ • lang=$ALANG}"
  log "Distance:  $DISTANCE_MODE"
  [[ "$USE_LFO" -eq 1 ]] && log "LFO:       enabled (breathing effect)"
  log "Output:    $OUT"

  [[ "$ACH" -ne 2 ]] && {
    warn "Audio non stereo (${ACH}ch). Preset progettato per stereo. Salto."
    continue
  }

  TMP="${OUT%.mkv}.part.$$.mkv"

  # Select filter and ITD based on distance mode
  case "$DISTANCE_MODE" in
    whisper)
      BASE_FILTER="$FILTER_WHISPER"
      ITD="$ITD_WHISPER"
      ;;
    near)
      BASE_FILTER="$FILTER_NEAR"
      ITD="$ITD_NEAR"
      ;;
    center)
      BASE_FILTER="$FILTER_CENTER"
      ITD="$ITD_CENTER"
      ;;
  esac

  # Build complete filter chain
  FILTER="$BASE_FILTER,$ITD"
  [[ "$USE_LFO" -eq 1 ]] && FILTER="$FILTER,$LFO_PART"

  cmd=(
    ffmpeg
    -hide_banner
    -fflags +genpts
    -i "$IN"
    -map_metadata 0
    -map_chapters 0
    -map 0:v?
    -map 0:"$AIDX"
    -map 0:s?
    -map 0:t?
    -c:v copy
    -c:s copy
    -c:t copy
    -filter:a:0 "$FILTER"
    -c:a:0 aac -b:a:0 256k -ac:a:0 2 -ar:a:0 48000
  )

  if [[ "$KEEP_ORIG" -eq 1 ]]; then
    cmd+=(
      -map 0:"$AIDX"           # seconda traccia = originale
      -c:a:1 copy
      -metadata:s:a:1 title="Original Stereo (unedited)"
      -disposition:a:1 0
    )
    [[ -n "$ALANG" && "${ALANG,,}" != "und" ]] && cmd+=(-metadata:s:a:1 language="$ALANG")
  fi

  [[ -n "$ALANG" && "${ALANG,,}" != "und" ]] && cmd+=(-metadata:s:a:0 language="$ALANG")
  
  # Title based on mode
  case "$DISTANCE_MODE" in
    whisper) TITLE="Intimate Whisper 20-30cm (2026 tuned)" ;;
    near)    TITLE="Intimate Near 30-50cm (2026 tuned)" ;;
    center)  TITLE="Intimate Center VR (2026 tuned)" ;;
  esac
  [[ "$USE_LFO" -eq 1 ]] && TITLE="$TITLE + Breathing LFO"
  
  cmd+=(
    -metadata:s:a:0 title="$TITLE"
    -disposition:a:0 default
    -y "$TMP"
  )

  log "Processing..."
  if "${cmd[@]}"; then
      mv -f "$TMP" "$OUT"
    else
      warn "ffmpeg fallito, file temporaneo lasciato per debug: $TMP"
    continue
  fi

  log "OK: $OUT"
  echo >&2
done

log "Fine elaborazione."