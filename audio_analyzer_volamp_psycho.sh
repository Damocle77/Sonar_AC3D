#!/usr/bin/env bash
# set -e rimosso: causa exit su espressioni aritmetiche (es. var=0; ((var++)))
set -uo pipefail

# ╭─────────────────────────────────────────────────────────────────────────────────╮
# │   audio_analyzer_delta.sh - V4.6 DELTA/VOLAMP/FILES/AUTORUN - Maggio 2026       │
# │                                                                                 │
# │   Sonda euristica per l'analisi offline di container multimediali 5.1.          │
# │   Misura il bilanciamento surround/centro e genera run_processing.sh            │
# │   per il processore aegis_sonar_wide_aura_voice_volamp_psycho.sh.               │
# │                                                                                 │
# │   METRICA UNICA: DELTA                                                          │
# │                                                                                 │
# │   Delta = I(SUR) - I(FC) in dB                                                  │
# │     - I(FC)  = loudness integrata del canale centrale                           │
# │     - I(SUR) = media energetica dei surround SL/SR o BL/BR                      │
# │                                                                                 │
# │   Valori negativi = surround piu' deboli del centro.                            │
# │   La metrica diagnostica direttamente cio' che il processore corregge:          │
# │   quanto la scena surround e' arretrata rispetto al parlato.                    │
# │                                                                                 │
# │   MAPPA PRESET (delta):                                                         │
# │     Delta < -15 dB       -> SONAR  (surround molto deboli, ricostruzione)       │
# │     Delta -15/-10 dB     -> AURA   (surround deboli, allargamento prudente)     │
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

C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"

info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

for _bin in ffmpeg ffprobe awk; do
  command -v "$_bin" &>/dev/null || { err "$_bin non trovato nel PATH"; exit 1; }
done

usage() {
  cat <<'USAGE'
UTILIZZO:
  ./audio_analyzer_delta.sh <file|directory|""> [codec] [keep] [bitrate]
  ./audio_analyzer_delta.sh --files <codec> <keep> <bitrate> <file1> [file2 ...]

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
  bitrate : 448k   (Default) Bitrate per il batch file generato.

METRICA:
  DELTA = I(SUR) - I(FC)
  Misura il rapporto fra surround e centrale. Richiede tracce 5.1.

OUTPUT:
  Se ci sono risultati validi, viene sempre generato run_processing.sh
  con i comandi consigliati per singolo file, lista manuale o intera cartella.

VOLAMP HEURISTIC:
  L'analizzatore stima anche un volamp finale (0 / 1.5 / 2 / 2.5 dB)
  usando la Loudness Integrata del file intero.
  La LRA viene misurata solo come protezione: se il mix ha dinamica alta,
  il volamp viene limitato per non schiacciare un mix cinematografico sano.

ESEMPI:
  ./audio_analyzer_delta.sh "film.mkv"                    # Singolo file, default eac3/no/448k
  ./audio_analyzer_delta.sh "film.mkv" eac3 si 768k       # Singolo file + run_processing.sh
  ./audio_analyzer_delta.sh "" eac3 no 448k               # Cartella corrente + run_processing.sh
  ./audio_analyzer_delta.sh . eac3 si 768k                
  ./audio_analyzer_delta.sh --files eac3 si 768k "ep01.mkv" "ep02.mkv" "ep03.mkv"
USAGE
  exit 1
}

# Senza argomenti o con -h/--help -> mostra usage
[[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

MULTI_FILES_MODE=false
MULTI_FILES=()

if [[ "${1:-}" == "--files" ]]; then
  MULTI_FILES_MODE=true

  if (( $# < 5 )); then
    err "Uso --files non valido. Sintassi: ./audio_analyzer_delta.sh --files <codec> <keep> <bitrate> <file1> [file2 ...]"
    usage
  fi

  shift
  INPUT_ARG=""
  BATCH_CODEC="${1:-eac3}"
  BATCH_KEEP="${2:-no}"
  BATCH_BITRATE="${3:-448k}"
  shift 3
  MULTI_FILES=("$@")
else
  INPUT_ARG="${1:-}"
  BATCH_CODEC="${2:-eac3}"
  BATCH_KEEP="${3:-no}"
  BATCH_BITRATE="${4:-448k}"
fi

# Validazione
case "$BATCH_CODEC" in ac3|eac3) ;; *) err "Codec '$BATCH_CODEC' non valido. Usa ac3 o eac3."; usage ;; esac
case "$BATCH_KEEP" in si|no) ;; *) err "Keep '$BATCH_KEEP' non valido. Usa si o no."; usage ;; esac
[[ "$BATCH_BITRATE" =~ ^[0-9]+(k|M)?$ ]] || { err "Bitrate '$BATCH_BITRATE' non valido. Es: 448k, 640k, 768k."; usage; }
[[ "$BATCH_BITRATE" =~ k$|M$ ]] || BATCH_BITRATE="${BATCH_BITRATE}k"

if [[ "$MULTI_FILES_MODE" == true ]]; then
  info "Metrica: DELTA | Input: lista manuale (${#MULTI_FILES[@]} file) | Batch: ${BATCH_CODEC} / keep=${BATCH_KEEP} / ${BATCH_BITRATE} / run_processing=auto"
else
  info "Metrica: DELTA | Batch: ${BATCH_CODEC} / keep=${BATCH_KEEP} / ${BATCH_BITRATE} / run_processing=auto"
fi
info "Volamp heuristic: target loudness prudente con step 0 / 1.5 / 2 / 2.5 dB"

# Variabili globali per il verdetto stagionale
GLOBAL_METRIC_VALUES=()
GLOBAL_METRIC_FILES=()
GLOBAL_METRIC_PATHS=()
GLOBAL_LOUDNESS_VALUES=()
GLOBAL_VOLAMP_VALUES=()
GLOBAL_WIDTH_VALUES=()
GLOBAL_LRA_VALUES=()

# ────────────────────────────────────────────────────────────────────────────────
# Raccolta file
# ────────────────────────────────────────────────────────────────────────────────
FILES=()
if [[ "$MULTI_FILES_MODE" == true ]]; then
  (( ${#MULTI_FILES[@]} > 0 )) || { err "Modalita' --files richiesta ma nessun file passato."; exit 1; }

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

(( ${#FILES[@]} == 0 )) && { err "Nessun file valido trovato da analizzare."; exit 1; }

# ────────────────────────────────────────────────────────────────────────────────
# Probe: struttura tracce audio
# ────────────────────────────────────────────────────────────────────────────────
probe_audio_streams() {
  local f="$1"
  info "Struttura Audio: $f"

  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_tags=language,title \
    -of csv=p=0 "$f" 2>/dev/null </dev/null || true)

  raw_data="${raw_data//$'\r'/}"

  if [[ -z "$raw_data" ]]; then
    warn "Nessuna traccia audio trovata."
    return 1
  fi

  local _A_LINES
  mapfile -t _A_LINES <<< "$raw_data"

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
pick_best_stream() {
  local f="$1"
  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null </dev/null || true)
  raw_data="${raw_data//$'\r'/}"

  local best_idx=""
  local best_ch=0
  local best_layout="unknown"
  local best_score=-1

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

      local score=0
      [[ "$ch" =~ ^[0-9]+$ && "$ch" -eq 6 ]] && score=$((score + 1000))
      [[ "$def" == "1" ]] && score=$((score + 200))
      [[ "${lang,,}" =~ ^it ]] && score=$((score + 300))

      if (( score > best_score )); then
        best_score=$score
        best_idx=$idx
        best_ch=$ch
        best_layout=$layout
      fi
    done
  fi

  echo "$best_idx $best_ch $best_layout"
}

# ────────────────────────────────────────────────────────────────────────────────
# Mappa Delta -> Preset
# ────────────────────────────────────────────────────────────────────────────────
delta_to_preset() {
  local d="$1"
  local is_sonar is_aura is_wide is_aegis
  is_sonar=$(awk -v d="$d" 'BEGIN { print (d < -15.0) ? 1 : 0 }')
  is_aura=$(awk -v d="$d" 'BEGIN { print (d >= -15.0 && d < -10.0) ? 1 : 0 }')
  is_wide=$(awk -v d="$d" 'BEGIN { print (d >= -10.0 && d < -6.0) ? 1 : 0 }')
  is_aegis=$(awk -v d="$d" 'BEGIN { print (d >= -6.0 && d <= -2.0) ? 1 : 0 }')

  if   [[ "$is_sonar" -eq 1 ]]; then echo "SONAR|\033[1;36m"
  elif [[ "$is_aura"  -eq 1 ]]; then echo "AURA|\033[1;35m"
  elif [[ "$is_wide"  -eq 1 ]]; then echo "WIDE|\033[1;32m"
  elif [[ "$is_aegis" -eq 1 ]]; then echo "AEGIS|\033[1;31m"
  else                                  echo "VOICE|\033[1;33m"
  fi
}

# ────────────────────────────────────────────────────────────────────────────────
# Misura Loudness Integrata (I:) dell'intero stream target
# Args: file stream_index
# ────────────────────────────────────────────────────────────────────────────────
measure_stream_loudness() {
  local f="$1" stream="$2"
  local log_file
  log_file=$(mktemp)

  ffmpeg -y -nostdin -hide_banner -nostats \
    -i "$f" \
    -map "0:${stream}" \
    -af "ebur128=framelog=verbose" \
    -vn -sn -f null - \
    >/dev/null 2>"$log_file" </dev/null || true

  local i_val
  i_val=$(grep -E "^\s+I:\s+-?[0-9]" "$log_file" | tr -d '\r' | awk '{print $2}' | tail -1)
  rm -f "$log_file"

  echo "${i_val:-}"
}

# ────────────────────────────────────────────────────────────────────────────────
# Euristica volamp da Loudness Integrata del file intero
# Output consentiti: 0 | 1.5 | 2 | 2.5
# ────────────────────────────────────────────────────────────────────────────────
loudness_to_volamp() {
  local i_val="$1"

  [[ -n "$i_val" ]] || { echo "0"; return; }
  [[ "$i_val" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || { echo "0"; return; }

  local deficit
  deficit=$(awk -v i="$i_val" 'BEGIN { printf "%.2f", (-18.0 - i) }')

  if awk -v d="$deficit" 'BEGIN { exit !(d < 0.8) }'; then
    echo "0"
  elif awk -v d="$deficit" 'BEGIN { exit !(d < 1.8) }'; then
    echo "1.5"
  elif awk -v d="$deficit" 'BEGIN { exit !(d < 2.3) }'; then
    echo "2"
  else
    echo "2.5"
  fi
}

volamp_to_desc() {
  case "$1" in
    0|0.0)   echo "Nessun incremento necessario" ;;
    1.5)     echo "Lieve recupero loudness" ;;
    2|2.0)   echo "Boost consigliato" ;;
    2.5)     echo "Boost massimo prudente" ;;
    *)       echo "Boost custom" ;;
  esac
}

source_volume_status() {
  local volamp="$1"
  case "$volamp" in
    0|0.0) echo "OK" ;;
    1.5)   echo "leggermente basso" ;;
    2|2.0) echo "basso" ;;
    2.5)   echo "molto basso" ;;
    *)     echo "da verificare" ;;
  esac
}

# ────────────────────────────────────────────────────────────────────────────────
# Misura LRA (solo per cap volamp, non per scelta preset)
# Args: file stream_index
# ────────────────────────────────────────────────────────────────────────────────
measure_stream_lra() {
  local f="$1" stream="$2"
  local log_file
  log_file=$(mktemp)

  ffmpeg -y -nostdin -hide_banner -nostats \
    -i "$f" \
    -map "0:${stream}" \
    -af "ebur128=framelog=verbose" \
    -vn -sn -f null - \
    >/dev/null 2>"$log_file" </dev/null || true

  local lra_val
  lra_val=$(grep -E "^\s+LRA:\s+-?[0-9]" "$log_file" | tr -d '\r' | awk '{print $2}' | tail -1)
  rm -f "$log_file"

  echo "${lra_val:-}"
}

# ────────────────────────────────────────────────────────────────────────────────
# Limita il volamp se il file ha dinamica alta.
# Integrato basso + LRA alta spesso significa mix cinematografico, non file rotto.
# ────────────────────────────────────────────────────────────────────────────────
cap_volamp_by_lra() {
  local volamp="$1" lra="$2"

  [[ -n "$lra" && "$lra" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || { echo "$volamp"; return; }

  if awk -v l="$lra" 'BEGIN { exit !(l >= 16.0) }'; then
    if awk -v v="$volamp" 'BEGIN { exit !(v > 1.5) }'; then
      echo "1.5"
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
width_to_desc() {
  local w="$1"
  [[ -n "$w" && "$w" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || { echo "N/A"; return; }

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
  log_file=$(mktemp)

  ffmpeg -y -nostdin -hide_banner -nostats \
    -i "$f" \
    -map "0:${stream}" \
    -af "pan=1c|${pan_formula},ebur128=framelog=verbose" \
    -vn -sn -f null - \
    >/dev/null 2>"$log_file" </dev/null || true

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

  local stream_info
  stream_info=$(pick_best_stream "$f")
  local target_stream="${stream_info%% *}"
  local rest="${stream_info#* }"
  local max_ch="${rest%% *}"
  local layout="${rest#* }"

  if [[ -z "$target_stream" ]]; then
    warn "Impossibile determinare stream target. File saltato."
    return 1
  fi

  if [[ "$max_ch" =~ ^[0-9]+$ && "$max_ch" -ne 6 ]]; then
    warn "Stream [$target_stream] ha $max_ch canali (non 5.1). Delta richiede 5.1. Saltato."
    return 1
  fi

  local sur_l="SL" sur_r="SR"
  case "$layout" in
    "5.1"|"5.1(back)") sur_l="BL"; sur_r="BR" ;;
    "5.1(side)")        sur_l="SL"; sur_r="SR" ;;
    *)                  sur_l="SL"; sur_r="SR"
                        warn "Layout '${layout}' non standard, assumo SL/SR." ;;
  esac

  info "Misura loudness FC... (stream [$target_stream])"
  local i_fc
  i_fc=$(measure_channel_loudness "$f" "$target_stream" "c0=FC")

  info "Misura loudness SL..."
  local i_sl
  i_sl=$(measure_channel_loudness "$f" "$target_stream" "c0=${sur_l}")

  info "Misura loudness SR..."
  local i_sr
  i_sr=$(measure_channel_loudness "$f" "$target_stream" "c0=${sur_r}")

  if [[ -z "$i_fc" || -z "$i_sl" || -z "$i_sr" ]]; then
    warn "Loudness non misurabile per $f. Canale silenzioso o file troppo corto?"
    return 1
  fi

  local i_sur delta
  _delta_tmp=$(mktemp)
  awk -v sl="$i_sl" -v sr="$i_sr" -v fc="$i_fc" 'BEGIN { sur=-10*log(((10^(sl/-10))+(10^(sr/-10)))/2)/log(10); d=sur-fc; printf "%.1f %.1f\n",sur,d }' < /dev/null > "$_delta_tmp"
  read -r i_sur delta < "$_delta_tmp"
  rm -f "$_delta_tmp"

  info "Misura width Mid/Side SL-SR..."
  local i_mid i_side width_ms width_desc
  i_mid=$(measure_channel_loudness "$f" "$target_stream" "c0=0.5*${sur_l}+0.5*${sur_r}")
  i_side=$(measure_channel_loudness "$f" "$target_stream" "c0=0.5*${sur_l}-0.5*${sur_r}")

  width_ms=""
  width_desc="N/A"
  if [[ -n "$i_mid" && -n "$i_side" ]]; then
    width_ms=$(awk -v side="$i_side" -v mid="$i_mid" 'BEGIN { printf "%.1f", side-mid }')
    width_desc=$(width_to_desc "$width_ms")
  fi

  local i_full lra_full volamp_raw volamp volamp_desc volume_status volamp_note
  i_full=$(measure_stream_loudness "$f" "$target_stream")
  lra_full=$(measure_stream_lra "$f" "$target_stream")
  volamp_raw=$(loudness_to_volamp "$i_full")
  volamp=$(cap_volamp_by_lra "$volamp_raw" "$lra_full")
  volamp_desc=$(volamp_to_desc "$volamp")
  volume_status=$(source_volume_status "$volamp")
  volamp_note=""
  [[ "$volamp" != "$volamp_raw" ]] && volamp_note=" cap LRA"

  local preset_raw
  preset_raw=$(delta_to_preset "$delta")
  local preset="${preset_raw%%|*}"
  local p_color="${preset_raw##*|}"

  local preset_desc
  case "$preset" in
    SONAR) preset_desc="Surround molto deboli, ricostruzione psicoacustica" ;;
    AURA)  preset_desc="Surround deboli, allargamento prudente" ;;
    WIDE)  preset_desc="Surround medi, allargo scena sonora laterale" ;;
    AEGIS) preset_desc="Surround buoni, controllo e bilanciamento" ;;
    VOICE) preset_desc="Surround forti o centro coperto, priorita' voce" ;;
  esac

  GLOBAL_METRIC_VALUES+=("$delta")
  GLOBAL_METRIC_FILES+=("$(basename "$f")")
  GLOBAL_METRIC_PATHS+=("$f")
  GLOBAL_LOUDNESS_VALUES+=("${i_full:-N/A}")
  GLOBAL_VOLAMP_VALUES+=("$volamp")
  GLOBAL_WIDTH_VALUES+=("${width_ms:-N/A}")
  GLOBAL_LRA_VALUES+=("${lra_full:-N/A}")

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

  if [[ "$CNT" -gt 1 ]]; then
    _vals_tmp=$(mktemp)
    printf '%s\n' "${GLOBAL_METRIC_VALUES[@]}" > "$_vals_tmp"

    _stats_tmp=$(mktemp)
    awk '{v[NR]=$1+0} END{n=NR; for(i=2;i<=n;i++){k=v[i];j=i-1; while(j>=1&&v[j]>k){v[j+1]=v[j];j--}; v[j+1]=k}; mn=v[1];mx=v[n]; s=0;for(i=1;i<=n;i++)s+=v[i]; avg=s/n; raw=0.25*n;rank=int(raw);if(raw>rank)rank=rank+1; if(rank<1)rank=1;if(rank>n)rank=n; pctl=v[rank]; printf "%.1f %.1f %.1f %.1f\n",mn,mx,avg,pctl}' "$_vals_tmp" > "$_stats_tmp"

    read -r m_min m_max m_avg m_pctl < "$_stats_tmp"
    rm -f "$_vals_tmp" "$_stats_tmp"

    m_spread=$(awk -v mx="$m_max" -v mn="$m_min" 'BEGIN { s=mx-mn; if(s<0)s=-s; printf "%.1f",s }')
    HIGH_SPREAD=$(awk -v s="$m_spread" 'BEGIN { print (s > 4.0) ? 1 : 0 }')
  else
    m_min="${GLOBAL_METRIC_VALUES[0]}"
    m_max="${GLOBAL_METRIC_VALUES[0]}"
    m_avg="${GLOBAL_METRIC_VALUES[0]}"
    m_pctl="${GLOBAL_METRIC_VALUES[0]}"
    m_spread="0.0"
  fi

  season_raw=$(delta_to_preset "$m_pctl")
  season_preset="${season_raw%%|*}"
  season_color="${season_raw##*|}"

  case "$season_preset" in
    SONAR) season_desc="Surround molto deboli, serve ricostruzione psicoacustica" ;;
    AURA)  season_desc="Surround deboli, allargamento prudente" ;;
    WIDE)  season_desc="Surround medi, allargamento scena laterale" ;;
    AEGIS) season_desc="Surround buoni, controllo e bilanciamento" ;;
    VOICE) season_desc="Surround forti o centro coperto, priorita' voce" ;;
  esac

  if [[ "$CNT" -gt 1 ]]; then
    echo -e "  Episodi analizzati:  \033[1;37m${CNT}\033[0m"
    echo -e "  Media:               \033[0;37m${m_avg} dB\033[0m"
    echo -e "  P25 (audiofilo):     ${season_color}${m_pctl} dB\033[0m"
    echo -e "  Range:               \033[0;37m${m_min} / ${m_max} dB  (spread: ${m_spread} dB)\033[0m"
    echo -e "  Preset Consigliato:  ${season_color}${season_preset}\033[0m  (${season_desc})"

    if [[ ${#GLOBAL_VOLAMP_VALUES[@]} -gt 0 ]]; then
      _volamp_tmp=$(mktemp)
      printf '%s\n' "${GLOBAL_VOLAMP_VALUES[@]}" > "$_volamp_tmp"
      season_volamp=$(awk '{v[NR]=$1+0} END{n=NR; for(i=2;i<=n;i++){k=v[i];j=i-1; while(j>=1&&v[j]>k){v[j+1]=v[j];j--}; v[j+1]=k}; raw=0.75*n;rank=int(raw);if(raw>rank)rank=rank+1; if(rank<1)rank=1;if(rank>n)rank=n; printf "%.1f",v[rank]}' "$_volamp_tmp")
      rm -f "$_volamp_tmp"
      echo -e "  Volamp Stagionale:  \033[1;36m${season_volamp} dB\033[0m  (P75 prudente della loudness)"
    fi

    if [[ "$HIGH_SPREAD" -eq 1 ]]; then
      echo ""
      echo -e "  \033[0;33m⚠  Spread > 4 dB: la stagione e' eterogenea.\033[0m"
      echo -e "  \033[0;33m   Per risultati ottimali, considera i preset per-file:\033[0m"
      echo ""
      for (( i=0; i<CNT; i++ )); do
        pf_raw=$(delta_to_preset "${GLOBAL_METRIC_VALUES[$i]}")
        pf_preset="${pf_raw%%|*}"
        pf_color="${pf_raw##*|}"
        fname="${GLOBAL_METRIC_FILES[$i]}"
        (( ${#fname} > 50 )) && fname="${fname:0:47}..."
        printf "    %-50s  %b%-5s\033[0m  (%s dB)\n" "$fname" "$pf_color" "$pf_preset" "${GLOBAL_METRIC_VALUES[$i]}"
      done
    fi
  fi

  # ── Generazione batch file ─────────────────────────────────────────────────
  BATCH_FILE="run_processing.sh"

  {
    echo '#!/usr/bin/env bash'
    echo "# ── Batch generato da audio_analyzer_delta (V4.6 DELTA/VOLAMP/FILES/AUTORUN) ──"
    echo "# Data: $(date '+%Y-%m-%d %H:%M')"
    echo "# Metrica: DELTA | Percentile: P25 (audiofilo)"
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

    for (( i=0; i<CNT; i++ )); do
      case "${GLOBAL_METRIC_PATHS[$i]}" in
        *_AC3_Aegis.mkv|*_AC3_Sonar.mkv|*_AC3_Wide.mkv|*_AC3_Aura.mkv|*_AC3_Voice.mkv|\
        *_EAC3_Aegis.mkv|*_EAC3_Sonar.mkv|*_EAC3_Wide.mkv|*_EAC3_Aura.mkv|*_EAC3_Voice.mkv)
          continue
          ;;
      esac

      file_preset=""
      if [[ "$HIGH_SPREAD" -eq 1 ]]; then
        pf_raw=$(delta_to_preset "${GLOBAL_METRIC_VALUES[$i]}")
        file_preset="${pf_raw%%|*}"
      else
        file_preset="$season_preset"
      fi

      file_preset_lower="${file_preset,,}"
      file_volamp="${GLOBAL_VOLAMP_VALUES[$i]:-0}"
      file_loudness="${GLOBAL_LOUDNESS_VALUES[$i]:-N/A}"
      file_width="${GLOBAL_WIDTH_VALUES[$i]:-N/A}"
      file_lra="${GLOBAL_LRA_VALUES[$i]:-N/A}"
      escaped_path=$(printf '%q' "${GLOBAL_METRIC_PATHS[$i]}")

      printf '"$PROC" "$CODEC" "$KEEP" %s "$BITRATE" %s %s  # DELTA %s dB | I=%s LUFS | LRA=%s LU | WidthMS=%s dB | volamp=%s dB\n' \
        "$escaped_path" "$file_preset_lower" "$file_volamp" "${GLOBAL_METRIC_VALUES[$i]}" "$file_loudness" "$file_lra" "$file_width" "$file_volamp"
    done

    echo ''
    echo 'echo "Batch completato."'
  } > "$BATCH_FILE"

  chmod +x "$BATCH_FILE"
  ok "Batch file generato: ${BATCH_FILE}"
else
  warn "Nessun risultato Delta valido: run_processing.sh non generato."
fi

echo -e ""
ok "Analisi completata. Nessun file audio e' stato modificato."
