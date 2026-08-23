#!/usr/bin/env bash
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────────╮
# │   aegis_sonar_wide_aura_voice_volamp_psycho.sh - Agosto 2026                     │
# │   By Sandro (D@mocle77) Sabbioni                                                 │
# │                                                                                  │
# │   Motore di processing audio offline per tracce 5.1 (EAC3/AC3).                  │
# │   Corregge dinamicamente mix sbilanciati tramite preset psicoacustici,           │
# │   migliorando l'intelligibilità dei dialoghi e ripristinando la bolla            │
# │   surround (Aegis, Sonar, Wide, Aura), con controllo mirato dei picchi LFE.      │
# │                                                                                  │
# │   - DSP ottimizzato per impianto 5.1/5.2, crossover unico 110 Hz (tutti Small)   │
# │   - Voce: EQ sartoriale FC, dinamica piena, nessun compressore                   │
# │   - Surround psicoacustici controllati                                           │
# │   - LFE: highpass 32 Hz + lowpass 110 Hz + limiter picchi                        │
# │   - Pipeline leggibile: input -> split -> voice -> surround -> output            │
# |   - gestione robusta dei sei canali anche con channel_layout=unknown             |
# ╰──────────────────────────────────────────────────────────────────────────────────╯

# Color codes per log: info, warning, error, ok. Usati per distinguere i livelli di messaggio in console.
C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"

# Funzioni di log: info, warn, err, ok. Usano colori per distinguere i livelli di messaggio.
info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

# Parametri di decorrelazione per i preset surround: valori empirici per creare un layer di aria senza alterare il mix principale.
DECORR_GAIN_SONAR="0.055"
DECORR_GAIN_AURA="0.048"
DECORR_GAIN_WIDE="0.042"
DECORR_GAIN_AEGIS="0.034"
DECORR_GAIN_VOICE="0"

# Guard rail della verifica audio comparativa input/output.
VERIFY_SILENCE_PEAK_DB="-80.0"
VERIFY_ACTIVE_INPUT_RMS_DB="-65.0"
VERIFY_MAX_OVERALL_DROP_DB="18.0"
VERIFY_MAX_MAIN_CHANNEL_DROP_DB="24.0"
VERIFY_MAX_LFE_DROP_DB="36.0"
VERIFY_MIN_SAMPLE_RATIO="0.98"

# FRONT_EQ: equalizzatore frontale condiviso, adattato a torri audio 3 vie.
FRONT_EQ="equalizer=f=320:t=q:w=1.1:g=-0.8,equalizer=f=5000:t=q:w=1.4:g=0.4,highshelf=f=11000:t=q:w=0.7:g=0.4"

# Controllo dipendenze: ffmpeg e ffprobe sono essenziali per il funzionamento dello script. Se non sono nel PATH, esco con errore.
for _bin in ffmpeg ffprobe; do
  command -v "$_bin" &>/dev/null || { err "$_bin non trovato nel PATH"; exit 1; }
done

usage() {
  cat <<'USAGE'
-----------------------------------------------------------------------------------------------------------
UTILIZZO:
  ./aegis_sonar_wide_aura_voice_volamp_psycho.sh <ac3|eac3> <si|no> <bitrate> <preset> <volamp> <file|"">
  ./aegis_sonar_wide_aura_voice_volamp_psycho.sh --files <ac3|eac3> <si|no> <bitrate> <preset> <volamp> <file1> [file2 ...]

PARAMETRI:
  ac3|eac3  : Codec audio in uscita.
  si|no     : Conserva file audio originale.
  file      : File input singolo. Se omesso o "" processa tutti file compatibili nella cartella.
  bitrate   : Es. 640k o 768k (default: 640k per AC3, 768k per EAC3).
  preset    : aegis | sonar | wide | aura | voice (default: sonar).
  volamp    : Gain finale opzionale in dB prima del limiter.
              Valori consentiti: 0 .. 6.0.
              0 = OFF, default = 4.0 dB.
              Esempi pratici: 0 | 3.0 | 4.0 | 5.0 | 6.0

MODALITA' --files:
  Processa soltanto i file elencati. Bitrate, preset e volamp sono obbligatori
  e in ordine fisso, cosi' i nomi dei file non risultano ambigui.
ESEMPIO:
  ./aegis_sonar_wide_aura_voice_volamp_psycho.sh eac3 si 768k sonar 4.0 "film.mkv"
  ./aegis_sonar_wide_aura_voice_volamp_psycho.sh ac3 no 640k wide 3.0 ""
  ./aegis_sonar_wide_aura_voice_volamp_psycho.sh --files eac3 no 768k sonar 4.0 ep1.mkv ep4.mkv

COMPATIBILITA': resta accettato il vecchio ordine codec keep file [bitrate] [preset] [volamp].

PRESET DISPONIBILI:
  aegis     -> Simula NEURAL:X (DTS:X)  | Cupola Sonora
  sonar     -> Simula ATMOS (5.1.2)     | Boost Verticale
  wide      -> Simula Dolby 7.1         | Allargamento Laterale
  aura      -> Simula Dolby 6.1         | Allargamento Posteriore
  voice     -> Esalta i dialoghi (FC)   | EQ Sartoriale Voce
-----------------------------------------------------------------------------------------------------------
USAGE
  exit 1
}

# Controllo se un token è un preset valido: deve essere uno dei nomi riconosciuti (aegis, sonar, wide, aura, voice).
is_preset_name() {
  case "$1" in
    aegis|sonar|wide|aura|voice) return 0 ;;
    *) return 1 ;;
  esac
}
# Controllo se un token è un bitrate valido: deve essere un numero con optional k/M, es. 640k, 768k, 1M, 1.5M, etc.
is_bitrate_token() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?([kKmM])?$ ]]
}

# Controllo argomenti e modalita' multi-file.
[[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
MULTI_FILES_MODE=false
MULTI_FILES=()
INPUT_FILE=""
BITRATE=""
SUR_MODE=""
VOLAMP_DB="4.0"

if [[ "${1:-}" == "--files" ]]; then
  # Sintassi fissa: --files codec keep bitrate preset volamp file...
  (( $# >= 7 )) || {
    err "Uso --files non valido: servono codec, keep, bitrate, preset, volamp e almeno un file."
    usage
  }
  MULTI_FILES_MODE=true
  OUT_CODEC="${2:-}"
  KEEP_ORIG="${3:-}"
  BITRATE="${4:-}"
  SUR_MODE="${5:-}"
  VOLAMP_DB="${6:-}"
  VOLAMP_DB="${VOLAMP_DB/,/.}"
  shift 6
  MULTI_FILES=("$@")
else
  # Sintassi canonica: codec keep bitrate preset volamp input.
  # Il terzo token (bitrate) la distingue dal vecchio ordine codec keep file...
  if (( $# == 6 )) && is_bitrate_token "${3:-}" && is_preset_name "${4:-}" && \
     [[ "${5:-}" =~ ^[0-9]+([.,][0-9]+)?$ ]]; then
    OUT_CODEC="${1:-}"
    KEEP_ORIG="${2:-}"
    BITRATE="${3:-}"
    SUR_MODE="${4:-}"
    VOLAMP_DB="${5:-}"
    VOLAMP_DB="${VOLAMP_DB/,/.}"
    INPUT_FILE="${6:-}"
    POSITIONAL=()
  else
    # Sintassi storica: codec e keep obbligatori; gli altri parametri restano flessibili.
    [[ $# -lt 2 ]] && usage
    OUT_CODEC="${1:-}"
    KEEP_ORIG="${2:-}"
    shift 2
    POSITIONAL=("$@")

    # Ultimo parametro opzionale = volamp (0 .. 6.0 dB)
    if (( ${#POSITIONAL[@]} > 0 )); then
      LAST_IDX=$((${#POSITIONAL[@]} - 1))
      LAST_ARG="${POSITIONAL[$LAST_IDX]}"
      LAST_ARG="${LAST_ARG/,/.}"

      if [[ "$LAST_ARG" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if awk -v v="$LAST_ARG" 'BEGIN { exit !(v >= 0 && v <= 6.0) }'; then
          VOLAMP_DB="$LAST_ARG"
          unset 'POSITIONAL[$LAST_IDX]'
          POSITIONAL=("${POSITIONAL[@]}")
        elif awk -v v="$LAST_ARG" 'BEGIN { exit !(v >= 32) }'; then
          : # numero grande: bitrate senza suffisso
        else
          err "Valore numerico ambiguo: '$LAST_ARG'"
          err "volamp ammette 0 .. 6.0 dB ; il bitrate va indicato >= 32 (es. 640 o 640k)."
          exit 1
        fi
      fi
    fi

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
  fi
fi

# Se il preset non è stato specificato, uso il default sonar. Se è stato specificato, deve essere uno dei nomi validi (controllo fatto più avanti).
SUR_MODE="${SUR_MODE:-sonar}"

# Controllo preset: deve essere uno dei nomi validi.
case "$SUR_MODE" in
  aegis|sonar|wide|aura|voice) ;;
  *) err "Preset '$SUR_MODE' non riconosciuto. Validi: aegis, sonar, wide, aura, voice."; exit 1 ;;
esac
# Controllo codec e flag keep_orig.
case "$OUT_CODEC" in ac3|eac3) ;; *) err "Codec deve essere ac3 o eac3"; exit 1 ;; esac
[[ "$KEEP_ORIG" =~ ^(si|no)$ ]] || { err "Parametro 2: si|no"; exit 1; }

# Se il bitrate è specificato, deve essere un numero con optional k/M. Se non specificato, default 640k per AC3 e 768k per EAC3.
[[ -z "$BITRATE" ]] && {
  [[ "$OUT_CODEC" = "ac3" ]] && BITRATE="640k" || BITRATE="768k"
}
[[ "$BITRATE" =~ [kKmM]$ ]] || BITRATE="${BITRATE}k"

# Validazione bitrate continua: accetto tutti i valori nel range 256..768 kbps.
BITRATE_LC="${BITRATE,,}"
if [[ "$BITRATE_LC" =~ ^([0-9]+)$ ]]; then
  BITRATE_KBPS="${BASH_REMATCH[1]}"
elif [[ "$BITRATE_LC" =~ ^([0-9]+)k$ ]]; then
  BITRATE_KBPS="${BASH_REMATCH[1]}"
elif [[ "$BITRATE_LC" =~ ^([0-9]+)m$ ]]; then
  BITRATE_KBPS="$(( ${BASH_REMATCH[1]} * 1000 ))"
else
  err "Bitrate non valido: $BITRATE"
  err "Formato accettato: numero intero opzionalmente con suffisso k o M (es. 256, 320k, 1M)."
  exit 1
fi

# Validazione bitrate per codec:
# - AC3: massimo 640 kbps
# - EAC3: massimo 768 kbps
# Mantengo step da 64 kbps nel range supportato dallo script.
BITRATE_MAX_KBPS=768
[[ "$OUT_CODEC" = "ac3" ]] && BITRATE_MAX_KBPS=640

if (( BITRATE_KBPS < 256 || BITRATE_KBPS > BITRATE_MAX_KBPS || ((BITRATE_KBPS - 256) % 64) != 0 )); then
  err "Bitrate non consentito per $OUT_CODEC: ${BITRATE_KBPS}k"
  if [[ "$OUT_CODEC" = "ac3" ]]; then
    err "Consentiti AC3: 256k, 320k, 384k, 448k, 512k, 576k, 640k"
  else
    err "Consentiti EAC3: 256k, 320k, 384k, 448k, 512k, 576k, 640k, 704k, 768k"
  fi
  exit 1
fi

# Normalizzo sempre il valore in uscita come NNk.
BITRATE="${BITRATE_KBPS}k"

# Controllo volamp opzionale: se specificato, deve essere un numero da 0 a 6.0 (con optional decimale).
if ! [[ "$VOLAMP_DB" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
   ! awk -v v="$VOLAMP_DB" 'BEGIN { exit !(v >= 0 && v <= 6.0) }'; then
  err "volamp non valido: '$VOLAMP_DB'. Valori consentiti: 0 .. 6.0 dB"
  exit 1
fi

# Gain globale opzionale applicato ai singoli canali prima del join.
#
# Sui canali principali conserva il recupero di volume richiesto.
# Sul canale LFE viene applicato prima del limiter dedicato, evitando che
# un picco del sub gia' amplificato piloti inutilmente il limiter globale 5.1.
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

# Guard rail: sopra 4.5 dB il limiter finale puo' iniziare a lavorare in modo udibile.
# fino a 6.0 resta permesso per sorgenti realmente basse, ma va trattato come modalita' spinta.
if awk -v v="$VOLAMP_DB" 'BEGIN { exit !(v > 4.5) }'; then
  warn "volamp alto (${VOLAMP_DB} dB): controlla eventuale compressione percepita nei picchi."
fi

# Resampling finale HQ con SoX Resampler / SOXR. Precisione 28 bit.
# 192k upsample: cutoff ininfluente (no contenuto sopra 24 kHz). 48k downsample: cutoff=0.91 per meno pre-ring.
ARESAMPLE_192K="aresample=192000:resampler=soxr:precision=28"
ARESAMPLE_48K="aresample=48000:resampler=soxr:precision=28:cutoff=0.91"

# Descrizioni preset per log: non sono parte del processing, ma aiutano a capire cosa fa ogni preset senza dover leggere il codice.
case "$SUR_MODE" in
  aegis) DESC="Simula NEURAL:X (DTS:X) | Cupola Sonora" ;;
  sonar) DESC="Simula ATMOS (5.1.2) | Boost Verticale" ;;
  wide)  DESC="Simula Dolby 7.1 | Allargamento Laterale" ;;
  aura)  DESC="Simula Dolby 6.1 | Allargamento Posteriore" ;;
  voice) DESC="Esalta la voce   | EQ Sartoriale Voce" ;;
esac

# Log dei parametri finali: utile per confermare cosa è stato interpretato dallo script, soprattutto con parsing flessibile.
info "Codec output:   $OUT_CODEC"
info "Surround mode:  $SUR_MODE ($DESC)"
info "Bitrate Target: $BITRATE"
info "Final volamp:   $VOLAMP_LABEL"

# Identifica la traccia 5.1 migliore privilegiando lingua italiana e flag default.
probe_audio_stream() {
  local f="$1" line
  local _lines
  mapfile -t _lines < <(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null || true)

  [[ ${#_lines[@]} -gt 0 ]] || return 1

  local best_line="" best_score=-999999
  for line in "${_lines[@]}"; do
    [[ -z "$line" ]] && continue
    local idx ch layout def lang
    IFS=',' read -r idx ch layout def lang <<<"$line"
    ch="${ch:-0}"
    def="${def:-0}"
    lang="${lang:-}"
    layout="${layout:-}"

    # Il processore lavora esclusivamente su 5.1: gli altri stream non entrano
    # nello scoring, neppure se piu' lunghi o marcati default.
    [[ "$ch" =~ ^[0-9]+$ && "$ch" -eq 6 ]] || continue

    local score=1000
    [[ "$def" == "1" ]] && score=$((score+200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score+300))

    # Se questo stream ha un punteggio migliore del migliore finora, lo salvo come best_line. In caso di parità, mantengo il primo trovato.
    if (( score > best_score )); then
      best_score=$score
      best_line="${idx}|${ch}|${layout}|${def}|${lang}"
    fi
  done
  # Se non ho trovato tracce valide, esco con errore. Altrimenti, best_line contiene la traccia migliore da processare.
  [[ -n "$best_line" ]] || return 1

  echo "$best_line"
}

# Funzione per ottenere il titolo della traccia audio (se presente), utile per log e debug. Non è critica, quindi errori vengono silenziati.
get_audio_title_by_index() {
  ffprobe -v error -select_streams a \
    -show_entries stream=index:stream_tags=title \
    -of default=nw=1 "$1" 2>/dev/null | awk -v idx="$2" '
    $0=="index="idx{f=1;next} f&&/^TAG:title=/{sub(/^TAG:title=/,"");print;exit} f&&/^index=/{exit}'
}

# Costruisco la lista dei file da processare: se è stato specificato un file, lo uso. Altrimenti, cerco tutti i file compatibili nella cartella.
FILES=()
if [[ "$MULTI_FILES_MODE" == true ]]; then
  for f in "${MULTI_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      FILES+=("$f")
    else
      warn "File inesistente, salto: $f"
    fi
  done
elif [[ -n "$INPUT_FILE" ]]; then
  [[ -f "$INPUT_FILE" ]] || { err "File non esiste"; exit 1; }
  FILES+=("$INPUT_FILE")
else
  shopt -s nullglob
  FILES+=( *.mkv *.MKV *.mp4 *.MP4 *.m2ts *.M2TS *.ac3 *.eac3 )
  shopt -u nullglob
fi
# Controllo se ho trovato file da processare: se la cartella è vuota o non ci sono file compatibili, esco con errore.
(( ${#FILES[@]} == 0 )) && { err "Nessun file trovato."; exit 1; }


# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# BLOCCHI VOCE
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

# Equalizzazione sartioriale della voce per preset surround, con EQ mirato per intelligibilità mantenendo la dinamica naturale. Serve a dare presenza alla voce senza rubare scena ai frontali.
read -r -d '' VOICE_EQ_BASE <<'EOF' || true
[FC]highpass=f=40:t=q:w=0.707,equalizer=f=150:t=q:w=1.1:g=0.2,equalizer=f=450:t=q:w=1.2:g=-0.6,equalizer=f=1100:t=q:w=1.4:g=0.8,equalizer=f=7200:t=q:w=2.5:g=-0.9[FC_pre];
EOF
read -r -d '' VOICE_DELTA_SONAR <<'EOF' || true
[FC_pre]volume=2.7dB,equalizer=f=1650:t=q:w=1.6:g=0.9,equalizer=f=2450:t=q:w=1.3:g=1.6,equalizer=f=3800:t=q:w=2.0:g=1.0,equalizer=f=6800:t=q:w=2.0:g=-1.0,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_AEGIS <<'EOF' || true
[FC_pre]volume=2.7dB,equalizer=f=1650:t=q:w=1.6:g=0.9,equalizer=f=2450:t=q:w=1.3:g=1.5,equalizer=f=3800:t=q:w=2.0:g=1.0,equalizer=f=6800:t=q:w=2.0:g=-1.0,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_WIDE <<'EOF' || true
[FC_pre]volume=2.8dB,equalizer=f=1650:t=q:w=1.6:g=0.9,equalizer=f=2450:t=q:w=1.3:g=1.6,equalizer=f=3800:t=q:w=2.0:g=1.0,equalizer=f=6800:t=q:w=2.0:g=-0.9,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_AURA <<'EOF' || true
[FC_pre]volume=2.5dB,equalizer=f=1650:t=q:w=1.6:g=0.8,equalizer=f=2450:t=q:w=1.3:g=1.4,equalizer=f=3800:t=q:w=2.0:g=0.9,equalizer=f=6800:t=q:w=2.0:g=-1.0,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_VOICEONLY <<'EOF' || true
[FC_pre]volume=2.9dB,equalizer=f=1650:t=q:w=1.6:g=1.0,equalizer=f=2450:t=q:w=1.3:g=1.8,equalizer=f=3800:t=q:w=2.0:g=1.1,equalizer=f=5200:t=q:w=2.0:g=-0.5,equalizer=f=6800:t=q:w=2.0:g=-1.1,volume=0.95[FCv];
EOF

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# BLOCCHI SURROUND
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

# SONAR: cupola sonora con boost verticale, più presenza medio-alta per SL/SR, e un layer di decorrelazione a basso livello per aria.
read -r -d '' SUR_FILTERS_SONAR <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,highpass=f=40:t=q:w=0.707,volume=0.95[SLd];
[SLp_in]adelay=18,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SLp];
[SLh_in]adelay=32,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=2.5:g=0.8,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SLh];
[SLlate_in]adelay=38,highpass=f=150,lowpass=f=1500,volume=0.58[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1 0.6 0.4 0.2':normalize=0,volume=1.05[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,highpass=f=40:t=q:w=0.707,volume=0.95[SRd];
[SRp_in]adelay=18,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SRp];
[SRh_in]adelay=32,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=2.5:g=0.8,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SRh];
[SRlate_in]adelay=41,highpass=f=150,lowpass=f=1500,volume=0.58[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1 0.6 0.4 0.2':normalize=0,volume=1.05[SR_out];
EOF

# AEGIS: cupola sonora con boost più bilanciato e meno artificiale, più presenza medio-alta per SL/SR, e un layer di decorrelazione a basso livello per aria.
read -r -d '' SUR_FILTERS_AEGIS <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,highpass=f=40:t=q:w=0.707,volume=0.95[SLd];
[SLp_in]adelay=18,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SLp];
[SLh_in]adelay=32,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SLh];
[SLlate_in]adelay=39,highpass=f=150,lowpass=f=1300,volume=0.42[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,highpass=f=40:t=q:w=0.707,volume=0.95[SRd];
[SRp_in]adelay=18,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SRp];
[SRh_in]adelay=32,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SRh];
[SRlate_in]adelay=42,highpass=f=150,lowpass=f=1300,volume=0.42[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SR_out];
EOF

# WIDE: allargamento laterale più marcato, con boost più evidente sulle sub-bande filtrate, e un layer di decorrelazione a basso livello per aria.
read -r -d '' SUR_FILTERS_WIDE <<'EOF' || true
[SL]asplit=3[SLd_in][SLe_in][SLx_in];
[SLd_in]adelay=1,highpass=f=40:t=q:w=0.707,volume=1.00[SLd];
[SLe_in]adelay=9,highpass=f=280,lowpass=f=7000,allpass=f=1200:t=q:w=0.65,volume=0.42[SLe];
[SLx_in]adelay=22,highpass=f=600,lowpass=f=5000,allpass=f=700:t=q:w=0.70,allpass=f=2600:t=q:w=0.70,volume=0.17[SLx];
[SLd][SLe][SLx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=250:g=0.5:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.00[SL_out];
[SR]asplit=3[SRd_in][SRe_in][SRx_in];
[SRd_in]adelay=1,highpass=f=40:t=q:w=0.707,volume=1.00[SRd];
[SRe_in]adelay=10,highpass=f=280,lowpass=f=7000,allpass=f=1350:t=q:w=0.65,volume=0.42[SRe];
[SRx_in]adelay=24,highpass=f=600,lowpass=f=5000,allpass=f=820:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,volume=0.17[SRx];
[SRd][SRe][SRx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=250:g=0.5:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.00[SR_out];
EOF

# AURA: allargamento posteriore. Due layer (diretto + allpass decorrelato), presenza medio-alta contenuta. Il più morbido tra i preset spaziali.
read -r -d '' SUR_FILTERS_AURA <<'EOF' || true
[SL]asplit=2[SLd_in][SLa_in];
[SLd_in]adelay=1,highpass=f=40:t=q:w=0.707,volume=1.00[SLd];
[SLa_in]adelay=8,highpass=f=800,lowpass=f=4500,allpass=f=1400:t=q:w=0.65,volume=0.22[SLa];
[SLd][SLa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=0.95[SL_out];
[SR]asplit=2[SRd_in][SRa_in];
[SRd_in]adelay=1,highpass=f=40:t=q:w=0.707,volume=1.00[SRd];
[SRa_in]adelay=9,highpass=f=800,lowpass=f=4500,allpass=f=1550:t=q:w=0.65,volume=0.22[SRa];
[SRd][SRa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=0.95[SR_out];
EOF

# VOICE-ONLY: preset rescue per esaltare i dialoghi quando il mix è critico e non si vuole alterare il surround. Solo HPF a 40 Hz e volume leggermente ridotto per SL/SR.
read -r -d '' SUR_FILTERS_VOICEONLY <<'EOF' || true
[SL]highpass=f=40:t=q:w=0.707,volume=0.88[SL_out];
[SR]highpass=f=40:t=q:w=0.707,volume=0.88[SR_out];
EOF

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# PROFILI PRESET
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

# Funzione per impostare i blocchi di processing in base al preset selezionato. Ogni preset ha un set specifico di filtri, guadagni e opzioni del limiter.
set_preset_profile() {
  case "$SUR_MODE" in
    sonar)
      SUR_BLOCK="$SUR_FILTERS_SONAR"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_SONAR}"
      DECORR_GAIN="$DECORR_GAIN_SONAR"
      LIMITER_OPTS="limit=0.985:attack=2.5:release=50:level=1:latency=1"
      MODE_TITLE="Sonar (Atmos Like)"
      ;;
    aegis)
      SUR_BLOCK="$SUR_FILTERS_AEGIS"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AEGIS}"
      DECORR_GAIN="$DECORR_GAIN_AEGIS"
      LIMITER_OPTS="limit=0.985:attack=2.5:release=50:level=1:latency=1"
      MODE_TITLE="AEGIS (Neural:X Like)"
      ;;
    aura)
      SUR_BLOCK="$SUR_FILTERS_AURA"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AURA}"
      DECORR_GAIN="$DECORR_GAIN_AURA"
      LIMITER_OPTS="limit=0.985:attack=2.5:release=50:level=1:latency=1"
      MODE_TITLE="AURA (Dolby 6.1 Like)"
      ;;
    wide)
      SUR_BLOCK="$SUR_FILTERS_WIDE"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_WIDE}"
      DECORR_GAIN="$DECORR_GAIN_WIDE"
      LIMITER_OPTS="limit=0.985:attack=2.5:release=50:level=1:latency=1"
      MODE_TITLE="Wide (7.1 Like)"
      ;;
    voice)
      SUR_BLOCK="$SUR_FILTERS_VOICEONLY"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_VOICEONLY}"
      DECORR_GAIN="$DECORR_GAIN_VOICE"
      LIMITER_OPTS="limit=0.985:attack=2.5:release=50:level=1:latency=1"
      MODE_TITLE="VOICE (Dialogue Plus)"
      ;;
    *)
      err "Preset '$SUR_MODE' non riconosciuto."
      exit 1
      ;;
  esac
}

# Funzione per costruire il blocco di split dei canali in ingresso con mapping posizionale.
build_input_split_graph() {
  cat <<EOF
[0:${A_STREAM_INDEX}]${INPUT_AFORMAT},
pan=5.1(side)|${INPUT_PAN_MAP}[base];
[base]channelsplit=channel_layout=5.1(side)[FL][FR][FC][LFE][SL][SR];
[FL]highpass=f=40:t=q:w=0.707,${FRONT_EQ}[FLp];
[FR]highpass=f=40:t=q:w=0.707,${FRONT_EQ}[FRp];
EOF
}

# Il blocco di processing surround psicoacustico: se DECORR_GAIN è 0, salto completamente la decorrelazione.
build_surround_psycho_graph() {
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

# Blocco finale di output:
# - applica il volamp separatamente ai cinque canali principali;
# - applica il volamp al LFE prima del limiter dedicato;
# - il file resta 5.1 con un solo canale LFE; l'eventuale doppio sub (5.2) e' gestito dall'AVR;
# - unisce i sei canali in 5.1(side);
# - mantiene il limiter finale come protezione globale;
# - esegue il true-peak oversampling a 192 kHz e il ritorno a 48 kHz.
#highshelf=f=12000:g=0.4:w=0.5:c=FL|FR|FC|SL|SR,${ARESAMPLE_192K},alimiter=${LIMITER_OPTS},${ARESAMPLE_48K},aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=5.1(side)[aout]
build_output_join_graph() {
  cat <<EOF
[FLp]${FINAL_GAIN_FILTER}aformat=channel_layouts=mono[FLf];
[FRp]${FINAL_GAIN_FILTER}aformat=channel_layouts=mono[FRf];
[FCv]${FINAL_GAIN_FILTER}aformat=channel_layouts=mono[FCf];
[LFE]aformat=channel_layouts=mono,highpass=f=32,lowpass=f=110,${FINAL_GAIN_FILTER}alimiter=limit=0.94:attack=2.0:release=120:level=0:latency=1[LFEf];
[SL_final]${FINAL_GAIN_FILTER}aformat=channel_layouts=mono[SLf];
[SR_final]${FINAL_GAIN_FILTER}aformat=channel_layouts=mono[SRf];
[FLf][FRf][FCf][LFEf][SLf][SRf]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,
highshelf=f=12000:g=0.4:w=0.5:c=FL|FR|FC|SL|SR,alimiter=${LIMITER_OPTS},aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=5.1(side)[aout]
EOF
}

# La funzione build_filter_complex assembla il filtergraph completo concatenando i 4 blocchi principali: input split, processing voce, processing surround, output join. Il risultato viene stampato su stdout.
build_filter_complex() {
  local input_graph psycho_graph output_graph
  input_graph="$(build_input_split_graph)"
  psycho_graph="$(build_surround_psycho_graph)"
  output_graph="$(build_output_join_graph)"
  printf '%s\n%s\n%s\n%s\n%s\n' "$input_graph" "$VOICE_BLOCK" "$SUR_BLOCK" "$psycho_graph" "$output_graph"
}

# Misura in una sola decodifica picco, RMS e numero di campioni, globalmente e per ciascun canale.
# peak|rms|samples|rms_c0|rms_c1|rms_c2|rms_c3|rms_c4|rms_c5
measure_audio_signal() {
  local f="$1" map_spec="$2" probe metrics

  probe="$(
    ffmpeg -hide_banner -nostdin -v info -i "$f" \
      -map "$map_spec" -vn -sn -dn \
      -af "aformat=sample_rates=48000:sample_fmts=fltp,astats=metadata=0:reset=0" \
      -f null - 2>&1 || true
  )"

  # Normalizza CRLF prima dei pattern awk ancorati a fine riga.
  # Su alcune combinazioni Windows/FFmpeg/MSYS il command substitution puo' conservare il CR.
  probe="${probe//$'\r'/}"

  metrics="$(printf '%s\n' "$probe" | awk '
    /Channel:/ {
      channel=$NF
      overall=0
      next
    }
    /] Overall$/ {
      overall=1
      channel=0
      next
    }
    /Peak level dB:/ {
      if (overall) overall_peak=$NF
      next
    }
    /RMS level dB:/ {
      if (overall) overall_rms=$NF
      else if (channel >= 1 && channel <= 6) channel_rms[channel]=$NF
      next
    }
    /Number of samples:/ {
      if (overall) samples=$NF
      next
    }
    END {
      if (overall_peak == "" || overall_rms == "" || samples == "") exit 1
      for (i=1; i<=6; i++) if (channel_rms[i] == "") exit 1
      printf "%s|%s|%s", overall_peak, overall_rms, samples
      for (i=1; i<=6; i++) printf "|%s", channel_rms[i]
      printf "\n"
    }
  ')" || return 1

  [[ -n "$metrics" ]] || return 1
  printf '%s\n' "$metrics"
}

is_finite_db() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

# Confronta l'output codificato con la traccia sorgente selezionata.
# Ritorni:
#   0 = segnale coerente
#   1 = output silenzioso, quasi muto, troncato o con un canale attivo perso
#   2 = misura non conclusiva
verify_output_audio_signal() {
  local f="$1" input_metrics="$2" output_metrics
  local -a in_m out_m channel_names=(FL FR FC LFE SL SR)
  local input_peak input_rms input_samples output_peak output_rms output_samples
  local i input_channel_rms output_channel_rms max_drop

  output_metrics="$(measure_audio_signal "$f" "0:a:0")" || {
    VERIFY_REASON="astats non ha restituito metriche complete per l'output"
    return 2
  }

  IFS='|' read -r -a in_m <<<"$input_metrics"
  IFS='|' read -r -a out_m <<<"$output_metrics"
  [[ ${#in_m[@]} -eq 9 && ${#out_m[@]} -eq 9 ]] || {
    VERIFY_REASON="numero di metriche input/output inatteso"
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

  for i in {0..5}; do
    input_channel_rms="${in_m[$((i+3))]}"
    output_channel_rms="${out_m[$((i+3))]}"

    # Un canale sorgente sotto questa soglia e' considerato intenzionalmente inattivo.
    if [[ "$input_channel_rms" == "-inf" ]]; then
      continue
    fi
    if ! is_finite_db "$input_channel_rms" || \
       { [[ "$output_channel_rms" != "-inf" ]] && ! is_finite_db "$output_channel_rms"; }; then
      VERIFY_REASON="metrica canale ${channel_names[$i]} non numerica"
      return 2
    fi
    if ! awk -v v="$input_channel_rms" -v lim="$VERIFY_ACTIVE_INPUT_RMS_DB" \
         'BEGIN { exit !(v > lim) }'; then
      continue
    fi
    if [[ "$output_channel_rms" == "-inf" ]]; then
      VERIFY_REASON="canale ${channel_names[$i]} attivo in input ma silenzioso in output"
      return 1
    fi

    max_drop="$VERIFY_MAX_MAIN_CHANNEL_DROP_DB"
    [[ $i -eq 3 ]] && max_drop="$VERIFY_MAX_LFE_DROP_DB"
    if awk -v src="$input_channel_rms" -v dst="$output_channel_rms" -v lim="$max_drop" \
         'BEGIN { exit !((src-dst) > lim) }'; then
      VERIFY_REASON="canale ${channel_names[$i]} attenuato eccessivamente: input=${input_channel_rms} dBFS, output=${output_channel_rms} dBFS"
      return 1
    fi
  done

  info "Verifica audio: peak ${input_peak}→${output_peak} dBFS; RMS ${input_rms}→${output_rms} dBFS; campioni ${input_samples}→${output_samples}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# CICLO ELABORAZIONE
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Il ciclo principale elabora tutti i file trovati, uno alla volta. Per ogni file:
OVERWRITE_ALL=false
OK_COUNT=0
ERR_COUNT=0

for CUR_FILE in "${FILES[@]}"; do
  info "Input: $CUR_FILE"
  # Se è stato specificato un file di input, lo uso. Altrimenti, controllo se il file è già stato processato (nome con suffisso _AC3_ o _EAC3_ + preset). Se sì, skippo il file e loggo un warning.
  if [[ -z "$INPUT_FILE" ]]; then
    case "$(basename "$CUR_FILE")" in
      *_AC3_Aegis.mkv|*_AC3_Sonar.mkv|*_AC3_Wide.mkv|*_AC3_Aura.mkv|*_AC3_Voice.mkv|\
      *_EAC3_Aegis.mkv|*_EAC3_Sonar.mkv|*_EAC3_Wide.mkv|*_EAC3_Aura.mkv|*_EAC3_Voice.mkv)
        warn "File già processato → salto: $CUR_FILE"
        continue
        ;;
    esac
  fi

  # Identifico la traccia audio migliore da processare, con preferenza per 5.1, default, italiano. Se non trovo tracce valide, skippo il file.
  PROBE_RESULT=$(probe_audio_stream "$CUR_FILE") || { warn "Nessuna traccia audio valida"; continue; }
  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LAYOUT A_IS_DEFAULT A_LANG <<<"$PROBE_RESULT"

  # Sanificazione: ffprobe su Windows può emettere CRLF; strip \r e spazi da A_CHANNELS.
  A_CHANNELS="${A_CHANNELS//[$'\r\n ']/}"

  # Se non è un 5.1, skippo il file prima ancora di fare il layout detection (evita warn fuorvianti).
  if ! [[ "$A_CHANNELS" =~ ^[0-9]+$ ]] || [[ "$A_CHANNELS" -ne 6 ]]; then
    warn "Non è un 5.1 (Canali: $A_CHANNELS) → Salto."
    continue
  fi

  # Normalizzo anche il layout: su Windows/Git Bash ffprobe può lasciare un CR finale.
  A_LAYOUT="${A_LAYOUT//$'\r'/}"

  # Mapping input robusto e non distruttivo: per ogni layout 5.1 supportato copio sempre
  # i sei canali per indice. Cosi' aformat non puo' attivare una rimappatura automatica.
  # Ordine canonico atteso: c0 FL, c1 FR, c2 FC, c3 LFE, c4 surround L, c5 surround R.
  INPUT_AFORMAT="aformat=sample_rates=48000:sample_fmts=fltp"
  INPUT_PAN_MAP="FL=c0|FR=c1|FC=c2|LFE=c3|SL=c4|SR=c5"
  case "$A_LAYOUT" in
    "5.1(side)")
      info "Layout input: 5.1(side) → copia posizionale pura c0..c5"
      ;;
    "5.1"|"5.1(back)")
      info "Layout input: ${A_LAYOUT} → copia posizionale pura; c4/c5 diventano SL/SR"
      ;;
    *)
      warn "Layout '${A_LAYOUT:-vuoto}' non dichiarato/non standard → mapping posizionale 6ch c0..c5"
      ;;
  esac

  # Imposto il profilo preset per questo file, costruisco il filter_complex dinamicamente, e preparo il comando ffmpeg. Se il file esiste già, chiedo conferma prima di sovrascrivere.
  set_preset_profile
  OUT_FILE="${CUR_FILE%.*}_${OUT_CODEC^^}_${SUR_MODE^}.mkv"

  # Se il file di output esiste già, chiedo conferma prima di sovrascrivere (con opzione "tutti" per sovrascrivere tutto senza chiedere).
  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      # Se la sessione è interattiva, chiedo conferma all'utente. Altrimenti, skippo il file e loggo un warning.
      if { exec 3</dev/tty; } 2>/dev/null; then
        echo -ne "${C_WARN} Il file '$OUT_FILE' esiste già. Sovrascrivere? [s/n/t] (s=sì, n=no, t=tutti): "
        read -r ans <&3
        exec 3<&-
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
        warn "Output già esistente e sessione non interattiva → salto: $OUT_FILE"
        continue
      fi
    else
      info "Sovrascrittura automatica di '$OUT_FILE'..."
    fi
  fi

  # Misuro la sorgente prima dell'encode: il controllo finale usera' questo riferimento
  # per distinguere un file naturalmente quieto da un output reso quasi muto dal processing.
  INPUT_AUDIO_METRICS="$(measure_audio_signal "$CUR_FILE" "0:$A_STREAM_INDEX")" || {
    err "Impossibile misurare in modo affidabile la traccia audio sorgente → salto: $CUR_FILE"
    ((ERR_COUNT++))
    continue
  }

  # L'encode viene scritto in un candidato temporaneo nella stessa cartella.
  # Solo un candidato verificato sostituisce atomicamente il nome finale.
  TMP_OUT_FILE="${OUT_FILE%.mkv}.partial.$$.${RANDOM}.mkv"
  if [[ -e "$TMP_OUT_FILE" ]]; then
    err "File temporaneo già esistente, impossibile procedere in sicurezza: $TMP_OUT_FILE"
    ((ERR_COUNT++))
    continue
  fi

  # Costruisco dinamicamente il filter_complex in base al preset scelto, concatenando i blocchi di input split, processing voce, processing surround, e output join.
  FILTER_COMPLEX="$(build_filter_complex)"

  # Preparo il comando ffmpeg con i parametri dinamici: input, filter_complex, mappatura tracce, codec audio, bitrate, metadata, e output.
  CMD=(ffmpeg -hide_banner -nostdin -stats -loglevel warning -y)
  CMD+=(
    -i "$CUR_FILE"
    -map_metadata 0 -map_chapters 0
    -filter_complex "$FILTER_COMPLEX"
    -map "0:V:0?" -c:v copy
    -map "0:s?" -c:s copy
    -map "0:t?" -c:t copy
    -map "[aout]" -c:a:0 "$OUT_CODEC" -b:a:0 "$BITRATE" -dialnorm -31 -ar:a:0 48000 -ac:a:0 6
    -metadata:s:a:0 title="${OUT_CODEC^^} 5.1 – ${MODE_TITLE}"
    -disposition:a:0 default
  )
  # Imposto la lingua della traccia audio principale, se specificata.
  [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:0 language="$A_LANG" )

  # Se l'opzione KEEP_ORIG è attiva, mantengo la traccia audio originale come secondaria, copiandola senza ricodifica e disattivando la flag di default.
  if [[ "$KEEP_ORIG" = "si" ]]; then
    ORIG_TITLE="$(get_audio_title_by_index "$CUR_FILE" "$A_STREAM_INDEX" || true)"
    [[ -z "${ORIG_TITLE// }" ]] && ORIG_TITLE="Original Audio"
    CMD+=( -map 0:"$A_STREAM_INDEX" -c:a:1 copy -metadata:s:a:1 title="$ORIG_TITLE" -disposition:a:1 0 )
  fi

  # Eseguo il comando ffmpeg. Se l'encode riesce, confronto livelli, canali e durata con la sorgente.
  CMD+=( "$TMP_OUT_FILE" )
  if "${CMD[@]}"; then
    VERIFY_REASON=""
    verify_output_audio_signal "$TMP_OUT_FILE" "$INPUT_AUDIO_METRICS"
    VERIFY_RC=$?
    case "$VERIFY_RC" in
      0)
        if mv -f -- "$TMP_OUT_FILE" "$OUT_FILE"; then
          ok "Creato e verificato: $OUT_FILE"
          ((OK_COUNT++))
        else
          err "Verifica superata, ma pubblicazione del file finale fallita: $TMP_OUT_FILE"
          ((ERR_COUNT++))
        fi
        ;;
      1)
        err "Candidato rifiutato dalla verifica audio: ${VERIFY_REASON}: $TMP_OUT_FILE"
        err "Il candidato resta con suffisso .partial per il debug; il file finale non viene toccato."
        ((ERR_COUNT++))
        ;;
      *)
        err "Verifica audio del candidato non conclusiva: ${VERIFY_REASON}: $TMP_OUT_FILE"
        err "Fail-closed: il file finale non viene toccato e il candidato resta .partial."
        ((ERR_COUNT++))
        ;;
    esac
  else
    warn "Errore su: $CUR_FILE (eventuale candidato incompleto: $TMP_OUT_FILE)"
    ((ERR_COUNT++))
  fi
done
# Log finale: riepilogo con exit code reale (1 se almeno un file è fallito).
if (( ERR_COUNT > 0 )); then
  err "Elaborazione completata con errori: OK=$OK_COUNT, FALLITI=$ERR_COUNT"
  exit 1
fi
# Nessun file effettivamente elaborato (tutti saltati: non-5.1, già processati o non interattivi):
# lo segnalo esplicitamente così un'automazione non scambia un "niente da fare" per un successo pieno.
if (( OK_COUNT == 0 )); then
  warn "Nessun file elaborato."
  exit 0
fi
ok "Elaborazione completata: OK=$OK_COUNT, FALLITI=0"
