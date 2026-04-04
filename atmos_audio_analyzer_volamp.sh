#!/usr/bin/env bash
# set -e rimosso: causa exit su espressioni aritmetiche (es. var=0; ((var++)))
set -uo pipefail
# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   audio_analyzer_atmos.sh - V1.2 VOLAMP - Aprile 2026                        │
# │                                                                              │
# │   Variante di audio_analyzer.sh specializzata per file prodotti da           │
# │   atmos_to_51_dynaudnorm.sh (dual-track: a:0 = EAC3 5.1 DynNorm,             │
# │   a:1 = EAC3 Atmos originale).                                               │
# │                                                                              │
# │   Analizza SOLO la traccia a:0 (5.1 core) con metrica delta o lra,           │
# │   suggerisce il preset ottimale + volamp, e genera un batch che:             │
# │     1. Invoca aegis_sonar_wide_aura_voice_volamp.sh sulla  5.1 (keep=no)     │
# │     2. Rimuxza il risultato con la traccia Atmos originale dal sorgente      │
# │                                                                              │
# │   La traccia Atmos non viene mai toccata né decodificata.                    │
# │                                                                              │
# │   STRUTTURA OUTPUT FINALE:                                                   │
# │     • Traccia 1: EAC3 5.1 processata con preset surround (default)           │
# │     • Traccia 2: EAC3 Atmos originale (copia bit-perfect)                    │
# │                                                                              │
# │   UTILIZZO:                                                                  │
# │     ./audio_analyzer_atmos.sh <file|""> [modo][codec][keep_atmos][bitrate]   │
# │                                                                              │
# │   PARAMETRI:                                                                 │
# │     file    : File sorgente (output di atmos_to_51_dynaudnorm.sh).           │
# │               Usa "" per batch su tutti i *_EAC3_51_DynNorm.mkv              │
# │     modo    : probe  (Default) Solo struttura tracce audio.                  │
# │               lra    Misura LRA, suggerisce preset e volamp.                 │
# │               delta  Misura Delta SUR-FC e suggerisce preset e volamp.       │
# │   codec   : eac3   (Default) Codec per il batch file generato.               │
# │   ac3    Alternativa.                                                        │
# │   keep_atmos : si  (Default) Mantiene la traccia Atmos/originale come        │
# │   seconda traccia quando disponibile.                                        │
# │   no  Produce output con sola traccia processata.                            │
# │   bitrate : 640k   (Default) Bitrate per la traccia processata.              │
# │                                                                              │
# │   DIPENDENZE: ffmpeg, ffprobe, awk                                           │
# ╰──────────────────────────────────────────────────────────────────────────────╯

C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"

info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

usage() {
  cat <<'USAGE'
UTILIZZO:
  ./audio_analyzer_atmos.sh <file|""> [modo] [codec] [keep_atmos] [bitrate]

PARAMETRI:
  file    : File sorgente. Accetta:
            - Output di atmos_to_51_dynaudnorm.sh (dual-track: 5.1 + Atmos)
            - File con singola traccia EAC3 Atmos (single-track)
            Usa "" (stringa vuota) per batch su tutti i video nella cartella.
  codec   : eac3   (Default) Codec per il batch file generato.
            ac3    Alternativa.
  keep_atmos : si  (Default) Mantiene la traccia Atmos/originale come
                 seconda traccia quando disponibile.
               no  Produce output con sola traccia processata.
  bitrate : 640k   (Default) Bitrate per la traccia processata.
  codec   : eac3   (Default) Codec per il batch file generato.
            ac3    Alternativa.
  bitrate : 640k   (Default) Bitrate per il batch file generato.

ESEMPI:
  ./audio_analyzer_atmos.sh film_EAC3_51_DynNorm.mkv probe
  ./audio_analyzer_atmos.sh film_EAC3_51_DynNorm.mkv delta
  ./audio_analyzer_atmos.sh "" delta                 # batch
  ./audio_analyzer_atmos.sh "" delta eac3 si 768k    # batch con Atmos/originale
  ./audio_analyzer_atmos.sh "" delta eac3 no 640k    # batch solo traccia processata

WORKFLOW TIPICO:
  1. atmos_to_51_dynaudnorm.sh film.mkv              # genera *_EAC3_51_DynNorm.mkv
  2. audio_analyzer_atmos.sh "" delta                # analizza e genera batch
  3. ./run_processing_atmos.sh                       # applica preset + rimux Atmos

DIPENDENZE: ffmpeg, ffprobe, awk
USAGE
  exit 0
}

# ── Help: nessun argomento o flag esplicito ───────────────────────────────────
[[ $# -eq 0 || "${1:-}" =~ ^(-h|--help)$ ]] && usage

for _bin in ffmpeg ffprobe awk; do
  command -v "$_bin" &>/dev/null || { err "$_bin non trovato nel PATH"; exit 1; }
done

INPUT_FILE="${1:-}"
MODE="${2:-probe}"
BATCH_CODEC="${3:-eac3}"
KEEP_ATMOS="${4:-si}"
BATCH_BITRATE="${5:-640k}"

# Validazione
case "$BATCH_CODEC" in ac3|eac3) ;; *) err "Codec '$BATCH_CODEC' non valido. Usa ac3 o eac3."; usage ;; esac
case "$KEEP_ATMOS" in si|no) ;; *) err "keep_atmos '$KEEP_ATMOS' non valido. Usa si o no."; usage ;; esac
[[ "$BATCH_BITRATE" =~ ^[0-9]+(k|M)?$ ]] || { err "Bitrate '$BATCH_BITRATE' non valido. Es: 640k, 768k."; usage; }
[[ "$BATCH_BITRATE" =~ k$|M$ ]] || BATCH_BITRATE="${BATCH_BITRATE}k"

case "$MODE" in
  probe|lra|delta) ;;
  *) err "Modo '$MODE' sconosciuto. Usa 'probe', 'lra' o 'delta'."; usage ;;
esac

if [[ "$MODE" == "lra" || "$MODE" == "delta" ]]; then
  info "Metrica: ${MODE^^} | Batch: ${BATCH_CODEC} / keep_atmos=${KEEP_ATMOS} / ${BATCH_BITRATE}"
  info "Volamp heuristic: target loudness prudente con step 0 / 1.5 / 2 / 2.5 dB"
fi

# Variabili globali per il Verdetto Stagionale
GLOBAL_METRIC_VALUES=()
GLOBAL_METRIC_FILES=()
GLOBAL_METRIC_PATHS=()
GLOBAL_HAS_ATMOS=()   # "yes" se esiste traccia Atmos separata, "no" se traccia singola
GLOBAL_ATMOS_STREAM_INDEXES=()
GLOBAL_LOUDNESS_VALUES=()
GLOBAL_VOLAMP_VALUES=()

# ────────────────────────────────────────────────────────────────────────────────
# Raccolta file
# ────────────────────────────────────────────────────────────────────────────────
FILES=()
if [[ -n "$INPUT_FILE" ]]; then
    [[ -f "$INPUT_FILE" ]] || { err "File '$INPUT_FILE' inesistente."; exit 1; }
    FILES+=("$INPUT_FILE")
else
    # Batch: prima cerca output di atmos_to_51_dynaudnorm.sh, poi tutti i video
    shopt -s nullglob
    FILES+=( *_EAC3_51_DynNorm.mkv )
    # Se nessun DynNorm trovato, cerca tutti i container video
    if (( ${#FILES[@]} == 0 )); then
      FILES+=( *.mkv *.MKV *.mp4 *.MP4 *.m2ts *.M2TS )
    fi
    shopt -u nullglob
fi

(( ${#FILES[@]} == 0 )) && { err "Nessun file video trovato."; exit 1; }

# ────────────────────────────────────────────────────────────────────────────────
# Validazione struttura dual-track
#
# Verifica che il file abbia almeno 2 tracce audio e che a:0 sia 5.1.
# Restituisce: "a0_global_idx|a0_ch|a0_layout|a1_global_idx|num_tracks"
# NOTA: warn/info dentro questa funzione vanno a stderr (&2) perché
# il chiamante cattura stdout via $(). Altrimenti i messaggi inquinano il valore.
# ────────────────────────────────────────────────────────────────────────────────
validate_dual_track() {
  local f="$1"
  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout,codec_name:stream_tags=title \
    -of csv=p=0 "$f" 2>/dev/null </dev/null || true)
  raw_data="${raw_data//$'\r'/}"

  [[ -z "$raw_data" ]] && { echo -e "${C_WARN} Nessuna traccia audio in $f" >&2; return 1; }

  local lines
  mapfile -t lines <<< "$raw_data"

  local num_tracks=${#lines[@]}

  if [[ $num_tracks -lt 2 ]]; then
    echo -e "${C_INFO} File ha $num_tracks traccia audio (nessuna Atmos separata). Analizzo a:0." >&2
  fi

  # Traccia a:0 (prima audio)
  # ffprobe csv order: index, codec_name, channels, channel_layout, [tags...]
  local idx0 codec0 ch0 layout0 title0
  IFS=',' read -r idx0 codec0 ch0 layout0 title0 <<<"${lines[0]}"
  ch0="${ch0:-0}"
  layout0="${layout0:-unknown}"

  # EAC3 Atmos decodificato da FFmpeg produce 5.1(side) anche da una traccia
  # JOC. Se il layout non viene esposto dal container, lo deduciamo dal codec.
  if [[ "$layout0" == "unknown" || -z "$layout0" ]]; then
    if [[ "$ch0" -eq 6 ]]; then
      layout0="5.1(side)"
      echo -e "${C_INFO} Layout non esposto dal container → assunto 5.1(side) per EAC3 6ch" >&2
    fi
  fi

  if [[ "$ch0" -ne 6 ]]; then
    echo -e "${C_WARN} Traccia a:0 (idx:$idx0) ha $ch0 canali, attesi 6 (5.1). Salto." >&2
    return 1
  fi

  # Traccia a:1 (seconda audio, Atmos — potrebbe non esistere)
  local idx1="none"
  if [[ $num_tracks -ge 2 ]]; then
    IFS=',' read -r idx1 _ _ _ _ <<<"${lines[1]}"
  fi

  echo "${idx0}|${ch0}|${layout0}|${idx1}|${num_tracks}"
}

# ────────────────────────────────────────────────────────────────────────────────
# Probe: struttura tracce audio
# ────────────────────────────────────────────────────────────────────────────────
probe_audio_streams() {
  local f="$1"
  info "--- Struttura Audio: $f ---"

  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,codec_name,channels,channel_layout,bit_rate:stream_tags=language,title \
    -of csv=p=0 "$f" 2>/dev/null </dev/null || true)
  raw_data="${raw_data//$'\r'/}"

  if [[ -z "$raw_data" ]]; then
    warn "Nessuna traccia audio trovata."
    return 1
  fi

  local _A_LINES
  mapfile -t _A_LINES <<< "$raw_data"

  local track_num=0
  for line in "${_A_LINES[@]}"; do
    [[ -z "$line" ]] && continue
    IFS=',' read -r idx codec ch layout bitrate lang title <<<"$line"
    ch="${ch:-?}"
    codec="${codec:-?}"
    layout="${layout:-unknown}"
    bitrate="${bitrate:-?}"
    lang="${lang:-und}"
    title="${title:-}"

    local role=""
    local total_tracks=${#_A_LINES[@]}
    if [[ $track_num -eq 0 ]]; then
      if [[ $total_tracks -ge 2 ]]; then
        role=" ← TARGET (5.1 core)"
      else
        role=" ← TARGET (unica traccia)"
      fi
    elif [[ $track_num -eq 1 ]]; then
      role=" ← ATMOS (preservata)"
    fi

    echo "  -> a:${track_num} [idx:$idx]: $codec $ch ch ($layout) | ${bitrate} bps | $lang | $title${role}"
    (( track_num++ )) || true
  done
  echo "------------------------------------------------------------"
}

# ────────────────────────────────────────────────────────────────────────────────
# Misura Integrated Loudness di un singolo canale
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
  i_val=$(grep -E "^\s+I:\s+-?[0-9]" "$log_file" | tr -d '\r' \
          | awk '{print $2}' | tail -1)
  rm -f "$log_file"

  echo "${i_val:-}"
}

# ────────────────────────────────────────────────────────────────────────────────
# Mappa Delta -> Preset
# ────────────────────────────────────────────────────────────────────────────────
delta_to_preset() {
  local d="$1"
  local is_aura=$(awk -v d="$d" 'BEGIN { print (d < -12.0) ? 1 : 0 }')
  local is_sonar=$(awk -v d="$d" 'BEGIN { print (d >= -12.0 && d < -7.0) ? 1 : 0 }')
  local is_wide=$(awk -v d="$d" 'BEGIN { print (d >= -7.0 && d < -4.0) ? 1 : 0 }')
  local is_aegis=$(awk -v d="$d" 'BEGIN { print (d >= -4.0 && d <= 0.0) ? 1 : 0 }')

  if   [[ "$is_aura"  -eq 1 ]]; then echo "AURA|\033[1;35m"
  elif [[ "$is_sonar" -eq 1 ]]; then echo "SONAR|\033[1;36m"
  elif [[ "$is_wide"  -eq 1 ]]; then echo "WIDE|\033[1;32m"
  elif [[ "$is_aegis" -eq 1 ]]; then echo "AEGIS|\033[1;31m"
  else                                echo "VOICE|\033[1;33m"
  fi
}

# ────────────────────────────────────────────────────────────────────────────────
# Mappa LRA -> Preset
# ────────────────────────────────────────────────────────────────────────────────
lra_to_preset() {
  local lra="$1"
  local is_voice=$(awk -v l="$lra" 'BEGIN { print (l < 6.0) ? 1 : 0 }')
  local is_aura=$(awk -v l="$lra" 'BEGIN { print (l >= 6.0 && l < 10.0) ? 1 : 0 }')
  local is_wide=$(awk -v l="$lra" 'BEGIN { print (l >= 10.0 && l < 15.0) ? 1 : 0 }')
  local is_sonar=$(awk -v l="$lra" 'BEGIN { print (l >= 15.0 && l < 20.0) ? 1 : 0 }')

  if   [[ "$is_voice" -eq 1 ]]; then echo "VOICE|\033[1;33m"
  elif [[ "$is_aura"  -eq 1 ]]; then echo "AURA|\033[1;35m"
  elif [[ "$is_wide"  -eq 1 ]]; then echo "WIDE|\033[1;32m"
  elif [[ "$is_sonar" -eq 1 ]]; then echo "SONAR|\033[1;36m"
  else                                echo "AEGIS|\033[1;31m"
  fi
}


# ────────────────────────────────────────────────────────────────────────────────
# Loudness Integrata stream target + volamp heuristic
# ────────────────────────────────────────────────────────────────────────────────
measure_stream_loudness() {
  local f="$1" stream="$2"
  local log_file
  log_file=$(mktemp)

  ffmpeg -y -nostdin -hide_banner -nostats     -i "$f"     -map "0:${stream}"     -af "ebur128=framelog=verbose"     -vn -sn -f null -     >/dev/null 2>"$log_file" </dev/null || true

  local i_val
  i_val=$(grep -E "^\s+I:\s+-?[0-9]" "$log_file" | tr -d '\r'           | awk '{print $2}' | tail -1)
  rm -f "$log_file"

  echo "${i_val:-}"
}

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

metric_to_preset() {
  if [[ "$MODE" == "delta" ]]; then
    delta_to_preset "$1"
  else
    lra_to_preset "$1"
  fi
}

# ────────────────────────────────────────────────────────────────────────────────
# Analisi Delta — punta alla traccia a:0 (indice globale da validate)
# ────────────────────────────────────────────────────────────────────────────────
scan_delta() {
  local f="$1" target_stream="$2" layout="$3"
  info "Avvio analisi Delta SUR-FC su: $f (stream idx:$target_stream)"

  # Nomi canali surround
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
    warn "Loudness non misurabile per $f. Canale silenzioso o troppo corto?"
    return 1
  fi

  local i_sur delta
  _delta_tmp=$(mktemp)
  awk -v sl="$i_sl" -v sr="$i_sr" -v fc="$i_fc" 'BEGIN { sur=-10*log(((10^(sl/-10))+(10^(sr/-10)))/2)/log(10); d=sur-fc; printf "%.1f %.1f\n",sur,d }' < /dev/null > "$_delta_tmp"
  read -r i_sur delta < "$_delta_tmp"
  rm -f "$_delta_tmp"

  local i_full volamp volamp_desc volume_status
  i_full=$(measure_stream_loudness "$f" "$target_stream")
  volamp=$(loudness_to_volamp "$i_full")
  volamp_desc=$(volamp_to_desc "$volamp")
  volume_status=$(source_volume_status "$volamp")

  local preset_raw
  preset_raw=$(delta_to_preset "$delta")
  local preset="${preset_raw%%|*}"
  local p_color="${preset_raw##*|}"

  local preset_desc
  case "$preset" in
    AURA)  preset_desc="Surround morti/inesistenti, gonfia il poco che c'e'" ;;
    SONAR) preset_desc="Surround anemici, tira fuori tutto dal segnale"      ;;
    WIDE)  preset_desc="Surround medi, allargamento laterale"                ;;
    AEGIS) preset_desc="Surround gia' incazzati, controlla e bilancia"       ;;
    VOICE) preset_desc="Muro di suono, solo EQ voce sui rear"               ;;
  esac

  GLOBAL_METRIC_VALUES+=("$delta")
  GLOBAL_METRIC_FILES+=("$(basename "$f")")
  GLOBAL_METRIC_PATHS+=("$f")
  GLOBAL_LOUDNESS_VALUES+=("${i_full:-N/A}")
  GLOBAL_VOLAMP_VALUES+=("$volamp")

  ok "Risultati Delta per: $f"
  echo -e "  \033[1;33mI(FC):    \033[0m  ${i_fc} LUFS"
  echo -e "  \033[1;33mI(SL):    \033[0m  ${i_sl} LUFS"
  echo -e "  \033[1;33mI(SR):    \033[0m  ${i_sr} LUFS"
  echo -e "  \033[1;33mI(SUR):   \033[0m  ${i_sur} LUFS  (media energetica SL+SR)"
  echo -e "  \033[1;37mDelta:    \033[0m  ${p_color}${delta} dB\033[0m  (SUR - FC)"
  echo -e "  \033[1;37mPreset:   \033[0m  ${p_color}${preset}\033[0m  (${preset_desc})"
  echo -e "  \033[1;37mVolume sorgente:\033[0m  \033[1;36m${volume_status}\033[0m"
  echo -e "  \033[1;37mVolamp:   \033[0m  \033[1;36m${volamp} dB\033[0m  (${volamp_desc})"
  echo ""
}

# ────────────────────────────────────────────────────────────────────────────────
# Analisi LRA — punta alla traccia a:0
# ────────────────────────────────────────────────────────────────────────────────
scan_lra() {
  local f="$1" target_stream="$2"
  info "Avvio analisi EBU R128 su: $f (stream idx:$target_stream)"

  local log_file
  log_file=$(mktemp)

  ffmpeg -y -nostdin -hide_banner -nostats \
    -i "$f" \
    -map "0:${target_stream}" \
    -af "ebur128=framelog=verbose" \
    -vn -sn -f null - \
    >/dev/null 2>"$log_file" </dev/null || true

  local i_val
  i_val=$(grep -E "^\s+I:\s+-?[0-9]" "$log_file" | tr -d '\r' \
          | awk '{print $2}' | tail -1)

  local lra_val
  lra_val=$(grep -E "^\s+LRA:\s+-?[0-9]" "$log_file" | tr -d '\r' \
            | awk '{print $2}' | tail -1)

  local peak_val
  peak_val=$(grep -E "^\s+Peak:\s+-?[0-9]" "$log_file" | tr -d '\r' \
             | awk '{print $2}' | tail -1)

  rm -f "$log_file"

  if [[ -z "$lra_val" ]]; then
    warn "Dati EBU R128 non trovati per $f."
    return 1
  fi

  local preset_raw
  preset_raw=$(lra_to_preset "$lra_val")
  local preset="${preset_raw%%|*}"
  local p_color="${preset_raw##*|}"

  local preset_desc
  case "$preset" in
    VOICE) preset_desc="Dinamica piatta, dialoghi compressi" ;;
    AURA)  preset_desc="Dinamica ridotta, surround contenuto" ;;
    WIDE)  preset_desc="Buona dinamica, palcoscenico stretto" ;;
    SONAR) preset_desc="Alta dinamica, atmosfere ricche"      ;;
    AEGIS) preset_desc="Transienti estremi, blockbuster"      ;;
  esac

  local volamp volamp_desc volume_status
  volamp=$(loudness_to_volamp "$i_val")
  volamp_desc=$(volamp_to_desc "$volamp")
  volume_status=$(source_volume_status "$volamp")

  GLOBAL_METRIC_VALUES+=("$lra_val")
  GLOBAL_METRIC_FILES+=("$(basename "$f")")
  GLOBAL_METRIC_PATHS+=("$f")
  GLOBAL_LOUDNESS_VALUES+=("${i_val:-N/A}")
  GLOBAL_VOLAMP_VALUES+=("$volamp")

  ok "Risultati EBU R128 per: $f"
  echo -e "  \033[1;33mLoudness Integrata:\033[0m  ${i_val:-N/A} LUFS"
  echo -e "  \033[1;33mLRA (Dinamica):    \033[0m  ${p_color}${lra_val} LU\033[0m"
  echo -e "  \033[1;33mTrue Peak:         \033[0m  ${peak_val:-N/A} dBTP"
  echo -e "  \033[1;37mPreset Consigliato:\033[0m  ${p_color}${preset}\033[0m  (${preset_desc})"
  echo -e "  \033[1;37mVolume sorgente:   \033[0m  \033[1;36m${volume_status}\033[0m"
  echo -e "  \033[1;37mVolamp:            \033[0m  \033[1;36m${volamp} dB\033[0m  (${volamp_desc})"
  echo ""
}

# ────────────────────────────────────────────────────────────────────────────────
# CICLO PRINCIPALE
# ────────────────────────────────────────────────────────────────────────────────
for CUR_FILE in "${FILES[@]}"; do
  info "Analisi: $CUR_FILE"
  probe_audio_streams "$CUR_FILE" || continue

  # Valida struttura dual-track e ottieni indici
  TRACK_INFO=$(validate_dual_track "$CUR_FILE") || continue
  IFS='|' read -r A0_IDX A0_CH A0_LAYOUT A1_IDX A_NUM_TRACKS <<<"$TRACK_INFO"

  local_has_atmos="no"
  [[ "$A1_IDX" != "none" ]] && local_has_atmos="yes"

  if [[ "$A1_IDX" != "none" ]]; then
    info "Dual-track: a:0 (5.1 idx:$A0_IDX) + a:1 (Atmos idx:$A1_IDX)"
  else
    info "Single-track: a:0 (idx:$A0_IDX, $A0_CH ch, $A0_LAYOUT)"
  fi

  # Pre-scan array count per verificare se la scan ha accumulato
  _pre_count=${#GLOBAL_METRIC_VALUES[@]}

  case "$MODE" in
    lra)   scan_lra   "$CUR_FILE" "$A0_IDX" ;;
    delta) scan_delta  "$CUR_FILE" "$A0_IDX" "$A0_LAYOUT" ;;
  esac

  # Se la scan ha accumulato un valore, sincronizziamo HAS_ATMOS
  if [[ ${#GLOBAL_METRIC_VALUES[@]} -gt $_pre_count ]]; then
    GLOBAL_HAS_ATMOS+=("$local_has_atmos")
    GLOBAL_ATMOS_STREAM_INDEXES+=("$A1_IDX")
  fi
done

# ────────────────────────────────────────────────────────────────────────────────
# VERDETTO STAGIONALE (solo se analizzati >= 2 file)
# ────────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "lra" || "$MODE" == "delta" ]] && [[ "${#GLOBAL_METRIC_VALUES[@]}" -gt 1 ]]; then
  CNT=${#GLOBAL_METRIC_VALUES[@]}

  _vals_tmp=$(mktemp)
  printf '%s\n' "${GLOBAL_METRIC_VALUES[@]}" > "$_vals_tmp"

  _stats_tmp=$(mktemp)
  if [[ "$MODE" == "delta" ]]; then
    awk '{v[NR]=$1+0} END{n=NR; for(i=2;i<=n;i++){k=v[i];j=i-1; while(j>=1&&v[j]>k){v[j+1]=v[j];j--}; v[j+1]=k}; mn=v[1];mx=v[n]; s=0;for(i=1;i<=n;i++)s+=v[i]; avg=s/n; raw=0.25*n;rank=int(raw);if(raw>rank)rank=rank+1; if(rank<1)rank=1;if(rank>n)rank=n; pctl=v[rank]; printf "%.1f %.1f %.1f %.1f\n",mn,mx,avg,pctl}' "$_vals_tmp" > "$_stats_tmp"
  else
    awk '{v[NR]=$1+0} END{n=NR; for(i=2;i<=n;i++){k=v[i];j=i-1; while(j>=1&&v[j]>k){v[j+1]=v[j];j--}; v[j+1]=k}; mn=v[1];mx=v[n]; s=0;for(i=1;i<=n;i++)s+=v[i]; avg=s/n; raw=0.75*n;rank=int(raw);if(raw>rank)rank=rank+1; if(rank<1)rank=1;if(rank>n)rank=n; pctl=v[rank]; printf "%.1f %.1f %.1f %.1f\n",mn,mx,avg,pctl}' "$_vals_tmp" > "$_stats_tmp"
  fi

  read -r m_min m_max m_avg m_pctl < "$_stats_tmp"
  rm -f "$_vals_tmp" "$_stats_tmp"

  m_spread=$(awk -v mx="$m_max" -v mn="$m_min" 'BEGIN { s=mx-mn; if(s<0)s=-s; printf "%.1f",s }')

  season_raw=$(metric_to_preset "$m_pctl")
  season_preset="${season_raw%%|*}"
  season_color="${season_raw##*|}"

  if [[ "$MODE" == "delta" ]]; then
    UNIT="dB"
    PCTL_LABEL="P25 (audiofilo)"
    case "$season_preset" in
      AURA)  season_desc="Surround morti/inesistenti nella maggioranza degli episodi" ;;
      SONAR) season_desc="Surround anemici, serve boost aggressivo"                   ;;
      WIDE)  season_desc="Surround medi, allargamento laterale"                       ;;
      AEGIS) season_desc="Surround gia' presenti, controllo e bilanciamento"          ;;
      VOICE) season_desc="Muro di suono, solo EQ voce"                                ;;
    esac
  else
    UNIT="LU"
    PCTL_LABEL="P75 (audiofilo)"
    case "$season_preset" in
      VOICE) season_desc="Contenuto fortemente compresso (broadcast/streaming lossy)" ;;
      AURA)  season_desc="Serie TV standard, dinamica ridotta"                        ;;
      WIDE)  season_desc="Blu-ray serie, film moderni"                               ;;
      SONAR) season_desc="Cinema, Blu-ray UHD con audio di qualita'"                 ;;
      AEGIS) season_desc="Blockbuster, film di guerra, transienti esplosivi"         ;;
    esac
  fi

  HIGH_SPREAD=$(awk -v s="$m_spread" 'BEGIN { print (s > 4.0) ? 1 : 0 }')

  echo ""
  echo -e "  ╭── VERDETTO STAGIONALE ──────────────────────────────────────╮"
  echo -e "  Episodi analizzati:  \033[1;37m${CNT}\033[0m"
  echo -e "  Media:               \033[0;37m${m_avg} ${UNIT}\033[0m"
  echo -e "  ${PCTL_LABEL}: ${season_color}${m_pctl} ${UNIT}\033[0m"
  echo -e "  Range:               \033[0;37m${m_min} / ${m_max} ${UNIT}  (spread: ${m_spread} ${UNIT})\033[0m"
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
    echo -e "  \033[0;33m⚠  Spread > 4 ${UNIT}: la stagione e' eterogenea.\033[0m"
    echo -e "  \033[0;33m   Per risultati ottimali, considera i preset per-file:\033[0m"
    echo ""
    for (( i=0; i<CNT; i++ )); do
      pf_raw=$(metric_to_preset "${GLOBAL_METRIC_VALUES[$i]}")
      pf_preset="${pf_raw%%|*}"
      pf_color="${pf_raw##*|}"
      fname="${GLOBAL_METRIC_FILES[$i]}"
      (( ${#fname} > 50 )) && fname="${fname:0:47}..."
      printf "    %-50s  %b%-5s\033[0m  (%s %s)\n" "$fname" "$pf_color" "$pf_preset" "${GLOBAL_METRIC_VALUES[$i]}" "$UNIT"
    done
  fi

  # ── Generazione batch file ─────────────────────────────────────────────────
  # Due modalità per file:
  #   DUAL-TRACK (output di atmos_to_51_dynaudnorm.sh, a:0 = 5.1, a:1 = Atmos):
  #     STEP 1: Processore con keep=no → file intermedio (solo traccia processata)
  #     STEP 2: Rimux file intermedio + a:1 dal sorgente → output finale
  #     STEP 3: Rimuovi file intermedio
  #
  #   SINGLE-TRACK (file con sola traccia Atmos/EAC3):
  #     Processore con keep=si → output finale (processata + originale preservata)
  #     Nessun rimux necessario.
  BATCH_FILE="run_processing_atmos.sh"

  {
    echo '#!/usr/bin/env bash'
    echo "# ── Batch generato da audio_analyzer_atmos (V1 - ${MODE^^}) ──"
    echo "# Data: $(date '+%Y-%m-%d %H:%M')"
    echo "# Metrica: ${MODE^^} | Percentile: ${PCTL_LABEL}"
    echo '#'
    echo '# WORKFLOW: processore surround sulla traccia 5.1.'
    echo '# File dual-track: processa a:0, poi opzionalmente rimux con a:1 (Atmos).'
    echo '# File single-track: keep variabile in base a KEEP_ATMOS.'
    echo '#'
    echo '# Modifica le variabili sotto se necessario, poi lancia:'
    echo "#   ./${BATCH_FILE}"
    echo '#'
    echo ''
    echo '# ── CONFIGURAZIONE (modifica qui) ──'
    echo "CODEC=\"${BATCH_CODEC}\"        # ac3 | eac3"
    echo "BITRATE=\"${BATCH_BITRATE}\"      # es. 640k, 768k"
    echo 'PROC="./aegis_sonar_wide_aura_voice_volamp.sh"'
    echo ''
    echo '# ── COMANDI ──'
    echo 'ERRORS=0'
    echo ''

    for (( i=0; i<CNT; i++ )); do
      local_file="${GLOBAL_METRIC_PATHS[$i]}"
      has_atmos="${GLOBAL_HAS_ATMOS[$i]}"
      atmos_stream_idx="${GLOBAL_ATMOS_STREAM_INDEXES[$i]}"
      file_volamp="${GLOBAL_VOLAMP_VALUES[$i]:-0}"
      file_loudness="${GLOBAL_LOUDNESS_VALUES[$i]:-N/A}"

      file_preset=""
      if [[ "$HIGH_SPREAD" -eq 1 ]]; then
        pf_raw=$(metric_to_preset "${GLOBAL_METRIC_VALUES[$i]}")
        file_preset="${pf_raw%%|*}"
      else
        file_preset="$season_preset"
      fi
      file_preset_lower="${file_preset,,}"
      escaped_path=$(printf '%q' "$local_file")

      local_base="${local_file%.*}"
      codec_upper="${BATCH_CODEC^^}"
      preset_cap="${file_preset_lower^}"
      proc_output="${local_base}_${codec_upper}_${preset_cap}.mkv"
      escaped_proc_output=$(printf '%q' "$proc_output")

      if [[ "$has_atmos" == "yes" ]]; then
        if [[ "$KEEP_ATMOS" == "si" ]]; then
          final_output="${local_base}_${codec_upper}_${preset_cap}_Atmos.mkv"
          escaped_final_output=$(printf '%q' "$final_output")

          cat <<BLOCK

# ── File: $(basename "$local_file")  (${MODE^^} ${GLOBAL_METRIC_VALUES[$i]} ${UNIT} → ${file_preset}) [DUAL-TRACK, keep_atmos=si]
echo ""
echo -e "\033[0;36m[INFO]\033[0m Processing (dual-track, keep_atmos=si): ${escaped_path}"

# STEP 1: Processore surround (keep=no, solo traccia 5.1)
"\$PROC" "\$CODEC" "no" ${escaped_path} "\$BITRATE" ${file_preset_lower} ${file_volamp}
if [[ \$? -ne 0 ]]; then
  echo -e "\033[0;31m[ERROR]\033[0m  Processore fallito su ${escaped_path}"
  (( ERRORS++ )) || true
else
  if [[ -f ${escaped_proc_output} ]]; then
    ffmpeg -hide_banner -nostdin -stats -loglevel warning -y \
      -i ${escaped_proc_output} \
      -i ${escaped_path} \
      -map_metadata 0 -map_chapters 0 \
      -map 0:V:0? -c:v copy \
      -map 0:s? -c:s copy \
      -map 0:t? -c:t copy \
      -map 0:a:0 -c:a:0 copy \
      -disposition:a:0 default \
      -map 1:${atmos_stream_idx} -c:a:1 copy \
      -metadata:s:a:1 "title=EAC3 Atmos (Original)" \
      -disposition:a:1 0 \
      ${escaped_final_output}

    if [[ \$? -eq 0 ]]; then
      echo -e "\033[0;32m[OK]\033[0m  Creato: ${escaped_final_output}"
      rm -f ${escaped_proc_output}
    else
      echo -e "\033[0;31m[ERROR]\033[0m  Rimux fallito per ${escaped_path}"
      (( ERRORS++ )) || true
    fi
  else
    echo -e "\033[0;31m[ERROR]\033[0m  Output processore non trovato: ${escaped_proc_output}"
    (( ERRORS++ )) || true
  fi
fi

echo "---"
BLOCK
        else
          cat <<BLOCK

# ── File: $(basename "$local_file")  (${MODE^^} ${GLOBAL_METRIC_VALUES[$i]} ${UNIT} → ${file_preset}) [DUAL-TRACK, keep_atmos=no]
echo ""
echo -e "\033[0;36m[INFO]\033[0m Processing (dual-track, solo 5.1 processata): ${escaped_path}"

"\$PROC" "\$CODEC" "no" ${escaped_path} "\$BITRATE" ${file_preset_lower} ${file_volamp}
if [[ \$? -eq 0 ]]; then
  echo -e "\033[0;32m[OK]\033[0m  Creato: ${escaped_proc_output}"
else
  echo -e "\033[0;31m[ERROR]\033[0m  Processore fallito su ${escaped_path}"
  (( ERRORS++ )) || true
fi

echo "---"
BLOCK
        fi
      else
        proc_keep="si"
        [[ "$KEEP_ATMOS" == "no" ]] && proc_keep="no"

        cat <<BLOCK

# ── File: $(basename "$local_file")  (${MODE^^} ${GLOBAL_METRIC_VALUES[$i]} ${UNIT} → ${file_preset}) [SINGLE-TRACK, keep_atmos=${KEEP_ATMOS}]
echo ""
echo -e "\033[0;36m[INFO]\033[0m Processing (single-track, keep=${proc_keep}): ${escaped_path}"

"\$PROC" "\$CODEC" "${proc_keep}" ${escaped_path} "\$BITRATE" ${file_preset_lower} ${file_volamp}
if [[ \$? -eq 0 ]]; then
  echo -e "\033[0;32m[OK]\033[0m  Creato: ${escaped_proc_output}"
else
  echo -e "\033[0;31m[ERROR]\033[0m  Processore fallito su ${escaped_path}"
  (( ERRORS++ )) || true
fi

echo "---"
BLOCK
      fi
    done

    echo ''
    echo 'echo ""'
    echo 'if [[ $ERRORS -gt 0 ]]; then'
    echo '  echo -e "\033[0;33m[WARNING]\033[0m Completato con $ERRORS errori."'
    echo 'else'
    echo '  echo -e "\033[0;32m[OK]\033[0m Batch completato senza errori."'
    echo 'fi'
  } > "$BATCH_FILE"

  chmod +x "$BATCH_FILE"
  ok "Batch file generato: ${BATCH_FILE}"

elif [[ "$MODE" == "lra" || "$MODE" == "delta" ]] && [[ "${#GLOBAL_METRIC_VALUES[@]}" -eq 1 ]]; then
  # Singolo file: genera batch semplificato
  CNT=1

  local_file="${GLOBAL_METRIC_PATHS[0]}"
  has_atmos="${GLOBAL_HAS_ATMOS[0]}"
  pf_raw=$(metric_to_preset "${GLOBAL_METRIC_VALUES[0]}")
  file_preset="${pf_raw%%|*}"
  file_preset_lower="${file_preset,,}"

  UNIT="dB"
  [[ "$MODE" == "lra" ]] && UNIT="LU"

  BATCH_FILE="run_processing_atmos.sh"
  escaped_path=$(printf '%q' "$local_file")
  local_base="${local_file%.*}"
  codec_upper="${BATCH_CODEC^^}"
  preset_cap="${file_preset_lower^}"
  proc_output="${local_base}_${codec_upper}_${preset_cap}.mkv"
  escaped_proc_output=$(printf '%q' "$proc_output")
  file_volamp="${GLOBAL_VOLAMP_VALUES[0]:-0}"
  atmos_stream_idx="${GLOBAL_ATMOS_STREAM_INDEXES[0]}"

  {
    echo '#!/usr/bin/env bash'
    echo "# ── Batch generato da audio_analyzer_atmos (V1 - ${MODE^^}) ──"
    echo "# Data: $(date '+%Y-%m-%d %H:%M')"
    echo "# File singolo: $(basename "$local_file")"
    echo "# Metrica: ${MODE^^} ${GLOBAL_METRIC_VALUES[0]} ${UNIT} → ${file_preset}"
    echo '#'
    echo ''
    echo '# ── CONFIGURAZIONE ──'
    echo "CODEC=\"${BATCH_CODEC}\""
    echo "BITRATE=\"${BATCH_BITRATE}\""
    echo 'PROC="./aegis_sonar_wide_aura_voice_volamp.sh"'
    echo ''

    if [[ "$has_atmos" == "yes" ]]; then
      if [[ "$KEEP_ATMOS" == "si" ]]; then
        # Dual-track: processa + rimux
        final_output="${local_base}_${codec_upper}_${preset_cap}_Atmos.mkv"
        escaped_final_output=$(printf '%q' "$final_output")

        echo "# STEP 1: Processore surround (keep=no)"
        echo ""\$PROC" "\$CODEC" "no" ${escaped_path} "\$BITRATE" ${file_preset_lower} ${file_volamp}"
        echo ''
        echo "# STEP 2: Rimux con Atmos originale"
        echo "if [[ -f ${escaped_proc_output} ]]; then"
        echo "  ffmpeg -hide_banner -nostdin -stats -loglevel warning -y \"
        echo "    -i ${escaped_proc_output} \"
        echo "    -i ${escaped_path} \"
        echo "    -map_metadata 0 -map_chapters 0 \"
        echo "    -map 0:V:0? -c:v copy \"
        echo "    -map 0:s? -c:s copy \"
        echo "    -map 0:t? -c:t copy \"
        echo "    -map 0:a:0 -c:a:0 copy \"
        echo "    -disposition:a:0 default \"
        echo "    -map 1:${atmos_stream_idx} -c:a:1 copy \"
        echo "    -metadata:s:a:1 \"title=EAC3 Atmos (Original)\" \"
        echo "    -disposition:a:1 0 \"
        echo "    ${escaped_final_output}"
        echo ''
        echo "  echo -e \"\033[0;32m[OK]\033[0m  Creato: ${escaped_final_output}\""
        echo "  rm -f ${escaped_proc_output}"
        echo "else"
        echo "  echo -e \"\033[0;31m[ERROR]\033[0m  Output processore non trovato: ${escaped_proc_output}\""
        echo "fi"
      else
        echo "# Dual-track: solo traccia processata, nessun rimux Atmos"
        echo ""\$PROC" "\$CODEC" "no" ${escaped_path} "\$BITRATE" ${file_preset_lower} ${file_volamp}"
      fi
    else
      proc_keep="si"
      [[ "$KEEP_ATMOS" == "no" ]] && proc_keep="no"
      echo "# Single-track: keep variabile in base a KEEP_ATMOS"
      echo ""\$PROC" "\$CODEC" "${proc_keep}" ${escaped_path} "\$BITRATE" ${file_preset_lower} ${file_volamp}"
    fi
  } > "$BATCH_FILE"

  chmod +x "$BATCH_FILE"
  ok "Batch file generato: ${BATCH_FILE}"
fi

echo -e ""
ok "Analisi completata. Nessun file audio e' stato modificato."
