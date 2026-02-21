#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# Intimate VR Presence 20–50cm — JMEIER BINAURAL EDITION (2026)
# ────────────────────────────────────────────────────────────────────────────────

OUTDIR=""
KEEP_ORIG=0
OVERWRITE=0
USE_LFO=0
DISTANCE_MODE="whisper"

die()  { echo -e "\033[0;31mERRORE:\033[0m $*" >&2; exit 1; }
log()  { echo -e "\033[0;36m•\033[0m $*" >&2; }
warn() { echo -e "\033[0;33m⚠\033[0m $*" >&2; }
ok()   { echo -e "\033[0;32m✓\033[0m $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Comando mancante: $1"; }
need_cmd ffmpeg
need_cmd ffprobe

show_help() {
  cat >&2 <<'EOF'
────────────────────────────────────────────────────────────────────────────────
  🧠 INTIMATE VR PRESENCE (J. Meier Crossfeed Edition)
────────────────────────────────────────────────────────────────────────────────
  Uso:
    ./asmr_vr_intimate.sh [opzioni] <file1> [file2 ...]

  Opzioni:
    -o <dir>    Cartella di output
    -d <mode>   Distanza: whisper (20-30cm) | near (30-50cm) | center (front)
    -k          Mantieni audio originale come traccia secondaria
    -l          Attiva effetto "Breathing LFO" (ipnotico)
    -f          Forza sovrascrittura
    -h          Mostra questa guida

  Note:
    • Preset WHISPER: Ottimizzato per sussurri all'orecchio (max intimità).
    • BS2B JMEIER: Algoritmo psicoacustico per eliminare la fatica in cuffia.
    • Bitrate 320k: Massima fedeltà per i micro-dettagli ASMR.
────────────────────────────────────────────────────────────────────────────────
EOF
}

[[ $# -eq 0 ]] && { show_help; exit 0; }

while getopts ":o:d:kfhl" opt; do
  case "$opt" in
    o) OUTDIR="$OPTARG" ;;
    d) DISTANCE_MODE="$OPTARG" ;;
    k) KEEP_ORIG=1 ;;
    f) OVERWRITE=1 ;;
    l) USE_LFO=1 ;;
    h) show_help; exit 0 ;;
    *) die "Opzione non valida. Usa -h per l'aiuto." ;;
  esac
done
shift $((OPTIND-1))

# ── Configurazione Filtri (BS2B JMEIER INTEGRATED) ────────────────────────────

# WHISPER (20-30cm)
FILTER_WHISPER="highpass=f=60:order=2,lowpass=f=15000,loudnorm=I=-20:TP=-2.0:LRA=13,aresample=48000,bs2b=profile=jmeier,stereotools=balance_in=0:slev=0.75:mlev=1.12:phase=0,pan=stereo|c0=1.08*c0 + 0.15*c1|c1=0.15*c0 + 1.08*c1,equalizer=f=85:t=q:w=1.6:g=2.2,equalizer=f=140:t=q:w=1.4:g=1.6,equalizer=f=320:t=q:w=1.2:g=-1.2,equalizer=f=2800:t=q:w=1.8:g=1.8,equalizer=f=5800:t=q:w=2.0:g=-1.8,alimiter=limit=0.96:attack=2:release=40"

# NEAR (30-50cm)
FILTER_NEAR="highpass=f=70:order=2,lowpass=f=14500,loudnorm=I=-19:TP=-1.8:LRA=12,aresample=48000,bs2b=profile=jmeier,stereotools=balance_in=0:slev=0.70:mlev=1.08:phase=0,pan=stereo|c0=1.10*c0 + 0.12*c1|c1=0.12*c0 + 1.10*c1,equalizer=f=100:t=q:w=1.5:g=1.8,equalizer=f=3200:t=q:w=1.6:g=1.4,equalizer=f=6200:t=q:w=2.0:g=-1.6,alimiter=limit=0.97:attack=2.5:release=45"

# CENTER (Frontal)
FILTER_CENTER="highpass=f=80:order=2,lowpass=f=14000,loudnorm=I=-18:TP=-1.5:LRA=11,aresample=48000,bs2b=profile=jmeier,stereotools=balance_in=0:slev=0.65:mlev=1.05:phase=0,pan=stereo|c0=1.12*c0 + 0.10*c1|c1=0.10*c0 + 1.12*c1,equalizer=f=120:t=q:w=1.4:g=1.4,equalizer=f=3200:t=q:w=1.8:g=1.1,equalizer=f=6200:t=q:w=2.2:g=-1.5,alimiter=limit=0.97:attack=3:release=50"

# Delays (ITD)
ITD_WHISPER="adelay=delays=0|0.38:all=0"
ITD_NEAR="adelay=delays=0|0.20:all=0"
ITD_CENTER=""

# LFO Breathing Effect
LFO_PART="chorus=0.6:0.8:50|65:0.30|0.25:0.20|0.35:decay=0.7,pan=stereo|c0=1.0*c0 + 0.06*c1*sin(2*PI*0.12*t)|c1=1.0*c1 + 0.06*c0*sin(2*PI*0.12*t + PI/3)"

# ── Main Processing Loop ─────────────────────────────────────────────────────

for IN in "$@"; do
  [[ -f "$IN" ]] || continue
  
  # Selezione preset
  case "$DISTANCE_MODE" in
    whisper) F_BASE="$FILTER_WHISPER"; ITD="$ITD_WHISPER"; T="Whisper 20-30cm" ;;
    near)    F_BASE="$FILTER_NEAR";    ITD="$ITD_NEAR";    T="Near 30-50cm" ;;
    center)  F_BASE="$FILTER_CENTER";  ITD="$ITD_CENTER";  T="Center Front" ;;
    *)       die "Distanza non valida: '$DISTANCE_MODE'. Valori: whisper | near | center" ;;
  esac
  
  if [[ -n "$ITD" ]]; then
    FINAL_F="$F_BASE,$ITD"
  else
    FINAL_F="$F_BASE"
  fi
  [[ "$USE_LFO" -eq 1 ]] && FINAL_F="$FINAL_F,$LFO_PART"

  OUT="${IN%.*}_INTIMATE_${DISTANCE_MODE^^}.mkv"
  [[ -n "$OUTDIR" ]] && OUT="$OUTDIR/$(basename "$OUT")"

  log "Processing: $(basename "$IN") -> $T"

  ffmpeg -y -hide_banner -loglevel warning -stats -i "$IN" \
    -filter:a:0 "$FINAL_F" \
    -c:v copy -c:s copy -c:t copy \
    -c:a:0 aac -b:a:0 320k -ac:a:0 2 -ar:a:0 48000 \
    -metadata:s:a:0 title="VR Intimate ($T) - Gemini J.Meier Tuned" \
    -disposition:a:0 default "$OUT"

  ok "Completato: $OUT"
done