#!/usr/bin/env bash
set -euo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   stereo251_gemini_pro.sh — UPMIX FIXED & SMART                              │
# │   • Fix: Join 5.1(side) per evitare errore SL                                │
# │   • Smart Args: Rileva se passi subito il file o la modalità                 │
# │   • Full Range + EQ Sartoriale V2                                            │
# ╰──────────────────────────────────────────────────────────────────────────────╯

# ────────────────────────────────────────────────────────────────────────────────
# Colori terminale
# ────────────────────────────────────────────────────────────────────────────────
C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"

info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

# ────────────────────────────────────────────────────────────────────────────────
# Gestione Argomenti Intelligente
# ────────────────────────────────────────────────────────────────────────────────
# Default
OUT_CODEC="eac3"
BITRATE="320k"
MODE="modern"
INPUT_FILE=""

# Helper per capire cosa l'utente sta passando
if [[ $# -gt 0 ]]; then
    # Se il primo argomento è un file esistente, assumiamo uso rapido
    if [[ -f "$1" ]]; then
        INPUT_FILE="$1"
        info "Rilevato file in ingresso diretto. Uso default: $OUT_CODEC $BITRATE $MODE"
    
    # Se il primo argomento è "vintage" o "modern", assumiamo uso con preset
    elif [[ "$1" == "vintage" || "$1" == "modern" ]]; then
        MODE="$1"
        if [[ -n "${2:-}" && -f "$2" ]]; then
            INPUT_FILE="$2"
        fi
        info "Rilevata modalità '$MODE'. Uso default: $OUT_CODEC $BITRATE"

    # Altrimenti, parsing classico: codec bitrate mode file
    else
        OUT_CODEC="${1:-eac3}"
        BITRATE="${2:-320k}"
        MODE="${3:-modern}"
        INPUT_FILE="${4:-}"
    fi
fi

# Validazione bitrate
[[ "$BITRATE" =~ ^[0-9]+k$ ]] || { warn "Bitrate sospetto: '$BITRATE'. Forzo 320k"; BITRATE="320k"; }

# Validazione Mode
if [[ "$MODE" != "vintage" && "$MODE" != "modern" ]]; then
    warn "Modalità '$MODE' sconosciuta. Forzo: modern"
    MODE="modern"
fi

info "Configurazione: Codec=$OUT_CODEC | Bitrate=$BITRATE | Mode=$MODE"

# ────────────────────────────────────────────────────────────────────────────────
# Logica Upmix
# ────────────────────────────────────────────────────────────────────────────────

EQ_VOICE="equalizer=f=230:t=q:w=2.0:g=-4.5,equalizer=f=350:t=q:w=1.5:g=-2.5,equalizer=f=1000:t=q:w=1.2:g=1.6,equalizer=f=2500:t=q:w=1.0:g=1.6,equalizer=f=7200:t=q:w=2.5:g=-1.2"

if [[ "$MODE" == "vintage" ]]; then
    # VINTAGE (Twin Peaks, X-Files, Film <2000)
    SUR_DELAY="12"
    SUR_VOL="0.65"
    SUR_LP="6000"
    info "Engine: VINTAGE (Delay 12ms, Lowpass 6kHz, Vol basso)"
else
    # MODERN (Star Trek, Netflix, Action)
    SUR_DELAY="25"
    SUR_VOL="0.90"
    SUR_LP="12000"
    info "Engine: MODERN (Delay 25ms, Lowpass 12kHz, Vol alto)"
fi

# FIX CRITICO: channel_layout=5.1(side) invece di 5.1 generico
UPMIX_FILTER="[0:a]asplit=4[front][c_in][lfe_in][surr_in];[front]aformat=channel_layouts=stereo[FLFR];[c_in]pan=mono|c0=0.5*c0+0.5*c1,${EQ_VOICE},aformat=channel_layouts=mono[FC];[lfe_in]pan=mono|c0=0.5*c0+0.5*c1,lowpass=f=120,aformat=channel_layouts=mono[LFE];[surr_in]adelay=${SUR_DELAY}|${SUR_DELAY},lowpass=f=${SUR_LP},volume=${SUR_VOL},aformat=channel_layouts=stereo[SLSR];[FLFR][FC][LFE][SLSR]join=inputs=4:channel_layout=5.1(side):map=0.0-FL|0.1-FR|1.0-FC|2.0-LFE|3.0-SL|3.1-SR,alimiter=limit=0.99:attack=5:release=50[aout]"

# ────────────────────────────────────────────────────────────────────────────────
# Esecuzione
# ────────────────────────────────────────────────────────────────────────────────
FILES=()
if [[ -n "$INPUT_FILE" ]]; then 
    FILES+=("$INPUT_FILE")
else 
    # Se nessun file specificato, cerca nella cartella
    shopt -s nullglob
    FILES+=( *.mkv *.mp4 *.avi )
    shopt -u nullglob
fi

(( ${#FILES[@]} == 0 )) && { err "Nessun file trovato."; exit 1; }

for CUR_FILE in "${FILES[@]}"; do
  info "Elaborazione: $CUR_FILE"

  CHANNELS=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=channels \
    -of default=noprint_wrappers=1:nokey=1 "$CUR_FILE" | head -n1 | tr -d '\r')

  [[ -z "$CHANNELS" ]] && { warn "Nessuna traccia audio in $CUR_FILE. Salto."; continue; }

  if [[ "$CHANNELS" -ne 2 ]]; then
    warn "Non è stereo (Canali: $CHANNELS). Salto."
    continue
  fi

  BASENAME="${CUR_FILE%.*}"
  OUT_FILE="${BASENAME}_UPMIX_5.1_${MODE^^}.mkv"

  [[ -f "$OUT_FILE" ]] && {
      read -p "File esistente: $OUT_FILE. Sovrascrivere? [s/N] " ans
      [[ ! "$ans" =~ ^[sS] ]] && continue
  }

  CMD=(ffmpeg -y -hide_banner -nostdin -stats -loglevel warning \
    -i "$CUR_FILE" \
    -map_metadata 0 -map_chapters 0 \
    -filter_complex "$UPMIX_FILTER" \
    -map 0:v -c:v copy \
    -map 0:t? -c:t copy \
    -map "[aout]" -c:a:0 "$OUT_CODEC" -b:a:0 "$BITRATE" \
    -metadata:s:a:0 title="Upmix 5.1 Gemini (${MODE^^})" \
    -disposition:a:0 default \
    "$OUT_FILE")

  if "${CMD[@]}"; then
    ok "Creato: $OUT_FILE"
  else
    err "Errore su $CUR_FILE"
  fi
done