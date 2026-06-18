#!/usr/bin/env bash
# set -e rimosso: causa exit imprevedibili su pattern && / || e aritmetica bash.
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   stereo251_upmix.sh - Giugno 2026                                           │
# │   By Sandro (D@mocle77) Sabbioni                                             │
# │                                                                              │
# │   Motore di upmix offline da Stereo a 5.1 (EAC3/AC3),                        │
# │   tarato per satelliti compatti con crossover globale a 100 Hz.              │
# │                                                                              │
# │   Filosofia:                                                                 │
# │     - Due soli preset operativi: to51 e quad.                                │
# │     - FL/FR restano pieni: il phantom center originale non viene sabotato.   │
# │     - FC come assist filtrato a 102 Hz, non sostituto dei frontali.          │
# │     - LFE sintetico molto prudente: il ricevitore fa gia' bass management.   │
# │     - Rear filtrati per non far parlare gli attori dietro la testa.          │
# │     - Psicoacustica leggera: delay Haas + allpass/air a basso livello.       │
# │     - Master limiter finale con upsample 192 kHz per contenere true peaks.   │
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
--------------------------------------------------------------------------------------
UTILIZZO:
  ./stereo251_upmix_psycho.sh <ac3|eac3> <si|no> [file|""] [bitrate] [preset]

PARAMETRI:
  ac3|eac3  : Codec audio in uscita.
  si|no     : Conserva traccia stereo originale come secondaria.
  file      : Nome del file, oppure "" per batch sulla cartella corrente.
  bitrate   : Es. 448k, 640k, 768k, 448K, 512 (default: 448k).
  preset    : to51  (default) Upmix 2.0 -> 5.1 controllato, cinema domestico.
              quad  Quadrifonia ponderata, naturale e meno invasiva.

PRESET:
  to51:
    - FL/FR pieni.
    - FC assist, filtrato e controllato.
    - Surround da side-matrix L-R + rear-bed psicoacustico leggero.
    - Migliore per film/serie/anime stereo larghi o action.

  quad:
    - FL -> SL e FR -> SR con delay Haas, banda limitata e volume prudente.
    - FC e LFE molto leggeri.
    - Migliore per concerti, TV stereo, anime/film vecchi, materiale mono-ish.

ESEMPI:
  ./stereo251_upmix_psycho_V8_to51_quad.sh eac3 no 'movie.mkv' 448k to51
  ./stereo251_upmix_psycho_V8_to51_quad.sh eac3 si 'concert.mkv' 640k quad
  ./stereo251_upmix_psycho_V8_to51_quad.sh ac3 no "" 448k to51
  --------------------------------------------------------------------------------------
USAGE
  exit 1
}

[[ $# -lt 2 ]] && usage

# Parametri
OUT_CODEC="${1:-}"
KEEP_STEREO="${2:-no}"
INPUT_FILE="${3:-}"
BITRATE="${4:-448k}"
MODE="${5:-to51}"
# Controllo parametri
case "$OUT_CODEC" in ac3|eac3) ;; *) err "Codec deve essere ac3 o eac3"; exit 1;; esac
[[ "$KEEP_STEREO" =~ ^(si|no)$ ]] || { err "Parametro 2 deve essere 'si' o 'no'"; exit 1; }
case "$MODE" in to51|quad) ;; *) err "Preset '$MODE' non valido. Usa to51 o quad."; exit 1;; esac

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

# Funzione per confermare sovrascrittura file
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
  # Score-based selection
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
    # Score calculation
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

# Filtra i file gia' upmixati
FILTERED_FILES=()
for f in "${FILES[@]}"; do
  case "$f" in
    *_UPMIX_5.1_MODERN.mkv|*_UPMIX_5.1_VINTAGE.mkv|\
    *_UPMIX_5.1_PSY160_MODERN.mkv|*_UPMIX_5.1_PSY160_VINTAGE.mkv|\
    *_UPMIX_5.1_V5_MODERN.mkv|*_UPMIX_5.1_V5_VINTAGE.mkv|\
    *_UPMIX_5.1_V6_MODERN.mkv|*_UPMIX_5.1_V6_VINTAGE.mkv|\
    *_UPMIX_5.1_V7_MODERN.mkv|*_UPMIX_5.1_V7_VINTAGE.mkv|\
    *_UPMIX_5.1_V8_TO51.mkv|*_UPMIX_5.1_V8_QUAD.mkv)
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
# Configurazione preset V8
# Defaults interni: non serve esportare variabili prima del lancio.
# Le variabili sono comunque sovrascrivibili dall'ambiente per debug avanzato.
# ────────────────────────────────────────────────────────────────────────────────
FRONT_VOL="${FRONT_VOL:-1.00}"

case "$MODE" in
  to51)
    # Upmix 2.0 -> 5.1 controllato.
    # Center assist: presente ma non ruba il phantom center originale.
    FC_MIX="${FC_MIX:-0.38}"
    FC_VOL="${FC_VOL:-0.84}"
    FC_HP="${FC_HP:-102}"
    FC_LP="${FC_LP:-5800}"
    FC_EQ="${FC_EQ:-equalizer=f=260:t=q:w=1.15:g=-0.9,equalizer=f=620:t=q:w=1.0:g=-0.5,equalizer=f=1750:t=q:w=1.5:g=0.5,equalizer=f=2550:t=q:w=1.25:g=0.8,equalizer=f=3700:t=q:w=1.7:g=0.5,equalizer=f=5800:t=q:w=1.8:g=-0.8}"

    # LFE sintetico molto prudente: il sub riceve gia' bass management dal ricevitore.
    LFE_VOL="${LFE_VOL:-0.10}"

    # Rear: side matrix + piccolo rear bed decorrelato.
    SUR_DELAY="${SUR_DELAY:-18}"
    SUR_PAN="${SUR_PAN:-0.58}"
    SUR_VOL="${SUR_VOL:-0.95}"
    SUR_BED_VOL="${SUR_BED_VOL:-0.16}"
    BED_DELAY_L="${BED_DELAY_L:-28}"
    BED_DELAY_R="${BED_DELAY_R:-38}"

    # Psicoacustica leggera: allpass + air a basso livello.
    SUR_EQ="highpass=f=150:t=q:w=0.707,lowpass=f=9000,equalizer=f=5200:t=q:w=1.4:g=0.5,equalizer=f=7200:t=q:w=2.0:g=-0.6"
    BED_EQ="highpass=f=230:t=q:w=0.707,lowpass=f=6500,equalizer=f=950:t=q:w=1.2:g=-1.2,equalizer=f=1800:t=q:w=1.4:g=-4.0,equalizer=f=3000:t=q:w=1.6:g=-3.4,equalizer=f=5200:t=q:w=1.8:g=0.3"
    MODE_TITLE="V8 TO51 Psycho Controlled"
    ;;

  quad)
    # Quadrifonia ponderata: piu' naturale e meno invasiva.
    # Center e LFE sono volutamente piu' leggeri.
    FC_MIX="${FC_MIX:-0.28}"
    FC_VOL="${FC_VOL:-0.78}"
    FC_HP="${FC_HP:-102}"
    FC_LP="${FC_LP:-5200}"
    FC_EQ="${FC_EQ:-equalizer=f=260:t=q:w=1.15:g=-0.7,equalizer=f=650:t=q:w=1.0:g=-0.4,equalizer=f=1800:t=q:w=1.5:g=0.4,equalizer=f=2600:t=q:w=1.25:g=0.6,equalizer=f=3600:t=q:w=1.7:g=0.4,equalizer=f=5200:t=q:w=1.8:g=-0.8}"

    LFE_VOL="${LFE_VOL:-0.08}"
    # Rear: quadrifonia con delay Haas, banda limitata e volume prudente.
    QUAD_DELAY_L="${QUAD_DELAY_L:-16}"
    QUAD_DELAY_R="${QUAD_DELAY_R:-19}"
    QUAD_VOL="${QUAD_VOL:-0.58}"
    QUAD_HP="${QUAD_HP:-250}"
    QUAD_LP="${QUAD_LP:-8000}"
    QUAD_AIR_VOL="${QUAD_AIR_VOL:-0.035}"
    MODE_TITLE="V8 QUAD Weighted Psycho"
    ;;
esac

info "Front vol:      ${FRONT_VOL}"
info "Center:         mix ${FC_MIX}, HP ${FC_HP}Hz, LP ${FC_LP}Hz, vol ${FC_VOL}"
info "LFE synth:      vol ${LFE_VOL}"
if [[ "$MODE" == "to51" ]]; then
  info "Rear side:      pan ${SUR_PAN}, vol ${SUR_VOL}, delay ${SUR_DELAY}ms"
  info "Rear bed:       vol ${SUR_BED_VOL}, delays ${BED_DELAY_L}/${BED_DELAY_R}ms"
else
  info "Rear quad:      vol ${QUAD_VOL}, delay ${QUAD_DELAY_L}/${QUAD_DELAY_R}ms, band ${QUAD_HP}-${QUAD_LP}Hz"
  info "Rear air:       vol ${QUAD_AIR_VOL}"
fi

# Nei valori sostituiti via ${var//pat/rep} l'unico carattere speciale del testo di
# rimpiazzo e' '&' (che ridiventa il match) e '\'. I parametri numerici non li contengono;
# esc_rep blinda i valori-stringa (catene EQ) eventualmente sovrascritti da ambiente.
esc_rep() { local s="${1//\\/\\\\}"; printf '%s' "${s//&/\\&}"; }

# Costruzione filtergraph per upmix 2.0 -> 5.1
# Placeholder sostituiti con espansione nativa bash (${var//pat/rep}): niente delimitatori
# come in sed; i valori-stringa EQ passano da esc_rep per restare letterali al 100%.
build_to51_filter() {
  local tpl
  tpl=$(cat <<'FILTER_EOF'
[0:__A_STREAM_INDEX__]aformat=sample_rates=48000:sample_fmts=fltp:channel_layouts=stereo,asplit=4[lr][fcsrc][lfe_src][rear_src];
[lr]channelsplit=channel_layout=stereo[FL_raw][FR_raw];
[FL_raw]equalizer=f=8200:t=q:w=1.2:g=0.20,volume=__FRONT_VOL__[FL_out];
[FR_raw]equalizer=f=7800:t=q:w=1.2:g=0.20,volume=__FRONT_VOL__[FR_out];
[fcsrc]pan=1c|c0=__FC_MIX__*FL+__FC_MIX__*FR[fc_mono];
[fc_mono]highpass=f=__FC_HP__:t=q:w=0.707,lowpass=f=__FC_LP__,__FC_EQ__,volume=__FC_VOL__[FC_out];
[lfe_src]pan=1c|c0=0.5*FL+0.5*FR[lfe_mono];
[lfe_mono]highpass=f=20:t=q:w=0.707,lowpass=f=85,equalizer=f=45:t=q:w=1.2:g=0.4,equalizer=f=120:t=q:w=1.0:g=-2.8,volume=__LFE_VOL__[LFE_out];
[rear_src]asplit=3[sl_side_in][sr_side_in][bed_src];
[sl_side_in]pan=1c|c0=__SUR_PAN__*FL-__SUR_PAN__*FR,adelay=__SUR_DELAY__,allpass=f=1400:width_type=o:width=0.65,__SUR_EQ__,volume=__SUR_VOL__[SL_side];
[sr_side_in]pan=1c|c0=__SUR_PAN__*FR-__SUR_PAN__*FL,adelay=__SUR_DELAY__,allpass=f=1200:width_type=o:width=0.65,__SUR_EQ__,volume=__SUR_VOL__[SR_side];
[bed_src]pan=1c|c0=0.5*FL+0.5*FR[bed_mono];
[bed_mono]asplit=2[bed_l][bed_r];
[bed_l]adelay=__BED_DELAY_L__,allpass=f=900:width_type=o:width=0.60,allpass=f=2600:width_type=o:width=0.70,__BED_EQ__,volume=__SUR_BED_VOL__[SL_bed];
[bed_r]adelay=__BED_DELAY_R__,allpass=f=1100:width_type=o:width=0.60,allpass=f=3100:width_type=o:width=0.70,__BED_EQ__,volume=__SUR_BED_VOL__[SR_bed];
[SL_side][SL_bed]amix=inputs=2:normalize=0:dropout_transition=0[SL_out];
[SR_side][SR_bed]amix=inputs=2:normalize=0:dropout_transition=0[SR_out];
[FL_out][FR_out][FC_out][LFE_out][SL_out][SR_out]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,aresample=192000,alimiter=limit=0.97:attack=3.0:release=60:level=0,aresample=48000[aout]
FILTER_EOF
)
  tpl="${tpl//__A_STREAM_INDEX__/$A_STREAM_INDEX}"
  tpl="${tpl//__FRONT_VOL__/$FRONT_VOL}"
  tpl="${tpl//__FC_MIX__/$FC_MIX}"
  tpl="${tpl//__FC_HP__/$FC_HP}"
  tpl="${tpl//__FC_LP__/$FC_LP}"
  tpl="${tpl//__FC_EQ__/$(esc_rep "$FC_EQ")}"
  tpl="${tpl//__FC_VOL__/$FC_VOL}"
  tpl="${tpl//__LFE_VOL__/$LFE_VOL}"
  tpl="${tpl//__SUR_PAN__/$SUR_PAN}"
  tpl="${tpl//__SUR_DELAY__/$SUR_DELAY}"
  tpl="${tpl//__SUR_EQ__/$(esc_rep "$SUR_EQ")}"
  tpl="${tpl//__SUR_VOL__/$SUR_VOL}"
  tpl="${tpl//__BED_DELAY_L__/$BED_DELAY_L}"
  tpl="${tpl//__BED_DELAY_R__/$BED_DELAY_R}"
  tpl="${tpl//__BED_EQ__/$(esc_rep "$BED_EQ")}"
  tpl="${tpl//__SUR_BED_VOL__/$SUR_BED_VOL}"
  printf '%s\n' "$tpl"
}

# Costruzione filtergraph per upmix 2.0 -> 4.0 quadrifonia
# Placeholder sostituiti con espansione nativa bash (vedi build_to51_filter).
build_quad_filter() {
  local tpl
  tpl=$(cat <<'FILTER_EOF'
[0:__A_STREAM_INDEX__]aformat=sample_rates=48000:sample_fmts=fltp:channel_layouts=stereo,asplit=3[lr][fcsrc][lfe_src];
[lr]channelsplit=channel_layout=stereo[FL_raw][FR_raw];
[FL_raw]asplit=2[FL_front_in][FL_quad_in];
[FR_raw]asplit=2[FR_front_in][FR_quad_in];
[FL_front_in]equalizer=f=8200:t=q:w=1.2:g=0.15,volume=__FRONT_VOL__[FL_out];
[FR_front_in]equalizer=f=7800:t=q:w=1.2:g=0.15,volume=__FRONT_VOL__[FR_out];
[fcsrc]pan=1c|c0=__FC_MIX__*FL+__FC_MIX__*FR[fc_mono];
[fc_mono]highpass=f=__FC_HP__:t=q:w=0.707,lowpass=f=__FC_LP__,__FC_EQ__,volume=__FC_VOL__[FC_out];
[lfe_src]pan=1c|c0=0.5*FL+0.5*FR[lfe_mono];
[lfe_mono]highpass=f=20:t=q:w=0.707,lowpass=f=80,equalizer=f=45:t=q:w=1.2:g=0.3,equalizer=f=120:t=q:w=1.0:g=-3.0,volume=__LFE_VOL__[LFE_out];
[FL_quad_in]adelay=__QUAD_DELAY_L__,highpass=f=__QUAD_HP__:t=q:w=0.707,lowpass=f=__QUAD_LP__,allpass=f=1400:width_type=o:width=0.55,volume=__QUAD_VOL__[SL_quad];
[FR_quad_in]adelay=__QUAD_DELAY_R__,highpass=f=__QUAD_HP__:t=q:w=0.707,lowpass=f=__QUAD_LP__,allpass=f=1200:width_type=o:width=0.55,volume=__QUAD_VOL__[SR_quad];
[SL_quad]asplit=2[SL_main][SL_air_in];
[SL_air_in]highpass=f=1800,lowpass=f=9000,adelay=7,allpass=f=2600:width_type=o:width=0.65,equalizer=f=7200:t=q:w=2.0:g=-0.8,volume=__QUAD_AIR_VOL__[SL_air];
[SL_main][SL_air]amix=inputs=2:normalize=0:dropout_transition=0[SL_out];
[SR_quad]asplit=2[SR_main][SR_air_in];
[SR_air_in]highpass=f=1800,lowpass=f=9000,adelay=9,allpass=f=3100:width_type=o:width=0.65,equalizer=f=7200:t=q:w=2.0:g=-0.8,volume=__QUAD_AIR_VOL__[SR_air];
[SR_main][SR_air]amix=inputs=2:normalize=0:dropout_transition=0[SR_out];
[FL_out][FR_out][FC_out][LFE_out][SL_out][SR_out]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,aresample=192000,alimiter=limit=0.97:attack=3.0:release=60:level=0,aresample=48000[aout]
FILTER_EOF
)
  tpl="${tpl//__A_STREAM_INDEX__/$A_STREAM_INDEX}"
  tpl="${tpl//__FRONT_VOL__/$FRONT_VOL}"
  tpl="${tpl//__FC_MIX__/$FC_MIX}"
  tpl="${tpl//__FC_HP__/$FC_HP}"
  tpl="${tpl//__FC_LP__/$FC_LP}"
  tpl="${tpl//__FC_EQ__/$(esc_rep "$FC_EQ")}"
  tpl="${tpl//__FC_VOL__/$FC_VOL}"
  tpl="${tpl//__LFE_VOL__/$LFE_VOL}"
  tpl="${tpl//__QUAD_DELAY_L__/$QUAD_DELAY_L}"
  tpl="${tpl//__QUAD_DELAY_R__/$QUAD_DELAY_R}"
  tpl="${tpl//__QUAD_HP__/$QUAD_HP}"
  tpl="${tpl//__QUAD_LP__/$QUAD_LP}"
  tpl="${tpl//__QUAD_VOL__/$QUAD_VOL}"
  tpl="${tpl//__QUAD_AIR_VOL__/$QUAD_AIR_VOL}"
  printf '%s\n' "$tpl"
}

# ────────────────────────────────────────────────────────────────────────────────
# Ciclo elaborazione
# ────────────────────────────────────────────────────────────────────────────────
OVERWRITE_ALL=false

for CUR_FILE in "${FILES[@]}"; do
  info "Elaborazione: $CUR_FILE"
  # Seleziona lo stream audio stereo migliore (score-based)
  PROBE_RESULT=$(pick_best_stereo_stream "$CUR_FILE") || { warn "Nessuna traccia audio trovata. Salto."; continue; }
  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LANG <<<"$PROBE_RESULT"

  if [[ "$A_CHANNELS" -ne 2 ]]; then
    warn "Stream selezionato non e' stereo (Canali: $A_CHANNELS). Salto."
    continue
  fi

  info "Stream [$A_STREAM_INDEX]: ${A_CHANNELS}ch, lingua: ${A_LANG:-und}"

  # Costruzione filtergraph
  if [[ "$MODE" == "to51" ]]; then
    UPMIX_FILTER="$(build_to51_filter)"
  else
    UPMIX_FILTER="$(build_quad_filter)"
  fi

  OUT_FILE="${CUR_FILE%.*}_UPMIX_5.1_V8_${MODE^^}.mkv"

  # Controllo sovrascrittura
  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      confirm_overwrite "$OUT_FILE" || { info "Skippo '$CUR_FILE'."; continue; }
    else
      info "Sovrascrittura automatica di '$OUT_FILE'..."
    fi
  fi
  # Costruzione comando ffmpeg
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
  # Aggiunge metadata lingua se disponibile e diversa da "und"
  [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:0 language="$A_LANG" )

  CMD+=( "$OUT_FILE" )
  "${CMD[@]}" && ok "Creato: $OUT_FILE" || warn "Errore su: $CUR_FILE"
done

ok "Elaborazione completata."
