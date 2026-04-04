#!/usr/bin/env bash
# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   atmos_to_51_dynaudnorm.sh                                                  │
# │                                                                              │
# │   Prende un file con traccia EAC3 Atmos (JOC) e produce un MKV con:          │
# │     • Traccia 1: EAC3 5.1 standard con normalizzazione dinamica (default)    │
# │     • Traccia 2: EAC3 Atmos originale (copia bit-perfect)                    │
# │                                                                              │
# │   La decodifica FFmpeg di EAC3 JOC produce il bed 5.1 automaticamente        │
# │   (FFmpeg non ha un renderer Atmos a oggetti). dynaudnorm equalizza la       │
# │   dinamica senza compressione distruttiva, ideale per ascolto notturno       │
# │   o sistemi senza ampia escursione dinamica.                                 │
# │                                                                              │
# │   UTILIZZO:                                                                  │
# │     ./atmos_to_51_dynaudnorm.sh <file|directory> [bitrate]                   │
# │                                                                              │
# │   PARAMETRI:                                                                 │
# │     file    : File sorgente (mkv/mp4/m2ts) oppure directory da processare.   │
# │     bitrate : Bitrate traccia 5.1 (default: 640k).                           │
# │                                                                              │
# │   DIPENDENZE: ffmpeg, ffprobe (con supporto EAC3 JOC)                        │
# ╰──────────────────────────────────────────────────────────────────────────────╯
set -uo pipefail

# ── Colori ────────────────────────────────────────────────────────────────────
C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"

info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

confirm_overwrite() {
  local target="$1"
  local ans=""
  if [[ ! -e /dev/tty ]]; then
    warn "TTY non disponibile e '$target' esiste gia' -> skip automatico."
    return 1
  fi
  echo -ne "${C_WARN} '$target' esiste gia'. Sovrascrivere? [s/n/t]: "
  if ! read -r ans < /dev/tty; then
    warn "Impossibile leggere da /dev/tty -> skip automatico."
    return 1
  fi
  case "${ans,,}" in
    t|tutti) OVERWRITE_ALL=true; info "Sovrascrittura automatica attivata."; return 0 ;;
    s|si|y|yes) info "Sovrascrivo."; return 0 ;;
    *) info "Skip manuale richiesto."; return 1 ;;
  esac
}


usage() {
  cat <<'USAGE'
UTILIZZO:
  ./atmos_to_51_dynaudnorm.sh <file|directory> [bitrate]

PARAMETRI:
  file|directory : File sorgente (mkv/mp4/m2ts) oppure cartella contenente
                   file video da processare in batch.
  bitrate        : Bitrate traccia EAC3 5.1 in uscita (default: 640k).

ESEMPI:
  ./atmos_to_51_dynaudnorm.sh film.mkv           # singolo file, 640k
  ./atmos_to_51_dynaudnorm.sh film.mkv 768k      # singolo file, bitrate custom
  ./atmos_to_51_dynaudnorm.sh /path/to/folder    # batch su cartella
  ./atmos_to_51_dynaudnorm.sh . 768k             # batch su dir corrente

OUTPUT:
  <nome>_EAC3_51_DynNorm.mkv con:
    • Traccia 1: EAC3 5.1 normalizzata (dynaudnorm, default)
    • Traccia 2: EAC3 Atmos originale (copia bit-perfect)

DIPENDENZE: ffmpeg, ffprobe (con supporto EAC3 JOC)
USAGE
  exit 0
}

# ── Help: nessun argomento o flag esplicito ───────────────────────────────────
[[ $# -eq 0 || "${1:-}" =~ ^(-h|--help)$ ]] && usage

for _bin in ffmpeg ffprobe; do
  command -v "$_bin" &>/dev/null || { err "$_bin non trovato nel PATH"; exit 1; }
done

# ── Parametri ─────────────────────────────────────────────────────────────────
INPUT_ARG="${1:-}"
BITRATE="${2:-640k}"

[[ "$BITRATE" =~ ^[0-9]+(k|M)?$ ]] || { err "Bitrate '$BITRATE' non valido. Es: 640k, 768k."; exit 1; }
# Fix bitrate senza suffisso
[[ "$BITRATE" =~ k$|M$ ]] || BITRATE="${BITRATE}k"

# ── dynaudnorm: parametri dallo screenshot (tutti default FFmpeg) ─────────────
# framelen=500   : finestra 500ms — buon compromesso reattività/smoothness
# gausssize=31   : finestra gaussiana 31 frame — smoothing ampio (no pumping)
# peak=0.95      : target peak 95% — headroom per evitare clipping
# maxgain=10     : max amplificazione 10x (20dB) — limita boost su silenzi
# targetrms=0    : disabilitato — lavora solo su peak, non su RMS
# compress=0     : disabilitato — nessuna compressione aggiuntiva
# coupling=1     : canali accoppiati — preserva l'immagine stereo/surround
# altboundary=0  : boundary mode standard
DYNAUDNORM="dynaudnorm=framelen=500:gausssize=31:peak=0.95:maxgain=10:targetrms=0:compress=0:coupling=1:altboundary=0"

# ── Probe: trova traccia EAC3 Atmos (JOC) ────────────────────────────────────
# Cerchiamo specificamente eac3 con atmos_information oppure joc_complexity > 0.
# Fallback: prima traccia eac3 con 6+ canali.
#
# NOTA: il profilo EAC3 Atmos in FFmpeg contiene spazi ("Dolby Digital Plus
# + Dolby Atmos") che rompono il parsing CSV. Per evitare il problema usiamo
# due probe separate: una CSV senza profilo per idx/codec/ch/lang, e una
# dedicata per verificare se il profilo contiene "atmos".
find_atmos_stream() {
  local f="$1"
  local _lines

  # Probe base: indice globale, codec, canali, lingua (no profilo = no spazi insidiosi)
  mapfile -t _lines < <(ffprobe -v error -select_streams a \
    -show_entries stream=index,codec_name,channels:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null || true)

  [[ ${#_lines[@]} -gt 0 ]] || return 1

  local best_idx="" best_ch=0 best_lang="" fallback_idx="" fallback_ch=0 fallback_lang=""
  local audio_ord=0

  for line in "${_lines[@]}"; do
    [[ -z "$line" ]] && { ((audio_ord++)) || true; continue; }

    local idx codec ch lang
    IFS=',' read -r idx codec ch lang <<<"$line"
    codec="${codec:-}"
    ch="${ch:-0}"
    lang="${lang:-}"

    # Solo EAC3
    if [[ "$codec" != "eac3" ]]; then
      ((audio_ord++)) || true
      continue
    fi

    local is_atmos=false

    # Metodo 1: profilo contiene "atmos" (usa indice relativo audio, non globale)
    local profile_str
    profile_str=$(ffprobe -v error -select_streams "a:${audio_ord}" \
      -show_entries stream=profile \
      -of csv=p=0 "$f" 2>/dev/null | head -1 || true)
    [[ "${profile_str,,}" == *"atmos"* ]] && is_atmos=true

    # Metodo 2: check joc_complexity via side_data (FFmpeg 5+)
    if [[ "$is_atmos" == false ]]; then
      local joc
      joc=$(ffprobe -v error -select_streams "a:${audio_ord}" \
        -show_entries frame_side_data=joc_complexity \
        -read_intervals "%+#1" \
        -of csv=p=0 "$f" 2>/dev/null | head -1 || true)
      [[ -n "$joc" && "$joc" != "0" ]] && is_atmos=true
    fi

    if [[ "$is_atmos" == true && "$ch" -ge 6 ]]; then
      # Preferisci italiano
      if [[ -z "$best_idx" ]] || [[ "${lang,,}" =~ ^it ]]; then
        best_idx="$idx"
        best_ch="$ch"
        best_lang="$lang"
      fi
    elif [[ "$ch" -ge 6 && -z "$fallback_idx" ]]; then
      fallback_idx="$idx"
      fallback_ch="$ch"
      fallback_lang="$lang"
    fi

    ((audio_ord++)) || true
  done

  if [[ -n "$best_idx" ]]; then
    echo "${best_idx}|${best_ch}|${best_lang}|atmos"
    return 0
  fi

  # Fallback: EAC3 multichannel (potrebbe essere Atmos non rilevato via probe —
  # capita spesso, specialmente con container MKV dove i metadati JOC sono nel
  # bitstream ma non esposti come side_data)
  if [[ -n "$fallback_idx" ]]; then
    warn "Nessun flag Atmos esplicito trovato — uso traccia EAC3 ${fallback_ch}ch (idx:${fallback_idx}) come fallback"
    echo "${fallback_idx}|${fallback_ch}|${fallback_lang}|fallback"
    return 0
  fi

  return 1
}

# ── Raccolta file ─────────────────────────────────────────────────────────────
FILES=()
if [[ -d "$INPUT_ARG" ]]; then
  shopt -s nullglob
  FILES+=( "$INPUT_ARG"/*.mkv "$INPUT_ARG"/*.MKV "$INPUT_ARG"/*.mp4 "$INPUT_ARG"/*.MP4 "$INPUT_ARG"/*.m2ts "$INPUT_ARG"/*.M2TS )
  shopt -u nullglob
elif [[ -f "$INPUT_ARG" ]]; then
  FILES+=("$INPUT_ARG")
else
  err "File o cartella non esiste: $INPUT_ARG"; exit 1
fi

FILTERED_FILES=()
for f in "${FILES[@]}"; do
  case "$f" in
    *_EAC3_51_DynNorm.mkv)
      info "Skip output gia' normalizzato: $f"
      continue
      ;;
    *)
      FILTERED_FILES+=("$f")
      ;;
  esac
done
FILES=("${FILTERED_FILES[@]}")

(( ${#FILES[@]} == 0 )) && { err "Nessun file trovato."; exit 1; }

info "Bitrate 5.1: $BITRATE"
info "dynaudnorm:  $DYNAUDNORM"
echo ""

# ── Ciclo elaborazione ───────────────────────────────────────────────────────
OVERWRITE_ALL=false

for CUR_FILE in "${FILES[@]}"; do
  info "━━━ Input: $CUR_FILE"

  # Trova traccia Atmos/EAC3
  PROBE_RESULT=$(find_atmos_stream "$CUR_FILE") || {
    warn "Nessuna traccia EAC3 multichannel trovata → salto."
    continue
  }

  IFS='|' read -r A_IDX A_CH A_LANG A_TYPE <<<"$PROBE_RESULT"

  info "Traccia audio: idx=$A_IDX, canali=$A_CH, lingua=$A_LANG, tipo=$A_TYPE"

  # Determina layout per il pan filter
  # EAC3 Atmos decodificato esce tipicamente come 5.1(side)
  A_LAYOUT=$(ffprobe -v error -select_streams a     -show_entries stream=index,channel_layout     -of csv=p=0 "$CUR_FILE" 2>/dev/null | awk -F',' -v idx="$A_IDX" '$1==idx { print $2; exit }' || true)

  # Se il layout non è esposto (capita con certi container), deduciamo da ch count
  if [[ -z "$A_LAYOUT" && "$A_CH" -ge 6 ]]; then
    A_LAYOUT="5.1(side)"
    info "Layout non esposto dal container → assunto 5.1(side) per EAC3 ${A_CH}ch"
  fi

  case "$A_LAYOUT" in
    "5.1(side)") SUR_L="SL"; SUR_R="SR" ;;
    "5.1"|"5.1(back)") SUR_L="BL"; SUR_R="BR" ;;
    *)
      SUR_L="SL"; SUR_R="SR"
      warn "Layout non standard: '${A_LAYOUT:-sconosciuto}' → fallback 5.1(side)"
      ;;
  esac

  # ── Filename output ─────────────────────────────────────────────────────────
  OUT_FILE="${CUR_FILE%.*}_EAC3_51_DynNorm.mkv"

  # ── Gestione sovrascrittura ─────────────────────────────────────────────────
  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      confirm_overwrite "$OUT_FILE" || { info "Salto '$CUR_FILE'."; continue; }
    else
      info "Sovrascrittura automatica: '$OUT_FILE'"
    fi
  fi

  # ── Filter complex ──────────────────────────────────────────────────────────
  # La traccia Atmos decodificata da FFmpeg produce il bed 5.1.
  # Normalizziamo a 5.1(side) per uniformità, applichiamo dynaudnorm con
  # coupling (preserva immagine surround), e codifichiamo in EAC3 standard.
  #
  # NOTA: dynaudnorm con coupling=1 analizza tutti i canali insieme e applica
  # lo stesso gain factor → l'immagine spaziale rimane intatta. Senza coupling,
  # canali silenziosi (LFE nei passaggi senza bassi) verrebbero amplificati
  # indipendentemente, causando rumore di fondo e pumping sul sub.
  FILTER_COMPLEX="[0:${A_IDX}]aformat=sample_rates=48000:sample_fmts=fltp:channel_layouts=5.1(side),pan=5.1(side)|FL=FL|FR=FR|FC=FC|LFE=LFE|SL=${SUR_L}|SR=${SUR_R},${DYNAUDNORM}[aout]"

  # ── FFmpeg command ──────────────────────────────────────────────────────────
  CMD=(ffmpeg -hide_banner -nostdin -stats -loglevel warning)
  [[ -f "$OUT_FILE" ]] && CMD+=( -y )
  CMD+=(
    -i "$CUR_FILE"
    -map_metadata 0 -map_chapters 0

    # Video, sottotitoli, allegati: copia
    -map "0:V:0?" -c:v copy
    -map "0:s?" -c:s copy
    -map "0:t?" -c:t copy

    # Traccia 1: EAC3 5.1 con dynaudnorm
    -filter_complex "$FILTER_COMPLEX"
    -map "[aout]"
    -c:a:0 eac3 -b:a:0 "$BITRATE" -ar:a:0 48000 -ac:a:0 6
    -metadata:s:a:0 "title=EAC3 5.1 – Dynamic Normalized"
    -disposition:a:0 default

    # Traccia 2: Atmos originale (copia bit-perfect)
    -map "0:${A_IDX}"
    -c:a:1 copy
    -metadata:s:a:1 "title=EAC3 Atmos (Original)"
    -disposition:a:1 0
  )

  # Lingua
  if [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]]; then
    CMD+=( -metadata:s:a:0 "language=$A_LANG" )
    CMD+=( -metadata:s:a:1 "language=$A_LANG" )
  fi

  CMD+=( "$OUT_FILE" )

  # ── Esecuzione ──────────────────────────────────────────────────────────────
  info "Avvio encoding..."
  "${CMD[@]}" && ok "Creato: $OUT_FILE" || warn "Errore su: $CUR_FILE"
  echo ""
done

ok "Elaborazione completata."
