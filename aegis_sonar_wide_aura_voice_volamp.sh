#!/usr/bin/env bash
# set -e rimosso: causa exit imprevedibili su pattern && / || e aritmetica bash.
# La gestione errori è esplicita nei punti critici (|| continue, || true, etc.)
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   aegis_sonar_wide_aura_voice.sh - GOD TIER EDITION - Aprile 2026            │
# │                                                                              │
# │   Motore di processing audio offline per tracce 5.1 (eAC3/AC3).              │
# │   Corregge dinamicamente mix sbilanciati tramite preset psicoacustici,       │
# │   migliorando l'intelligibilità dei dialoghi e ripristinando la bolla        │
# │   surround (Aegis, Sonar, Wide, Aura) senza alterare LFE e frontali L/R.     │
# │   * Ottimizzato per transienti fisici, LFE intatto e prompt overwrite *      │
# │                                                                              │
# │   CHANGELOG:                                                                 │
# │     - Rimosso set -e (allineato ad audio_analyzer)                           │
# │     - Rimosso re-probe ridondante del layout (bug indice a: vs globale)      │
# │     - Validazione preset anticipata (prima del ciclo file)                   │
# │     - Documentato limiter level=0 (no auto-leveling, gain manuale)           │
# │     - probe_audio_stream() ritorna via stdout (no global side-effects)       │
# │     - Aggiunto volamp finale opzionale (0 .. 2.5 dB) come ultimo parametro   │
# │     - Parsing argomenti reso più flessibile (file/bitrate/preset opzionali)  │
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
  ./aegis_sonar_wide_aura_voice.sh <ac3|eac3> <si|no> [file] [bitrate] [preset] [volamp]

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

# Controllo argomenti minimi
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

# Parsing flessibile dei rimanenti parametri:
# file opzionale, bitrate opzionale, preset opzionale
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

# Validazione preset anticipata (fail-fast prima del ciclo file)
case "$SUR_MODE" in
  aegis|sonar|wide|aura|voice) ;;
  *) err "Preset '$SUR_MODE' non riconosciuto. Validi: aegis, sonar, wide, aura, voice."; exit 1 ;;
esac

case "$OUT_CODEC" in ac3|eac3) ;; *) err "Codec deve essere ac3 o eac3"; exit 1;; esac
[[ "$KEEP_ORIG" =~ ^(si|no)$ ]] || { err "Parametro 2: si|no"; exit 1; }

[[ -z "$BITRATE" ]] && {
  [[ "$OUT_CODEC" = "ac3" ]] && BITRATE="640k" || BITRATE="768k"
}

# --- FIX BITRATE KAMIKAZE ---
# Se l'utente digita "640" dimenticando la "k", la aggiungiamo noi
[[ "$BITRATE" =~ [kKmM]$ ]] || BITRATE="${BITRATE}k"
# ----------------------------

# Gain finale opzionale prima del limiter
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

# Mapping descrizioni per log (Sincronizzato con SUR_MODE)
case "$SUR_MODE" in
  aegis) DESC="Simula NEURAL:X (DTS:X) | Cupola Sonora";;
  sonar) DESC="Simula ATMOS (5.1.2) | Boost Verticale";;
  wide)  DESC="Simula Dolby 7.1 | Allargamento Laterale";;
  aura)  DESC="Simula Dolby 6.1 | Allargamento Posteriore";;
  voice) DESC="Esalta la voce   | EQ Sartoriale Voce";;
  *)     DESC="Custom Mode";;
esac

info "Codec output:   $OUT_CODEC"
info "Surround mode:  $SUR_MODE ($DESC)"
info "Bitrate Target: $BITRATE"
info "Final volamp:   $VOLAMP_LABEL"

# ────────────────────────────────────────────────────────────────────────────────
# Probe Functions
# ────────────────────────────────────────────────────────────────────────────────
probe_audio_stream() {
  local f="$1" line
  local _lines
  mapfile -t _lines < <(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null || true)

  [[ ${#_lines[@]} -gt 0 ]] || return 1

  local best_line="" best_score=-1
  for line in "${_lines[@]}"; do
    local idx ch layout def lang
    IFS=',' read -r idx ch layout def lang <<<"$line"
    ch="${ch:-0}"
    def="${def:-0}"
    lang="${lang:-}"
    layout="${layout:-}"

    local score=0
    [[ "$ch" -eq 6 ]] && score=$((score+1000))
    [[ "$def" == "1" ]] && score=$((score+200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score+300))

    if (( score > best_score )); then
      best_score=$score
      best_line="$line"
    fi
  done

  [[ -n "$best_line" ]] || return 1

  # Output: idx|ch|layout|is_default|lang (pipe-separated, no globals)
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

# ────────────────────────────────────────────────────────────────────────────────
# Raccolta file
# ────────────────────────────────────────────────────────────────────────────────
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
# BLOCCHI FILTRI (FULL RANGE)
# ────────────────────────────────────────────────────────────────────────────────

# 1. EQ VOCE
# I tagli a 230/350 Hz ripuliscono il "fango" (bleed LFE, riverbero ambientale)
# ma devono essere misurati: su contenuto ben mixato (SONAR/AEGIS territory)
# togliere troppo in zona 200-400 Hz svuota la risonanza toracica della voce.
# V2.1: tagli ridotti (-2.5 e -1.2 vs -4.5 e -2.5) per preservare corpo.
read -r -d '' VOICE_EQ_BASE <<'EOF' || true
[FC]equalizer=f=230:t=q:w=2.0:g=-2.5,equalizer=f=350:t=q:w=1.5:g=-1.2,equalizer=f=1000:t=q:w=1.2:g=1.6,equalizer=f=2500:t=q:w=1.0:g=1.6,equalizer=f=7200:t=q:w=2.5:g=-1.2[FC_pre];
EOF

# 2. DELTA VOCE
# Ogni preset aggiunge le sue regolazioni sopra la base.
# Tutti includono un boost di presenza a 1.8kHz (articolazione consonantica)
# e un 2.5kHz allargato (Q1.5) per copertura uniforme della banda 1.5-3.5kHz.
# SONAR/AEGIS aggiungono anche +warmth a 300Hz (corpo voce su contenuto pulito).
# L'intensita' del 1.8kHz scala con l'aggressivita' del preset:
#   AURA +0.8 | WIDE +1.0 | AEGIS +1.2 | SONAR +1.5 | VOICE +2.0
read -r -d '' VOICE_DELTA_SONAR <<'EOF' || true
[FC_pre]volume=2.4dB,equalizer=f=300:t=q:w=1.5:g=1.2,equalizer=f=1800:t=q:w=1.8:g=1.5,equalizer=f=2500:t=q:w=1.5:g=1.8[FCv];
EOF
read -r -d '' VOICE_DELTA_AEGIS <<'EOF' || true
[FC_pre]volume=1.9dB,equalizer=f=300:t=q:w=1.5:g=1.0,equalizer=f=1800:t=q:w=1.8:g=1.2,equalizer=f=2500:t=q:w=1.5:g=1.5[FCv];
EOF
read -r -d '' VOICE_DELTA_WIDE <<'EOF' || true
[FC_pre]volume=2.2dB,equalizer=f=1800:t=q:w=1.8:g=1.0,equalizer=f=2500:t=q:w=1.5:g=1.2[FCv];
EOF
read -r -d '' VOICE_DELTA_AURA <<'EOF' || true
[FC_pre]volume=1.4dB,equalizer=f=1800:t=q:w=1.8:g=0.8,equalizer=f=2500:t=q:w=1.5:g=0.5[FCv];
EOF
read -r -d '' VOICE_DELTA_VOICEONLY <<'EOF' || true
[FC_pre]volume=3.0dB,equalizer=f=1800:t=q:w=1.8:g=2.0,equalizer=f=2500:t=q:w=1.5:g=2.5[FCv];
EOF

# 3. DSP SURROUND 
# (SONAR)
read -r -d '' SUR_FILTERS_SONAR <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,volume=0.95[SLd];
[SLp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SLp];
[SLh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-3.0,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SLh];
[SLlate_in]adelay=50,highpass=f=150,lowpass=f=1500,volume=0.65[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1 0.6 0.4 0.2':normalize=0,volume=1.05[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,volume=0.95[SRd];
[SRp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SRp];
[SRh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-3.0,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SRh];
[SRlate_in]adelay=50,highpass=f=150,lowpass=f=1500,volume=0.65[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1 0.6 0.4 0.2':normalize=0,volume=1.05[SR_out];
EOF

# (AEGIS)
read -r -d '' SUR_FILTERS_AEGIS <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,volume=0.95[SLd];
[SLp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SLp];
[SLh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SLh];
[SLlate_in]adelay=50,highpass=f=150,lowpass=f=1300,volume=0.45[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,volume=0.95[SRd];
[SRp_in]adelay=14,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SRp];
[SRh_in]adelay=28,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SRh];
[SRlate_in]adelay=50,highpass=f=150,lowpass=f=1300,volume=0.45[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SR_out];
EOF

# (WIDE)
read -r -d '' SUR_FILTERS_WIDE <<'EOF' || true
[SL]asplit=3[SLd_in][SLe_in][SLx_in];
[SLd_in]adelay=1,volume=1.00[SLd];
[SLe_in]adelay=9,highpass=f=280,lowpass=f=7000,allpass=f=1200:t=q:w=0.65,volume=0.42[SLe];
[SLx_in]adelay=22,highpass=f=600,lowpass=f=5000,allpass=f=700:t=q:w=0.70,allpass=f=2600:t=q:w=0.70,volume=0.17[SLx];
[SLd][SLe][SLx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=250:g=0.5:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.00[SL_out];
[SR]asplit=3[SRd_in][SRe_in][SRx_in];
[SRd_in]adelay=1,volume=1.00[SRd];
[SRe_in]adelay=10,highpass=f=280,lowpass=f=7000,allpass=f=1350:t=q:w=0.65,volume=0.42[SRe];
[SRx_in]adelay=24,highpass=f=600,lowpass=f=5000,allpass=f=820:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,volume=0.17[SRx];
[SRd][SRe][SRx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=250:g=0.5:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.00[SR_out];
EOF

# (AURA)
read -r -d '' SUR_FILTERS_AURA <<'EOF' || true
[SL]asplit=2[SLd_in][SLa_in];
[SLd_in]adelay=1,volume=1.00[SLd];
[SLa_in]adelay=8,highpass=f=800,lowpass=f=4500,allpass=f=1400:t=q:w=0.65,volume=0.22[SLa];
[SLd][SLa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=0.95[SL_out];
[SR]asplit=2[SRd_in][SRa_in];
[SRd_in]adelay=1,volume=1.00[SRd];
[SRa_in]adelay=9,highpass=f=800,lowpass=f=4500,allpass=f=1550:t=q:w=0.65,volume=0.22[SRa];
[SRd][SRa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=0.95[SR_out];
EOF

# (VOICE)
read -r -d '' SUR_FILTERS_VOICEONLY <<'EOF' || true
[SL]volume=0.85[SL_out];
[SR]volume=0.85[SR_out];
EOF

# ────────────────────────────────────────────────────────────────────────────────
# CICLO ELABORAZIONE
# ────────────────────────────────────────────────────────────────────────────────
OVERWRITE_ALL=false

for CUR_FILE in "${FILES[@]}"; do
  info "Input: $CUR_FILE"

  PROBE_RESULT=$(probe_audio_stream "$CUR_FILE") || { warn "Nessuna traccia audio valida"; continue; }

  # Parse risultato probe: idx|ch|layout|is_default|lang
  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LAYOUT A_IS_DEFAULT A_LANG <<<"$PROBE_RESULT"

  # Il layout arriva direttamente dal probe, nessun re-probe necessario.
  # (V1 faceva un secondo ffprobe con -select_streams a:${idx} che usava
  #  l'indice relativo audio invece di quello globale → bug latente su
  #  file con molte tracce audio.)

  # ── Layout normalization ────────────────────────────────────────────────────
  # Internamente il filtergraph lavora sempre in 5.1(side) (FL FR FC LFE SL SR).
  # Se il sorgente e' 5.1 o 5.1(back), i surround si chiamano BL/BR invece di
  # SL/SR. Il pan= nel filtergraph rimappa: SL=${SUR_L_CH} | SR=${SUR_R_CH},
  # quindi BL→SL e BR→SR. Risultato: tutto normalizzato a 5.1(side) prima
  # del channelsplit, indipendentemente dal layout originale.
  case "$A_LAYOUT" in
    "5.1(side)")
      IN_LAYOUT="5.1(side)"; SUR_L_CH="SL"; SUR_R_CH="SR" ;;
    "5.1"|"5.1(back)")
      IN_LAYOUT="5.1"; SUR_L_CH="BL"; SUR_R_CH="BR" ;;
    *)
      IN_LAYOUT="5.1(side)"; SUR_L_CH="SL"; SUR_R_CH="SR"
      warn "Layout input non standard: '${A_LAYOUT:-unknown}' → fallback: 5.1(side)" ;;
  esac

  if [[ "$A_CHANNELS" -ne 6 ]]; then
    warn "Non è un 5.1 (Canali: $A_CHANNELS) → Salto."
    continue
  fi

  # Configurazione Preset con Limiter Ottimizzato
  # NOTA: level=0 disabilita l'auto-leveling di alimiter. Il gain complessivo
  # è interamente governato dai volume= nei blocchi VOICE e SUR. Il limiter
  # agisce solo come safety net sui picchi (brick-wall), senza alterare il
  # livello percepito. Necessario perché i delta voce (fino a +3.0dB in VOICE)
  # possono spingere i transienti oltre 0dBFS.
  case "$SUR_MODE" in
    sonar) SUR_BLOCK="$SUR_FILTERS_SONAR"; VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_SONAR}"; LIMITER_OPTS="limit=0.97:attack=3.5:release=65:level=0"; MODE_TITLE="Sonar (Atmos Like)" ;;
    aegis) SUR_BLOCK="$SUR_FILTERS_AEGIS"; VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AEGIS}"; LIMITER_OPTS="limit=0.98:attack=2.5:release=50:level=0"; MODE_TITLE="AEGIS (Neural:X Like)" ;;
    aura)  SUR_BLOCK="$SUR_FILTERS_AURA";  VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AURA}";  LIMITER_OPTS="limit=0.975:attack=3.0:release=60:level=0"; MODE_TITLE="AURA (Dolby 6.1 Like)" ;;
    wide)  SUR_BLOCK="$SUR_FILTERS_WIDE";  VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_WIDE}";  LIMITER_OPTS="limit=0.97:attack=3.5:release=65:level=0"; MODE_TITLE="Wide (7.1 Like)" ;;
    voice) SUR_BLOCK="$SUR_FILTERS_VOICEONLY"; VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_VOICEONLY}"; LIMITER_OPTS="limit=0.95:attack=2.0:release=40:level=0"; MODE_TITLE="VOICE (Dialogue Plus)" ;;
    # Il default non dovrebbe mai arrivare qui (validazione anticipata sopra)
    *) err "Preset '$SUR_MODE' non riconosciuto."; exit 1 ;;
  esac

  OUT_FILE="${CUR_FILE%.*}_${OUT_CODEC^^}_${SUR_MODE^}.mkv"

  # ────────────────────────────────────────────────────────────────────────────────
  # GESTIONE SOVRASCRITTURA (s/n/t)
  # ────────────────────────────────────────────────────────────────────────────────
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

  # Filter complex assemblato
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
${FINAL_GAIN_FILTER}alimiter=${LIMITER_OPTS}[aout]
"

  # FFmpeg Command Array
  # -y solo se il file esiste gia' (l'utente ha confermato la sovrascrittura).
  # Se il file non esiste, -y e' inutile e rischia di mascherare overwrite
  # accidentali se la logica di skip cambia in futuro.
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
     -disposition:a:0 default)

  [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:0 language="$A_LANG" )

  if [[ "$KEEP_ORIG" = "si" ]]; then
    ORIG_TITLE=$(get_audio_title_by_index "$CUR_FILE" "$A_STREAM_INDEX" || echo "Original Audio")
    CMD+=( -map 0:"$A_STREAM_INDEX" -c:a:1 copy -metadata:s:a:1 title="$ORIG_TITLE" -disposition:a:1 0 )
  fi

  CMD+=( "$OUT_FILE" )
  "${CMD[@]}" && ok "Creato: $OUT_FILE" || warn "Errore su: $CUR_FILE"
done

ok "Elaborazione completata"