#!/usr/bin/env bash
# set -e rimosso: causa exit imprevedibili su pattern && / || e aritmetica bash.
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   stereo251_upmix.sh - V7 PSY120 CENTER-BODY / REAR-FILL - Aprile 2026            │
# │                                                                              │
# │   Motore di upmix offline da Stereo a 5.1 (EAC3/AC3),                        │
# │   tarato per AVR/casse con crossover intorno a 110-120Hz.                   │
# │                                                                              │
# │   Filosofia V7:                                                              │
# │     - Non sottrae voce ai frontali: FL/FR restano a livello pieno.            │
# │     - FC come ancoraggio: piu' corpo con crossover 110-120, non protagonista.│
# │     - FC filtrato: HP 115/120Hz, LP dedicato, medio-basso controllato.       │
# │     - Surround a doppio motore: side matrix + rear bed decorrelato dal mid.  │
# │     - Nessun limiter intermedio sui surround: solo limiter finale post-join. │
# │     - Parametri chiave sovrascrivibili via variabili ambiente.               │
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
  ./stereo251_upmix_v7_psy120_center_body.sh <ac3|eac3> <si|no> [file|""] [bitrate] [preset]

PARAMETRI:
  ac3|eac3  : Codec audio in uscita.
  si|no     : Conserva traccia stereo originale come secondaria.
  file      : Nome del file, oppure "" per batch sulla cartella corrente.
  bitrate   : Es. 448k, 640k, 768k, 448K, 512 (default: 448k).
  preset    : modern  (default) Rear piu' presenti, ariosi, decorrelati.
              vintage Rear piu' morbidi, ritardati, stile Pro Logic.

TUNING RAPIDO VIA ENV, senza editare lo script:
  FC_VOL=0.88 FC_HP=120 FC_MIX=0.42 ./stereo251_upmix_v7_psy120_center_body.sh eac3 no 'movie.mkv' 448k modern

NOTE:
  V7 evita il problema della V4: non abbassa FL/FR per "fare spazio" al centro.
  Il centrale e' un center-assist piu' corposo, tarato per crossover AVR 110-120Hz.
  Se ruba scena, abbassa FC_VOL o FC_MIX prima di toccare i frontali.

ESEMPI:
  ./stereo251_upmix_v7_psy120_center_body.sh eac3 no 'movie.mkv' 448k modern
  ./stereo251_upmix_v7_psy120_center_body.sh ac3 si '' 640k vintage
  ./stereo251_upmix_v7_psy120_center_body.sh eac3 no
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

# Normalizza bitrate: accetta 448, 448k, 448K, 1M.
if [[ "$BITRATE" =~ ^([0-9]+)([kKmM]?)$ ]]; then
  _br_num="${BASH_REMATCH[1]}"
  _br_sfx="${BASH_REMATCH[2]}"
  [[ -z "$_br_sfx" ]] && _br_sfx="k"
  [[ "$_br_sfx" == "K" ]] && _br_sfx="k"
  BITRATE="${_br_num}${_br_sfx}"
else
  err "Bitrate '$BITRATE' non valido. Es: 448k, 640k, 768k, 448K, 512."
  exit 1
fi
unset _br_num _br_sfx

info "Upmix Mode:     ${MODE^^}"
info "Codec target:   ${OUT_CODEC^^} @ ${BITRATE}"

confirm_overwrite() {
  local target="$1"
  local ans=""
  if [[ ! -e /dev/tty ]]; then
    warn "TTY non disponibile e '$target' esiste gia' -> skip automatico."
    return 1
  fi
  echo -ne "${C_WARN} Il file '$target' esiste. Sovrascrivere? [s/n/t] (s=si, n=no, t=tutti): "
  if ! read -r ans < /dev/tty; then
    warn "Impossibile leggere da /dev/tty -> skip automatico."
    return 1
  fi
  case "${ans,,}" in
    t|tutti) OVERWRITE_ALL=true; info "Sovrascrittura automatica da qui in poi."; return 0 ;;
    s|si|y|yes) info "Sovrascrivo questo file."; return 0 ;;
    *) info "Skip manuale richiesto."; return 1 ;;
  esac
}

# ────────────────────────────────────────────────────────────────────────────────
# Selezione stream score-based
# Score: 2 canali (stereo) +1000, default +200, lingua italiana +300.
# A parita' di score vince il primo trovato.
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
# Raccolta file
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

FILTERED_FILES=()
for f in "${FILES[@]}"; do
  case "$f" in
    *_UPMIX_5.1_MODERN.mkv|*_UPMIX_5.1_VINTAGE.mkv|*_UPMIX_5.1_PSY160_MODERN.mkv|*_UPMIX_5.1_PSY160_VINTAGE.mkv|*_UPMIX_5.1_V5_MODERN.mkv|*_UPMIX_5.1_V5_VINTAGE.mkv|*_UPMIX_5.1_V6_MODERN.mkv|*_UPMIX_5.1_V6_VINTAGE.mkv|*_UPMIX_5.1_V7_MODERN.mkv|*_UPMIX_5.1_V7_VINTAGE.mkv)
      info "Skip output gia' upmixato: $f"
      continue
      ;;
    *)
      FILTERED_FILES+=("$f")
      ;;
  esac
done
FILES=("${FILTERED_FILES[@]}")

(( ${#FILES[@]} == 0 )) && { err "Nessun file trovato da processare."; exit 1; }

# ────────────────────────────────────────────────────────────────────────────────
# Configurazione preset V7
# Le variabili possono essere sovrascritte dall'ambiente.
# ────────────────────────────────────────────────────────────────────────────────
case "$MODE" in
  vintage)
    FRONT_VOL="${FRONT_VOL:-1.00}"

    # Center body: un filo piu' corpo della V6, ma senza fango.
    # Target: casse migliori + crossover AVR 110-120Hz.
    FC_MIX="${FC_MIX:-0.40}"
    FC_VOL="${FC_VOL:-0.86}"
    FC_HP="${FC_HP:-115}"
    FC_LP="${FC_LP:-5600}"
    FC_EQ="${FC_EQ:-equalizer=f=280:t=q:w=1.15:g=-1.3,equalizer=f=620:t=q:w=1.0:g=-0.5,equalizer=f=1700:t=q:w=1.5:g=0.5,equalizer=f=2500:t=q:w=1.25:g=0.8,equalizer=f=3600:t=q:w=1.7:g=0.5,equalizer=f=5600:t=q:w=1.8:g=-0.9}"

    # LFE sintetico prudente: l'AVR fa gia' bass management, non serve evocare Cthulhu.
    LFE_VOL="${LFE_VOL:-0.22}"

    SUR_DELAY="${SUR_DELAY:-26}"
    SUR_PAN="${SUR_PAN:-0.62}"
    SUR_VOL="${SUR_VOL:-1.06}"
    SUR_BED_VOL="${SUR_BED_VOL:-0.24}"
    BED_DELAY_L="${BED_DELAY_L:-38}"
    BED_DELAY_R="${BED_DELAY_R:-52}"

    SUR_EQ="highpass=f=130,lowpass=f=6800,equalizer=f=3200:t=q:w=1.6:g=0.4"
    BED_EQ="highpass=f=200,lowpass=f=5600,equalizer=f=1000:t=q:w=1.2:g=-1.2,equalizer=f=1900:t=q:w=1.4:g=-3.8,equalizer=f=3200:t=q:w=1.6:g=-3.2"
    MODE_TITLE="V7 Vintage PSY120 Center-Body + Rear-Fill"
    ;;
  modern)
    FRONT_VOL="${FRONT_VOL:-1.00}"

    # Center body: piu' pieno della V6, ma ancora da assist e non da protagonista.
    # Target: casse migliori + crossover AVR 110-120Hz.
    FC_MIX="${FC_MIX:-0.42}"
    FC_VOL="${FC_VOL:-0.88}"
    FC_HP="${FC_HP:-120}"
    FC_LP="${FC_LP:-6200}"
    FC_EQ="${FC_EQ:-equalizer=f=280:t=q:w=1.15:g=-1.4,equalizer=f=650:t=q:w=1.0:g=-0.6,equalizer=f=1850:t=q:w=1.5:g=0.6,equalizer=f=2700:t=q:w=1.25:g=1.0,equalizer=f=3900:t=q:w=1.7:g=0.7,equalizer=f=6200:t=q:w=1.8:g=-0.7}"

    # LFE sintetico prudente: l'AVR fa gia' bass management, non serve evocare Cthulhu.
    LFE_VOL="${LFE_VOL:-0.22}"

    SUR_DELAY="${SUR_DELAY:-16}"
    SUR_PAN="${SUR_PAN:-0.68}"
    SUR_VOL="${SUR_VOL:-1.18}"
    SUR_BED_VOL="${SUR_BED_VOL:-0.28}"
    BED_DELAY_L="${BED_DELAY_L:-31}"
    BED_DELAY_R="${BED_DELAY_R:-43}"

    SUR_EQ="highpass=f=125,lowpass=f=9800,equalizer=f=5200:t=q:w=1.4:g=0.9,equalizer=f=7200:t=q:w=2.0:g=-0.6"
    BED_EQ="highpass=f=190,lowpass=f=6800,equalizer=f=950:t=q:w=1.2:g=-1.0,equalizer=f=1800:t=q:w=1.4:g=-3.6,equalizer=f=3000:t=q:w=1.6:g=-3.2,equalizer=f=5200:t=q:w=1.8:g=0.5"
    MODE_TITLE="V7 Modern PSY120 Center-Body + Rear-Fill"
    ;;
esac

info "Front vol:      ${FRONT_VOL}"
info "Center:         mix ${FC_MIX}, HP ${FC_HP}Hz, LP ${FC_LP}Hz, vol ${FC_VOL}"
info "LFE synth:      vol ${LFE_VOL}"
info "Rear side:      pan ${SUR_PAN}, vol ${SUR_VOL}, delay ${SUR_DELAY}ms"
info "Rear bed:       vol ${SUR_BED_VOL}, delays ${BED_DELAY_L}/${BED_DELAY_R}ms"

# ────────────────────────────────────────────────────────────────────────────────
# Ciclo elaborazione
# ────────────────────────────────────────────────────────────────────────────────
OVERWRITE_ALL=false

for CUR_FILE in "${FILES[@]}"; do
  info "Elaborazione: $CUR_FILE"

  PROBE_RESULT=$(pick_best_stereo_stream "$CUR_FILE") || { warn "Nessuna traccia audio trovata. Salto."; continue; }
  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LANG <<<"$PROBE_RESULT"

  if [[ "$A_CHANNELS" -ne 2 ]]; then
    warn "Stream selezionato non e' stereo (Canali: $A_CHANNELS). Salto."
    continue
  fi

  info "Stream [$A_STREAM_INDEX]: ${A_CHANNELS}ch, lingua: ${A_LANG:-und}"

  # ── Matrice Upmix V7 ───────────────────────────────────────────────────────
  # Front L/R:
  #   restano a volume pieno: il phantom center originale non viene sabotato.
  #
  # FC:
  #   center-assist da mid mono attenuato, non sostituto dei frontali.
  #   HP/LP dedicati per dare corpo con crossover 110-120Hz senza impastare.
  #
  # Rear:
  #   side matrix = ambiente reale stereo, quando esiste differenza L-R.
  #   rear bed = piccolo letto decorrelato dal mid per materiale mono-ish.
  #   Il bed e' filtrato con dip sulle zone di intelligibilita' vocale per non
  #   far parlare gli attori da dietro la testa. Perche' siamo civili, almeno qui.
  #
  # Limiter:
  #   nessun limiter intermedio sui rear; solo finale post-join con level=0.
  UPMIX_FILTER="
[0:${A_STREAM_INDEX}]asplit=4[lr][mid][fcsrc][side];
[lr]channelsplit=channel_layout=stereo[FL_raw][FR_raw];
[FL_raw]equalizer=f=8200:t=q:w=1.2:g=0.25,volume=${FRONT_VOL}[FL_out];
[FR_raw]equalizer=f=7800:t=q:w=1.2:g=0.25,volume=${FRONT_VOL}[FR_out];
[mid]pan=1c|c0=0.5*FL+0.5*FR[mid_mono];
[fcsrc]pan=1c|c0=${FC_MIX}*FL+${FC_MIX}*FR[fc_mono];
[mid_mono]asplit=2[lfe_in][bed_in];
[fc_mono]highpass=f=${FC_HP},lowpass=f=${FC_LP},${FC_EQ},volume=${FC_VOL}[FC_out];
[lfe_in]lowpass=f=85,equalizer=f=45:t=q:w=1.2:g=0.6,equalizer=f=120:t=q:w=1.0:g=-2.4,volume=${LFE_VOL}[LFE_out];
[side]asplit=2[sl_side_in][sr_side_in];
[sl_side_in]pan=1c|c0=${SUR_PAN}*FL-${SUR_PAN}*FR,adelay=${SUR_DELAY},allpass=f=1400:width_type=o:width=0.8,${SUR_EQ},volume=${SUR_VOL}[SL_side];
[sr_side_in]pan=1c|c0=${SUR_PAN}*FR-${SUR_PAN}*FL,adelay=${SUR_DELAY},allpass=f=1200:width_type=o:width=0.8,${SUR_EQ},volume=${SUR_VOL}[SR_side];
[bed_in]asplit=2[bed_l][bed_r];
[bed_l]adelay=${BED_DELAY_L},allpass=f=900:width_type=o:width=0.7,allpass=f=2600:width_type=o:width=0.9,${BED_EQ},volume=${SUR_BED_VOL}[SL_bed];
[bed_r]adelay=${BED_DELAY_R},allpass=f=1100:width_type=o:width=0.7,allpass=f=3100:width_type=o:width=0.9,${BED_EQ},volume=${SUR_BED_VOL}[SR_bed];
[SL_side][SL_bed]amix=inputs=2:normalize=0:dropout_transition=0[SL_out];
[SR_side][SR_bed]amix=inputs=2:normalize=0:dropout_transition=0[SR_out];
[FL_out][FR_out][FC_out][LFE_out][SL_out][SR_out]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,
alimiter=limit=0.97:attack=3.0:release=60:level=0[aout]
"

  OUT_FILE="${CUR_FILE%.*}_UPMIX_5.1_V7_${MODE^^}.mkv"

  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      confirm_overwrite "$OUT_FILE" || { info "Skippo '$CUR_FILE'."; continue; }
    else
      info "Sovrascrittura automatica di '$OUT_FILE'..."
    fi
  fi

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
    -metadata:s:a:0 title="${OUT_CODEC^^} 5.1 - Upmix ${MODE_TITLE}"
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
