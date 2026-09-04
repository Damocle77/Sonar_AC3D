#!/usr/bin/env bash
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────────────────╮
# │   stereo251_upmix_psycho.sh - Settembre 2026                                             │
# │   By Sandro (D@mocle77) Sabbioni                                                         │
# │                                                                                          │
# │   Motore di upmix offline da Stereo a 5.1 (EAC3/AC3),                                    │
# │   tarato per satelliti compatti con crossover globale a 110 Hz.                          │
# │                                                                                          │
# │   Filosofia:                                                                             │
# │     - Due soli preset operativi: to51 e quad.                                            │
# │     - FL/FR restano pieni: il phantom center originale non viene sabotato.               │
# │     - FC come assist leggero; il crossover fisico resta affidato al ricevitore.          │
# │     - LFE sintetico quasi nullo: il ricevitore esegue gia' il bass management.           │
# │     - Rear ricavati soprattutto dalla componente laterale L-R.                           │
# │     - Psicoacustica leggera: delay Haas + allpass/air a basso livello.                   │
# │     - Headroom preventiva e limiter finale 4x solo come protezione dei true peak.        │
# │     - Output atomico con verifica comparativa stereo -> 5.1 prima della pubblicazione.   │
# ╰──────────────────────────────────────────────────────────────────────────────────────────╯

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

if ! ffmpeg -hide_banner -h filter=aresample 2>&1 | grep -qi 'soxr'; then
  err "SOXR non disponibile in questo FFmpeg: serve una build con libsoxr."
  exit 1
fi

# Guard rail della verifica comparativa stereo -> 5.1.
VERIFY_SILENCE_PEAK_DB="-80.0"
VERIFY_MAX_OVERALL_DROP_DB="18.0"
VERIFY_MAX_FRONT_DROP_DB="18.0"
VERIFY_MIN_SAMPLE_RATIO="0.98"

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
              quad  Quadrifonia ponderata per musica/concerti; non per fiction.
PRESET:
  to51:
    - FL/FR pieni.
    - FC assist, filtrato e controllato.
    - Surround principalmente da side-matrix L-R + rear-bed mono molto attenuato.
    - Migliore per film/serie/anime stereo larghi o action.

  quad:
    - FL -> SL e FR -> SR con delay Haas, banda limitata e volume prudente.
    - FC e LFE molto leggeri.
    - Riservato a concerti e musica; puo' trascinare dialoghi nei posteriori.

ESEMPI:
  ./stereo251_upmix_psycho.sh eac3 no 'movie.mkv' 448k to51
  ./stereo251_upmix_psycho.sh eac3 si 'concert.mkv' 640k quad
  ./stereo251_upmix_psycho.sh ac3 no "" 448k to51
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

if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "^[[:space:]]*A[.A-Z]*[[:space:]]+${OUT_CODEC}[[:space:]]" >/dev/null; then
  err "Encoder FFmpeg '${OUT_CODEC}' non disponibile in questa build."
  exit 1
fi

# Normalizza e valida il bitrate in funzione del codec.
if [[ "$BITRATE" =~ ^([0-9]+)([kKmM]?)$ ]]; then
  _br_num="${BASH_REMATCH[1]}"
  _br_sfx="${BASH_REMATCH[2],,}"
  [[ -z "$_br_sfx" ]] && _br_sfx="k"
else
  err "Bitrate '$BITRATE' non valido. Es: 448k, 640k, 768k, 448K, 512."
  exit 1
fi

if [[ "$_br_sfx" == "m" ]]; then
  BITRATE_KBPS="$(( _br_num * 1000 ))"
else
  BITRATE_KBPS="$_br_num"
fi

MAX_BITRATE_KBPS=768
[[ "$OUT_CODEC" == "ac3" ]] && MAX_BITRATE_KBPS=640
if (( BITRATE_KBPS < 256 || BITRATE_KBPS > MAX_BITRATE_KBPS || ((BITRATE_KBPS - 256) % 64) != 0 )); then
  err "Bitrate non consentito per ${OUT_CODEC^^}: ${BITRATE_KBPS}k"
  if [[ "$OUT_CODEC" == "ac3" ]]; then
    err "Consentiti: 256k, 320k, 384k, 448k, 512k, 576k, 640k"
  else
    err "Consentiti: 256k, 320k, 384k, 448k, 512k, 576k, 640k, 704k, 768k"
  fi
  exit 1
fi
BITRATE="${BITRATE_KBPS}k"
unset _br_num _br_sfx MAX_BITRATE_KBPS

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
# Il parser usa coppie chiave=valore: ffprobe non garantisce l'ordine richiesto
# delle entry, quindi il vecchio CSV posizionale era fragile.
# Restituisce via stdout: idx|ch|lang
# ────────────────────────────────────────────────────────────────────────────────
pick_best_stereo_stream() {
  local f="$1"
  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels:stream_disposition=default:stream_tags=language \
    -of compact=p=0:nk=0 "$f" 2>/dev/null </dev/null || true)
  raw_data="${raw_data//$'\r'/}"

  [[ -z "$raw_data" ]] && return 1

  local best_line="" best_score=-1 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local idx="" ch="0" def="0" lang="" field
    local fields=()
    IFS='|' read -r -a fields <<<"$line"
    for field in "${fields[@]}"; do
      case "$field" in
        index=*)               idx="${field#index=}" ;;&
        channels=*)            ch="${field#channels=}" ;;&
        disposition:default=*) def="${field#disposition:default=}" ;;&
        tag:language=*)        lang="${field#tag:language=}" ;;&
      esac
    done

    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    [[ "$ch" =~ ^[0-9]+$ ]] || ch=0

    local score=0
    (( ch == 2 )) && score=$((score + 1000))
    [[ "$def" == "1" ]] && score=$((score + 200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score + 300))

    if (( score > best_score )); then
      best_score=$score
      best_line="${idx}|${ch}|${lang:-und}"
    fi
  done <<< "$raw_data"

  [[ -n "$best_line" ]] || return 1
  printf '%s\n' "$best_line"
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
    *_UPMIX_5.1_V8_TO51.mkv|*_UPMIX_5.1_V8_QUAD.mkv|\
    *_UPMIX_5.1_V9_TO51.mkv|*_UPMIX_5.1_V9_QUAD.mkv)
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
# Configurazione preset V9
# Defaults interni: non serve esportare variabili prima del lancio.
# Le variabili sono comunque sovrascrivibili dall'ambiente per debug avanzato.
# ────────────────────────────────────────────────────────────────────────────────
FRONT_VOL="${FRONT_VOL:-0.96}"

case "$MODE" in
  to51)
    # Upmix 2.0 -> 5.1 controllato.
    # Center assist: presente ma non ruba il phantom center originale.
    FC_MIX="${FC_MIX:-0.32}"
    FC_VOL="${FC_VOL:-0.86}"
    FC_HP="${FC_HP:-60}"
    FC_LP="${FC_LP:-6500}"
    FC_EQ="${FC_EQ:-equalizer=f=260:t=q:w=1.15:g=-0.7,equalizer=f=650:t=q:w=1.0:g=-0.4,equalizer=f=1750:t=q:w=1.5:g=0.5,equalizer=f=2550:t=q:w=1.25:g=0.8,equalizer=f=3800:t=q:w=1.7:g=0.5,equalizer=f=6500:t=q:w=1.8:g=-0.6}"

    # LFE sintetico molto prudente: il sub riceve gia' bass management dal ricevitore.
    LFE_VOL="${LFE_VOL:-0.035}"

    # Rear: side matrix + piccolo rear bed decorrelato.
    SUR_DELAY_L="${SUR_DELAY_L:-14}"
    SUR_DELAY_R="${SUR_DELAY_R:-20}"
    SUR_PAN="${SUR_PAN:-0.50}"
    SUR_VOL="${SUR_VOL:-0.86}"
    SUR_BED_VOL="${SUR_BED_VOL:-0.06}"
    BED_DELAY_L="${BED_DELAY_L:-24}"
    BED_DELAY_R="${BED_DELAY_R:-33}"

    # Psicoacustica leggera: allpass + air a basso livello.
    SUR_EQ="highpass=f=170:t=q:w=0.707,lowpass=f=8500,equalizer=f=5200:t=q:w=1.4:g=0.3,equalizer=f=7200:t=q:w=2.0:g=-0.8"
    BED_EQ="highpass=f=320:t=q:w=0.707,lowpass=f=5600,equalizer=f=700:t=q:w=1.1:g=-2.0,equalizer=f=1500:t=q:w=1.2:g=-5.5,equalizer=f=2600:t=q:w=1.4:g=-6.0,equalizer=f=4000:t=q:w=1.6:g=-3.0,equalizer=f=5200:t=q:w=1.8:g=-1.0"
    MODE_TITLE="TO51"
    ;;

  quad)
    # Quadrifonia ponderata: piu' naturale e meno invasiva.
    # Center e LFE sono volutamente piu' leggeri.
    FC_MIX="${FC_MIX:-0.28}"
    FC_VOL="${FC_VOL:-0.78}"
    FC_HP="${FC_HP:-60}"
    FC_LP="${FC_LP:-5200}"
    FC_EQ="${FC_EQ:-equalizer=f=260:t=q:w=1.15:g=-0.7,equalizer=f=650:t=q:w=1.0:g=-0.4,equalizer=f=1800:t=q:w=1.5:g=0.4,equalizer=f=2600:t=q:w=1.25:g=0.6,equalizer=f=3600:t=q:w=1.7:g=0.4,equalizer=f=5200:t=q:w=1.8:g=-0.8}"

    LFE_VOL="${LFE_VOL:-0.03}"
    # Rear: quadrifonia con delay Haas, banda limitata e volume prudente.
    QUAD_DELAY_L="${QUAD_DELAY_L:-16}"
    QUAD_DELAY_R="${QUAD_DELAY_R:-19}"
    QUAD_VOL="${QUAD_VOL:-0.58}"
    QUAD_HP="${QUAD_HP:-250}"
    QUAD_LP="${QUAD_LP:-8000}"
    QUAD_AIR_VOL="${QUAD_AIR_VOL:-0.035}"
    MODE_TITLE="QUAD"
    ;;
esac

info "Front vol:      ${FRONT_VOL}"
info "Center:         mix ${FC_MIX}, HP ${FC_HP}Hz, LP ${FC_LP}Hz, vol ${FC_VOL}"
info "LFE synth:      vol ${LFE_VOL}"
if [[ "$MODE" == "to51" ]]; then
  info "Rear side:      pan ${SUR_PAN}, vol ${SUR_VOL}, delay ${SUR_DELAY_L}/${SUR_DELAY_R}ms"
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
[sl_side_in]pan=1c|c0=__SUR_PAN__*FL-__SUR_PAN__*FR,adelay=__SUR_DELAY_L__,allpass=f=1400:width_type=o:width=0.65,__SUR_EQ__,volume=__SUR_VOL__[SL_side];
[sr_side_in]pan=1c|c0=__SUR_PAN__*FR-__SUR_PAN__*FL,adelay=__SUR_DELAY_R__,allpass=f=1200:width_type=o:width=0.65,__SUR_EQ__,volume=__SUR_VOL__[SR_side];
[bed_src]pan=1c|c0=0.5*FL+0.5*FR[bed_mono];
[bed_mono]asplit=2[bed_l][bed_r];
[bed_l]adelay=__BED_DELAY_L__,allpass=f=900:width_type=o:width=0.60,allpass=f=2600:width_type=o:width=0.70,__BED_EQ__,volume=__SUR_BED_VOL__[SL_bed];
[bed_r]adelay=__BED_DELAY_R__,allpass=f=1100:width_type=o:width=0.60,allpass=f=3100:width_type=o:width=0.70,__BED_EQ__,volume=__SUR_BED_VOL__[SR_bed];
[SL_side][SL_bed]amix=inputs=2:normalize=0:dropout_transition=0[SL_out];
[SR_side][SR_bed]amix=inputs=2:normalize=0:dropout_transition=0[SR_out];
[FL_out][FR_out][FC_out][LFE_out][SL_out][SR_out]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,aresample=192000:resampler=soxr:precision=28,alimiter=limit=0.97:attack=3.0:release=60:level=0:latency=1,aresample=48000:resampler=soxr:precision=28:cutoff=0.91[aout]
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
  tpl="${tpl//__SUR_DELAY_L__/$SUR_DELAY_L}"
  tpl="${tpl//__SUR_DELAY_R__/$SUR_DELAY_R}"
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
[FL_out][FR_out][FC_out][LFE_out][SL_out][SR_out]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,aresample=192000:resampler=soxr:precision=28,alimiter=limit=0.97:attack=3.0:release=60:level=0:latency=1,aresample=48000:resampler=soxr:precision=28:cutoff=0.91[aout]
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

# Misura peak, RMS, campioni e RMS per-canale.
measure_audio_signal() {
  local f="$1" map_spec="$2" expected_channels="$3" probe metrics
  probe="$(
    ffmpeg -hide_banner -nostdin -v info -i "$f" \
      -map "$map_spec" -vn -sn -dn \
      -af "aformat=sample_rates=48000:sample_fmts=fltp,astats=metadata=0:reset=0" \
      -f null - 2>&1 || true
  )"
  probe="${probe//$'\r'/}"

  metrics="$(printf '%s\n' "$probe" | awk -v expected="$expected_channels" '
    /Channel:/ { channel=$NF; overall=0; next }
    /] Overall$/ { overall=1; channel=0; next }
    /Peak level dB:/ { if (overall) overall_peak=$NF; next }
    /RMS level dB:/ {
      if (overall) overall_rms=$NF
      else if (channel >= 1 && channel <= expected) channel_rms[channel]=$NF
      next
    }
    /Number of samples:/ { if (overall) samples=$NF; next }
    END {
      if (overall_peak == "" || overall_rms == "" || samples == "") exit 1
      for (i=1; i<=expected; i++) if (channel_rms[i] == "") exit 1
      printf "%s|%s|%s", overall_peak, overall_rms, samples
      for (i=1; i<=expected; i++) printf "|%s", channel_rms[i]
      printf "\n"
    }
  ')" || return 1

  [[ -n "$metrics" ]] || return 1
  printf '%s\n' "$metrics"
}

is_finite_db() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

verify_upmix_output() {
  local f="$1" input_metrics="$2" output_metrics
  local -a in_m out_m
  local input_peak input_rms input_samples output_peak output_rms output_samples
  local i input_front output_front spatial_active=0 spatial_rms

  output_metrics="$(measure_audio_signal "$f" "0:a:0" 6)" || {
    VERIFY_REASON="astats non ha restituito metriche 5.1 complete per l'output"
    return 2
  }
  IFS='|' read -r -a in_m <<<"$input_metrics"
  IFS='|' read -r -a out_m <<<"$output_metrics"
  [[ ${#in_m[@]} -eq 5 && ${#out_m[@]} -eq 9 ]] || {
    VERIFY_REASON="numero di metriche stereo/5.1 inatteso"
    return 2
  }

  input_peak="${in_m[0]}"; input_rms="${in_m[1]}"; input_samples="${in_m[2]}"
  output_peak="${out_m[0]}"; output_rms="${out_m[1]}"; output_samples="${out_m[2]}"
  if [[ "$output_peak" == "-inf" || "$output_rms" == "-inf" ]]; then
    VERIFY_REASON="output digitalmente silenzioso"
    return 1
  fi
  if ! is_finite_db "$input_peak" || ! is_finite_db "$input_rms" || \
     ! is_finite_db "$output_peak" || ! is_finite_db "$output_rms" || \
     ! [[ "$input_samples" =~ ^[0-9]+([.][0-9]+)?$ && "$output_samples" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    VERIFY_REASON="metriche globali non numeriche"
    return 2
  fi
  if awk -v v="$output_peak" -v lim="$VERIFY_SILENCE_PEAK_DB" 'BEGIN { exit !(v <= lim) }'; then
    VERIFY_REASON="picco output troppo basso (${output_peak} dBFS)"
    return 1
  fi
  if awk -v i="$input_rms" -v o="$output_rms" -v lim="$VERIFY_MAX_OVERALL_DROP_DB" \
       'BEGIN { exit !((i-o) > lim) }'; then
    VERIFY_REASON="perdita RMS globale eccessiva: input=${input_rms} dBFS, output=${output_rms} dBFS"
    return 1
  fi
  if awk -v i="$input_samples" -v o="$output_samples" -v ratio="$VERIFY_MIN_SAMPLE_RATIO" \
       'BEGIN { exit !(o < i*ratio) }'; then
    VERIFY_REASON="output troncato: campioni input=${input_samples}, output=${output_samples}"
    return 1
  fi

  # FL e FR devono preservare i rispettivi canali sorgente quando questi sono attivi.
  for i in {0..1}; do
    input_front="${in_m[$((i+3))]}"
    output_front="${out_m[$((i+3))]}"
    [[ "$input_front" == "-inf" ]] && continue
    if ! is_finite_db "$input_front" || \
       { [[ "$output_front" != "-inf" ]] && ! is_finite_db "$output_front"; }; then
      VERIFY_REASON="metrica frontale $i non numerica"
      return 2
    fi
    if awk -v v="$input_front" -v lim="-65.0" 'BEGIN { exit !(v > lim) }'; then
      if [[ "$output_front" == "-inf" ]] || \
         awk -v src="$input_front" -v dst="$output_front" -v lim="$VERIFY_MAX_FRONT_DROP_DB" \
           'BEGIN { exit !((src-dst) > lim) }'; then
        VERIFY_REASON="frontale $i perso o attenuato eccessivamente"
        return 1
      fi
    fi
  done

  # Almeno uno fra FC/SL/SR deve contenere il segnale sintetizzato. Questo resta
  # valido anche per sorgenti mono, dual-mono o in opposizione di fase.
  for i in 5 7 8; do
    spatial_rms="${out_m[$i]}"
    [[ "$spatial_rms" == "-inf" ]] && continue
    is_finite_db "$spatial_rms" || { VERIFY_REASON="metrica canale sintetizzato non numerica"; return 2; }
    if awk -v v="$spatial_rms" 'BEGIN { exit !(v > -80.0) }'; then
      spatial_active=1
    fi
  done
  if (( spatial_active == 0 )); then
    VERIFY_REASON="FC, SL e SR risultano tutti virtualmente muti"
    return 1
  fi

  info "Verifica audio: peak ${input_peak}→${output_peak} dBFS; RMS ${input_rms}→${output_rms} dBFS; campioni ${input_samples}→${output_samples}"
  return 0
}

# ────────────────────────────────────────────────────────────────────────────────
# Output atomico: un errore FFmpeg non lascia un MKV finale incompleto e non
# distrugge un output precedente fino al completamento corretto del nuovo file.
# ────────────────────────────────────────────────────────────────────────────────
CURRENT_TMP=""
cleanup_tmp() {
  [[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]] && rm -f -- "$CURRENT_TMP"
}
trap cleanup_tmp EXIT INT TERM

# ────────────────────────────────────────────────────────────────────────────────
# Ciclo elaborazione
# ────────────────────────────────────────────────────────────────────────────────
OVERWRITE_ALL=false
OK_COUNT=0
ERR_COUNT=0
SKIP_COUNT=0

for CUR_FILE in "${FILES[@]}"; do
  info "Elaborazione: $CUR_FILE"
  # Seleziona lo stream audio stereo migliore (score-based)
  PROBE_RESULT=$(pick_best_stereo_stream "$CUR_FILE") || { warn "Nessuna traccia audio trovata. Salto."; ((SKIP_COUNT+=1)); continue; }
  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LANG <<<"$PROBE_RESULT"

  if ! [[ "$A_CHANNELS" =~ ^[0-9]+$ ]] || [[ "$A_CHANNELS" -ne 2 ]]; then
    warn "Stream selezionato non e' stereo (Canali: $A_CHANNELS). Salto."
    ((SKIP_COUNT+=1))
    continue
  fi

  info "Stream [$A_STREAM_INDEX]: ${A_CHANNELS}ch, lingua: ${A_LANG:-und}"

  INPUT_AUDIO_METRICS="$(measure_audio_signal "$CUR_FILE" "0:$A_STREAM_INDEX" 2)" || {
    err "Impossibile misurare in modo affidabile la traccia stereo sorgente. Salto."
    ((ERR_COUNT+=1))
    continue
  }

  # Costruzione filtergraph
  if [[ "$MODE" == "to51" ]]; then
    UPMIX_FILTER="$(build_to51_filter)"
  else
    UPMIX_FILTER="$(build_quad_filter)"
  fi

  OUT_FILE="${CUR_FILE%.*}_UPMIX_5.1_V9_${MODE^^}.mkv"

  # Controllo sovrascrittura
  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      confirm_overwrite "$OUT_FILE" || { info "Skippo '$CUR_FILE'."; ((SKIP_COUNT+=1)); continue; }
    else
      info "Sovrascrittura automatica di '$OUT_FILE'..."
    fi
  fi
  # Costruzione comando ffmpeg su file temporaneo, poi rename atomico.
  OUT_DIR=$(dirname -- "$OUT_FILE")
  OUT_BASE=$(basename -- "${OUT_FILE%.mkv}")
  CURRENT_TMP="${OUT_DIR}/.${OUT_BASE}.part.$$.mkv"
  if [[ -e "$CURRENT_TMP" ]]; then
    err "File temporaneo gia' esistente, impossibile procedere: $CURRENT_TMP"
    ((ERR_COUNT+=1))
    continue
  fi

  CMD=(ffmpeg -hide_banner -nostdin -stats -loglevel warning -y)
  CMD+=(
    -i "$CUR_FILE"
    -map_metadata 0 -map_chapters 0
    -filter_complex "$UPMIX_FILTER"
    -map "0:V:0?" -c:v copy
    -map "0:s?" -c:s copy
    -map "0:t?" -c:t copy
    -map "[aout]" -c:a:0 "$OUT_CODEC" -b:a:0 "$BITRATE" -dialnorm -31 -ar:a:0 48000 -ac:a:0 6
    -metadata:s:a:0 title="${OUT_CODEC^^} 5.1 Upmix ${MODE_TITLE}"
    -disposition:a:0 default
  )

  if [[ "$KEEP_STEREO" == "si" ]]; then
    CMD+=( -map 0:"$A_STREAM_INDEX" -c:a:1 copy
           -metadata:s:a:1 title="Stereo 2.0 Original"
           -disposition:a:1 0 )
  fi
  # Aggiunge metadata lingua se disponibile e diversa da "und"
  if [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]]; then
    CMD+=( -metadata:s:a:0 language="$A_LANG" )
    [[ "$KEEP_STEREO" == "si" ]] && CMD+=( -metadata:s:a:1 language="$A_LANG" )
  fi

  CMD+=( "$CURRENT_TMP" )
  if "${CMD[@]}"; then
    VERIFY_REASON=""
    verify_upmix_output "$CURRENT_TMP" "$INPUT_AUDIO_METRICS"
    VERIFY_RC=$?
    case "$VERIFY_RC" in
      0)
        if mv -f -- "$CURRENT_TMP" "$OUT_FILE"; then
          CURRENT_TMP=""
          ok "Creato e verificato: $OUT_FILE"
          ((OK_COUNT+=1))
        else
          err "Verifica superata, ma pubblicazione fallita: $CURRENT_TMP"
          ((ERR_COUNT+=1))
        fi
        ;;
      1|2)
        err "Candidato rifiutato dalla verifica audio: ${VERIFY_REASON}: $CURRENT_TMP"
        err "Il file finale non viene toccato; il candidato resta per il debug."
        CURRENT_TMP=""
        ((ERR_COUNT+=1))
        ;;
    esac
  else
    warn "Errore su: $CUR_FILE (candidato incompleto rimosso)"
    cleanup_tmp
    CURRENT_TMP=""
    ((ERR_COUNT+=1))
  fi
done

if (( ERR_COUNT > 0 )); then
  err "Elaborazione completata con errori: OK=$OK_COUNT, FALLITI=$ERR_COUNT, SALTATI=$SKIP_COUNT"
  exit 1
fi
if (( OK_COUNT == 0 )); then
  warn "Nessun file elaborato: SALTATI=$SKIP_COUNT"
  exit 0
fi
ok "Elaborazione completata: OK=$OK_COUNT, FALLITI=0, SALTATI=$SKIP_COUNT"
