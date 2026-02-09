#!/usr/bin/env bash
set -euo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   aegis_sonar_wide_aura_voice.sh — Febbraio (2026)                           │
# │                                                                              │
# │ • Converte una traccia 5.1 in AC3/EAC3                                       │
# │ • DSP surround Sonar / Wide / Aegis / Aura (psicoacustico)                   │
# │ • EQ Voce Sartoriale ottimizzata (2.5kHz: +1.6dB invece di +2.3dB)           │
# │ • Ottimizzato per AVR con crossover 160Hz + speaker Small                    │
# │ • Delay ridotti (50ms invece di 85ms) per stanze >4×5×4m                     │
# │ • Mantiene video, sottotitoli e traccia originale opzionale                  │
# │   WIDE → Film d'azione, sport, concerti, car chase, battaglie                │
# │   AEGIS → Film moderni ben mixati, thriller, boost moderato                  │
# │   SONAR → Sci-fi, fantasy, film con molto "sky/ceiling action"               │
# │   AURA → Drama, dialoghi, film vintage rimasterizzati                        │
# │   VOICE → Quando l'audio 5.1 originale è perfetto                            │                                               │
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
# Parsing argomenti
# ────────────────────────────────────────────────────────────────────────────────
OUT_CODEC="${1:-}"
KEEP_ORIG="${2:-}"
INPUT_FILE="${3:-}"
BITRATE="${4:-}"
SUR_MODE="${5:-sonar}"

[[ $# -lt 2 ]] && {
cat <<'USAGE'
─────────────────────────────────────────────────────────────────────────────────────────────────────────
UTILIZZO:
  ./aegis_sonar_wide_aura_voice.sh <ac3|eac3> <si|no> [file|""] [bitrate] [sonar|wide|aegis|aura|voice]

PARAMETRI:
  1) codec      ac3 | eac3
  2) keep_orig  si  | no   (si/no mantiene o no anche la traccia originale)
  3) file       "film.mkv" | "" (elabora tutti i file video nella cartella)
  4) bitrate    es. 448k, 640k, 768k (default: ac3=640k, eac3=768k)
  5) mode       sonar | wide | aegis | aura | voice
               • sonar = “altezza” (illusione verticale 5.1.2)
               • wide  = “ampiezza” (illusione orizzontale 7.1)
               • aegis = "intermedia" (cupola coerente, boost moderato)
               • aura  = “wide light” (spazio laterale soft, bassa energia)
               • voice = solo EQ Voce Sartoriale su FC (surround pass-through)

ESEMPI:
  ./aegis_sonar_wide_aura_voice.sh eac3 no  "film.mkv" 768k aura
  ./aegis_sonar_wide_aura_voice.sh ac3  si  ""         640k wide
─────────────────────────────────────────────────────────────────────────────────────────────────────────
USAGE
exit 1
}

case "$OUT_CODEC" in ac3|eac3) ;; *) err "Codec deve essere ac3 o eac3"; exit 1;; esac
[[ "$KEEP_ORIG" =~ ^(si|no)$ ]] || { err "Parametro 2: si|no"; exit 1; }
[[ "$SUR_MODE" =~ ^(sonar|wide|aegis|aura|voice)$ ]] || { err "Modalità: sonar|wide|aegis|aura|voice"; exit 1; }

[[ -z "$BITRATE" ]] && {
  [[ "$OUT_CODEC" = "ac3" ]] && BITRATE="640k" || BITRATE="768k"
}
[[ "$BITRATE" =~ ^[0-9]+k$ ]] || { err "Bitrate non valido"; exit 1; }

# Vincolo AC3: max 640k
if [[ "$OUT_CODEC" == "ac3" ]]; then
  b="${BITRATE%k}"
  (( b <= 640 )) || { err "AC3 non supporta bitrate > 640k (richiesto: $BITRATE)"; exit 1; }
fi

info "Codec output:   $OUT_CODEC"
info "Mantieni orig:  $KEEP_ORIG"
info "Bitrate:        $BITRATE"
info "Surround mode:  $SUR_MODE"

# ────────────────────────────────────────────────────────────────────────────────
# Funzioni probe audio
# ────────────────────────────────────────────────────────────────────────────────
probe_audio_stream() {
  local f="$1" line

  mapfile -t _A_LINES < <(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null || true)

  [[ ${#_A_LINES[@]} -gt 0 ]] || return 1

  # Scoring:
  #  +1000 6ch (5.1)
  #  +200  default
  #  +300  language it*
  #  +10   layout known (non vuoto/non unknown)
  local best_line="" best_score=-1
  for line in "${_A_LINES[@]}"; do
    IFS=',' read -r idx ch layout def lang <<<"$line"
    ch="${ch:-0}"
    def="${def:-0}"
    lang="${lang:-}"
    layout="${layout:-}"

    local score=0
    [[ "$ch" -eq 6 ]] && score=$((score+1000))
    [[ "$def" == "1" ]] && score=$((score+200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score+300))
    [[ -n "$layout" && "${layout,,}" != "unknown" ]] && score=$((score+10))

    if (( score > best_score )); then
      best_score=$score
      best_line="$line"
    fi
  done

  [[ -n "$best_line" ]] || return 1
  IFS=',' read -r A_STREAM_INDEX A_CHANNELS A_LAYOUT A_IS_DEFAULT A_LANG <<<"$best_line"
  A_LANG="${A_LANG:-}"
}

get_audio_title_by_index() {
  ffprobe -v error -select_streams a \
    -show_entries stream=index:stream_tags=title \
    -of default=nw=1 "$1" 2>/dev/null | awk -v idx="$2" '
    $0=="index="idx{f=1;next} f&&/^TAG:title=/{sub(/^TAG:title=/,"");print;exit} f&&/^index=/{exit}'
}

# ────────────────────────────────────────────────────────────────────────────────
# Raccolta file
# ────────────────────────────────────────────────────────────────────────────────
FILES=()
if [[ -n "$INPUT_FILE" ]]; then
  [[ -f "$INPUT_FILE" ]] || { err "File '$INPUT_FILE' non esiste"; exit 1; }
  FILES+=("$INPUT_FILE")
else
  shopt -s nullglob
  FILES+=( *.mkv *.MKV *.mp4 *.MP4 *.m2ts *.M2TS )
  shopt -u nullglob
fi

(( ${#FILES[@]} == 0 )) && { err "Nessun file da elaborare"; exit 1; }

# ────────────────────────────────────────────────────────────────────────────────
# DSP – BLOCCO SONAR (SURROUND)
# ────────────────────────────────────────────────────────────────────────────────
read -r -d '' SUR_FILTERS_SONAR <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,volume=0.95[SLd];
[SLp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SLp];
[SLh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-3.0,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SLh];
[SLlate_in]adelay=50,lowpass=f=1500,volume=0.65[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1.10 0.85 0.80 0.55':normalize=0,volume=1.35[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,volume=0.95[SRd];
[SRp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SRp];
[SRh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-3.0,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SRh];
[SRlate_in]adelay=50,lowpass=f=1500,volume=0.65[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1.10 0.85 0.80 0.55':normalize=0,volume=1.35[SR_out];
EOF

# ────────────────────────────────────────────────────────────────────────────────
# DSP – BLOCCO AEGIS (SURROUND)
# ────────────────────────────────────────────────────────────────────────────────
read -r -d '' SUR_FILTERS_AEGIS <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,volume=0.95[SLd];
[SLp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SLp];
[SLh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SLh];
[SLlate_in]adelay=50,lowpass=f=1300,volume=0.45[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,volume=0.95[SRd];
[SRp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SRp];
[SRh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SRh];
[SRlate_in]adelay=50,lowpass=f=1300,volume=0.45[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SR_out];
EOF

# ────────────────────────────────────────────────────────────────────────────────
# DSP – BLOCCO WIDE (SURROUND)
# ────────────────────────────────────────────────────────────────────────────────
read -r -d '' SUR_FILTERS_WIDE <<'EOF' || true
[SL]asplit=3[SLd_in][SLe_in][SLx_in];
[SLd_in]adelay=1,volume=1.00[SLd];
[SLe_in]adelay=9,highpass=f=280,lowpass=f=7000,allpass=f=1200:t=q:w=0.65,volume=0.42[SLe];
[SLx_in]adelay=22,highpass=f=600,lowpass=f=5000,allpass=f=700:t=q:w=0.70,allpass=f=2600:t=q:w=0.70,volume=0.17[SLx];
[SLd][SLe][SLx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=160:g=0.2:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.30[SL_out];
[SR]asplit=3[SRd_in][SRe_in][SRx_in];
[SRd_in]adelay=1,volume=1.00[SRd];
[SRe_in]adelay=10,highpass=f=280,lowpass=f=7000,allpass=f=1350:t=q:w=0.65,volume=0.42[SRe];
[SRx_in]adelay=24,highpass=f=600,lowpass=f=5000,allpass=f=820:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,volume=0.17[SRx];
[SRd][SRe][SRx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=160:g=0.2:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.30[SR_out];
EOF

# ────────────────────────────────────────────────────────────────────────────────
# DSP – BLOCCO AURA (SURROUND) — Wide Light (spazio laterale soft)
# Banda più stretta + decorrelazione lieve + energia contenuta
# ────────────────────────────────────────────────────────────────────────────────
read -r -d '' SUR_FILTERS_AURA <<'EOF' || true
[SL]asplit=2[SLd_in][SLa_in];
[SLd_in]adelay=1,volume=1.00[SLd];
[SLa_in]adelay=8,highpass=f=800,lowpass=f=4500,allpass=f=1400:t=q:w=0.65,volume=0.22[SLa];
[SLd][SLa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=1.15[SL_out];

[SR]asplit=2[SRd_in][SRa_in];
[SRd_in]adelay=1,volume=1.00[SRd];
[SRa_in]adelay=9,highpass=f=800,lowpass=f=4500,allpass=f=1550:t=q:w=0.65,volume=0.22[SRa];
[SRd][SRa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=1.15[SR_out];
EOF

# ────────────────────────────────────────────────────────────────────────────────
# DSP – BLOCCO VOICE (solo EQ FC, surround pass-through)
# ────────────────────────────────────────────────────────────────────────────────
read -r -d '' SUR_FILTERS_VOICEONLY <<'EOF' || true
[SL]volume=1.08[SL_out];
[SR]volume=1.08[SR_out];
EOF

# ────────────────────────────────────────────────────────────────────────────────
# EQ - BLOCCO VOCE SARTORIALE (FC)
# ────────────────────────────────────────────────────────────────────────────────
read -r -d '' VOICE_EQ_BASE <<'EOF' || true
[FC]
equalizer=f=230:t=q:w=1.4:g=-1.0,
equalizer=f=350:t=q:w=1.0:g=-1.0,
equalizer=f=900:t=q:w=3.0:g=-0.5,
equalizer=f=1000:t=q:w=1.2:g=1.6,
equalizer=f=1800:t=q:w=3.0:g=0.4,
equalizer=f=2500:t=q:w=1.0:g=1.6,
equalizer=f=3200:t=q:w=1.0:g=0.35,
equalizer=f=7200:t=q:w=2.5:g=-1.0,
EOF

read -r -d '' VOICE_DELTA_SONAR <<'EOF' || true
volume=0.54dB[FCv];
EOF

read -r -d '' VOICE_DELTA_WIDE <<'EOF' || true
volume=0.58dB,equalizer=f=2500:t=q:w=1.2:g=0.25[FCv];
EOF

read -r -d '' VOICE_DELTA_AURA <<'EOF' || true
volume=0.56dB,equalizer=f=2500:t=q:w=1.2:g=0.15[FCv];
EOF

read -r -d '' VOICE_DELTA_AEGIS <<'EOF' || true
volume=0.57dB,equalizer=f=2500:t=q:w=1.2:g=0.20[FCv];
EOF

read -r -d '' VOICE_DELTA_VOICEONLY <<'EOF' || true
volume=0dB[FCv];
EOF

# ────────────────────────────────────────────────────────────────────────────────
# CICLO ELABORAZIONE
# ────────────────────────────────────────────────────────────────────────────────
for CUR_FILE in "${FILES[@]}"; do
  info "Input: $CUR_FILE"

  probe_audio_stream "$CUR_FILE" || { warn "Nessuna traccia audio valida"; continue; }

  # Detect input channel layout (side/back) + canali surround corretti
  A_LAYOUT=$(ffprobe -v error -select_streams a:${A_STREAM_INDEX} \
    -show_entries stream=channel_layout -of default=nk=1:nw=1 "$CUR_FILE" | tr -d '\r')

  case "$A_LAYOUT" in
    "5.1(side)")
      IN_LAYOUT="5.1(side)"
      SUR_L_CH="SL"; SUR_R_CH="SR"
      ;;
    "5.1"|"5.1(back)")
      IN_LAYOUT="5.1(back)"
      SUR_L_CH="BL"; SUR_R_CH="BR"
      ;;
    *)
      layout_disp="${A_LAYOUT:-<vuoto/unknown>}"
      warn "Layout input non standard: '${layout_disp}' (stream a:${A_STREAM_INDEX}) → fallback: 5.1(side) (SL/SR)"
      IN_LAYOUT="5.1(side)"
      SUR_L_CH="SL"; SUR_R_CH="SR"
      ;;
  esac

  info "Layout in: ${A_LAYOUT:-<non rilevato>} → mapping surround: ${SUR_L_CH}/${SUR_R_CH} → SL/SR"

  if [[ "$A_CHANNELS" -ne 6 ]]; then
    warn "Non 5.1 (trovati $A_CHANNELS canali) → salto"
    continue
  fi

  MODE_KEY="$SUR_MODE"
  BASENAME="${CUR_FILE%.*}"
  OUT_FILE="${BASENAME}_${OUT_CODEC^^}_${MODE_KEY^}.mkv"

  [[ -f "$OUT_FILE" ]] && {
    read -p "Sovrascrivere $OUT_FILE? [s/N] " ans
    [[ ! "$ans" =~ ^[sS]$ ]] && continue
  }

  # Selezione blocchi DSP + limiter + titolo
  if [[ "$SUR_MODE" = "sonar" ]]; then
    SUR_BLOCK="$SUR_FILTERS_SONAR"
    VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_SONAR}"
    LIMITER_OPTS="limit=0.97:attack=1.5:release=25"
    MODE_TITLE="Sonar (EQ Voce + DSP Surround)"

  elif [[ "$SUR_MODE" = "aegis" ]]; then
    SUR_BLOCK="$SUR_FILTERS_AEGIS"
    VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AEGIS}"
    LIMITER_OPTS="limit=0.98:attack=1.0:release=15"
    MODE_TITLE="AEGIS (Intermedia Sonar + EQ Voce)"

  elif [[ "$SUR_MODE" = "aura" ]]; then
    SUR_BLOCK="$SUR_FILTERS_AURA"
    VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AURA}"
    LIMITER_OPTS="limit=0.975:attack=1.4:release=24"
    MODE_TITLE="AURA (Wide Light – spazio laterale soft)"
  elif [[ "$MODE_KEY" = "voice" ]]; then
    SUR_BLOCK="$SUR_FILTERS_VOICEONLY"
    VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_VOICEONLY}"
    LIMITER_OPTS="limit=0.99:attack=1.0:release=25"
    MODE_TITLE="VOICE (EQ Voce Sartoriale – solo FC)"
  else
    SUR_BLOCK="$SUR_FILTERS_WIDE"
    VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_WIDE}"
    LIMITER_OPTS="limit=0.97:attack=1.5:release=25"
    MODE_TITLE="Wide (EQ Voce + DSP Surround)"
  fi

  FILTER_COMPLEX="
[0:${A_STREAM_INDEX}]aformat=sample_rates=48000:sample_fmts=fltp:channel_layouts=${IN_LAYOUT},
pan=5.1(side)|FL=FL|FR=FR|FC=FC|LFE=LFE|SL=${SUR_L_CH}|SR=${SUR_R_CH}[base];
[base]channelsplit=channel_layout=5.1(side)[FL][FR][FC][LFE][SL][SR];
${VOICE_BLOCK}
[FL]aformat=channel_layouts=mono[FLf];
[FR]aformat=channel_layouts=mono[FRf];
[FCv]aformat=channel_layouts=mono[FCf];
[LFE]aformat=channel_layouts=mono[LFEf];
${SUR_BLOCK}
[SL_out]aformat=channel_layouts=mono[SLf];
[SR_out]aformat=channel_layouts=mono[SRf];
[FLf][FRf][FCf][LFEf][SLf][SRf]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,
alimiter=${LIMITER_OPTS}:asc=1:level=1[aout]
"

  CMD=(ffmpeg -y -hide_banner -nostdin -stats -loglevel warning
       -i "$CUR_FILE"
       -map_metadata 0
       -map_chapters 0
       -filter_complex "$FILTER_COMPLEX"
       -map 0:v -c:v copy
       -map 0:t? -c:t copy
       -map "[aout]" -c:a:0 "$OUT_CODEC" -b:a:0 "$BITRATE" -ar:a:0 48000 -ac:a:0 6
       -metadata:s:a:0 title="${OUT_CODEC^^} 5.1 – ${MODE_TITLE}"
       -disposition:a:0 default)

  [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:0 language="$A_LANG" )

  if ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$CUR_FILE" | grep -q .; then
    CMD+=( -map 0:s -c:s copy )
  fi

  if [[ "$KEEP_ORIG" = "si" ]]; then
    ORIG_TITLE=$(get_audio_title_by_index "$CUR_FILE" "$A_STREAM_INDEX" || echo "Original Audio")
    CMD+=( -map 0:"$A_STREAM_INDEX" -c:a:1 copy -metadata:s:a:1 title="$ORIG_TITLE" -disposition:a:1 0 )
  fi

  CMD+=( "$OUT_FILE" )
  if "${CMD[@]}"; then
    ok "Creato: $OUT_FILE"
  else
    warn "Errore su: $CUR_FILE"
  fi
done

ok "Elaborazione completata"
