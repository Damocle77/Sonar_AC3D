#!/usr/bin/env bash
set -uo pipefail

# ╭─────────────────────────────────────────────────────────────────────────────────╮
# │   audio_analyzer_volamp_psycho.sh - Luglio 2026                                 │
# │   By Sandro (D@mocle77) Sabbioni                                                │
# │                                                                                 │
# │   Sonda euristica per l'analisi offline di container multimediali 5.1.          │
# │   Misura il bilanciamento surround/centro e genera run_processing.sh            │
# │   per il processore aegis_sonar_wide_aura_voice_volamp_psycho.sh.               │
# │                                                                                 │
# │   METRICA UNICA:                                                                │
# │   Delta = I(SUR) - I(FC) in dB                                                  │
# │     - I(FC)  = loudness integrata del canale centrale                           │
# │     - I(SUR) = media energetica dei surround SL/SR o BL/BR                      │
# │                                                                                 │
# │   Valori negativi = surround piu' deboli del centro.                            │
# │   La metrica diagnostica direttamente cio' che il processore corregge:          │
# │   quanto la scena surround e' arretrata rispetto al parlato.                    │
# │                                                                                 │
# │   MAPPA PRESET (delta):                                                         │
# │     Delta < -13 dB       -> SONAR  (foldown molto schiacciato, ri-espansione)   │
# │     Delta -13/-10 dB     -> AURA   (surround deboli, allargamento prudente)     │
# │     Delta -10/-6 dB      -> WIDE   (surround medi, scena laterale)              │
# │     Delta -6/-2 dB       -> AEGIS  (surround buoni, controllo/bilanciamento)    │
# │     Delta > -2 dB        -> VOICE  (sur forti o centro coperto)                 │
# │                                                                                 │
# │   VERDETTO STAGIONALE:                                                          │
# │     Delta -> P25 (bias audiofilo verso episodi con surround piu' deboli).       │
# │   Se spread > 4 dB, suggerisce preset per-file.                                 │
# │                                                                                 │
# │   LRA non sceglie piu' il preset: viene misurata solo per limitare il volamp    │
# │   quando un mix cinematografico e' basso ma molto dinamico.                     │
# ╰─────────────────────────────────────────────────────────────────────────────────╯
# Note:
C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"

# Funzioni di log con colori: info, warn, err, ok. Usate per output coerente e facilmente distinguibile.
info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

# Controllo binari essenziali: ffmpeg, ffprobe, awk. Se uno manca, esco con errore. Importante per evitare errori a cascata nelle fasi successive quando si tenta di analizzare i file.
for _bin in ffmpeg ffprobe awk; do
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
  ./audio_analyzer_volamp_psycho.sh <file|directory|""> [codec] [keep] [bitrate] [run]
  ./audio_analyzer_volamp_psycho.sh --files <codec> <keep> <bitrate> [run] <file1> [file2 ...]

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

METRICA:
  DELTA = I(SUR) - I(FC)
  Misura il rapporto fra surround e centrale. Richiede tracce 5.1.

ESEMPI:
  ./audio_analyzer_volamp_psycho.sh "film.mkv"                         # Default: genera run_processing.sh
  ./audio_analyzer_volamp_psycho.sh "film.mkv" eac3 si 768k no         # Solo analisi, nessun batch
  ./audio_analyzer_volamp_psycho.sh "" eac3 no 448k si                 # Cartella corrente + batch
  ./audio_analyzer_volamp_psycho.sh . eac3 si 768k no                  # Cartella corrente, solo analisi
  ./audio_analyzer_volamp_psycho.sh --files eac3 si 768k no "ep01.mkv" "ep02.mkv"
  ./audio_analyzer_volamp_psycho.sh --files eac3 si 768k "ep01.mkv" "ep02.mkv"  
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
  INPUT_ARG="${1:-}"
  BATCH_CODEC="${2:-eac3}"
  BATCH_KEEP="${3:-no}"
  BATCH_BITRATE="${4:-}"
  CREATE_RUN="${5:-si}"
fi
# Valori di default
[[ -z "$BATCH_BITRATE" ]] && {
  [[ "$BATCH_CODEC" = "ac3" ]] && BATCH_BITRATE="640k" || BATCH_BITRATE="768k"
}

# Validazione
case "$BATCH_CODEC" in ac3|eac3) ;; *) err "Codec '$BATCH_CODEC' non valido. Usa ac3 o eac3."; usage ;; esac
case "$BATCH_KEEP" in si|no) ;; *) err "Keep '$BATCH_KEEP' non valido. Usa si o no."; usage ;; esac
case "$CREATE_RUN" in si|no) ;; *) err "Run '$CREATE_RUN' non valido. Usa si o no."; usage ;; esac
[[ "$BATCH_BITRATE" =~ ^[0-9]+([kKmM])?$ ]] || { err "Bitrate '$BATCH_BITRATE' non valido. Es: 448k, 640k, 768k."; usage; }
[[ "$BATCH_BITRATE" =~ [kKmM]$ ]] || BATCH_BITRATE="${BATCH_BITRATE}k"
# Nota: non controllo se i file in --files esistono qui, lo faccio dopo per permettere di passare anche file parzialmente inesistenti senza bloccare tutto.
if [[ "$MULTI_FILES_MODE" == true ]]; then
  info "Metrica: DELTA | Input: lista manuale (${#MULTI_FILES[@]} file) | Batch: ${BATCH_CODEC} / keep=${BATCH_KEEP} / ${BATCH_BITRATE} / run_processing=${CREATE_RUN}"
else
  info "Metrica: DELTA | Batch: ${BATCH_CODEC} / keep=${BATCH_KEEP} / ${BATCH_BITRATE} / run_processing=${CREATE_RUN}"
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

# Se la media energetica dei surround e' sotto questa soglia, trattiamo il file
# come falso 5.1 / front-heavy e forziamo un preset conservativo.
FAKE_SUR_GATE="-60.0"

# A Delta > -2 dB i surround sono forti rispetto al centro: due casi opposti.
# Se la loudness ASSOLUTA del centro e' >= a questa soglia -> buon mix immersivo (AEGIS).
# Se e' piu' bassa -> dialogo davvero coperto -> VOICE. Disambigua VOICE vs AEGIS.
VOICE_FC_GATE="-27.0"

# Width Mid/Side sotto questa soglia = surround collassati/stretti (poca separazione L/R).
# In quel caso, a parita' di Delta, una ricostruzione laterale (WIDE) rende di piu'
# di AURA/AEGIS. Non tocca SONAR (deficit estremo) ne' VOICE.
WIDTH_WIDE_GATE="-7.0"

info "Target loudness analitico: ${LOUDNESS_TARGET} LUFS"
info "Fake 5.1 gate surround: ${FAKE_SUR_GATE} LUFS"
info "Voice/Aegis gate centro: ${VOICE_FC_GATE} LUFS | Width->Wide gate: ${WIDTH_WIDE_GATE} dB"

# Variabili globali per il verdetto stagionale
GLOBAL_METRIC_VALUES=()
GLOBAL_METRIC_FILES=()
GLOBAL_METRIC_PATHS=()
GLOBAL_LOUDNESS_VALUES=()
GLOBAL_VOLAMP_VALUES=()
GLOBAL_WIDTH_VALUES=()
GLOBAL_LRA_VALUES=()
GLOBAL_PRESET_VALUES=()
GLOBAL_PRESET_FORCED_VALUES=()

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
# Probe: struttura tracce audio
# ────────────────────────────────────────────────────────────────────────────────
probe_audio_streams() {
  local f="$1"
  info "Struttura Audio: $f"
  # ffprobe con output CSV, poi mapfile per array. Gestione robusta di linee vuote e carriage return.
  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_tags=language,title \
    -of csv=p=0 "$f" 2>/dev/null </dev/null || true)
  # Rimozione carriage return per compatibilità Windows/Git Bash: ffprobe a volte emette linee con \r\n, che interferisce con mapfile.
  raw_data="${raw_data//$'\r'/}"
  # Se ffprobe non restituisce dati (es. file senza tracce audio), esco con warning e codice di errore.
  if [[ -z "$raw_data" ]]; then
    warn "Nessuna traccia audio trovata."
    return 1
  fi
  # Parsing robusto dell'output CSV: mapfile per array, gestione di linee vuote, e default per campi mancanti (es. canali, layout, lingua, titolo). Output formattato per display umano.
  local _A_LINES
  mapfile -t _A_LINES <<< "$raw_data"
  # Output formattato: "Stream [index]: Canali: X (layout) | Lingua: lang | Titolo: title"
  for line in "${_A_LINES[@]}"; do
    [[ -z "$line" ]] && continue
    IFS=',' read -r idx ch layout lang title <<<"$line"
    ch="${ch:-?}"
    layout="${layout:-unknown}"
    lang="${lang:-und}"
    title="${title:-}"
    echo "  -> Stream [$idx]: Canali: $ch ($layout) | Lingua: $lang | Titolo: $title"
  done
  echo "----------------------------------------------------------------------------"
}

# ────────────────────────────────────────────────────────────────────────────────
# Selezione stream con sistema a punteggio allineato al processore
# Score: 6 canali -> +1000, default -> +200, lingua italiana -> +300
# Restituisce: "stream_index canali layout"
# ────────────────────────────────────────────────────────────────────────────────
# Controllo robusto: se ffprobe non restituisce dati, esco con warning e codice di errore. Se nessuno stream è valido, esco con warning e codice di errore. Questo evita errori a cascata nelle fasi successive quando si tenta di analizzare un file senza tracce audio o con tracce non valide.
pick_best_stream() {
  local f="$1"
  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null </dev/null || true)
  raw_data="${raw_data//$'\r'/}"
  # Punteggio e selezione in linea con la logica del processore: preferenza per 6 canali, traccia default, lingua italiana.
  local best_idx=""
  local best_ch=0
  local best_layout="unknown"
  local best_score=-1

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
      # Punteggio: 6 canali -> +1000, default -> +200, lingua italiana -> +300. Allineato alla logica di scelta del processore.
      local score=0
      [[ "$ch" =~ ^[0-9]+$ && "$ch" -eq 6 ]] && score=$((score + 1000))
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

# ────────────────────────────────────────────────────────────────────────────────────────
# Classificazione preset in UN solo awk (meno subprocess: rilevante su Git Bash).
#   d     = Delta SUR-FC (obbligatorio)
#   i_fc  = loudness assoluta del centro (opz.): disambigua VOICE vs AEGIS a Delta>-2
#   width = width Mid/Side dei surround (opz.): se collassati -> WIDE (ricostr. laterale)
# Output: "PRESET|<colore-ansi>"
# ────────────────────────────────────────────────────────────────────────────────────────
# Controllo robusto: se d non è un numero valido, restituisco "VOICE" come preset di default con colore giallo. Evita errori di classificazione e permette di gestire casi in cui la metrica Delta non è disponibile (es. file troppo corto o silenzioso).
classify_preset() {
  local d="$1" i_fc="${2:-}" width="${3:-}"
  awk -v d="$d" -v fc="$i_fc" -v w="$width" \
      -v fcgate="$VOICE_FC_GATE" -v wgate="$WIDTH_WIDE_GATE" 'BEGIN {
    d += 0;
    preset="VOICE"; color="\033[1;33m";
    if      (d < -13.0) { preset="SONAR"; color="\033[1;31m"; }
    else if (d < -10.0) { preset="AURA";  color="\033[1;35m"; }
    else if (d <  -6.0) { preset="WIDE";  color="\033[1;32m"; }
    else if (d <= -2.0) { preset="AEGIS"; color="\033[38;5;208m"; }
    else {
      # Delta > -2: surround forti. Centro sano in assoluto -> buon mix (AEGIS),
      # altrimenti dialogo davvero coperto -> VOICE.
      if (fc != "" && (fc+0) >= (fcgate+0)) { preset="AEGIS"; color="\033[38;5;208m"; }
      else                                  { preset="VOICE"; color="\033[1;33m"; }
    }
    # Surround collassati/stretti: a parita di Delta una ricostruzione laterale
    # (WIDE) rende piu di AURA/AEGIS. Non tocca SONAR (deficit estremo) ne VOICE.
    if (w != "" && (w+0) < (wgate+0)) {
      if (preset=="AURA" || preset=="AEGIS") { preset="WIDE"; color="\033[1;32m"; }
    }
    printf "%s|%s", preset, color;
  }'
}

# ────────────────────────────────────────────────────────────────────────────────
# Mappa Delta -> Preset (wrapper sola-Delta: usato per il verdetto stagionale P25,
# dove non esistono i_fc/width aggregati). Per-file si usa classify_preset completo.
# ────────────────────────────────────────────────────────────────────────────────
delta_to_preset() {
  classify_preset "$1"
}

# ────────────────────────────────────────────────────────────────────────────────
# Misura Loudness Integrata (I:) e LRA dell'intero stream in UN SOLO passaggio.
# ebur128 emette sia I: che LRA: nello stesso log: niente doppia decodifica
# (rilevante su Git Bash/Windows, dove ogni pass ffmpeg costa di piu').
# Args: file stream_index | Output: "I|LRA" (campi vuoti se non misurabili)
# ────────────────────────────────────────────────────────────────────────────────
measure_stream_i_lra() {
  local f="$1" stream="$2"
  local log_file
  log_file=$(mktemp -p "$ANALYZER_TMPDIR")
  # Esecuzione ffmpeg con ebur128 in un solo passaggio per misurare sia I: che LRA:. Se il file è troppo corto o silenzioso, ebur128 potrebbe non riuscire a misurare la loudness, quindi gestisco l'output in modo che se non riesco a estrarre valori validi, restituisco stringhe vuote per I e LRA.
  ffmpeg -y -nostdin -hide_banner -nostats \
    -i "$f" \
    -map "0:${stream}" \
    -af "ebur128=framelog=verbose" \
    -vn -sn -f null - \
    >/dev/null 2>"$log_file" </dev/null || true

  local i_val lra_val
  i_val=$(grep -E "^\s+I:\s+-?[0-9]" "$log_file" | tr -d '\r' | awk '{print $2}' | tail -1)
  lra_val=$(grep -E "^\s+LRA:\s+-?[0-9]" "$log_file" | tr -d '\r' | awk '{print $2}' | tail -1)
  rm -f "$log_file"

  echo "${i_val:-}|${lra_val:-}"
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
# (LRA ora misurata insieme a I: in measure_stream_i_lra, un solo passaggio ebur128)
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
# width = I(SIDE) - I(MID). Valori molto negativi = SL/SR simili/collassati.
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

# ────────────────────────────────────────────────────────────────────────────────
# Misura Integrated Loudness (I:) di un singolo canale estratto via pan=
# Args: file stream_index pan_formula
# ────────────────────────────────────────────────────────────────────────────────
measure_channel_loudness() {
  local f="$1" stream="$2" pan_formula="$3"
  local log_file
  log_file=$(mktemp -p "$ANALYZER_TMPDIR")

  # Filtro pan= per estrarre il canale specifico (es. c0=FC o c0=SL) e poi ebur128 per misurare la loudness di quel canale. Output silenziato, log ebur128 catturato in un file temporaneo. Se ffmpeg fallisce (es. canale non esistente), continuo comunque per gestire il caso di canali silenziosi o file troppo corti.
  ffmpeg -y -nostdin -hide_banner -nostats \
    -i "$f" \
    -map "0:${stream}" \
    -af "pan=1c|${pan_formula},ebur128=framelog=verbose" \
    -vn -sn -f null - \
    >/dev/null 2>"$log_file" </dev/null || true
  # Estrazione del valore I: dal log di ebur128. Se non riesco a estrarre un valore valido, restituisco stringa vuota. Questo può accadere se il canale è silenzioso o se il file è troppo corto per misurare la loudness.
  local i_val
  i_val=$(grep -E "^\s+I:\s+-?[0-9]" "$log_file" | tr -d '\r' | awk '{print $2}' | tail -1)
  rm -f "$log_file"

  echo "${i_val:-}"
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
  if [[ "$max_ch" =~ ^[0-9]+$ && "$max_ch" -ne 6 ]]; then
    warn "Stream [$target_stream] ha $max_ch canali (non 5.1). Delta richiede 5.1. Saltato."
    return 1
  fi
  # Controllo layout: se è un layout 5.1 riconosciuto, uso le designazioni corrette per i canali surround (BL/BR o SL/SR). Se il layout è sconosciuto, uso SL/SR come default e emetto un warning.
  local sur_l="SL" sur_r="SR"
  case "$layout" in
    "5.1"|"5.1(back)") sur_l="BL"; sur_r="BR" ;;
    "5.1(side)")        sur_l="SL"; sur_r="SR" ;;
    *)                  sur_l="SL"; sur_r="SR"
                        info "Layout audio '${layout}' non dichiarato in modo standard: uso SL/SR come standard surround." ;;
  esac
  # Controllo robusto: se layout è dichiarato ma non è un layout 5.1 riconosciuto, emetto un warning ma continuo comunque con SL/SR come default per i canali surround.
  info "Misura loudness FC... (stream [$target_stream])"
  local i_fc
  i_fc=$(measure_channel_loudness "$f" "$target_stream" "c0=FC")

  # Controllo robusto: se i_fc è vuoto o non è un numero valido, esco con warning e codice di errore. Questo può accadere se il canale centrale è silenzioso o se il file è troppo corto per misurare la loudness.
  info "Misura loudness SL..."
  local i_sl
  i_sl=$(measure_channel_loudness "$f" "$target_stream" "c0=${sur_l}")

  # Controllo robusto: se i_sl è vuoto o non è un numero valido, esco con warning e codice di errore. Questo può accadere se il canale surround sinistro è silenzioso o se il file è troppo corto per misurare la loudness.
  info "Misura loudness SR..."
  local i_sr
  i_sr=$(measure_channel_loudness "$f" "$target_stream" "c0=${sur_r}")

  # Controllo robusto: se i_sr è vuoto o non è un numero valido, esco con warning e codice di errore. Questo può accadere se il canale surround destro è silenzioso o se il file è troppo corto per misurare la loudness.
  if [[ -z "$i_fc" || -z "$i_sl" || -z "$i_sr" ]]; then
    warn "Loudness non misurabile per $f. Canale silenzioso o file troppo corto?"
    return 1
  fi
  # Calcolo SUR come media energetica di SL e SR, poi Delta come differenza tra SUR e FC. Uso un file temporaneo per gestire i calcoli in awk, evitando problemi di precisione o formattazione nei passaggi di variabili.
  local i_sur delta
  _delta_tmp=$(mktemp -p "$ANALYZER_TMPDIR")
  awk -v sl="$i_sl" -v sr="$i_sr" -v fc="$i_fc" 'BEGIN { sur=-10*log(((10^(sl/-10))+(10^(sr/-10)))/2)/log(10); d=sur-fc; printf "%.1f %.1f\n",sur,d }' < /dev/null > "$_delta_tmp"
  read -r i_sur delta < "$_delta_tmp"
  rm -f "$_delta_tmp"

  # Controllo robusto: se i_sur o delta non sono numeri validi, esco con warning e codice di errore.
  local forced_preset=0 forced_reason=""
  if awk -v sur="$i_sur" -v gate="$FAKE_SUR_GATE" 'BEGIN { exit !(sur < gate) }'; then
    warn "Surround virtualmente muti (${i_sur} LUFS): falso 5.1 / front-heavy. Forzo VOICE."
    forced_preset=1
    forced_reason="fake_surround"
  fi

  # Se Delta > -2 dB, i surround sono forti rispetto al centro. Se in questo caso la loudness assoluta del centro è molto bassa (sotto VOICE_FC_GATE), è probabile che il dialogo sia davvero coperto e non un mix immersivo con surround forti. In questo caso, forzo il preset VOICE per dare priorità alla voce, altrimenti lascio AEGIS che è più bilanciato.
  info "Misura width Mid/Side SL-SR..."
  local i_mid i_side width_ms width_desc
  i_mid=$(measure_channel_loudness "$f" "$target_stream" "c0=0.5*${sur_l}+0.5*${sur_r}")
  i_side=$(measure_channel_loudness "$f" "$target_stream" "c0=0.5*${sur_l}-0.5*${sur_r}")

  # Controllo robusto: se i_mid o i_side non sono numeri validi, non calcolo width e lo segnalo come N/A. Questo può accadere se i canali surround sono silenziosi o se il file è troppo corto per misurare la loudness.
  width_ms=""
  width_desc="N/A"
  if [[ -n "$i_mid" && -n "$i_side" ]]; then
    width_ms=$(awk -v side="$i_side" -v mid="$i_mid" 'BEGIN { printf "%.1f", side-mid }')
    width_desc=$(width_to_desc "$width_ms")
  fi

  # Misura loudness integrata (I:) e LRA dell'intero stream in un solo passaggio, per valutare il volamp consigliato. Se la misura non è possibile (es. file troppo corto), i_full e lra_full saranno vuoti, e il volamp sarà 0 (nessun boost).
  local i_full lra_full volamp_raw volamp volamp_desc volume_status volamp_note
  local _i_lra
  _i_lra=$(measure_stream_i_lra "$f" "$target_stream")
  i_full="${_i_lra%%|*}"
  lra_full="${_i_lra##*|}"
  volamp_raw=$(loudness_to_volamp "$i_full")
  volamp=$(cap_volamp_by_lra "$volamp_raw" "$lra_full")
  volamp_desc=$(volamp_to_desc "$volamp")
  volume_status=$(source_volume_status "$volamp")
  volamp_note=""
  [[ "$volamp" != "$volamp_raw" ]] && volamp_note=" cap LRA"

  # Classificazione preset finale, con logica completa che considera Delta, loudness assoluta del centro (i_fc) e width dei surround. Se è stato forzato un preset a causa di surround molto deboli, uso direttamente VOICE con il colore associato, altrimenti uso classify_preset per determinare il preset in base alle metriche.
  local preset_raw
  if [[ "$forced_preset" -eq 1 ]]; then
    preset_raw="VOICE|\033[1;33m"
  else
    preset_raw=$(classify_preset "$delta" "$i_fc" "$width_ms")
  fi
  local preset="${preset_raw%%|*}"
  local p_color="${preset_raw##*|}"

  # Descrizione testuale del preset, per display più umano. Se il preset è stato forzato, aggiungo una nota che indica la ragione del forzamento.
  local preset_desc
  case "$preset" in
    SONAR) preset_desc="Surround molto deboli, ricostruzione psicoacustica" ;;
    AURA)  preset_desc="Surround deboli, allargamento prudente" ;;
    WIDE)  preset_desc="Surround medi, allargo scena sonora laterale" ;;
    AEGIS) preset_desc="Surround buoni, controllo e bilanciamento" ;;
    VOICE) preset_desc="Surround forti o centro coperto, priorita' voce" ;;
  esac
  [[ "$forced_preset" -eq 1 ]] && preset_desc="${preset_desc}; forzato da ${forced_reason}"

  # Accumulo risultati per verdetto stagionale e tabella finale. Se il preset è stato forzato, uso comunque il Delta reale per il verdetto stagionale, perché riflette la realtà del mix, ma segnalo il preset forzato nella tabella per chiarezza.
  GLOBAL_METRIC_VALUES+=("$delta")
  GLOBAL_METRIC_FILES+=("$(basename "$f")")
  GLOBAL_METRIC_PATHS+=("$f")
  GLOBAL_LOUDNESS_VALUES+=("${i_full:-N/A}")
  GLOBAL_VOLAMP_VALUES+=("$volamp")
  GLOBAL_WIDTH_VALUES+=("${width_ms:-N/A}")
  GLOBAL_LRA_VALUES+=("${lra_full:-N/A}")
  GLOBAL_PRESET_VALUES+=("$preset")
  GLOBAL_PRESET_FORCED_VALUES+=("$forced_preset")

  # Display dei risultati per il file, con colori e descrizioni. Se alcune metriche non sono misurabili, le segnalo come N/A. Se il preset è stato forzato, mostro comunque il preset forzato ma con la descrizione che indica la ragione.
  ok "Risultati Delta per: $f"
  echo -e "  \033[1;33mI(FC):    \033[0m  ${i_fc} LUFS"
  echo -e "  \033[1;33mI(SL):    \033[0m  ${i_sl} LUFS"
  echo -e "  \033[1;33mI(SR):    \033[0m  ${i_sr} LUFS"
  echo -e "  \033[1;33mI(SUR):   \033[0m  ${i_sur} LUFS  (media energia SL+SR)"
  echo -e "  \033[1;37mDelta:    \033[0m  ${p_color}${delta} dB\033[0m  (SUR - FC)"
  echo -e "  \033[1;36mWidth MS: \033[0m  ${width_ms:-N/A} dB  (${width_desc}; SIDE - MID SL/SR)"
  echo -e "  \033[1;33mI(full):  \033[0m  ${i_full:-N/A} LUFS"
  echo -e "  \033[1;33mLRA:      \033[0m  ${lra_full:-N/A} LU  (solo cap volamp)"
  echo -e "  \033[1;37mPreset:   \033[0m  ${p_color}${preset}\033[0m  (${preset_desc})"
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
  probe_audio_streams "$CUR_FILE" || continue
  scan_delta "$CUR_FILE"
done

# ────────────────────────────────────────────────────────────────────────────────
# VERDETTO STAGIONALE / GENERAZIONE BATCH
# Delta -> P25 (bias audiofilo verso episodi con surround piu' deboli)
# Spread > 4 dB -> stagione eterogenea, tabella per-file.
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
  # Determino il preset stagionale consigliato in base al valore P25 (audiofilo) di Delta, usando la mappa Delta -> Preset. Se per qualche motivo la classificazione fallisce, esco con warning e codice di errore.
  season_raw=$(delta_to_preset "$m_pctl")
  season_preset="${season_raw%%|*}"
  season_color="${season_raw##*|}"

  # Descrizione testuale del preset stagionale, per display più umano. Allineata alla logica dei preset: SONAR per surround molto deboli, AURA per surround deboli, WIDE per surround medi, AEGIS per surround buoni, VOICE per surround forti o centro coperto.
  case "$season_preset" in
    SONAR) season_desc="Surround molto deboli, serve ricostruzione psicoacustica" ;;
    AURA)  season_desc="Surround deboli, allargamento prudente" ;;
    WIDE)  season_desc="Surround medi, allargamento scena laterale" ;;
    AEGIS) season_desc="Surround buoni, controllo e bilanciamento" ;;
    VOICE) season_desc="Surround forti o centro coperto, priorita' voce" ;;
  esac
  # Display del verdetto stagionale, con statistiche e preset consigliato. Se lo spread è alto, avverto che la stagione è eterogenea e suggerisco di considerare i preset per-file, che mostro in una tabella con i nomi dei file (troncati se troppo lunghi), i valori di Delta e i preset consigliati per ciascun file, con colori.
  if [[ "$CNT" -gt 1 ]]; then
    echo -e "  Episodi analizzati:  \033[1;37m${CNT}\033[0m"
    echo -e "  Media:               \033[0;37m${m_avg} dB\033[0m"
    echo -e "  P25 (audiofilo):     ${season_color}${m_pctl} dB\033[0m"
    echo -e "  Range:               \033[0;37m${m_min} / ${m_max} dB  (spread: ${m_spread} dB)\033[0m"
    echo -e "  Preset Consigliato:  ${season_color}${season_preset}\033[0m  (${season_desc})"

    # Se alcuni file hanno preset forzati a VOICE a causa di surround virtualmente muti, conto quanti sono e mostro una nota che indica quanti file hanno questo problema, per dare un'indicazione aggiuntiva sulla natura della stagione.
    forced_count=0
    for fp in "${GLOBAL_PRESET_FORCED_VALUES[@]}"; do
      [[ "$fp" == "1" ]] && forced_count=$((forced_count + 1))
    done
    if [[ "$forced_count" -gt 0 ]]; then
      echo -e "  \033[0;33mNota: ${forced_count} file con surround virtualmente muti: preset forzato per-file a VOICE.\033[0m"
    fi 
    # Se ho valori di volamp consigliati per-file, calcolo anche il volamp stagionale come P75 prudente della loudness integrata, per dare un'indicazione aggiuntiva sul livello di boost consigliato a livello stagionale. Uso un file temporaneo e awk per calcolare il P75, che è un valore prudente per il boost consigliato, evitando di essere influenzato da outlier con volamp molto alti.
    if [[ ${#GLOBAL_VOLAMP_VALUES[@]} -gt 0 ]]; then
      _volamp_tmp=$(mktemp -p "$ANALYZER_TMPDIR")
      printf '%s\n' "${GLOBAL_VOLAMP_VALUES[@]}" > "$_volamp_tmp"
      season_volamp=$(awk '{v[NR]=$1+0} END{n=NR; for(i=2;i<=n;i++){k=v[i];j=i-1; while(j>=1&&v[j]>k){v[j+1]=v[j];j--}; v[j+1]=k}; raw=0.75*n;rank=int(raw);if(raw>rank)rank=rank+1; if(rank<1)rank=1;if(rank>n)rank=n; printf "%.1f",v[rank]}' "$_volamp_tmp")
      rm -f "$_volamp_tmp"
      echo -e "  Volamp Stagionale:  \033[1;36m${season_volamp} dB\033[0m  (P75 prudente della loudness)"
    fi
    # Se lo spread è alto, avverto che la stagione è eterogenea e suggerisco di considerare i preset per-file, mostrando una tabella con i nomi dei file (troncati se troppo lunghi), i valori di Delta e i preset consigliati per ciascun file, con colori.
    if [[ "$HIGH_SPREAD" -eq 1 ]]; then
      echo ""
      echo -e "  \033[0;33m⚠  Spread > 4 dB: la stagione e' eterogenea.\033[0m"
      echo -e "  \033[0;33m   Per risultati ottimali, considera i preset per-file:\033[0m"
      echo ""
      for (( i=0; i<CNT; i++ )); do
        pf_preset="${GLOBAL_PRESET_VALUES[$i]}"
        pf_color="$(preset_color "$pf_preset")"
        fname="${GLOBAL_METRIC_FILES[$i]}"
        (( ${#fname} > 50 )) && fname="${fname:0:47}..."
        printf "    %-50s  %b%-5s\033[0m  (%s dB)\n" "$fname" "$pf_color" "$pf_preset" "${GLOBAL_METRIC_VALUES[$i]}"
      done
    fi
  fi

  # ── Generazione batch file ─────────────────────────────────────────────────
  # Se ho risultati validi, genero un batch file con i comandi di processing consigliati per ogni file, usando i preset raffinati per-file se sono stati forzati o se la stagione è eterogenea, altrimenti usando il preset stagionale. Il batch file include commenti e istruzioni per l'utente, e ogni comando include un commento con le metriche rilevanti per quel file.
  BATCH_FILE="run_processing.sh"
  if [[ "$CREATE_RUN" == "si" ]]; then
    {
      echo '#!/usr/bin/env bash'
      echo "# ── Batch generato da audio_analyzer_delta (V4.8 BASE4/DELTA/VOLAMP/FILES/RUNSELECT) ──"
      echo "# Data: $(date '+%Y-%m-%d %H:%M')"
      echo "# Metrica: DELTA (+ raffinamento width / I(FC)) | Percentile: P25 (audiofilo)"
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
  
      # Per ogni file, genero un comando di processing usando il preset raffinato per-file se è stato forzato o se la stagione è eterogenea, altrimenti usando il preset stagionale. Escludo i file che hanno già preset AC3 dedicati, perché non hanno senso da processare con questo script di upmix/boost.
      for (( i=0; i<CNT; i++ )); do
        case "${GLOBAL_METRIC_PATHS[$i]}" in
          *_AC3_Aegis.mkv|*_AC3_Sonar.mkv|*_AC3_Wide.mkv|*_AC3_Aura.mkv|*_AC3_Voice.mkv|\
          *_EAC3_Aegis.mkv|*_EAC3_Sonar.mkv|*_EAC3_Wide.mkv|*_EAC3_Aura.mkv|*_EAC3_Voice.mkv)
            continue
            ;;
        esac
        # Determino il preset da usare per il comando di processing: se è stato forzato o se la stagione è eterogenea, uso il preset raffinato per-file già calcolato in scan_delta (che include la disambiguazione width / I(FC)), altrimenti uso il preset stagionale.
        file_preset=""
        if [[ "${GLOBAL_PRESET_FORCED_VALUES[$i]:-0}" == "1" || "$HIGH_SPREAD" -eq 1 ]]; then
          # Forzato (fake 5.1) o stagione eterogenea: uso il preset raffinato per-file
          # gia' calcolato in scan_delta (include disambiguazione width / I(FC)).
          file_preset="${GLOBAL_PRESET_VALUES[$i]}"
        else
          file_preset="$season_preset"
        fi
        # Se per qualche motivo il preset per-file è vuoto, uso il preset stagionale come fallback, per garantire che ogni file abbia un preset assegnato nel batch.
        [[ -z "$file_preset" ]] && file_preset="${season_preset:-SONAR}"
        file_preset_lower="${file_preset,,}"
        file_volamp="${GLOBAL_VOLAMP_VALUES[$i]:-0}"
        file_loudness="${GLOBAL_LOUDNESS_VALUES[$i]:-N/A}"
        file_width="${GLOBAL_WIDTH_VALUES[$i]:-N/A}"
        file_lra="${GLOBAL_LRA_VALUES[$i]:-N/A}"
        escaped_path=$(printf '%q' "${GLOBAL_METRIC_PATHS[$i]}")
  
        # Genero il comando di processing per il file, usando il preset determinato e includendo un commento con le metriche rilevanti (Delta, I(FC), LRA, Width MS, volamp consigliato). Il comando è formattato in modo che i parametri siano chiari e facilmente modificabili se necessario.
        printf '"$PROC" "$CODEC" "$KEEP" %s "$BITRATE" %s %s  # DELTA %s dB | I=%s LUFS | LRA=%s LU | WidthMS=%s dB | volamp=%s dB\n' \
          "$escaped_path" "$file_preset_lower" "$file_volamp" "${GLOBAL_METRIC_VALUES[$i]}" "$file_loudness" "$file_lra" "$file_width" "$file_volamp"
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
    warn "Nessun risultato Delta valido: run_processing.sh non generato."
  else
    warn "Nessun risultato Delta valido."
  fi
fi

echo -e ""
ok "Analisi completata. Nessun file audio e' stato modificato."
