#!/usr/bin/env bash
# set -e rimosso: causa exit imprevedibili su pattern && / || e aritmetica bash.
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   stereo251_upmix.sh - V2 - Febbraio 2026                                    │
# │                                                                              │
# │   Motore di upmix offline da Stereo a 5.1 (eAC3/AC3).                        │
# │   Estrae il canale centrale (Dialoghi) e simula un'ambienza surround         │
# │   basata su mid/side processing e decorrelazione (Effetto Haas).             │
# │                                                                              │
# │   CHANGELOG V2:                                                              │
# │     - Rimosso set -e (allineato a aegis/analyzer)                            │
# │     - Selezione stream score-based (2ch, default, ita)                       │
# │     - asplit=3 invece di 6 (meno RAM/CPU)                                    │
# │     - Crossover FC/LFE: FC highpass 80Hz, LFE lowpass 120Hz + volume -6dB    │
# │     - Surround volume ridotto (0.85 modern, 0.70 vintage)                    │
# │     - Limiter level=0 (no auto-leveling, allineato al processore 5.1)        │
# │     - -y condizionale (solo su sovrascrittura confermata)                    │
# │     - Prompt overwrite da /dev/tty + opzione "tutti"                         │
# │     - Glob estesi + formati uppercase                                        │
# ╰──────────────────────────────────────────────────────────────────────────────╯

C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"

info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

for _bin in ffmpeg ffprobe; do
  command -v "$_bin" &>/dev/null || { err "$_bin non trovato nel PATH"; exit 1; }
done

usage() {
  cat <<'USAGE'
UTILIZZO:
  ./stereo251_upmix.sh <ac3|eac3> <si|no> [file|""] [bitrate] [preset]

PARAMETRI:
  ac3|eac3  : Codec audio in uscita.
  si|no     : Conserva traccia stereo originale come secondaria.
  file      : Nome del file (o "" per batch su cartella).
  bitrate   : Es. 448k, 640k, 768k (default: 448k).
  preset    : modern  (Default) Surround reattivi, eq brillante (Azione/Sci-Fi).
              vintage Surround ritardati, roll-off alto (Stile Dolby Pro Logic).

NOTA:
  La selezione dello stream e' score-based (allineata a aegis/analyzer):
  priorita' a tracce stereo (2ch), default, lingua italiana.

ESEMPI:
  ./stereo251_upmix.sh eac3 no 'movie.mkv' 448k modern
  ./stereo251_upmix.sh ac3 si '' 640k vintage   # Batch su cartella
  ./stereo251_upmix.sh eac3 no                   # Batch, default 448k modern
USAGE
  exit 1
}

[[ $# -lt 2 ]] && usage

OUT_CODEC="${1:-}"
KEEP_STEREO="${2:-no}"
INPUT_FILE="${3:-}"
BITRATE="${4:-448k}"
MODE="${5:-modern}"

case "$OUT_CODEC" in ac3|eac3) ;; *) err "Codec deve essere ac3 o eac3"; exit 1;; esac
[[ "$KEEP_STEREO" =~ ^(si|no)$ ]] || { err "Parametro 2 deve essere 'si' o 'no'"; exit 1; }
case "$MODE" in modern|vintage) ;; *) err "Preset '$MODE' non valido. Usa modern o vintage."; exit 1;; esac

# --- FIX BITRATE KAMIKAZE ---
[[ "$BITRATE" =~ k$|M$ ]] || BITRATE="${BITRATE}k"
# ----------------------------

info "Upmix Mode:     ${MODE^^}"
info "Codec target:   ${OUT_CODEC^^} @ ${BITRATE}"

# ────────────────────────────────────────────────────────────────────────────────
# Selezione stream score-based (allineata a aegis/analyzer)
#
# Score: 2 canali (stereo) -> +1000, default -> +200, lingua italiana -> +300
# A parita' di score, vince il primo trovato.
# Restituisce via stdout: idx|ch|lang
# ────────────────────────────────────────────────────────────────────────────────
pick_best_stereo_stream() {
  local f="$1"
  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null </dev/null || true)
  raw_data="${raw_data//$'\r'/}"

  [[ -z "$raw_data" ]] && return 1

  local best_line="" best_score=-1
  local lines
  mapfile -t lines <<< "$raw_data"
  for line in "${lines[@]}"; do
    [[ -z "$line" ]] && continue
    local idx ch def lang
    IFS=',' read -r idx ch def lang <<<"$line"
    ch="${ch:-0}"
    def="${def:-0}"
    lang="${lang:-}"

    local score=0
    [[ "$ch" =~ ^[0-9]+$ && "$ch" -eq 2 ]] && score=$((score + 1000))
    [[ "$def" == "1" ]] && score=$((score + 200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score + 300))

    if (( score > best_score )); then
      best_score=$score
      best_line="${idx}|${ch}|${lang:-und}"
    fi
  done

  [[ -n "$best_line" ]] || return 1
  echo "$best_line"
}

# ────────────────────────────────────────────────────────────────────────────────
# Raccolta file (glob allineato al processore 5.1)
# ────────────────────────────────────────────────────────────────────────────────
FILES=()
if [[ -n "$INPUT_FILE" ]]; then
    [[ -f "$INPUT_FILE" ]] || { err "File '$INPUT_FILE' inesistente."; exit 1; }
    FILES+=("$INPUT_FILE")
else
    shopt -s nullglob
    FILES+=( *.mkv *.MKV *.mp4 *.MP4 *.avi *.AVI *.mka *.MKA \
             *.m2ts *.M2TS *.wav *.WAV *.flac *.FLAC )
    shopt -u nullglob
fi

(( ${#FILES[@]} == 0 )) && { err "Nessun file trovato da processare."; exit 1; }

# ────────────────────────────────────────────────────────────────────────────────
# Configurazione preset
# ────────────────────────────────────────────────────────────────────────────────
# Surround: il segnale side (FL-FR / FR-FL) puo' essere molto energetico su
# contenuto con stereo-wide (musica, film con ampio soundstage).
# Volume conservativo per evitare che i surround sovrastino i frontali.
case "$MODE" in
  vintage)
    SUR_DELAY="25"
    SUR_EQ="lowpass=f=7000"
    SUR_VOL="0.70"
    MODE_TITLE="Vintage (Pro Logic)"
    ;;
  modern)
    SUR_DELAY="12"
    SUR_EQ="equalizer=f=6000:t=q:w=1:g=2.5"
    SUR_VOL="0.85"
    MODE_TITLE="Modern (Haas)"
    ;;
esac

# ────────────────────────────────────────────────────────────────────────────────
# CICLO ELABORAZIONE
# ────────────────────────────────────────────────────────────────────────────────
OVERWRITE_ALL=false

for CUR_FILE in "${FILES[@]}"; do
  info "Elaborazione: $CUR_FILE"

  # Selezione stream score-based
  PROBE_RESULT=$(pick_best_stereo_stream "$CUR_FILE") || { warn "Nessuna traccia audio trovata. Salto."; continue; }

  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LANG <<<"$PROBE_RESULT"

  if [[ "$A_CHANNELS" -ne 2 ]]; then
    warn "Stream selezionato non e' stereo (Canali: $A_CHANNELS). Salto."
    continue
  fi

  info "Stream [$A_STREAM_INDEX]: ${A_CHANNELS}ch, lingua: ${A_LANG:-und}"

  # ── Matrice Upmix ──────────────────────────────────────────────────────────
  # asplit=3: una copia per L/R diretti, una per mid (FC+LFE), una per side (SL/SR).
  #
  # Crossover FC/LFE:
  #   FC = mid (0.5*FL+0.5*FR) con highpass 80Hz → toglie le basse dal centro
  #   LFE = mid con lowpass 120Hz + volume -6dB → sub pulito senza doppio-basso
  #   Le due bande non si sovrappongono (80-120Hz di overlap minimo, accettabile).
  #
  # Surround:
  #   SL = (FL-FR) decorrelato, SR = (FR-FL) decorrelato
  #   Delay Haas + EQ preset-dipendente + volume conservativo
  #
  # Limiter:
  #   level=0 → no auto-leveling (allineato al processore 5.1)
  #   Il gain e' interamente governato dai volume= nei blocchi.
  UPMIX_FILTER="
[0:${A_STREAM_INDEX}]asplit=3[lr][mid][side];
[lr]channelsplit=channel_layout=stereo[FL_out][FR_out];
[mid]pan=1c|c0=0.5*FL+0.5*FR[mid_mono];
[mid_mono]asplit=2[fc_in][lfe_in];
[fc_in]highpass=f=80,equalizer=f=2500:t=q:w=1.2:g=1.5[FC_out];
[lfe_in]lowpass=f=120,volume=0.5[LFE_out];
[side]asplit=2[sl_in][sr_in];
[sl_in]pan=1c|c0=FL-FR,adelay=${SUR_DELAY},${SUR_EQ},volume=${SUR_VOL}[SL_out];
[sr_in]pan=1c|c0=FR-FL,adelay=${SUR_DELAY},${SUR_EQ},volume=${SUR_VOL}[SR_out];
[FL_out][FR_out][FC_out][LFE_out][SL_out][SR_out]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,
alimiter=limit=0.97:attack=3.0:release=60:level=0[aout]
"

  OUT_FILE="${CUR_FILE%.*}_UPMIX_5.1_${MODE^^}.mkv"

  # ── Gestione sovrascrittura (s/n/t) — allineata al processore 5.1 ──────────
  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      echo -ne "${C_WARN} Il file '$OUT_FILE' esiste. Sovrascrivere? [s/n/t] (s=si, n=no, t=tutti): "
      read -r ans < /dev/tty
      case "${ans,,}" in
        t|tutti)
          OVERWRITE_ALL=true
          info "God mode attivato: sovrascrittura automatica da qui in poi."
          ;;
        s|si|y|yes)
          info "Sovrascrivo questo file."
          ;;
        *)
          info "Skippo '$CUR_FILE'."
          continue
          ;;
      esac
    else
      info "Sovrascrittura automatica di '$OUT_FILE'..."
    fi
  fi

  # ── FFmpeg Command ─────────────────────────────────────────────────────────
  # -y solo se il file esiste (l'utente ha confermato la sovrascrittura)
  CMD=(ffmpeg -hide_banner -nostdin -stats -loglevel warning)
  [[ -f "$OUT_FILE" ]] && CMD+=( -y )
  CMD+=(
    -i "$CUR_FILE"
    -map_metadata 0 -map_chapters 0
    -filter_complex "$UPMIX_FILTER"
    -map "0:V:0?" -c:v copy
    -map "0:s?" -c:s copy
    -map "0:t?" -c:t copy
    -map "[aout]" -c:a:0 "$OUT_CODEC" -b:a:0 "$BITRATE" -ar:a:0 48000 -ac:a:0 6
    -metadata:s:a:0 title="${OUT_CODEC^^} 5.1 – Upmix ${MODE_TITLE}"
    -disposition:a:0 default
  )

  if [[ "$KEEP_STEREO" == "si" ]]; then
    CMD+=( -map 0:"$A_STREAM_INDEX" -c:a:1 copy
           -metadata:s:a:1 title="Stereo Originale 2.0"
           -disposition:a:1 0 )
  fi

  [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:0 language="$A_LANG" )

  CMD+=( "$OUT_FILE" )
  "${CMD[@]}" && ok "Creato: $OUT_FILE" || warn "Errore su: $CUR_FILE"
done

ok "Elaborazione completata."
