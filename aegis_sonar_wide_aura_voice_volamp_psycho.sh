#!/usr/bin/env bash
# set -e rimosso: causa exit imprevedibili su pattern && / || e aritmetica bash.
# La gestione errori è esplicita nei punti critici (|| continue, || true, etc.)
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   aegis_sonar_wide_aura_voice_volamp.sh - GOD TIER EDITION - Maggio 2026     │
# │                                                                              │
# │   Motore di processing audio offline per tracce 5.1 (eAC3/AC3).              │
# │   Corregge dinamicamente mix sbilanciati tramite preset psicoacustici,       │
# │   migliorando l'intelligibilità dei dialoghi e ripristinando la bolla        │
# │   surround (Aegis, Sonar, Wide, Aura) senza alterare LFE e frontali L/R.     │
# │                                                                              │
# │   READABILITY REFACTOR:                                                      │
# │   - DSP ottimizzato per JBL SCS200 / AVR crossover 100 Hz                    │
# │   - Voce italiana: intelligibilità a basso volume senza perdere corpo        │
# │   - Surround psicoacustici più controllati e meno artificiali                │
# │   - Pipeline leggibile: input -> split -> voice -> surround -> output        │
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
  ./aegis_sonar_wide_aura_voice_volamp.sh <ac3|eac3> <si|no> [file] [bitrate] [preset] [volamp]

PARAMETRI:
  ac3|eac3  : Codec audio in uscita.
  si|no     : Conserva file audio originale.
  file      : File input singolo. Se omesso, processa i file compatibili nella cartella.
  bitrate   : Es. 640k o 768k (default: 640k per AC3, 768k per EAC3).
  preset    : aegis | sonar | wide | aura | voice (default: sonar).
  volamp    : Gain finale opzionale in dB prima del limiter.
              Valori consentiti: 0, da 0.1 a 2.5.
              Esempi pratici: 0 | 1.5 | 2 | 2.5

PRESET DISPONIBILI:
  aegis     -> Simula NEURAL:X (DTS:X)  | Cupola Sonora
  sonar     -> Simula ATMOS (5.1.2)     | Boost Verticale
  wide      -> Simula Dolby 7.1         | Allargamento Laterale
  aura      -> Simula Dolby 6.1         | Allargamento Posteriore
  voice     -> Esalta i dialoghi (FC)   | EQ Sartoriale Voce
USAGE
  exit 1
}

is_preset_name() {
  case "$1" in
    aegis|sonar|wide|aura|voice) return 0 ;;
    *) return 1 ;;
  esac
}

is_bitrate_token() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?([kKmM])?$ ]]
}

[[ $# -lt 2 ]] && usage

OUT_CODEC="${1:-}"
KEEP_ORIG="${2:-}"
shift 2

INPUT_FILE=""
BITRATE=""
SUR_MODE=""
VOLAMP_DB="0"
POSITIONAL=("$@")

# Ultimo parametro opzionale = volamp (0 .. 2.5 dB)
if (( ${#POSITIONAL[@]} > 0 )); then
  LAST_IDX=$((${#POSITIONAL[@]} - 1))
  LAST_ARG="${POSITIONAL[$LAST_IDX]}"
  LAST_ARG="${LAST_ARG/,/.}"

  if [[ "$LAST_ARG" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk -v v="$LAST_ARG" 'BEGIN { exit !(v >= 0 && v <= 2.5) }'; then
      VOLAMP_DB="$LAST_ARG"
      unset 'POSITIONAL[$LAST_IDX]'
      POSITIONAL=("${POSITIONAL[@]}")
    else
      err "volamp fuori range: '$LAST_ARG' (consentito: 0 .. 2.5 dB)"
      exit 1
    fi
  fi
fi

# Parsing flessibile dei rimanenti parametri
for arg in "${POSITIONAL[@]}"; do
  if [[ -z "$BITRATE" ]] && is_bitrate_token "$arg"; then
    BITRATE="$arg"
  elif [[ -z "$SUR_MODE" ]] && is_preset_name "$arg"; then
    SUR_MODE="$arg"
  elif [[ -z "$INPUT_FILE" ]]; then
    INPUT_FILE="$arg"
  else
    err "Troppi argomenti o ordine non valido: '$arg'"
    usage
  fi
done

SUR_MODE="${SUR_MODE:-sonar}"

case "$SUR_MODE" in
  aegis|sonar|wide|aura|voice) ;;
  *) err "Preset '$SUR_MODE' non riconosciuto. Validi: aegis, sonar, wide, aura, voice."; exit 1 ;;
esac

case "$OUT_CODEC" in ac3|eac3) ;; *) err "Codec deve essere ac3 o eac3"; exit 1 ;; esac
[[ "$KEEP_ORIG" =~ ^(si|no)$ ]] || { err "Parametro 2: si|no"; exit 1; }

[[ -z "$BITRATE" ]] && {
  [[ "$OUT_CODEC" = "ac3" ]] && BITRATE="640k" || BITRATE="768k"
}
[[ "$BITRATE" =~ [kKmM]$ ]] || BITRATE="${BITRATE}k"

case "$VOLAMP_DB" in
  0|0.0|0.00|0.000)
    FINAL_GAIN_FILTER=""
    VOLAMP_LABEL="OFF"
    ;;
  *)
    FINAL_GAIN_FILTER="volume=${VOLAMP_DB}dB,"
    VOLAMP_LABEL="+${VOLAMP_DB} dB"
    ;;
esac

case "$SUR_MODE" in
  aegis) DESC="Simula NEURAL:X (DTS:X) | Cupola Sonora" ;;
  sonar) DESC="Simula ATMOS (5.1.2) | Boost Verticale" ;;
  wide)  DESC="Simula Dolby 7.1 | Allargamento Laterale" ;;
  aura)  DESC="Simula Dolby 6.1 | Allargamento Posteriore" ;;
  voice) DESC="Esalta la voce   | EQ Sartoriale Voce" ;;
esac

info "Codec output:   $OUT_CODEC"
info "Surround mode:  $SUR_MODE ($DESC)"
info "Bitrate Target: $BITRATE"
info "Final volamp:   $VOLAMP_LABEL"

probe_audio_stream() {
  local f="$1" line
  local _lines
  mapfile -t _lines < <(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null || true)

  [[ ${#_lines[@]} -gt 0 ]] || return 1

  local best_line="" best_score=-1
  for line in "${_lines[@]}"; do
    [[ -z "$line" ]] && continue
    local idx ch layout def lang
    IFS=',' read -r idx ch layout def lang <<<"$line"
    ch="${ch:-0}"
    def="${def:-0}"
    lang="${lang:-}"
    layout="${layout:-}"

    local score=0
    [[ "$ch" =~ ^[0-9]+$ && "$ch" -eq 6 ]] && score=$((score+1000))
    [[ "$def" == "1" ]] && score=$((score+200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score+300))

    if (( score > best_score )); then
      best_score=$score
      best_line="$line"
    fi
  done

  [[ -n "$best_line" ]] || return 1

  local o_idx o_ch o_layout o_def o_lang
  IFS=',' read -r o_idx o_ch o_layout o_def o_lang <<<"$best_line"
  echo "${o_idx}|${o_ch:-0}|${o_layout:-}|${o_def:-0}|${o_lang:-}"
}

get_audio_title_by_index() {
  ffprobe -v error -select_streams a \
    -show_entries stream=index:stream_tags=title \
    -of default=nw=1 "$1" 2>/dev/null | awk -v idx="$2" '
    $0=="index="idx{f=1;next} f&&/^TAG:title=/{sub(/^TAG:title=/,"");print;exit} f&&/^index=/{exit}'
}

FILES=()
if [[ -n "$INPUT_FILE" ]]; then
  [[ -f "$INPUT_FILE" ]] || { err "File non esiste"; exit 1; }
  FILES+=("$INPUT_FILE")
else
  shopt -s nullglob
  FILES+=( *.mkv *.MKV *.mp4 *.MP4 *.m2ts *.M2TS *.ac3 *.eac3 )
  shopt -u nullglob
fi

(( ${#FILES[@]} == 0 )) && { err "Nessun file trovato."; exit 1; }

# ────────────────────────────────────────────────────────────────────────────────
# BLOCCHI VOCE
# ────────────────────────────────────────────────────────────────────────────────
# Low-volume intelligibility: center più leggibile senza effetto megafono.
# Niente highpass alto sul dialogo: il controllo sibilanti è fatto con EQ statico leggero.
read -r -d '' VOICE_EQ_BASE <<'EOF' || true
[FC]highpass=f=102:t=q:w=0.707,equalizer=f=220:t=q:w=1.4:g=-0.8,equalizer=f=350:t=q:w=1.4:g=-0.6,equalizer=f=1100:t=q:w=1.4:g=0.8,equalizer=f=7200:t=q:w=2.5:g=-0.9[FC_pre];
EOF
read -r -d '' VOICE_DELTA_SONAR <<'EOF' || true
[FC_pre]volume=1.5dB,equalizer=f=1650:t=q:w=1.6:g=0.8,equalizer=f=2450:t=q:w=1.3:g=1.3,equalizer=f=3800:t=q:w=2.0:g=0.8,equalizer=f=6800:t=q:w=2.0:g=-0.8,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_AEGIS <<'EOF' || true
[FC_pre]volume=1.6dB,equalizer=f=1650:t=q:w=1.6:g=0.8,equalizer=f=2450:t=q:w=1.3:g=1.3,equalizer=f=3800:t=q:w=2.0:g=0.8,equalizer=f=6800:t=q:w=2.0:g=-0.8,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_WIDE <<'EOF' || true
[FC_pre]volume=1.7dB,equalizer=f=1650:t=q:w=1.6:g=0.8,equalizer=f=2450:t=q:w=1.3:g=1.4,equalizer=f=3800:t=q:w=2.0:g=0.9,equalizer=f=6800:t=q:w=2.0:g=-0.7,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_AURA <<'EOF' || true
[FC_pre]volume=1.4dB,equalizer=f=1650:t=q:w=1.6:g=0.6,equalizer=f=2450:t=q:w=1.3:g=1.1,equalizer=f=3800:t=q:w=2.0:g=0.7,equalizer=f=6800:t=q:w=2.0:g=-0.8,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_VOICEONLY <<'EOF' || true
[FC_pre]volume=2.2dB,equalizer=f=1650:t=q:w=1.6:g=1.2,equalizer=f=2450:t=q:w=1.3:g=2.0,equalizer=f=3800:t=q:w=2.0:g=1.4,equalizer=f=6800:t=q:w=2.0:g=-1.0,volume=0.95[FCv];
EOF
# ────────────────────────────────────────────────────────────────────────────────
# BLOCCHI SURROUND
# ────────────────────────────────────────────────────────────────────────────────
read -r -d '' SUR_FILTERS_SONAR <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,highpass=f=112:t=q:w=0.707,volume=0.95[SLd];
[SLp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SLp];
[SLh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-3.0,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SLh];
[SLlate_in]adelay=38,highpass=f=150,lowpass=f=1500,volume=0.58[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1 0.6 0.4 0.2':normalize=0,volume=1.05[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,highpass=f=112:t=q:w=0.707,volume=0.95[SRd];
[SRp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SRp];
[SRh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-3.0,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SRh];
[SRlate_in]adelay=41,highpass=f=150,lowpass=f=1500,volume=0.58[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1 0.6 0.4 0.2':normalize=0,volume=1.05[SR_out];
EOF

read -r -d '' SUR_FILTERS_AEGIS <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,highpass=f=112:t=q:w=0.707,volume=0.95[SLd];
[SLp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SLp];
[SLh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SLh];
[SLlate_in]adelay=39,highpass=f=150,lowpass=f=1300,volume=0.42[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,highpass=f=112:t=q:w=0.707,volume=0.95[SRd];
[SRp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SRp];
[SRh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SRh];
[SRlate_in]adelay=42,highpass=f=150,lowpass=f=1300,volume=0.42[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SR_out];
EOF

read -r -d '' SUR_FILTERS_WIDE <<'EOF' || true
[SL]asplit=3[SLd_in][SLe_in][SLx_in];
[SLd_in]adelay=1,highpass=f=112:t=q:w=0.707,volume=1.00[SLd];
[SLe_in]adelay=9,highpass=f=280,lowpass=f=7000,allpass=f=1200:t=q:w=0.65,volume=0.42[SLe];
[SLx_in]adelay=22,highpass=f=600,lowpass=f=5000,allpass=f=700:t=q:w=0.70,allpass=f=2600:t=q:w=0.70,volume=0.17[SLx];
[SLd][SLe][SLx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=250:g=0.5:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.00[SL_out];
[SR]asplit=3[SRd_in][SRe_in][SRx_in];
[SRd_in]adelay=1,highpass=f=112:t=q:w=0.707,volume=1.00[SRd];
[SRe_in]adelay=10,highpass=f=280,lowpass=f=7000,allpass=f=1350:t=q:w=0.65,volume=0.42[SRe];
[SRx_in]adelay=24,highpass=f=600,lowpass=f=5000,allpass=f=820:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,volume=0.17[SRx];
[SRd][SRe][SRx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=250:g=0.5:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.00[SR_out];
EOF

read -r -d '' SUR_FILTERS_AURA <<'EOF' || true
[SL]asplit=2[SLd_in][SLa_in];
[SLd_in]adelay=1,highpass=f=112:t=q:w=0.707,volume=1.00[SLd];
[SLa_in]adelay=8,highpass=f=800,lowpass=f=4500,allpass=f=1400:t=q:w=0.65,volume=0.22[SLa];
[SLd][SLa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=0.95[SL_out];
[SR]asplit=2[SRd_in][SRa_in];
[SRd_in]adelay=1,highpass=f=112:t=q:w=0.707,volume=1.00[SRd];
[SRa_in]adelay=9,highpass=f=800,lowpass=f=4500,allpass=f=1550:t=q:w=0.65,volume=0.22[SRa];
[SRd][SRa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=0.95[SR_out];
EOF

read -r -d '' SUR_FILTERS_VOICEONLY <<'EOF' || true
[SL]highpass=f=112:t=q:w=0.707,volume=0.85[SL_out];
[SR]highpass=f=112:t=q:w=0.707,volume=0.85[SR_out];
EOF

# ────────────────────────────────────────────────────────────────────────────────
# PROFILI PRESET
# ────────────────────────────────────────────────────────────────────────────────
set_preset_profile() {
  case "$SUR_MODE" in
    sonar)
      SUR_BLOCK="$SUR_FILTERS_SONAR"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_SONAR}"
      DECORR_GAIN="0.060"
      LIMITER_OPTS="limit=0.97:attack=3.5:release=65:level=0"
      MODE_TITLE="Sonar (Atmos Like)"
      ;;
    aegis)
      SUR_BLOCK="$SUR_FILTERS_AEGIS"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AEGIS}"
      DECORR_GAIN="0.052"
      LIMITER_OPTS="limit=0.98:attack=2.5:release=50:level=0"
      MODE_TITLE="AEGIS (Neural:X Like)"
      ;;
    aura)
      SUR_BLOCK="$SUR_FILTERS_AURA"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AURA}"
      DECORR_GAIN="0.035"
      LIMITER_OPTS="limit=0.975:attack=3.0:release=60:level=0"
      MODE_TITLE="AURA (Dolby 6.1 Like)"
      ;;
    wide)
      SUR_BLOCK="$SUR_FILTERS_WIDE"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_WIDE}"
      DECORR_GAIN="0.045"
      LIMITER_OPTS="limit=0.97:attack=3.5:release=65:level=0"
      MODE_TITLE="Wide (7.1 Like)"
      ;;
    voice)
      SUR_BLOCK="$SUR_FILTERS_VOICEONLY"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_VOICEONLY}"
      DECORR_GAIN="0"
      LIMITER_OPTS="limit=0.95:attack=2.0:release=40:level=0"
      MODE_TITLE="VOICE (Dialogue Plus)"
      ;;
    *)
      err "Preset '$SUR_MODE' non riconosciuto."
      exit 1
      ;;
  esac
}

build_input_split_graph() {
  cat <<EOF
[0:${A_STREAM_INDEX}]aformat=sample_rates=48000:sample_fmts=fltp:channel_layouts=${IN_LAYOUT},
pan=5.1(side)|FL=FL|FR=FR|FC=FC|LFE=LFE|SL=${SUR_L_CH}|SR=${SUR_R_CH}[base];
[base]channelsplit=channel_layout=5.1(side)[FL][FR][FC][LFE][SL][SR];
[FL]highpass=f=112:t=q:w=0.707[FLp];
[FR]highpass=f=112:t=q:w=0.707[FRp];
EOF
}


build_surround_psycho_graph() {
  # Air layer psicoacustico: micro-decorrelazione continua, a basso livello.
  # Serve a dare aria/lateralità ai surround senza gonfiare il volume o creare pumping.
  if [[ "${DECORR_GAIN:-0}" = "0" ]]; then
    cat <<EOF
[SL_out]anull[SL_final];
[SR_out]anull[SR_final];
EOF
  else
    cat <<EOF
[SL_out]asplit=2[SL_main][SL_air_in];
[SL_air_in]highpass=f=1600,lowpass=f=9500,adelay=12,allpass=f=1400:t=q:w=0.60,allpass=f=3400:t=q:w=0.65,equalizer=f=7200:t=q:w=2.0:g=-1.0,volume=${DECORR_GAIN}[SL_air];
[SL_main][SL_air]amix=inputs=2:weights='1 1':normalize=0[SL_final];
[SR_out]asplit=2[SR_main][SR_air_in];
[SR_air_in]highpass=f=1600,lowpass=f=9500,adelay=15,allpass=f=1650:t=q:w=0.60,allpass=f=3150:t=q:w=0.65,equalizer=f=7200:t=q:w=2.0:g=-1.0,volume=${DECORR_GAIN}[SR_air];
[SR_main][SR_air]amix=inputs=2:weights='1 1':normalize=0[SR_final];
EOF
  fi
}

build_output_join_graph() {
  cat <<EOF
[FLp]aformat=channel_layouts=mono[FLf];
[FRp]aformat=channel_layouts=mono[FRf];
[FCv]aformat=channel_layouts=mono[FCf];
[LFE]aformat=channel_layouts=mono[LFEf];
[SL_final]aformat=channel_layouts=mono[SLf];
[SR_final]aformat=channel_layouts=mono[SRf];
[FLf][FRf][FCf][LFEf][SLf][SRf]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,
highshelf=f=12000:g=0.8:w=0.5:c=FL|FR|FC|SL|SR,${FINAL_GAIN_FILTER}aresample=192000,alimiter=${LIMITER_OPTS},aresample=48000[aout]
EOF
}

build_filter_complex() {
  local input_graph psycho_graph output_graph
  input_graph="$(build_input_split_graph)"
  psycho_graph="$(build_surround_psycho_graph)"
  output_graph="$(build_output_join_graph)"
  printf '%s\n%s\n%s\n%s\n%s\n' "$input_graph" "$VOICE_BLOCK" "$SUR_BLOCK" "$psycho_graph" "$output_graph"
}

# ────────────────────────────────────────────────────────────────────────────────
# CICLO ELABORAZIONE
# ────────────────────────────────────────────────────────────────────────────────
OVERWRITE_ALL=false

for CUR_FILE in "${FILES[@]}"; do
  info "Input: $CUR_FILE"

  PROBE_RESULT=$(probe_audio_stream "$CUR_FILE") || { warn "Nessuna traccia audio valida"; continue; }
  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LAYOUT A_IS_DEFAULT A_LANG <<<"$PROBE_RESULT"

  case "$A_LAYOUT" in
    "5.1(side)")
      IN_LAYOUT="5.1(side)"; SUR_L_CH="SL"; SUR_R_CH="SR"
      ;;
    "5.1"|"5.1(back)")
      IN_LAYOUT="5.1"; SUR_L_CH="BL"; SUR_R_CH="BR"
      ;;
    *)
      IN_LAYOUT="5.1(side)"; SUR_L_CH="SL"; SUR_R_CH="SR"
      warn "Layout input non standard: '${A_LAYOUT:-unknown}' → fallback: 5.1(side)"
      ;;
  esac

  if [[ "$A_CHANNELS" -ne 6 ]]; then
    warn "Non è un 5.1 (Canali: $A_CHANNELS) → Salto."
    continue
  fi

  set_preset_profile
  OUT_FILE="${CUR_FILE%.*}_${OUT_CODEC^^}_${SUR_MODE^}.mkv"

  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      echo -ne "${C_WARN} Il file '$OUT_FILE' esiste già. Sovrascrivere? [s/n/t] (s=sì, n=no, t=tutti): "
      read -r ans < /dev/tty
      case "${ans,,}" in
        t|tutti)
          OVERWRITE_ALL=true
          info "God mode attivato: sovrascriverò tutto da qui in poi senza pietà."
          ;;
        s|si|y|yes)
          info "Piallo e sovrascrivo questo file."
          ;;
        *)
          info "Skippo '$CUR_FILE' e passo al prossimo."
          continue
          ;;
      esac
    else
      info "Sovrascrittura automatica di '$OUT_FILE'..."
    fi
  fi

  FILTER_COMPLEX="$(build_filter_complex)"

  CMD=(ffmpeg -hide_banner -nostdin -stats -loglevel warning)
  [[ -f "$OUT_FILE" ]] && CMD+=( -y )
  CMD+=(
    -i "$CUR_FILE"
    -map_metadata 0 -map_chapters 0
    -filter_complex "$FILTER_COMPLEX"
    -map "0:V:0?" -c:v copy
    -map "0:s?" -c:s copy
    -map "0:t?" -c:t copy
    -map "[aout]" -c:a:0 "$OUT_CODEC" -b:a:0 "$BITRATE" -ar:a:0 48000 -ac:a:0 6
    -metadata:s:a:0 title="${OUT_CODEC^^} 5.1 – ${MODE_TITLE}"
    -disposition:a:0 default
  )

  [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:0 language="$A_LANG" )

  if [[ "$KEEP_ORIG" = "si" ]]; then
    ORIG_TITLE=$(get_audio_title_by_index "$CUR_FILE" "$A_STREAM_INDEX" || echo "Original Audio")
    CMD+=( -map 0:"$A_STREAM_INDEX" -c:a:1 copy -metadata:s:a:1 title="$ORIG_TITLE" -disposition:a:1 0 )
  fi

  CMD+=( "$OUT_FILE" )
  "${CMD[@]}" && ok "Creato: $OUT_FILE" || warn "Errore su: $CUR_FILE"
done

ok "Elaborazione completata"
