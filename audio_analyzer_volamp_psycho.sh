#!/usr/bin/env bash
set -uo pipefail

# ╭─────────────────────────────────────────────────────────────────────────────────╮
# │   audio_analyzer_volamp_psycho.sh - Settembre 2026                              │
# │   By Sandro (D@mocle77) Sabbioni                                                │
# │                                                                                 │
# │   Sonda euristica per l'analisi offline di container multimediali 5.1.          │
# │   Misura il bilanciamento surround/centro e genera run_processing.sh            │
# │   per il processore aegis_sonar_wide_aura_voice_volamp_psycho.sh.               │
# │                                                                                 │
# │   CLASSIFIER (RMS full-duration + banda voce, stesso passaggio):                │
# │     - DeltaSur = RMS(SL/SR) - RMS(FL/FR/FC)                                     │
# │     - DeltaFC  = RMS full-band(FC) - RMS full-band(FL/FR)                       │
# │     - VoiceDelta = RMS 250-5000 Hz(FC) - RMS 250-5000 Hz(FL/FR)                 │
# │     - VoiceMask  = RMS 250-5000 Hz(SL/SR) - RMS 250-5000 Hz(FC)                 │
# │     - Balance  = differenza assoluta SL/SR                                      │
# │     - Width    = RMS(SIDE) - RMS(MID)                                           │
# │                                                                                 │
# │   DECISIONE: silenzio/falso 5.1 -> sicurezza; voce debole o mascherata          │
# │   -> VOICE; surround molto arretrati -> SONAR; surround stretti                 │
# │   -> WIDE; moderatamente arretrati -> AURA; mix equilibrato -> AEGIS.           │
# │   PASS A EBU e PASS B RMS condividono una sola decodifica FFmpeg.               │
# │                                                                                 │
# │   VERDETTO STAGIONALE:                                                          │
# │   Verdetto: servono almeno 2/3 di consenso; parita'/spread > 4 dB -> MIXED.     │
# │                                                                                 │
# │   LRA non sceglie piu' il preset: viene misurata solo per limitare il volamp    │
# │   quando un mix cinematografico e' basso ma molto dinamico.                     │
# ╰─────────────────────────────────────────────────────────────────────────────────╯
# Note:
C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"
C_PROGRESS="\033[1;35m[AVANZAMENTO]\033[0m"

# Funzioni di log con colori: info, warn, err, ok. Usate per output coerente e facilmente distinguibile.
info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

# Controllo binari essenziali: ffmpeg, ffprobe, awk. Se uno manca, esco con errore. Importante per evitare errori a cascata quando si tenta di analizzare i file.
for _bin in ffmpeg ffprobe awk sort; do
  command -v "$_bin" &>/dev/null || { err "$_bin non trovato nel PATH"; exit 1; }
done

# Directory temporanea unica per i log ebur128: ripulita anche su interruzione (Ctrl-C),
# importante su Git Bash/Windows dove i temp orfani danno piu' fastidio.
ANALYZER_TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t analyzer)"
trap 'rm -rf "$ANALYZER_TMPDIR"' EXIT INT TERM

usage() {
  cat <<'USAGE'
-----------------------------------------------------------------------------------------------------------
UTILIZZO:
  ./audio_analyzer_volamp_psycho.sh <codec> <keep> <bitrate> <run> <file|directory|"">
  ./audio_analyzer_volamp_psycho.sh --files <codec> <keep> <bitrate> <run> <file1> [file2 ...]

MODALITA' INPUT:
  file      : Analizza un singolo file multimediale.
  directory : Analizza tutti i file compatibili dentro la directory indicata.
  ""        : Analizza tutti i file compatibili nella cartella corrente.
  --files   : Analizza solo i file elencati esplicitamente dopo i parametri.
              Utile per testare 2-3 episodi campione senza scandire tutta la folder.

PARAMETRI:
  codec   : eac3   (Default) Codec per il batch file generato.
            ac3    Alternativa.
  keep    : no     (Default) Non conservare audio originale.
            si     Conserva audio originale nel file processato.
  bitrate : Default automatico: AC3  = 640k - EAC3 = 768k
  run     : si     (Default) Genera o aggiorna run_processing.sh.
            no     Esegue solo l'analisi senza creare/modificare il batch.

ESEMPI:
  ./audio_analyzer_volamp_psycho.sh eac3 no 768k si "film.mkv"
  ./audio_analyzer_volamp_psycho.sh eac3 si 768k no .
  ./audio_analyzer_volamp_psycho.sh eac3 no 768k si ""
  ./audio_analyzer_volamp_psycho.sh --files eac3 no 768k no ep1.mkv ep4.mkv

COMPATIBILITA': resta accettato il vecchio ordine <input> [codec] [keep] [bitrate] [run].
-----------------------------------------------------------------------------------------------------------
USAGE
  exit 1
}

# Senza argomenti o con -h/--help -> mostra usage
[[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
# Modalità multi-file: se il primo argomento è --files, attivo la modalità multi-file e raccolgo i parametri specifici per questa modalità.
# CREATE_RUN accetta si|no e resta "si" per compatibilità con le versioni precedenti.
MULTI_FILES_MODE=false
MULTI_FILES=()
CREATE_RUN="si"

# Modalità --files: i primi 3 argomenti dopo --files sono codec, keep, bitrate.
# Il token successivo è interpretato come run solo se vale esattamente si oppure no;
# altrimenti viene trattato come primo filename, mantenendo la sintassi precedente.
if [[ "${1:-}" == "--files" ]]; then
  MULTI_FILES_MODE=true
  if (( $# < 5 )); then
    err "Uso --files non valido. Sintassi: ./audio_analyzer_volamp_psycho.sh --files <codec> <keep> <bitrate> [run] <file1> [file2 ...]"
    usage
  fi

  shift
  INPUT_ARG=""
  BATCH_CODEC="${1:-eac3}"
  BATCH_KEEP="${2:-no}"
  BATCH_BITRATE="${3:-}"
  shift 3

  if [[ "${1:-}" == "si" || "${1:-}" == "no" ]]; then
    CREATE_RUN="$1"
    shift
  fi

  MULTI_FILES=("$@")
else
  # Sintassi canonica: codec keep bitrate run input. Il primo token permette
  # di distinguerla senza ambiguita' dal vecchio ordine che iniziava col file.
  if (( $# == 5 )) && [[ "${1:-}" =~ ^(ac3|eac3)$ ]]; then
    BATCH_CODEC="${1:-eac3}"
    BATCH_KEEP="${2:-no}"
    BATCH_BITRATE="${3:-}"
    CREATE_RUN="${4:-si}"
    INPUT_ARG="${5:-}"
  else
    INPUT_ARG="${1:-}"
    BATCH_CODEC="${2:-eac3}"
    BATCH_KEEP="${3:-no}"
    BATCH_BITRATE="${4:-}"
    CREATE_RUN="${5:-si}"
  fi
fi
# Valori di default
[[ -z "$BATCH_BITRATE" ]] && {
  [[ "$BATCH_CODEC" = "ac3" ]] && BATCH_BITRATE="640k" || BATCH_BITRATE="768k"
}

# Validazione parametri: codec, keep, run, bitrate. Se un parametro non è valido, esco con errore e mostro usage.
case "$BATCH_CODEC" in ac3|eac3) ;; *) err "Codec '$BATCH_CODEC' non valido. Usa ac3 o eac3."; usage ;; esac
case "$BATCH_KEEP" in si|no) ;; *) err "Keep '$BATCH_KEEP' non valido. Usa si o no."; usage ;; esac
case "$CREATE_RUN" in si|no) ;; *) err "Run '$CREATE_RUN' non valido. Usa si o no."; usage ;; esac
[[ "$BATCH_BITRATE" =~ ^[0-9]+([kKmM])?$ ]] || { err "Bitrate '$BATCH_BITRATE' non valido. Es: 448k, 640k, 768k."; usage; }
[[ "$BATCH_BITRATE" =~ [kKmM]$ ]] || BATCH_BITRATE="${BATCH_BITRATE}k"

# Validazione allineata al processore: step da 64 kbps, AC3 fino a 640k,
# EAC3 fino a 768k. Evita di generare un run_processing.sh non eseguibile.
BITRATE_LC="${BATCH_BITRATE,,}"
if [[ "$BITRATE_LC" =~ ^([0-9]+)k$ ]]; then
  BITRATE_KBPS="${BASH_REMATCH[1]}"
elif [[ "$BITRATE_LC" =~ ^([0-9]+)m$ ]]; then
  BITRATE_KBPS="$(( ${BASH_REMATCH[1]} * 1000 ))"
else
  err "Bitrate non valido: $BATCH_BITRATE"
  usage
fi
BITRATE_MAX_KBPS=768
[[ "$BATCH_CODEC" == "ac3" ]] && BITRATE_MAX_KBPS=640
if (( BITRATE_KBPS < 256 || BITRATE_KBPS > BITRATE_MAX_KBPS || ((BITRATE_KBPS - 256) % 64) != 0 )); then
  err "Bitrate non consentito per $BATCH_CODEC: ${BITRATE_KBPS}k"
  if [[ "$BATCH_CODEC" == "ac3" ]]; then
    err "Consentiti: 256k, 320k, 384k, 448k, 512k, 576k, 640k"
  else
    err "Consentiti: 256k, 320k, 384k, 448k, 512k, 576k, 640k, 704k, 768k"
  fi
  exit 1
fi
BATCH_BITRATE="${BITRATE_KBPS}k"
# Nota: non controllo se i file in --files esistono qui, lo faccio dopo per permettere di passare anche file parzialmente inesistenti senza bloccare tutto.
if [[ "$MULTI_FILES_MODE" == true ]]; then
  info "Metrica: CLASSIFIER RMS + VOICE BAND | Input: lista manuale (${#MULTI_FILES[@]} file) | Batch: ${BATCH_CODEC} / keep=${BATCH_KEEP} / ${BATCH_BITRATE} / run_processing=${CREATE_RUN}"
else
  info "Metrica: CLASSIFIER RMS + VOICE BAND | Batch: ${BATCH_CODEC} / keep=${BATCH_KEEP} / ${BATCH_BITRATE} / run_processing=${CREATE_RUN}"
fi
info "Volamp heuristic: make-up DSP 4.0 dB + recupero loudness con step 4 / 4.5 / 5 / 5.5 dB"

# ── CONFIG ANALITICA INTERNA ──────────────────────────────────────────────────
# Target domestico fisso: niente variabili da esportare prima del lancio.
# -21 LUFS = compromesso home theater; -23 LUFS sarebbe piu' broadcast/reference.
LOUDNESS_TARGET="-21.0"

# Make-up gain minimo del processore.
# Non rappresenta una sorgente "bassa": compensa la perdita percepita introdotta
# da split/EQ/compressori/limiter della pipeline psicoacustica.
VOLAMP_BASE="4.0"
VOLAMP_MAX="5.5"

# Width Mid/Side sotto questa soglia = surround collassati/stretti (poca separazione L/R).
# In quel caso, a parita' di Delta, una ricostruzione laterale (WIDE) rende di piu'
# di AURA/AEGIS. Non tocca SONAR (deficit estremo) ne' VOICE.
WIDTH_WIDE_GATE="-7.0"

# Classificatore: l'energia full-band descrive la scena; la banda 250-5000 Hz
# descrive la prominenza del parlato senza far pesare eccessivamente bassi ed LFE.
SUR_FAKE_RMS_GATE="-65.0"
CENTER_FULL_SAFETY_GATE="-9.0" # FC full-band - FL/FR: anomalia severa
VOICE_DELTA_GATE="-4.5"        # FC voice-band - FL/FR voice-band
VOICE_MASK_GATE="-1.5"         # SUR voice-band - FC voice-band
VOICE_BAND_RMS_GATE="-70.0"    # sotto questo livello la metrica voce non e' valida
SUR_DOMINANT_GATE="1.0"        # SUR full-band - FL/FR/FC
DOMINANT_VOICE_DELTA_GATE="0.0" # dominanza SUR critica solo con FC non prominente
SONAR_DELTA_GATE="-13.0"
AURA_DELTA_GATE="-7.0"
SUR_BALANCE_WARN_DB="10.0"
PRESET_BORDERLINE_MARGIN="0.7"

# Un picco globale uguale o inferiore a questa soglia viene considerato
# silenzio/quasi-silenzio e non deve produrre preset o comandi batch.
ANALYZER_SILENCE_PEAK_DB="-80.0"

# Sample Peak rapido per l'analisi sorgente. Il True Peak che tutela il risultato
# finale resta obbligatorio post-codec nella verifica del processore.
ANALYZER_PROGRESS_INTERVAL="${ANALYZER_PROGRESS_INTERVAL:-15}"
if ! [[ "$ANALYZER_PROGRESS_INTERVAL" =~ ^[0-9]+$ ]] || (( ANALYZER_PROGRESS_INTERVAL < 1 )); then
  ANALYZER_PROGRESS_INTERVAL="15"
fi
ASTATS_RMS_OPTS="metadata=0:reset=0:measure_perchannel=RMS_level:measure_overall=none"

# Soglie del profilo tonale FC volutamente conservative. La zona NORMAL e' ampia;
# questi valori restano da calibrare sul corpus, senza usare il validation set.
FC_DARK_PRESENCE_MAX="-12.0"
FC_DARK_MID_MAX="-5.0"
FC_BRIGHT_PRESENCE_MIN="2.0"
FC_SIBILANT_INDEX_MIN="2.0"

# Analisi della dinamica surround. Soglie iniziali da calibrare sul corpus.
WINDOW_ACTIVITY_GATE="-55.0"
SUR_MIN_ACTIVE_WINDOWS="10"
SUR_AMBIENT_P95_MAX="14.0"
SUR_AMBIENT_TAIL95_MAX="5.0"
SUR_TRANSIENT_P95_MIN="20.0"
SUR_HOT22_AMBIENT_MAX="1.0"
SUR_HOT22_TRANSIENT_MIN="5.0"

# Bias Atmos conservativo. Il tag della traccia originale non forza mai SONAR:
# amplia soltanto la zona borderline quando il contenuto e' gia' compatibile.
# AMBIENT: estensione massima di 1.5 dB; MIXED: estensione di 1.0 dB.
# TRANSIENT non riceve bias. VOICE/WIDE non vengono mai sovrascritti.
ATMOS_SONAR_AMBIENT_GATE="-11.5"
ATMOS_SONAR_MIXED_GATE="-12.0"
ATMOS_ORIGINAL_TITLE="EAC3 Atmos (Original)"

info "Target loudness analitico: ${LOUDNESS_TARGET} LUFS"
info "Classifier: voice FC/front=${VOICE_DELTA_GATE} dB | voice SUR/FC=${VOICE_MASK_GATE} dB | FC safety=${CENTER_FULL_SAFETY_GATE} dB"
info "Peak input: Sample Peak rapido; avanzamento ogni ${ANALYZER_PROGRESS_INTERVAL}s"

# Variabili globali per il verdetto stagionale
GLOBAL_METRIC_VALUES=()
GLOBAL_METRIC_FILES=()
GLOBAL_METRIC_PATHS=()
GLOBAL_LOUDNESS_VALUES=()
GLOBAL_INPUT_PEAK_VALUES=()
GLOBAL_FC_BODY_VALUES=()
GLOBAL_FC_MID_VALUES=()
GLOBAL_FC_PRESENCE_VALUES=()
GLOBAL_FC_SIBILANCE_VALUES=()
GLOBAL_PRESENCE_INDEX_VALUES=()
GLOBAL_SIBILANCE_INDEX_VALUES=()
GLOBAL_FC_PROFILE_VALUES=()
GLOBAL_FC_CONFIDENCE_VALUES=()
GLOBAL_SUR_ACTIVE_VALUES=()
GLOBAL_CREST_P50_VALUES=()
GLOBAL_CREST_P90_VALUES=()
GLOBAL_CREST_P95_VALUES=()
GLOBAL_CREST_P99_VALUES=()
GLOBAL_CREST_MAX_VALUES=()
GLOBAL_TAIL95_VALUES=()
GLOBAL_TAIL99_VALUES=()
GLOBAL_HOT22_VALUES=()
GLOBAL_HOT25_VALUES=()
GLOBAL_SUR_PROFILE_VALUES=()
GLOBAL_SUR_CONFIDENCE_VALUES=()
GLOBAL_SOURCE_CLASS_VALUES=()
GLOBAL_SOURCE_BIAS_VALUES=()
GLOBAL_VOLAMP_VALUES=()
GLOBAL_WIDTH_VALUES=()
GLOBAL_LRA_VALUES=()
GLOBAL_PRESET_VALUES=()
GLOBAL_PRESET_FORCED_VALUES=()
GLOBAL_CENTER_DELTA_VALUES=()
GLOBAL_VOICE_DELTA_VALUES=()
GLOBAL_VOICE_MASK_VALUES=()
GLOBAL_BALANCE_VALUES=()
GLOBAL_CONFIDENCE_VALUES=()
GLOBAL_ALTERNATIVE_VALUES=()
GLOBAL_REASON_VALUES=()

# ────────────────────────────────────────────────────────────────────────────────
# Raccolta file
# ────────────────────────────────────────────────────────────────────────────────
# Modalità raccolta file:
FILES=()
if [[ "$MULTI_FILES_MODE" == true ]]; then
  (( ${#MULTI_FILES[@]} > 0 )) || { err "Modalita' --files richiesta ma nessun file passato."; exit 1; }
  # Controllo esistenza file in modalità --files: se un file non esiste, lo salto con warning ma continuo con gli altri (non blocco tutto).
  for f in "${MULTI_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      FILES+=("$f")
    else
      warn "File inesistente, salto: $f"
    fi
  done
elif [[ -z "$INPUT_ARG" ]]; then
  shopt -s nullglob
  FILES+=( *.mkv *.MKV *.mp4 *.MP4 *.avi *.AVI *.mka *.MKA \
           *.m2ts *.M2TS *.ac3 *.AC3 *.eac3 *.EAC3 \
           *.wav *.WAV *.flac *.FLAC )
  shopt -u nullglob
elif [[ -d "$INPUT_ARG" ]]; then
  shopt -s nullglob
  FILES+=( "$INPUT_ARG"/*.mkv "$INPUT_ARG"/*.MKV "$INPUT_ARG"/*.mp4 "$INPUT_ARG"/*.MP4 \
           "$INPUT_ARG"/*.avi "$INPUT_ARG"/*.AVI "$INPUT_ARG"/*.mka "$INPUT_ARG"/*.MKA \
           "$INPUT_ARG"/*.m2ts "$INPUT_ARG"/*.M2TS "$INPUT_ARG"/*.ac3 "$INPUT_ARG"/*.AC3 \
           "$INPUT_ARG"/*.eac3 "$INPUT_ARG"/*.EAC3 "$INPUT_ARG"/*.wav "$INPUT_ARG"/*.WAV \
           "$INPUT_ARG"/*.flac "$INPUT_ARG"/*.FLAC )
  shopt -u nullglob
elif [[ -f "$INPUT_ARG" ]]; then
  FILES+=("$INPUT_ARG")
else
  err "File o cartella inesistente: $INPUT_ARG"
  exit 1
fi

# Filtra i file già processati dal processore 
FILTERED_FILES=()
for f in "${FILES[@]}"; do
  case "$f" in
    *_AC3_Aegis.mkv|*_AC3_Sonar.mkv|*_AC3_Wide.mkv|*_AC3_Aura.mkv|*_AC3_Voice.mkv|\
    *_EAC3_Aegis.mkv|*_EAC3_Sonar.mkv|*_EAC3_Wide.mkv|*_EAC3_Aura.mkv|*_EAC3_Voice.mkv)
      info "Skip output gia' processato: $f"
      continue
      ;;
    *)
      FILTERED_FILES+=("$f")
      ;;
  esac
done
FILES=("${FILTERED_FILES[@]}")
# Controllo finale: se dopo il filtro non ci sono file validi, esco con errore.
(( ${#FILES[@]} == 0 )) && { err "Nessun file valido trovato da analizzare."; exit 1; }

# ────────────────────────────────────────────────────────────────────────────────
# Selezione stream con sistema a punteggio allineato al processore.
# Entrano solo stream 5.1; tra questi prevalgono lingua italiana e flag default.
# Restituisce: "stream_index canali layout"
# ────────────────────────────────────────────────────────────────────────────────
pick_best_stream() {
  local f="$1"
  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null </dev/null || true)
  raw_data="${raw_data//$'\r'/}"
  # Punteggio identico al processore: lingua italiana, poi flag default.
  local best_idx=""
  local best_ch=0
  local best_layout="unknown"
  local best_score=-999999

  # Se ffprobe non restituisce dati, esco con warning e codice di errore.
  if [[ -n "$raw_data" ]]; then
    local lines
    mapfile -t lines <<< "$raw_data"
    for line in "${lines[@]}"; do
      [[ -z "$line" ]] && continue
      IFS=',' read -r idx ch layout def lang <<<"$line"
      ch="${ch:-0}"
      layout="${layout:-unknown}"
      def="${def:-0}"
      lang="${lang:-}"

      # L'analizzatore e il processore lavorano esclusivamente sul 5.1.
      [[ "$ch" =~ ^[0-9]+$ && "$ch" -eq 6 ]] || continue

      local score=1000
      [[ "$def" == "1" ]] && score=$((score + 200))
      [[ "${lang,,}" =~ ^it ]] && score=$((score + 300))
      # Se questo stream ha un punteggio migliore del migliore finora, lo seleziono come nuovo best.
      if (( score > best_score )); then
        best_score=$score
        best_idx=$idx
        best_ch=$ch
        best_layout=$layout
      fi
    done
  fi
  # Se non ho trovato stream validi, esco con warning e codice di errore.
  echo "$best_idx $best_ch $best_layout"
}

# ──────────────────────────────────────────────────────────────────────────────────
# Rilevamento provenienza Atmos dal tag della traccia originale conservata dal
# pre-processore atmos_to_51_dynaudnorm_psicho.sh. Il tag e' un hint di provenienza:
# non dimostra che il bed 5.1 richieda SONAR e non modifica da solo il preset.
# Output: ATMOS oppure UNKNOWN.
# ──────────────────────────────────────────────────────────────────────────────────
detect_source_class() {
  local f="$1" title
  while IFS= read -r title; do
    title="${title//$'\r'/}"
    if [[ "${title,,}" == "${ATMOS_ORIGINAL_TITLE,,}" ]]; then
      echo "ATMOS"
      return 0
    fi
  done < <(ffprobe -v error -select_streams a \
    -show_entries stream_tags=title -of default=nw=1:nk=1 "$f" 2>/dev/null || true)

  echo "UNKNOWN"
}

# Applica un bias Atmos soltanto a un AURA gia' deciso dal classifier. In questo
# modo la provenienza Atmos non puo' scavalcare VOICE, WIDE o un SONAR gia' netto.
# Output invariato: PRESET|COLORE|CONFIDENCE|ALTERNATIVE|REASON
apply_atmos_sonar_bias() {
  local preset_raw="$1" source_class="$2" sur_profile="$3" delta_sur="$4"
  local preset color confidence alternative reason gate=""
  IFS='|' read -r preset color confidence alternative reason <<<"$preset_raw"

  [[ "$source_class" == "ATMOS" && "$preset" == "AURA" ]] || { printf '%s
' "$preset_raw"; return; }

  case "$sur_profile" in
    AMBIENT) gate="$ATMOS_SONAR_AMBIENT_GATE" ;;
    MIXED)   gate="$ATMOS_SONAR_MIXED_GATE" ;;
    *)       printf '%s
' "$preset_raw"; return ;;
  esac

  if awk -v ds="$delta_sur" -v gate="$gate" 'BEGIN { exit !(ds < gate) }'; then
    preset="SONAR"
    color="\033[1;31m"
    confidence="bassa"
    alternative="AURA"
    reason="bias Atmos conservativo: sorgente originale Atmos + surround borderline SONAR (${sur_profile})"
  fi

  printf '%s|%s|%s|%s|%s
' "$preset" "$color" "$confidence" "$alternative" "$reason"
}

# ──────────────────────────────────────────────────────────────────────────────────
# Colore ANSI associato a un preset (per display coerente quando si parte dal nome).
# ──────────────────────────────────────────────────────────────────────────────────
# Controllo robusto: se il preset non è riconosciuto, restituisco un colore di default (bianco). Evita errori di visualizzazione e permette di gestire casi in cui il preset non è stato classificato correttamente.
preset_color() {
  case "$1" in
    SONAR) echo "\033[1;31m" ;;       # rosso
    AEGIS) echo "\033[38;5;208m" ;;   # arancione (ANSI 256 colori)
    WIDE)  echo "\033[1;32m" ;;       # verde
    AURA)  echo "\033[1;35m" ;;       # viola/magenta
    VOICE) echo "\033[1;33m" ;;       # giallo
    *)     echo "\033[1;37m" ;;       # bianco
  esac
}

# Classificatore: priorita' alla voce, poi alla correzione spaziale.
# Output: PRESET|COLORE|CONFIDENCE|ALTERNATIVE|REASON
classify_spatial_preset() {
  local delta_sur="$1" delta_fc="$2" delta_voice="$3" voice_mask="$4" width="$5"
  awk -v ds="$delta_sur" -v df="$delta_fc" -v dv="$delta_voice" \
      -v vm="$voice_mask" -v w="$width" \
      -v fcgate="$CENTER_FULL_SAFETY_GATE" -v vgate="$VOICE_DELTA_GATE" \
      -v vmaskgate="$VOICE_MASK_GATE" -v domgate="$SUR_DOMINANT_GATE" \
      -v domvoicegate="$DOMINANT_VOICE_DELTA_GATE" \
      -v sonargate="$SONAR_DELTA_GATE" -v auragate="$AURA_DELTA_GATE" \
      -v wgate="$WIDTH_WIDE_GATE" -v margin="$PRESET_BORDERLINE_MARGIN" '
  function spatial_preset(delta, width) {
    if (delta < sonargate) return "SONAR";
    if (width != "" && width < wgate) return "WIDE";
    if (delta < auragate) return "AURA";
    return "AEGIS";
  }
  BEGIN {
    preset="AEGIS"; color="\033[38;5;208m"; confidence="alta"; alt="-"; reason="mix equilibrato";
    hasvoice=(dv != "" && vm != "");
    spatial=spatial_preset(ds, w);

    if (df < fcgate) {
      preset="VOICE"; color="\033[1;33m"; reason="centro full-band anormalmente debole"; alt=spatial;
      if ((fcgate-df) <= margin) confidence="bassa";
    } else if (hasvoice && dv < vgate) {
      preset="VOICE"; color="\033[1;33m"; reason="voce centrale debole nella banda 250-5000 Hz"; alt=spatial;
      if ((vgate-dv) <= margin) confidence="bassa";
    } else if (hasvoice && vm > vmaskgate) {
      preset="VOICE"; color="\033[1;33m"; reason="banda voce mascherata dai surround"; alt=spatial;
      if ((vm-vmaskgate) <= margin) confidence="bassa";
    } else if (hasvoice && ds > domgate && dv < domvoicegate) {
      preset="VOICE"; color="\033[1;33m"; reason="surround dominanti con voce centrale non prominente"; alt=spatial;
      if ((ds-domgate) <= margin || (domvoicegate-dv) <= margin) confidence="bassa";
    } else if (ds < sonargate) {
      preset="SONAR"; color="\033[1;31m"; reason="surround molto arretrati";
      if ((sonargate-ds) <= margin) { confidence="bassa"; alt="AURA"; }
    } else if (w != "" && w < wgate) {
      preset="WIDE"; color="\033[1;32m"; reason="surround stretti o collassati";
      if ((wgate-w) <= margin) {
        confidence="bassa";
        if (ds < auragate) alt="AURA"; else alt="AEGIS";
      }
    } else if (ds < auragate) {
      preset="AURA"; color="\033[1;35m"; reason="surround moderatamente arretrati";
      if ((ds-sonargate) <= margin) { confidence="bassa"; alt="SONAR"; }
      else if ((auragate-ds) <= margin) { confidence="bassa"; alt="AEGIS"; }
    } else {
      preset="AEGIS"; color="\033[38;5;208m"; reason="mix surround gia equilibrato";
      if ((ds-auragate) <= margin) { confidence="bassa"; alt="AURA"; }
    }

    # Un preset spaziale diventa incerto vicino a una soglia della voce.
    if (preset != "VOICE" && (df-fcgate) >= 0 && (df-fcgate) <= margin) {
      confidence="bassa"; alt="VOICE"; reason=reason " (borderline centro full-band)";
    }
    if (preset != "VOICE" && hasvoice && (dv-vgate) >= 0 && (dv-vgate) <= margin) {
      confidence="bassa"; alt="VOICE"; reason=reason " (borderline prominenza voce)";
    }
    if (preset != "VOICE" && hasvoice && (vmaskgate-vm) >= 0 && (vmaskgate-vm) <= margin) {
      confidence="bassa"; alt="VOICE"; reason=reason " (borderline mascheramento voce)";
    }
    if (preset != "VOICE" && hasvoice && ds > domgate && dv >= domvoicegate &&
        (dv-domvoicegate) <= margin) {
      confidence="bassa"; alt="VOICE"; reason=reason " (surround dominanti, voce borderline)";
    }
    if (preset != "VOICE" && preset != "SONAR" && w != "" &&
        (w-wgate) >= 0 && (w-wgate) <= margin) {
      confidence="bassa"; alt="WIDE"; reason=reason " (borderline width)";
    }

    printf "%s|%s|%s|%s|%s", preset, color, confidence, alt, reason;
  }'
}

# ────────────────────────────────────────────────────────────────────────────────
# Estrae Loudness Integrata, LRA e Sample Peak esclusivamente dall'ultimo
# summary completo di ebur128. Non interpreta Peak appartenenti ad altre sezioni.
# Args: log_file | Output: "I|LRA|SAMPLE_PEAK"; errore se incompleto.
# ────────────────────────────────────────────────────────────────────────────────
parse_ebur128_summary() {
  awk '
    /Summary:/ { in_summary=1; section=""; i_val=""; lra_val=""; peak_val=""; next }
    !in_summary { next }
    /^[[:space:]]*Integrated loudness:[[:space:]]*$/ { section="integrated"; next }
    /^[[:space:]]*Loudness range:[[:space:]]*$/      { section="range"; next }
    /^[[:space:]]*Sample peak:[[:space:]]*$/         { section="sample_peak"; next }
    section == "integrated" && /^[[:space:]]*I:[[:space:]]+/    { i_val=$2; next }
    section == "range"      && /^[[:space:]]*LRA:[[:space:]]+/  { lra_val=$2; next }
    section == "sample_peak" && /^[[:space:]]*Peak:[[:space:]]+/ { peak_val=$2; next }
    END {
      number="^-?[0-9]+([.][0-9]+)?$"
      if (i_val !~ number || lra_val !~ number || (peak_val !~ number && peak_val != "-inf")) exit 1
      printf "%s|%s|%s\n", i_val, lra_val, peak_val
    }
  ' "$1"
}

is_finite_db() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

# ────────────────────────────────────────────────────────────────────────────────
# Euristica volamp da Loudness Integrata del file intero
# Output consentiti automatici: 4 | 4.5 | 5 | 5.5
# ────────────────────────────────────────────────────────────────────────────────
loudness_to_volamp() {
  local i_val="$1"
  # Se la misura non e' disponibile, uso comunque il make-up DSP standard.
  [[ -n "$i_val" ]] || { echo "$VOLAMP_BASE"; return; }
  [[ "$i_val" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || { echo "$VOLAMP_BASE"; return; }

  local deficit
  deficit=$(awk -v i="$i_val" -v t="$LOUDNESS_TARGET" 'BEGIN { printf "%.2f", (t - i) }')

  # Baseline allineata al default del processore: +4 dB nominali.
  # Gli step superiori recuperano sorgenti progressivamente piu' basse.
  # - 4.0 dB = make-up DSP standard
  # - 4.5/5.0/5.5 dB = recupero crescente sotto il target loudness
  if awk -v d="$deficit" 'BEGIN { exit !(d < 0.8) }'; then
    echo "$VOLAMP_BASE"
  elif awk -v d="$deficit" 'BEGIN { exit !(d < 1.8) }'; then
    echo "4.5"
  elif awk -v d="$deficit" 'BEGIN { exit !(d < 3.0) }'; then
    echo "5.0"
  else
    echo "$VOLAMP_MAX"
  fi
}

# Descrizione testuale del volamp consigliato per il display.
volamp_to_desc() {
  case "$1" in
    4|4.0)   echo "Make-up DSP standard" ;;
    4.5)     echo "Recupero loudness leggero" ;;
    5|5.0)   echo "Recupero loudness" ;;
    5.5)     echo "Recupero loudness forte" ;;
    6|6.0)   echo "Recupero massimo manuale" ;;
    0|0.0)   echo "OFF manuale" ;;
    *)       echo "Boost custom" ;;
  esac
}

# Stato sintetico del livello della sorgente, derivato dal volamp consigliato.
source_volume_status() {
  local volamp="$1"
  case "$volamp" in
    4|4.0)   echo "standard / make-up DSP" ;;
    4.5)     echo "basso" ;;
    5|5.0)   echo "molto basso" ;;
    5.5)     echo "estremamente basso" ;;
    6|6.0)   echo "modalita' manuale spinta" ;;
    0|0.0)   echo "OFF manuale" ;;
    *)       echo "da verificare" ;;
  esac
}

# ───────────────────────────────────────────────────────────────────────────────────
# (I, LRA e Sample Peak sono misurati dal ramo EBU del PASS A/B combinato.)
# ───────────────────────────────────────────────────────────────────────────────────

# ───────────────────────────────────────────────────────────────────────────────────
# Limita il volamp se il file ha dinamica alta.
# Integrato basso + LRA alta spesso significa mix cinematografico, non file rotto.
# ───────────────────────────────────────────────────────────────────────────────────
cap_volamp_by_lra() {
  local volamp="$1" lra="$2"
  [[ -n "$lra" && "$lra" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || { echo "$volamp"; return; }

  # Mix molto dinamico: consento il recupero ma limito gli step piu' spinti.
  # Il cap non scende mai sotto il make-up base di 4.0 dB.
  if awk -v l="$lra" 'BEGIN { exit !(l >= 18.0) }'; then
    if awk -v v="$volamp" 'BEGIN { exit !(v > 4.5) }'; then
      echo "4.5"
    else
      echo "$volamp"
    fi
  else
    echo "$volamp"
  fi
}

# ────────────────────────────────────────────────────────────────────────────────
# Classifica width Mid/Side dei surround.
# width = RMS(SIDE) - RMS(MID). Valori molto negativi = SL/SR simili/collassati.
# ────────────────────────────────────────────────────────────────────────────────
# Controllo robusto: se width non è un numero valido, restituisco "N/A". Evita output non numerici e permette di gestire casi in cui la misura width non è disponibile (es. file troppo corto).
width_to_desc() {
  local w="$1"
  [[ -n "$w" && "$w" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || { echo "N/A"; return; }
  # Soglie empiriche per descrivere la separazione L/R dei surround: se width è molto negativo, i surround sono simili o collassati -> "collassato". Se width è moderatamente negativo, i surround sono stretti -> "stretto". Se width è vicino a 0 o positivo, i surround hanno buona separazione -> "medio" o "largo". Queste soglie sono indicative e possono essere regolate in base all'ascolto.
  if awk -v w="$w" 'BEGIN { exit !(w < -12.0) }'; then
    echo "collassato"
  elif awk -v w="$w" 'BEGIN { exit !(w < -7.0) }'; then
    echo "stretto"
  elif awk -v w="$w" 'BEGIN { exit !(w < -3.0) }'; then
    echo "medio"
  else
    echo "largo"
  fi
}

# Classificazione timbrica prudenziale del centrale. Usa solo rapporti tra
# bande FC e resta indipendente da DeltaFC/VoiceDelta. In caso di ambiguita'
# o metrica non valida il chiamante mantiene NORMAL.
classify_fc_profile() {
  local presence_index="$1" sibilance_index="$2" mid_index="$3"
  awk -v pi="$presence_index" -v si="$sibilance_index" -v mi="$mid_index" \
      -v dark_pi="$FC_DARK_PRESENCE_MAX" -v dark_mi="$FC_DARK_MID_MAX" \
      -v bright_pi="$FC_BRIGHT_PRESENCE_MIN" -v sib_si="$FC_SIBILANT_INDEX_MIN" 'BEGIN {
    profile="NORMAL"; confidence="alta"; reason="deadband centrale"

    # SIBILANT richiede sia una coda 5-9 kHz dominante sia presenza non scura.
    if (si >= sib_si && pi >= -3.0) {
      profile="SIBILANT"; reason="coda alta FC chiaramente dominante"
      if (si < sib_si+1.5 || pi < -1.5) confidence="bassa"
    }
    # BRIGHT richiede presenza nettamente sopra il body, ma non una coda
    # abbastanza forte da soddisfare la condizione SIBILANT.
    else if (pi >= bright_pi && si < sib_si) {
      profile="BRIGHT"; reason="presenza FC chiaramente elevata"
      if (pi < bright_pi+1.5) confidence="bassa"
    }
    # DARK usa due indici concordi: presenza/body e mid/body.
    else if (pi <= dark_pi && mi <= dark_mi) {
      profile="DARK"; reason="presenza e medi FC chiaramente arretrati"
      if (pi > dark_pi-2.0 || mi > dark_mi-2.0) confidence="bassa"
    }
    # Vicino a qualunque frontiera si resta NORMAL con confidenza bassa.
    else if ((pi > dark_pi-2.0 && pi < dark_pi+2.0) ||
             (pi > bright_pi-2.0 && pi < bright_pi+2.0) ||
             (si > sib_si-2.0 && si < sib_si+2.0)) {
      confidence="bassa"; reason="deadband/borderline: nessuna correzione"
    }

    printf "%s|%s|%s", profile, confidence, reason
  }'
}

# Converte un percorso temporaneo nel formato accettato dentro un filtergraph
# FFmpeg. Su Git Bash il drive Windows richiede l'escape del carattere ':'.
ffmpeg_filter_path() {
  local p="$1"
  if command -v cygpath &>/dev/null; then
    p=$(cygpath -m "$p") || return 1
  fi
  p="${p/:/\\:}"
  printf '%s\n' "$p"
}

# Combina per indice le finestre SL/SR prodotte da ametadata. Il Crest Factor
# di astats e' lineare: viene convertito in dB solo dopo l'activity gate.
# Output: TOTAL|ACTIVE|P50|P90|P95|P99|MAX|TAIL95|TAIL99|HOT22|HOT25
measure_surround_transients() {
  local sl_log="$1" sr_log="$2" crest_values sorted_values counts total active stats
  crest_values=$(mktemp -p "$ANALYZER_TMPDIR")
  sorted_values=$(mktemp -p "$ANALYZER_TMPDIR")

  counts=$(awk -v out="$crest_values" -v gate="$WINDOW_ACTIVITY_GATE" '
    FNR == 1 { source++ }
    /^frame:/ { frame=$1; sub(/^frame:/,"",frame); next }
    /lavfi[.]astats[.]1[.]RMS_level=/ {
      split($0,a,"="); if (source == 1) sl_rms[frame]=a[2]; else sr_rms[frame]=a[2]; next
    }
    /lavfi[.]astats[.]1[.]Crest_factor=/ {
      split($0,a,"="); if (source == 1) sl_crest[frame]=a[2]; else sr_crest[frame]=a[2]; next
    }
    END {
      number="^-?[0-9]+([.][0-9]+)?$"; total=0; active=0
      for (f in sl_rms) {
        if (!(f in sr_rms)) continue
        total++
        if (sl_rms[f] !~ number || sr_rms[f] !~ number ||
            sl_crest[f] !~ number || sr_crest[f] !~ number ||
            sl_crest[f] <= 0 || sr_crest[f] <= 0) continue
        power=(10^(sl_rms[f]/10)+10^(sr_rms[f]/10))/2
        sur_rms=10*log(power)/log(10)
        if (sur_rms <= gate) continue
        crest=(sl_crest[f] > sr_crest[f]) ? sl_crest[f] : sr_crest[f]
        crest_db=20*log(crest)/log(10)
        printf "%.6f\n", crest_db > out
        active++
      }
      printf "%d|%d\n", total, active
    }
  ' "$sl_log" "$sr_log") || { rm -f "$crest_values" "$sorted_values"; return 1; }

  IFS='|' read -r total active <<<"$counts"
  if ! [[ "$active" =~ ^[0-9]+$ ]] || (( active == 0 )); then
    rm -f "$crest_values" "$sorted_values"
    printf '%s|0|N/A|N/A|N/A|N/A|N/A|N/A|N/A|0.0|0.0\n' "${total:-0}"
    return 0
  fi

  sort -n "$crest_values" > "$sorted_values" || {
    rm -f "$crest_values" "$sorted_values"
    return 1
  }
  stats=$(awk '
    { v[NR]=$1+0 }
    function pct(p, raw,rank) {
      raw=p*n; rank=int(raw); if (raw>rank) rank++
      if (rank<1) rank=1; if (rank>n) rank=n
      return v[rank]
    }
    END {
      n=NR; if (!n) exit 1
      p50=pct(0.50); p90=pct(0.90); p95=pct(0.95); p99=pct(0.99)
      hot22=0; hot25=0
      for (i=1;i<=n;i++) { if (v[i]>22) hot22++; if (v[i]>25) hot25++ }
      printf "%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f", \
        p50,p90,p95,p99,v[n],p95-p50,p99-p50,100*hot22/n,100*hot25/n
    }
  ' "$sorted_values") || { rm -f "$crest_values" "$sorted_values"; return 1; }
  rm -f "$crest_values" "$sorted_values"
  printf '%s|%s|%s\n' "$total" "$active" "$stats"
}

# Classificatore ibrido: baseline, coda e frequenza degli eventi devono essere
# concordi. MAX non entra mai nella decisione; MIXED e' sempre il fallback.
classify_sur_profile() {
  local active="$1" p50="$2" p95="$3" tail95="$4" hot22="$5"
  if ! [[ "$active" =~ ^[0-9]+$ ]] || (( active < SUR_MIN_ACTIVE_WINDOWS )) || \
     ! is_finite_db "$p50" || ! is_finite_db "$p95" || \
     ! is_finite_db "$tail95" || ! is_finite_db "$hot22"; then
    echo "MIXED|bassa|fallback: finestre attive insufficienti o metriche non valide"
    return
  fi

  awk -v p50="$p50" -v p95="$p95" -v tail="$tail95" -v hot="$hot22" \
      -v ambient_p95="$SUR_AMBIENT_P95_MAX" -v ambient_tail="$SUR_AMBIENT_TAIL95_MAX" \
      -v transient_p95="$SUR_TRANSIENT_P95_MIN" \
      -v ambient_hot="$SUR_HOT22_AMBIENT_MAX" -v transient_hot="$SUR_HOT22_TRANSIENT_MIN" 'BEGIN {
    profile="MIXED"; confidence="alta"; reason="distribuzione ibrida/borderline"
    if (p95 <= ambient_p95 && tail <= ambient_tail && hot <= ambient_hot) {
      profile="AMBIENT"; reason="coda crest bassa e impulsi rari"
      if (p95 > ambient_p95-2 || tail > ambient_tail-1.5 || hot > ambient_hot/2) confidence="bassa"
    } else if (p95 >= transient_p95 && hot >= transient_hot) {
      profile="TRANSIENT"; reason="P95 alto e quota impulsiva significativa"
      if (p95 < transient_p95+2 || hot < transient_hot+3) confidence="bassa"
    } else if ((p95 > ambient_p95-2 && p95 < ambient_p95+2) ||
               (p95 > transient_p95-2 && p95 < transient_p95+2) ||
               (hot > transient_hot-2 && hot < transient_hot+2)) {
      confidence="bassa"
    }
    printf "%s|%s|%s", profile, confidence, reason
  }'
}

# ────────────────────────────────────────────────────────────────────────────────
# Misura in un'unica decodifica PASS A (I/LRA/picco) e PASS B. I canali
# full-band condividono una sola istanza astats multicanale; lo stesso vale
# per la banda voce. MID/SIDE, bande FC e finestre SL/SR sono rami diagnostici.
# Output: "FL|FR|FC|SL|SR|MID|SIDE|VFL|VFR|VFC|VSL|VSR|FC_BODY|FC_MID|
#          FC_PRESENCE|FC_SIBILANCE|I|LRA|PEAK|SUR_STATS..."
# ────────────────────────────────────────────────────────────────────────────────
measure_all_rms() {
  local f="$1" stream="$2"
  local log_file progress_file sl_window_log sr_window_log
  local sl_window_log_ff sr_window_log_ff ffmpeg_pid ffmpeg_rc processed last_processed=""
  log_file=$(mktemp -p "$ANALYZER_TMPDIR")
  progress_file=$(mktemp -p "$ANALYZER_TMPDIR")
  sl_window_log=$(mktemp -p "$ANALYZER_TMPDIR")
  sr_window_log=$(mktemp -p "$ANALYZER_TMPDIR")
  sl_window_log_ff=$(ffmpeg_filter_path "$sl_window_log") || return 1
  sr_window_log_ff=$(ffmpeg_filter_path "$sr_window_log") || return 1

  ffmpeg -y -nostdin -hide_banner -nostats \
    -stats_period "$ANALYZER_PROGRESS_INTERVAL" -progress "$progress_file" \
    -i "$f" \
    -filter_complex "[0:${stream}]asplit=7[full][voice][mid_in][side_in][fc_bands_in][sur_windows_in][ebu];\
[full]astats@full=${ASTATS_RMS_OPTS},anullsink;\
[voice]highpass=f=250,lowpass=f=5000,astats@voice=${ASTATS_RMS_OPTS},anullsink;\
[mid_in]pan=1c|c0=0.5*c4+0.5*c5,astats@mid=${ASTATS_RMS_OPTS},anullsink;\
[side_in]pan=1c|c0=0.5*c4-0.5*c5,astats@side=${ASTATS_RMS_OPTS},anullsink;\
[fc_bands_in]pan=1c|c0=c2,asplit=4[fc_body_in][fc_mid_in][fc_presence_in][fc_sibilance_in];\
[fc_body_in]highpass=f=250,lowpass=f=800,astats@fc_body=${ASTATS_RMS_OPTS},anullsink;\
[fc_mid_in]highpass=f=800,lowpass=f=1600,astats@fc_mid=${ASTATS_RMS_OPTS},anullsink;\
[fc_presence_in]highpass=f=1600,lowpass=f=4000,astats@fc_presence=${ASTATS_RMS_OPTS},anullsink;\
[fc_sibilance_in]highpass=f=5000,lowpass=f=9000,astats@fc_sibilance=${ASTATS_RMS_OPTS},anullsink;\
[sur_windows_in]asplit=2[sl_window_in][sr_window_in];\
[sl_window_in]pan=1c|c0=c4,aformat=sample_rates=48000:sample_fmts=fltp,asetnsamples=n=48000:p=1,astats=metadata=1:reset=1:measure_perchannel=RMS_level+Crest_factor:measure_overall=none,ametadata=mode=print:file='${sl_window_log_ff}':direct=1,anullsink;\
[sr_window_in]pan=1c|c0=c5,aformat=sample_rates=48000:sample_fmts=fltp,asetnsamples=n=48000:p=1,astats=metadata=1:reset=1:measure_perchannel=RMS_level+Crest_factor:measure_overall=none,ametadata=mode=print:file='${sr_window_log_ff}':direct=1,anullsink;\
[ebu]ebur128=peak=sample:framelog=verbose[o0]" \
    -map "[o0]" \
    -vn -sn -f null - \
    >/dev/null 2>"$log_file" </dev/null &
  ffmpeg_pid=$!

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep 2
    processed=$(awk -F= '$1 == "out_time" { value=$2 } END { print value }' "$progress_file" 2>/dev/null)
    if [[ -n "$processed" && "$processed" != "$last_processed" ]]; then
      printf '%b Audio analizzato: %s\n' "$C_PROGRESS" "$processed" >&2
      last_processed="$processed"
    fi
  done
  wait "$ffmpeg_pid"
  ffmpeg_rc=$?
  if (( ffmpeg_rc != 0 )); then
    rm -f "$log_file" "$progress_file" "$sl_window_log" "$sr_window_log"
    return 1
  fi

  local rms_values ebu_values sur_stats
  rms_values=$(awk '
  /Channel:/ {
    if      (index($0,"[astats@full "))  full_channel=$NF
    else if (index($0,"[astats@voice ")) voice_channel=$NF
    next
  }
  /RMS level dB:/ {
    if (index($0,"[astats@full ")) {
      if      (full_channel == 1) fl=$NF
      else if (full_channel == 2) fr=$NF
      else if (full_channel == 3) fc=$NF
      else if (full_channel == 5) sl=$NF
      else if (full_channel == 6) sr=$NF
    } else if (index($0,"[astats@voice ")) {
      if      (voice_channel == 1) vfl=$NF
      else if (voice_channel == 2) vfr=$NF
      else if (voice_channel == 3) vfc=$NF
      else if (voice_channel == 5) vsl=$NF
      else if (voice_channel == 6) vsr=$NF
    } else if (index($0,"[astats@mid "))           mid=$NF
      else if (index($0,"[astats@side "))          side=$NF
      else if (index($0,"[astats@fc_body "))       fc_body=$NF
      else if (index($0,"[astats@fc_mid "))        fc_mid=$NF
      else if (index($0,"[astats@fc_presence "))   fc_presence=$NF
      else if (index($0,"[astats@fc_sibilance "))  fc_sibilance=$NF
  } END { printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s", fl,fr,fc,sl,sr,mid,side,vfl,vfr,vfc,vsl,vsr,fc_body,fc_mid,fc_presence,fc_sibilance }' "$log_file")
  ebu_values=$(parse_ebur128_summary "$log_file") || {
    rm -f "$log_file" "$progress_file" "$sl_window_log" "$sr_window_log"
    return 1
  }
  # La transient analysis e' qualitativa: un errore di parsing/statistica non deve
  # invalidare RMS, loudness, FC profile e scelta preset gia' misurati correttamente.
  # In caso di errore degrada a metriche non disponibili; classify_sur_profile()
  # applichera' il fallback prudenziale MIXED con confidenza bassa.
  if ! sur_stats=$(measure_surround_transients "$sl_window_log" "$sr_window_log"); then
    warn "Analisi transient surround non disponibile: fallback MIXED." >&2
    sur_stats="0|0|N/A|N/A|N/A|N/A|N/A|N/A|N/A|0.0|0.0"
  fi
  rm -f "$log_file" "$progress_file" "$sl_window_log" "$sr_window_log"

  echo "${rms_values}|${ebu_values}|${sur_stats}"
}

# Media energetica in dB di due o tre valori RMS. I valori devono essere finiti.
power_mean_db() {
  awk -v a="$1" -v b="$2" -v c="${3:-}" 'BEGIN {
    if (c == "") p=(10^(a/10)+10^(b/10))/2;
    else         p=(10^(a/10)+10^(b/10)+10^(c/10))/3;
    printf "%.1f", 10*log(p)/log(10);
  }'
}

db_floor_for_math() {
  if [[ "$1" == "-inf" ]]; then
    echo "-120.0"
  elif is_finite_db "$1"; then
    echo "$1"
  else
    return 1
  fi
}

sur_activity_desc() {
  local active="$1" total="$2"
  if ! [[ "$active" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || (( total <= 0 )); then
    echo "N/A"; return
  fi
  local pct=$(( active * 100 / total ))
  if (( pct >= 70 )); then echo "ALTA"
  elif (( pct >= 35 )); then echo "MEDIA"
  elif (( pct > 0 )); then echo "BASSA"
  else echo "ASSENTE"
  fi
}

crest_typical_desc() {
  local v="$1"
  is_finite_db "$v" || { echo "N/A"; return; }
  if awk -v x="$v" 'BEGIN{exit !(x < 8)}'; then echo "BASSI"
  elif awk -v x="$v" 'BEGIN{exit !(x < 14)}'; then echo "MODERATI"
  elif awk -v x="$v" 'BEGIN{exit !(x < 20)}'; then echo "ELEVATI"
  else echo "MOLTO ELEVATI"
  fi
}

crest_strong_desc() {
  local v="$1"
  is_finite_db "$v" || { echo "N/A"; return; }
  if awk -v x="$v" 'BEGIN{exit !(x < 14)}'; then echo "BASSI"
  elif awk -v x="$v" 'BEGIN{exit !(x < 20)}'; then echo "ELEVATI"
  elif awk -v x="$v" 'BEGIN{exit !(x < 25)}'; then echo "MOLTO ELEVATI"
  else echo "ESTREMI"
  fi
}

crest_rare_desc() {
  local v="$1"
  is_finite_db "$v" || { echo "N/A"; return; }
  if awk -v x="$v" 'BEGIN{exit !(x < 12)}'; then echo "BASSI"
  elif awk -v x="$v" 'BEGIN{exit !(x < 18)}'; then echo "MODERATI"
  elif awk -v x="$v" 'BEGIN{exit !(x < 24)}'; then echo "MOLTO ELEVATI"
  else echo "ESTREMI"
  fi
}

tail_desc() {
  local v="$1"
  is_finite_db "$v" || { echo "N/A"; return; }
  if awk -v x="$v" 'BEGIN{exit !(x <= 5)}'; then echo "STRETTA"
  elif awk -v x="$v" 'BEGIN{exit !(x <= 9)}'; then echo "MEDIA"
  else echo "AMPIA"
  fi
}

hot_desc() {
  local v="$1"
  is_finite_db "$v" || { echo "N/A"; return; }
  if awk -v x="$v" 'BEGIN{exit !(x <= 1)}'; then echo "ASSENTI/RARI"
  elif awk -v x="$v" 'BEGIN{exit !(x < 5)}'; then echo "RARI"
  elif awk -v x="$v" 'BEGIN{exit !(x < 12)}'; then echo "FREQUENTI"
  else echo "MOLTO FREQUENTI"
  fi
}

sur_profile_interpretation() {
  case "$1" in
    AMBIENT) echo "surround prevalentemente continui/atmosferici; massima spazialita'" ;;
    TRANSIENT) echo "transienti forti e ricorrenti; priorita' al punch" ;;
    *) echo "transienti presenti ma non dominanti; compromesso tra spazialita' e punch" ;;
  esac
}

sur_processing_desc() {
  case "$1" in
    AMBIENT) echo "delay 0% | late 0% | air 0%" ;;
    TRANSIENT) echo "delay -30% | late -45% | air -25%" ;;
    *) echo "delay -10% | late -15% | air -10%" ;;
  esac
}

fc_intervention_desc() {
  case "$1" in
    DARK) echo "lieve recupero della presenza" ;;
    BRIGHT) echo "lieve contenimento della presenza" ;;
    SIBILANT) echo "lieve contenimento della coda alta/sibilanza" ;;
    *) echo "nessuna correzione tonale aggiuntiva" ;;
  esac
}

# ────────────────────────────────────────────────────────────────────────────────
# Analisi Delta (bilanciamento canali SUR vs FC)
# ────────────────────────────────────────────────────────────────────────────────
scan_delta() {
  local f="$1"
  info "Avvio analisi Delta SUR-FC su: $f"
  # Seleziono lo stream migliore usando la stessa logica del processore: preferenza per 6 canali, traccia default, lingua italiana. Restituisce "stream_index canali layout". Se non riesco a trovare stream validi, esco con warning e codice di errore.
  local stream_info
  stream_info=$(pick_best_stream "$f")
  local target_stream="${stream_info%% *}"
  local rest="${stream_info#* }"
  local max_ch="${rest%% *}"
  local layout="${rest#* }"
  # Se pick_best_stream non riesce a trovare stream validi, esce con warning e codice di errore. Controllo robusto: se target_stream non è un numero valido, esco con warning e codice di errore.
  if [[ -z "$target_stream" ]]; then
    warn "Impossibile determinare stream target. File saltato."
    return 1
  fi
  # Controllo robusto: se max_ch non è un numero valido, esco con warning e codice di errore.
  if ! [[ "$max_ch" =~ ^[0-9]+$ ]] || [[ "$max_ch" -ne 6 ]]; then
    warn "Stream [$target_stream] ha '${max_ch:-?}' canali (non 5.1). Delta richiede esattamente 6 canali. Saltato."
    return 1
  fi
  info "Stream selezionato: [$target_stream], ${max_ch} canali, layout ${layout:-unknown}."

  local source_class
  source_class=$(detect_source_class "$f")
  if [[ "$source_class" == "ATMOS" ]]; then
    info "Origine: ATMOS rilevata dal tag della traccia originale; bias SONAR solo borderline."
  else
    info "Origine: nessun tag Atmos originale rilevato; classifier standard."
  fi

  # Mapping posizionale robusto, allineato al processore principale: nell'ordine
  # canonico 5.1 c2 e' FC, c4/c5 sono i surround. Non dipende dai nomi del layout.
  case "$layout" in
    "5.1(side)")
      info "Layout audio 5.1(side): mapping posizionale FC=c2, SL=c4, SR=c5." ;;
    "5.1"|"5.1(back)")
      info "Layout audio ${layout}: mapping posizionale; c4/c5 diventano SL/SR." ;;
    *)
      warn "Layout audio '${layout:-unknown}' non standard: mapping posizionale sicuro c0..c5." ;;
  esac

  # PASS A e PASS B restano separati logicamente, ma condividono la decodifica:
  # il contenitore video viene quindi letto una sola volta per file.
  info "PASS A/B combinato: Loudness, LRA, Sample Peak, RMS, Width e banda voce..."
  local all_rms rms_fl rms_fr rms_fc rms_sl rms_sr rms_mid rms_side
  local rms_vfl rms_vfr rms_vfc rms_vsl rms_vsr i_full lra_full input_peak_full
  local fc_body fc_mid fc_presence fc_sibilance
  local sur_total_windows sur_active_windows crest_p50 crest_p90 crest_p95 crest_p99 crest_max
  local tail95 tail99 hot22 hot25
  all_rms=$(measure_all_rms "$f" "$target_stream") || {
    warn "Analisi combinata non conclusiva o summary EBU R128 non valido. File saltato."
    return 1
  }
  IFS='|' read -r rms_fl rms_fr rms_fc rms_sl rms_sr rms_mid rms_side \
    rms_vfl rms_vfr rms_vfc rms_vsl rms_vsr fc_body fc_mid fc_presence fc_sibilance \
    i_full lra_full input_peak_full sur_total_windows sur_active_windows \
    crest_p50 crest_p90 crest_p95 crest_p99 crest_max tail95 tail99 hot22 hot25 <<<"$all_rms"

  # Il picco distingue il vero silenzio dal valore sentinella -70 LUFS
  # restituito da ebur128 per una traccia digitalmente vuota.
  if [[ "$input_peak_full" == "-inf" ]]; then
    warn "Traccia audio digitalmente silenziosa. File saltato."
    return 1
  fi
  if ! is_finite_db "$input_peak_full"; then
    warn "Sample Peak globale non misurabile. File saltato."
    return 1
  fi
  if awk -v peak="$input_peak_full" -v gate="$ANALYZER_SILENCE_PEAK_DB" 'BEGIN { exit !(peak <= gate) }'; then
    warn "Traccia audio quasi silenziosa (Sample Peak ${input_peak_full} dBFS). File saltato."
    return 1
  fi

  local fl_math fr_math fc_math sl_math sr_math
  fl_math=$(db_floor_for_math "$rms_fl") || { warn "RMS FL non misurabile. File saltato."; return 1; }
  fr_math=$(db_floor_for_math "$rms_fr") || { warn "RMS FR non misurabile. File saltato."; return 1; }
  fc_math=$(db_floor_for_math "$rms_fc") || { warn "RMS FC non misurabile. File saltato."; return 1; }
  sl_math=$(db_floor_for_math "$rms_sl") || { warn "RMS SL non misurabile. File saltato."; return 1; }
  sr_math=$(db_floor_for_math "$rms_sr") || { warn "RMS SR non misurabile. File saltato."; return 1; }

  local rms_sur rms_front rms_main delta_sur delta_fc balance_sur
  rms_sur=$(power_mean_db "$sl_math" "$sr_math")
  rms_front=$(power_mean_db "$fl_math" "$fr_math")
  rms_main=$(power_mean_db "$fl_math" "$fr_math" "$fc_math")
  delta_sur=$(awk -v sur="$rms_sur" -v main="$rms_main" 'BEGIN { printf "%.1f", sur-main }')
  delta_fc=$(awk -v fc="$fc_math" -v front="$rms_front" 'BEGIN { printf "%.1f", fc-front }')
  balance_sur=$(awk -v sl="$sl_math" -v sr="$sr_math" 'BEGIN { d=sl-sr; if(d<0)d=-d; printf "%.1f", d }')

  # Prominenza del parlato e rischio di mascheramento nella banda utile alla
  # voce. Se tutta la banda e' praticamente vuota, non la usiamo per decidere:
  # il classificatore ricade sul controllo full-band del centrale.
  local vfl_math vfr_math vfc_math vsl_math vsr_math
  vfl_math=$(db_floor_for_math "$rms_vfl") || { warn "RMS voice-band FL non misurabile. File saltato."; return 1; }
  vfr_math=$(db_floor_for_math "$rms_vfr") || { warn "RMS voice-band FR non misurabile. File saltato."; return 1; }
  vfc_math=$(db_floor_for_math "$rms_vfc") || { warn "RMS voice-band FC non misurabile. File saltato."; return 1; }
  vsl_math=$(db_floor_for_math "$rms_vsl") || { warn "RMS voice-band SL non misurabile. File saltato."; return 1; }
  vsr_math=$(db_floor_for_math "$rms_vsr") || { warn "RMS voice-band SR non misurabile. File saltato."; return 1; }

  local rms_voice_front rms_voice_sur rms_voice_main delta_voice voice_mask voice_metric_note
  rms_voice_front=$(power_mean_db "$vfl_math" "$vfr_math")
  rms_voice_sur=$(power_mean_db "$vsl_math" "$vsr_math")
  rms_voice_main=$(power_mean_db "$vfl_math" "$vfr_math" "$vfc_math")
  delta_voice=""
  voice_mask=""
  voice_metric_note="valida"
  if awk -v rms="$rms_voice_main" -v gate="$VOICE_BAND_RMS_GATE" 'BEGIN { exit !(rms >= gate) }'; then
    delta_voice=$(awk -v fc="$vfc_math" -v front="$rms_voice_front" 'BEGIN { printf "%.1f", fc-front }')
    voice_mask=$(awk -v sur="$rms_voice_sur" -v fc="$vfc_math" 'BEGIN { printf "%.1f", sur-fc }')
  else
    voice_metric_note="N/A: banda voce sotto ${VOICE_BAND_RMS_GATE} dBFS"
  fi

  local width_ms width_desc
  local mid_math side_math
  mid_math=$(db_floor_for_math "$rms_mid") || { warn "RMS MID non misurabile. File saltato."; return 1; }
  side_math=$(db_floor_for_math "$rms_side") || { warn "RMS SIDE non misurabile. File saltato."; return 1; }
  width_ms=$(awk -v side="$side_math" -v mid="$mid_math" 'BEGIN { printf "%.1f", side-mid }')
  width_desc=$(width_to_desc "$width_ms")

  # Profilo tonale FC indipendente dal livello relativo della voce. Le quattro
  # bande sono euristiche: se anche una sola non e' valida si torna a NORMAL.
  local presence_index="N/A" sibilance_index="N/A" fc_mid_index="N/A"
  local fc_profile="NORMAL" fc_profile_confidence="bassa"
  local fc_profile_reason="fallback: metrica FC non valida"
  local fc_profile_raw
  if is_finite_db "$fc_body" && is_finite_db "$fc_mid" && \
     is_finite_db "$fc_presence" && is_finite_db "$fc_sibilance"; then
    presence_index=$(awk -v p="$fc_presence" -v b="$fc_body" 'BEGIN { printf "%.1f", p-b }')
    sibilance_index=$(awk -v s="$fc_sibilance" -v p="$fc_presence" 'BEGIN { printf "%.1f", s-p }')
    fc_mid_index=$(awk -v m="$fc_mid" -v b="$fc_body" 'BEGIN { printf "%.1f", m-b }')
    fc_profile_raw=$(classify_fc_profile "$presence_index" "$sibilance_index" "$fc_mid_index")
    IFS='|' read -r fc_profile fc_profile_confidence fc_profile_reason <<<"$fc_profile_raw"
  fi

  local sur_profile="MIXED" sur_profile_confidence="bassa"
  local sur_profile_reason="fallback: metriche transienti non valide"
  local sur_profile_raw
  sur_profile_raw=$(classify_sur_profile "$sur_active_windows" "$crest_p50" "$crest_p95" "$tail95" "$hot22")
  IFS='|' read -r sur_profile sur_profile_confidence sur_profile_reason <<<"$sur_profile_raw"

  # Override di sicurezza: tracce surround assenti o fortemente sbilanciate non
  # sono materiale adatto a una scelta spaziale automatica.
  local forced_preset=0 preset_raw
  if [[ "$rms_sl" == "-inf" || "$rms_sr" == "-inf" ]] || \
     awk -v sur="$rms_sur" -v gate="$SUR_FAKE_RMS_GATE" 'BEGIN { exit !(sur < gate) }'; then
    warn "Surround virtualmente muti (${rms_sur} dBFS RMS): forzo VOICE."
    forced_preset=1
    preset_raw="VOICE|\033[1;33m|bassa|-|surround virtualmente muti"
  elif [[ "$rms_fc" == "-inf" ]]; then
    warn "Canale centrale silenzioso: forzo VOICE e richiedo controllo manuale."
    forced_preset=1
    preset_raw="VOICE|\033[1;33m|bassa|CHECK|centro silenzioso"
  elif awk -v b="$balance_sur" -v gate="$SUR_BALANCE_WARN_DB" 'BEGIN { exit !(b >= gate) }'; then
    warn "Sbilanciamento SL/SR elevato (${balance_sur} dB): VOICE prudenziale, controllo manuale consigliato."
    forced_preset=1
    preset_raw="VOICE|\033[1;33m|bassa|CHECK|sbilanciamento SL/SR"
  else
    preset_raw=$(classify_spatial_preset "$delta_sur" "$delta_fc" "$delta_voice" "$voice_mask" "$width_ms")
    preset_raw=$(apply_atmos_sonar_bias "$preset_raw" "$source_class" "$sur_profile" "$delta_sur")
  fi

  # Loudness integrata, LRA e picco sono gia' stati misurati nel ramo PASS A.
  local volamp_raw volamp volamp_desc volume_status volamp_note
  volamp_raw=$(loudness_to_volamp "$i_full")
  volamp=$(cap_volamp_by_lra "$volamp_raw" "$lra_full")
  volamp_desc=$(volamp_to_desc "$volamp")
  volume_status=$(source_volume_status "$volamp")
  volamp_note=""
  [[ "$volamp" != "$volamp_raw" ]] && volamp_note=" cap LRA"

  local preset p_color confidence alternative preset_reason
  IFS='|' read -r preset p_color confidence alternative preset_reason <<<"$preset_raw"
  local source_bias_applied="no"
  [[ "$preset_reason" == "bias Atmos conservativo:"* ]] && source_bias_applied="sonar"
  if (( forced_preset == 0 )) && \
     awk -v b="$balance_sur" -v gate="$SUR_BALANCE_WARN_DB" -v margin="$PRESET_BORDERLINE_MARGIN" \
       'BEGIN { exit !(b < gate && (gate-b) <= margin) }'; then
    confidence="bassa"
    alternative="CHECK"
    preset_reason="${preset_reason} (borderline sbilanciamento)"
  fi

  # Accumulo risultati per verdetto stagionale e tabella finale. Se il preset è stato forzato, uso comunque il Delta reale per il verdetto stagionale, perché riflette la realtà del mix, ma segnalo il preset forzato nella tabella per chiarezza.
  GLOBAL_METRIC_VALUES+=("$delta_sur")
  GLOBAL_METRIC_FILES+=("$(basename "$f")")
  GLOBAL_METRIC_PATHS+=("$f")
  GLOBAL_LOUDNESS_VALUES+=("${i_full:-N/A}")
  GLOBAL_INPUT_PEAK_VALUES+=("${input_peak_full:-N/A}")
  GLOBAL_FC_BODY_VALUES+=("${fc_body:-N/A}")
  GLOBAL_FC_MID_VALUES+=("${fc_mid:-N/A}")
  GLOBAL_FC_PRESENCE_VALUES+=("${fc_presence:-N/A}")
  GLOBAL_FC_SIBILANCE_VALUES+=("${fc_sibilance:-N/A}")
  GLOBAL_PRESENCE_INDEX_VALUES+=("$presence_index")
  GLOBAL_SIBILANCE_INDEX_VALUES+=("$sibilance_index")
  GLOBAL_FC_PROFILE_VALUES+=("$fc_profile")
  GLOBAL_FC_CONFIDENCE_VALUES+=("$fc_profile_confidence")
  GLOBAL_SUR_ACTIVE_VALUES+=("${sur_active_windows:-0}/${sur_total_windows:-0}")
  GLOBAL_CREST_P50_VALUES+=("${crest_p50:-N/A}")
  GLOBAL_CREST_P90_VALUES+=("${crest_p90:-N/A}")
  GLOBAL_CREST_P95_VALUES+=("${crest_p95:-N/A}")
  GLOBAL_CREST_P99_VALUES+=("${crest_p99:-N/A}")
  GLOBAL_CREST_MAX_VALUES+=("${crest_max:-N/A}")
  GLOBAL_TAIL95_VALUES+=("${tail95:-N/A}")
  GLOBAL_TAIL99_VALUES+=("${tail99:-N/A}")
  GLOBAL_HOT22_VALUES+=("${hot22:-0.0}")
  GLOBAL_HOT25_VALUES+=("${hot25:-0.0}")
  GLOBAL_SUR_PROFILE_VALUES+=("$sur_profile")
  GLOBAL_SUR_CONFIDENCE_VALUES+=("$sur_profile_confidence")
  GLOBAL_SOURCE_CLASS_VALUES+=("$source_class")
  GLOBAL_SOURCE_BIAS_VALUES+=("$source_bias_applied")
  GLOBAL_VOLAMP_VALUES+=("$volamp")
  GLOBAL_WIDTH_VALUES+=("${width_ms:-N/A}")
  GLOBAL_LRA_VALUES+=("${lra_full:-N/A}")
  GLOBAL_PRESET_VALUES+=("$preset")
  GLOBAL_PRESET_FORCED_VALUES+=("$forced_preset")
  GLOBAL_CENTER_DELTA_VALUES+=("$delta_fc")
  GLOBAL_VOICE_DELTA_VALUES+=("${delta_voice:-N/A}")
  GLOBAL_VOICE_MASK_VALUES+=("${voice_mask:-N/A}")
  GLOBAL_BALANCE_VALUES+=("$balance_sur")
  GLOBAL_CONFIDENCE_VALUES+=("$confidence")
  GLOBAL_ALTERNATIVE_VALUES+=("$alternative")
  GLOBAL_REASON_VALUES+=("$preset_reason")

  # Display dei risultati per il file, con colori e descrizioni. Se alcune metriche non sono misurabili, le segnalo come N/A. Se il preset è stato forzato, mostro comunque il preset forzato ma con la descrizione che indica la ragione.
  ok "Risultati Classifier per: $f"
  echo -e "  \033[1;33mRMS MAIN: \033[0m  ${rms_main} dBFS  (media energetica FL/FR/FC)"
  echo -e "  \033[1;33mRMS SUR:  \033[0m  ${rms_sur} dBFS  (media energetica SL/SR)"
  echo -e "  \033[1;37mDeltaSur: \033[0m  ${p_color}${delta_sur} dB\033[0m  (SUR - MAIN)"
  echo -e "  \033[1;37mDeltaFC:  \033[0m  ${delta_fc} dB  (FC - FRONT)"
  echo -e "  \033[1;33mVoiceDelta:\033[0m ${delta_voice:-N/A} dB  (FC - FRONT, 250-5000 Hz; ${voice_metric_note})"
  echo -e "  \033[1;33mVoiceMask: \033[0m ${voice_mask:-N/A} dB  (SUR - FC, 250-5000 Hz; alto = piu' rischio)"
  echo -e "  \033[1;37mBalance:  \033[0m  ${balance_sur} dB  (|SL - SR|)"
  echo -e "  \033[1;36mWidth MS: \033[0m  ${width_ms} dB  (${width_desc}; SIDE - MID SL/SR)"
  echo -e "  \033[1;33mI(full):  \033[0m  ${i_full:-N/A} LUFS"
  echo -e "  \033[1;33mLRA:      \033[0m  ${lra_full:-N/A} LU  (solo cap volamp)"
  printf "  \033[1;33m%-11s\033[0m %s dBFS  (diagnostica; non seleziona il preset)\n" \
    "Sample Peak:" "$input_peak_full"
  echo ""
  echo -e "  \033[1;36mSOURCE\033[0m"
  if [[ "$source_class" == "ATMOS" ]]; then
    echo -e "    Origine:       ATMOS — tag '${ATMOS_ORIGINAL_TITLE}' rilevato"
    if [[ "$source_bias_applied" == "sonar" ]]; then
      echo -e "    Influenza:     bias SONAR applicato solo in zona borderline"
    else
      echo -e "    Influenza:     nessun override; classifier guidato dal contenuto"
    fi
  else
    echo -e "    Origine:       UNKNOWN / standard"
    echo -e "    Influenza:     nessun bias Atmos"
  fi
  echo ""
  echo -e "  \033[1;35mVOICE TONALITY\033[0m"
  echo -e "    Profilo:      ${fc_profile} — ${fc_profile_reason}"
  echo -e "    Intervento:   $(fc_intervention_desc "$fc_profile")"
  echo -e "    Confidenza:   ${fc_profile_confidence}"
  echo -e "    Dettagli:     PresenceIndex=${presence_index} dB | SibilanceIdx=${sibilance_index} dB"
  echo ""
  echo -e "  \033[1;34mSURROUND DYNAMICS\033[0m"
  echo -e "    Attivita':          $(sur_activity_desc "${sur_active_windows:-0}" "${sur_total_windows:-0}")"
  echo -e "    Transienti tipici:  $(crest_typical_desc "${crest_p50:-N/A}")"
  echo -e "    Transienti forti:   $(crest_strong_desc "${crest_p95:-N/A}")"
  echo -e "    Eventi rari:        $(crest_rare_desc "${crest_p99:-N/A}")"
  echo -e "    Coda dinamica:      $(tail_desc "${tail95:-N/A}")"
  echo -e "    Impulsi forti:      $(hot_desc "${hot22:-0.0}")"
  echo ""
  echo -e "    Profilo:            ${sur_profile}"
  echo -e "    Interpretazione:    $(sur_profile_interpretation "$sur_profile")"
  echo -e "    Processing:         $(sur_processing_desc "$sur_profile")"
  echo -e "    Confidenza:         ${sur_profile_confidence}"
  echo -e "  \033[1;37mPreset:   \033[0m  ${p_color}${preset}\033[0m  (${preset_reason})"
  echo -e "  \033[1;37mConfid.:  \033[0m  ${confidence}  | alternativa: ${alternative}"
  echo -e "  \033[1;37mVolume:   \033[0m  \033[1;36m${volume_status}\033[0m"
  echo -e "  \033[1;37mVolamp:   \033[0m  \033[1;36m${volamp} dB\033[0m  (${volamp_desc}${volamp_note})"
  echo ""
}

# ────────────────────────────────────────────────────────────────────────────────
# CICLO PRINCIPALE
# ────────────────────────────────────────────────────────────────────────────────
# Per ogni file, analizzo la struttura audio e poi eseguo l'analisi Delta. Se la struttura audio non è valida (es. nessuna traccia, traccia non 5.1), salto il file con un warning. I risultati di ogni file vengono accumulati in array globali per il verdetto stagionale e la tabella finale.
for CUR_FILE in "${FILES[@]}"; do
  info "Analisi: $CUR_FILE"
  scan_delta "$CUR_FILE"
done

# ────────────────────────────────────────────────────────────────────────────────
# VERDETTO STAGIONALE / GENERAZIONE BATCH
# Preset modale per-file; consenso < 2/3, parita' o spread DeltaSur > 4 dB -> MIXED.
# ────────────────────────────────────────────────────────────────────────────────
if [[ "${#GLOBAL_METRIC_VALUES[@]}" -gt 0 ]]; then
  CNT=${#GLOBAL_METRIC_VALUES[@]}
  HIGH_SPREAD=0

  # Se ho più di un episodio, calcolo statistiche (min, max, media, P25) per il verdetto stagionale. Uso file temporanei e awk per gestire i calcoli in modo robusto e preciso, evitando problemi di formattazione o precisione nei passaggi di variabili. Se ho un solo episodio, uso direttamente quel valore per tutte le statistiche.
  if [[ "$CNT" -gt 1 ]]; then
    _vals_tmp=$(mktemp -p "$ANALYZER_TMPDIR")
    printf '%s\n' "${GLOBAL_METRIC_VALUES[@]}" > "$_vals_tmp"
    # Calcolo statistiche con awk: ordino i valori, prendo min (primo), max (ultimo), media (somma/n) e P25 (valore al rank 0.25*n). Se il calcolo fallisce per qualche motivo, esco con warning e codice di errore.
    _stats_tmp=$(mktemp -p "$ANALYZER_TMPDIR")
    awk '{v[NR]=$1+0} END{n=NR; for(i=2;i<=n;i++){k=v[i];j=i-1; while(j>=1&&v[j]>k){v[j+1]=v[j];j--}; v[j+1]=k}; mn=v[1];mx=v[n]; s=0;for(i=1;i<=n;i++)s+=v[i]; avg=s/n; raw=0.25*n;rank=int(raw);if(raw>rank)rank=rank+1; if(rank<1)rank=1;if(rank>n)rank=n; pctl=v[rank]; printf "%.1f %.1f %.1f %.1f\n",mn,mx,avg,pctl}' "$_vals_tmp" > "$_stats_tmp"
    
    # Leggo le statistiche calcolate da awk, che sono formattate con una cifra decimale. Se per qualche motivo la lettura fallisce, esco con warning e codice di errore.
    read -r m_min m_max m_avg m_pctl < "$_stats_tmp"
    rm -f "$_vals_tmp" "$_stats_tmp"
    # Calcolo lo spread come differenza tra max e min, formattato con una cifra decimale. Se lo spread è maggiore di 4 dB, considero la stagione eterogenea e suggerisco di considerare i preset per-file invece del verdetto stagionale.
    m_spread=$(awk -v mx="$m_max" -v mn="$m_min" 'BEGIN { s=mx-mn; if(s<0)s=-s; printf "%.1f",s }')
    HIGH_SPREAD=$(awk -v s="$m_spread" 'BEGIN { print (s > 4.0) ? 1 : 0 }')
  else
    m_min="${GLOBAL_METRIC_VALUES[0]}"
    m_max="${GLOBAL_METRIC_VALUES[0]}"
    m_avg="${GLOBAL_METRIC_VALUES[0]}"
    m_pctl="${GLOBAL_METRIC_VALUES[0]}"
    m_spread="0.0"
  fi
  # Il verdetto stagionale deriva dai preset finali per-file e conserva quindi
  # DeltaFC, VoiceDelta, VoiceMask e Width. Il batch resta sempre per-file.
  declare -A PRESET_COUNTS=()
  for p in "${GLOBAL_PRESET_VALUES[@]}"; do
    PRESET_COUNTS[$p]=$(( ${PRESET_COUNTS[$p]:-0} + 1 ))
  done
  dominant_preset=""; dominant_count=0; dominant_tie=0
  preset_distribution=""
  for p in SONAR AURA WIDE AEGIS VOICE; do
    p_count="${PRESET_COUNTS[$p]:-0}"
    (( p_count > 0 )) && preset_distribution+="${p}:${p_count} "
    if (( p_count > dominant_count )); then
      dominant_preset="$p"; dominant_count=$p_count; dominant_tie=0
    elif (( p_count == dominant_count && p_count > 0 )); then
      dominant_tie=1
    fi
  done

  low_confidence_count=0
  forced_count=0
  for (( i=0; i<CNT; i++ )); do
    [[ "${GLOBAL_CONFIDENCE_VALUES[$i]}" == "bassa" ]] && low_confidence_count=$((low_confidence_count + 1))
    [[ "${GLOBAL_PRESET_FORCED_VALUES[$i]}" == "1" ]] && forced_count=$((forced_count + 1))
  done

  season_preset="$dominant_preset"
  season_desc="preset piu' frequente tra le decisioni per-file"
  # Oltre alla parita', richiedo almeno due terzi di consenso: una maggioranza
  # debole non e' una base sufficiente per suggerire un preset unico.
  if (( dominant_tie == 1 || HIGH_SPREAD == 1 || dominant_count * 3 < CNT * 2 )); then
    season_preset="MIXED"
    season_color="\033[1;37m"
    season_desc="nessun preset unico affidabile; usare le decisioni per-file"
  else
    season_color="$(preset_color "$season_preset")"
  fi
  # Display del verdetto stagionale, con statistiche e preset consigliato. Se lo spread è alto, avverto che la stagione è eterogenea e suggerisco di considerare i preset per-file, che mostro in una tabella con i nomi dei file (troncati se troppo lunghi), i valori di Delta e i preset consigliati per ciascun file, con colori.
  if [[ "$CNT" -gt 1 ]]; then
    echo -e "  Episodi analizzati:  \033[1;37m${CNT}\033[0m"
    echo -e "  DeltaSur medio:      \033[0;37m${m_avg} dB\033[0m"
    echo -e "  DeltaSur P25:        \033[0;37m${m_pctl} dB\033[0m  (solo diagnostica)"
    echo -e "  Range DeltaSur:      \033[0;37m${m_min} / ${m_max} dB  (spread: ${m_spread} dB)\033[0m"
    echo -e "  Distribuzione:       \033[0;37m${preset_distribution% }\033[0m"
    echo -e "  Decisioni incerte:   \033[0;37m${low_confidence_count}/${CNT}\033[0m"
    echo -e "  Preset Consigliato:  ${season_color}${season_preset}\033[0m  (${season_desc})"

    # Se alcuni file hanno preset forzati a VOICE a causa di surround virtualmente muti, conto quanti sono e mostro una nota che indica quanti file hanno questo problema, per dare un'indicazione aggiuntiva sulla natura della stagione.
    if [[ "$forced_count" -gt 0 ]]; then
      echo -e "  \033[0;33mNota: ${forced_count} file con override di sicurezza; verificare le righe per-file.\033[0m"
    fi 
    # Se ho valori di volamp consigliati per-file, calcolo anche il volamp stagionale come P75 prudente della loudness integrata, per dare un'indicazione aggiuntiva sul livello di boost consigliato a livello stagionale. Uso un file temporaneo e awk per calcolare il P75, che è un valore prudente per il boost consigliato, evitando di essere influenzato da outlier con volamp molto alti.
    if [[ ${#GLOBAL_VOLAMP_VALUES[@]} -gt 0 ]]; then
      _volamp_tmp=$(mktemp -p "$ANALYZER_TMPDIR")
      printf '%s\n' "${GLOBAL_VOLAMP_VALUES[@]}" > "$_volamp_tmp"
      season_volamp=$(awk '{v[NR]=$1+0} END{n=NR; for(i=2;i<=n;i++){k=v[i];j=i-1; while(j>=1&&v[j]>k){v[j+1]=v[j];j--}; v[j+1]=k}; raw=0.75*n;rank=int(raw);if(raw>rank)rank=rank+1; if(rank<1)rank=1;if(rank>n)rank=n; printf "%.1f",v[rank]}' "$_volamp_tmp")
      rm -f "$_volamp_tmp"
      echo -e "  Volamp Stagionale:  \033[1;36m${season_volamp} dB\033[0m  (P75 prudente della loudness)"
    fi
    # Se il verdetto e' MIXED, mostro le metriche decisive per ogni file.
    if [[ "$season_preset" == "MIXED" ]]; then
      echo ""
      echo -e "  \033[0;33m   La stagione è eterogenea o non ha consenso sufficiente.\033[0m"
      echo -e "  \033[0;33m   Per risultati ottimali, considera i preset per-file:\033[0m"
      echo ""
      for (( i=0; i<CNT; i++ )); do
        pf_preset="${GLOBAL_PRESET_VALUES[$i]}"
        pf_color="$(preset_color "$pf_preset")"
        fname="${GLOBAL_METRIC_FILES[$i]}"
        (( ${#fname} > 50 )) && fname="${fname:0:47}..."
        printf "    %-50s  %b%-5s\033[0m  (Sur=%s, FC=%s, Voice=%s, Mask=%s dB, src=%s, conf=%s)\n" \
          "$fname" "$pf_color" "$pf_preset" "${GLOBAL_METRIC_VALUES[$i]}" \
          "${GLOBAL_CENTER_DELTA_VALUES[$i]}" "${GLOBAL_VOICE_DELTA_VALUES[$i]}" \
          "${GLOBAL_VOICE_MASK_VALUES[$i]}" "${GLOBAL_SOURCE_CLASS_VALUES[$i]}" "${GLOBAL_CONFIDENCE_VALUES[$i]}"
      done
    fi
  fi

  # ── Generazione batch file ─────────────────────────────────────────────────
  # Se ho risultati validi, genero un batch file con i comandi di processing consigliati per ogni file, usando i preset raffinati per-file se sono stati forzati o se la stagione è eterogenea, altrimenti usando il preset stagionale. Il batch file include commenti e istruzioni per l'utente, e ogni comando include un commento con le metriche rilevanti per quel file.
  BATCH_FILE="run_processing.sh"
  if [[ "$CREATE_RUN" == "si" ]]; then
    {
      echo '#!/usr/bin/env bash'
      echo "# ── Batch Clearvoice: analisi FC + dinamica surround ──"
      echo "# Data: $(date '+%Y-%m-%d %H:%M')"
      echo "# Metrica: DeltaSur + DeltaFC + VoiceDelta + VoiceMask + Balance + Width | preset sempre per-file"
      echo '#'
      echo '# Modifica le variabili sotto se necessario, poi lancia:'
      echo "#   ./${BATCH_FILE}"
      echo '#'
      echo ''
      echo '# ── CONFIGURAZIONE (modifica qui) ──'
      echo "CODEC=\"${BATCH_CODEC}\"        # ac3 | eac3"
      echo "KEEP=\"${BATCH_KEEP}\"           # si | no"
      echo "BITRATE=\"${BATCH_BITRATE}\"      # es. 448k, 640k, 768k"
      echo 'PROC="${PROC:-./aegis_sonar_wide_aura_voice_volamp_psycho.sh}"'
      echo ''
      echo '# ── COMANDI ──'
      echo "# Nota: l'ultimo parametro numerico e' il volamp consigliato per-file."
  
      # Per ogni file genero un comando usando sempre il preset raffinato per-file. Escludo gli output già processati.
      for (( i=0; i<CNT; i++ )); do
        case "${GLOBAL_METRIC_PATHS[$i]}" in
          *_AC3_Aegis.mkv|*_AC3_Sonar.mkv|*_AC3_Wide.mkv|*_AC3_Aura.mkv|*_AC3_Voice.mkv|\
          *_EAC3_Aegis.mkv|*_EAC3_Sonar.mkv|*_EAC3_Wide.mkv|*_EAC3_Aura.mkv|*_EAC3_Voice.mkv)
            continue
            ;;
        esac
        # Il batch usa SEMPRE il preset raffinato per-file gia' calcolato in scan_delta.
        # In questo modo non perde le metriche voce, Width e gli override di sicurezza.
        file_preset="${GLOBAL_PRESET_VALUES[$i]:-}"
        # Il preset stagionale e' solo diagnostico; fallback neutro se manca il per-file.
        [[ -z "$file_preset" ]] && file_preset="AEGIS"
        file_preset_lower="${file_preset,,}"
        file_volamp="${GLOBAL_VOLAMP_VALUES[$i]:-0}"
        file_loudness="${GLOBAL_LOUDNESS_VALUES[$i]:-N/A}"
        file_input_peak="${GLOBAL_INPUT_PEAK_VALUES[$i]:-N/A}"
        file_fc_body="${GLOBAL_FC_BODY_VALUES[$i]:-N/A}"
        file_fc_mid="${GLOBAL_FC_MID_VALUES[$i]:-N/A}"
        file_fc_presence="${GLOBAL_FC_PRESENCE_VALUES[$i]:-N/A}"
        file_fc_sibilance="${GLOBAL_FC_SIBILANCE_VALUES[$i]:-N/A}"
        file_presence_index="${GLOBAL_PRESENCE_INDEX_VALUES[$i]:-N/A}"
        file_sibilance_index="${GLOBAL_SIBILANCE_INDEX_VALUES[$i]:-N/A}"
        file_fc_profile="${GLOBAL_FC_PROFILE_VALUES[$i]:-NORMAL}"
        file_fc_confidence="${GLOBAL_FC_CONFIDENCE_VALUES[$i]:-bassa}"
        file_sur_active="${GLOBAL_SUR_ACTIVE_VALUES[$i]:-0/0}"
        file_crest_p50="${GLOBAL_CREST_P50_VALUES[$i]:-N/A}"
        file_crest_p90="${GLOBAL_CREST_P90_VALUES[$i]:-N/A}"
        file_crest_p95="${GLOBAL_CREST_P95_VALUES[$i]:-N/A}"
        file_crest_p99="${GLOBAL_CREST_P99_VALUES[$i]:-N/A}"
        file_crest_max="${GLOBAL_CREST_MAX_VALUES[$i]:-N/A}"
        file_tail95="${GLOBAL_TAIL95_VALUES[$i]:-N/A}"
        file_tail99="${GLOBAL_TAIL99_VALUES[$i]:-N/A}"
        file_hot22="${GLOBAL_HOT22_VALUES[$i]:-0.0}"
        file_hot25="${GLOBAL_HOT25_VALUES[$i]:-0.0}"
        file_sur_profile="${GLOBAL_SUR_PROFILE_VALUES[$i]:-MIXED}"
        file_sur_confidence="${GLOBAL_SUR_CONFIDENCE_VALUES[$i]:-bassa}"
        file_source_class="${GLOBAL_SOURCE_CLASS_VALUES[$i]:-UNKNOWN}"
        file_source_bias="${GLOBAL_SOURCE_BIAS_VALUES[$i]:-no}"
        file_width="${GLOBAL_WIDTH_VALUES[$i]:-N/A}"
        file_lra="${GLOBAL_LRA_VALUES[$i]:-N/A}"
        file_delta_fc="${GLOBAL_CENTER_DELTA_VALUES[$i]:-N/A}"
        file_delta_voice="${GLOBAL_VOICE_DELTA_VALUES[$i]:-N/A}"
        file_voice_mask="${GLOBAL_VOICE_MASK_VALUES[$i]:-N/A}"
        file_balance="${GLOBAL_BALANCE_VALUES[$i]:-N/A}"
        file_confidence="${GLOBAL_CONFIDENCE_VALUES[$i]:-N/A}"
        file_alternative="${GLOBAL_ALTERNATIVE_VALUES[$i]:--}"
        escaped_path=$(printf '%q' "${GLOBAL_METRIC_PATHS[$i]}")
  
        # Il commento conserva le metriche, la confidenza, l'alternativa e la provenienza.
        printf 'FC_PROFILE=%s SUR_PROFILE=%s SOURCE_CLASS=%s "$PROC" "$CODEC" "$KEEP" "$BITRATE" %s %s %s  # Source=%s AtmosBias=%s | DeltaSur=%s dB | DeltaFC=%s dB | VoiceDelta=%s dB | VoiceMask=%s dB | Balance=%s dB | Width=%s dB | conf=%s alt=%s | I=%s LUFS LRA=%s LU SamplePeak=%s dBFS | FCBody=%s FCMid=%s FCPresence=%s FCSibilance=%s dBFS | PresenceIndex=%s dB SibilanceIndex=%s dB FCconf=%s | SurWindows=%s CrestP50=%s P90=%s P95=%s P99=%s Max=%s Tail95=%s Tail99=%s Hot22=%s%% Hot25=%s%% SurConf=%s\n' \
          "${file_fc_profile,,}" "${file_sur_profile,,}" "${file_source_class,,}" "$file_preset_lower" "$file_volamp" "$escaped_path" "$file_source_class" "$file_source_bias" "${GLOBAL_METRIC_VALUES[$i]}" \
          "$file_delta_fc" "$file_delta_voice" "$file_voice_mask" "$file_balance" "$file_width" "$file_confidence" "$file_alternative" \
          "$file_loudness" "$file_lra" "$file_input_peak" "$file_fc_body" "$file_fc_mid" "$file_fc_presence" "$file_fc_sibilance" \
          "$file_presence_index" "$file_sibilance_index" "$file_fc_confidence" "$file_sur_active" \
          "$file_crest_p50" "$file_crest_p90" "$file_crest_p95" "$file_crest_p99" "$file_crest_max" \
          "$file_tail95" "$file_tail99" "$file_hot22" "$file_hot25" "$file_sur_confidence"
      done
  
      echo ''
      echo 'echo "Batch completato."'
    } > "$BATCH_FILE"
    # Rendo eseguibile il batch file generato e mostro un messaggio di conferma. Se per qualche motivo il batch file non è stato generato correttamente, esco con warning e codice di errore.
    chmod +x "$BATCH_FILE"
    ok "Batch file generato: ${BATCH_FILE}"
  else
    info "Generazione run_processing.sh disattivata (run=no)."
    info "Un eventuale run_processing.sh esistente non viene modificato o rimosso."
  fi
else
  if [[ "$CREATE_RUN" == "si" ]]; then
    warn "Nessun risultato Classifier valido: run_processing.sh non generato."
  else
    warn "Nessun risultato Classifier valido."
  fi
fi

echo -e ""
ok "Analisi completata. Nessun file audio e' stato modificato."
