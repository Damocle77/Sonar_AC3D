#!/usr/bin/env bash
# set -e rimosso: causa exit su espressioni aritmetiche (es. var=0; ((var++)))
set -uo pipefail
# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   audio_analyzer.sh - V4 - Febbraio 2026                                    │
# │                                                                              │
# │   Sonda euristica per l'analisi offline di container multimediali.           │
# │   Identifica le tracce audio e suggerisce il preset ottimale per il          │
# │   processore aegis_sonar_wide_aura_voice.sh.                                │
# │                                                                              │
# │   DUE METRICHE DISPONIBILI:                                                 │
# │                                                                              │
# │   lra  - LRA (Loudness Range, EBU R128) in LU                               │
# │          Misura la dinamica temporale del file intero.                       │
# │          Buona per distinguere broadcast da Blu-ray.                         │
# │          Proxy indiretto: non dice nulla sul bilanciamento canali.           │
# │                                                                              │
# │   delta - Delta = I(SUR) - I(FC) in dB                                      │
# │          Misura il bilanciamento surround/centro via EBU R128 Integrated     │
# │          Loudness per canale. Diagnostica esattamente cio' che il            │
# │          processore corregge: quanto i surround sono deboli vs il centro.    │
# │          Metrica diretta e piu' accurata.                                    │
# │                                                                              │
# │   MAPPA PRESET (delta):                                                      │
# │     Delta < -12 dB  -> AURA   (surround morti/inesistenti)                  │
# │     Delta -12/-7 dB -> SONAR  (surround anemici)                            │
# │     Delta -7/-4 dB  -> WIDE   (surround medi/normali)                       │
# │     Delta -4/0 dB   -> AEGIS  (surround gia' incazzati)                     │
# │     Delta > 0 dB    -> VOICE  (muro di suono, sur > centro)                 │
# │                                                                              │
# │   MAPPA PRESET (lra):                                                        │
# │     LRA < 6 LU   -> VOICE  (dinamica piatta)                                │
# │     LRA  6-10 LU -> AURA   (dinamica ridotta)                               │
# │     LRA 10-15 LU -> WIDE   (buona dinamica)                                 │
# │     LRA 15-20 LU -> SONAR  (alta dinamica)                                  │
# │     LRA > 20 LU  -> AEGIS  (transienti estremi)                             │
# │                                                                              │
# │   VERDETTO STAGIONALE:                                                       │
# │     LRA  -> P75 (bias verso dinamica alta)                                   │
# │     Delta -> P25 (bias verso surround deboli = processing piu' aggressivo)  │
# │   Se spread > 4 (LU o dB), suggerisce preset per-file.                      │
# ╰──────────────────────────────────────────────────────────────────────────────╯

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
  ./audio_analyzer.sh <file|""> [modo] [codec] [keep] [bitrate]

PARAMETRI:
  file    : Nome del file multimediale.
            Usa "" (stringa vuota) per batch su tutti i file nella cartella.
  modo    : probe  (Default) Solo struttura tracce audio.
            lra    Misura LRA (EBU R128) e suggerisce preset (dinamica temporale).
            delta  Misura Delta SUR-FC e suggerisce preset (bilanciamento canali).
                   Piu' accurato di lra: diagnostica esattamente cio' che il
                   processore corregge. Richiede tracce 5.1.
  codec   : eac3   (Default) Codec per il batch file generato.
            ac3    Alternativa.
  keep    : no     (Default) Non conservare audio originale.
            si     Conserva audio originale nel file processato.
  bitrate : 448k   (Default) Bitrate per il batch file generato.

ESEMPI:
  ./audio_analyzer.sh movie.mkv probe          # Struttura tracce
  ./audio_analyzer.sh movie.mkv delta          # Analisi delta singolo file
  ./audio_analyzer.sh "" delta                 # Batch delta (default eac3/no/448k)
  ./audio_analyzer.sh "" delta eac3 no 448k    # Batch delta esplicito
  ./audio_analyzer.sh "" lra                   # Batch LRA (legacy)
  ./audio_analyzer.sh "" lra ac3 si 640k       # Batch LRA con AC3
USAGE
  exit 1
}

# Senza argomenti o con -h/--help -> mostra usage
[[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

INPUT_FILE="${1:-}"
MODE="${2:-probe}"
BATCH_CODEC="${3:-eac3}"
BATCH_KEEP="${4:-no}"
BATCH_BITRATE="${5:-448k}"

# Validazione
case "$BATCH_CODEC" in ac3|eac3) ;; *) err "Codec '$BATCH_CODEC' non valido. Usa ac3 o eac3."; usage ;; esac
case "$BATCH_KEEP" in si|no) ;; *) err "Keep '$BATCH_KEEP' non valido. Usa si o no."; usage ;; esac
[[ "$BATCH_BITRATE" =~ ^[0-9]+(k|M)?$ ]] || { err "Bitrate '$BATCH_BITRATE' non valido. Es: 448k, 640k, 768k."; usage; }
[[ "$BATCH_BITRATE" =~ k$|M$ ]] || BATCH_BITRATE="${BATCH_BITRATE}k"

case "$MODE" in
  probe|lra|delta) ;;
  *) err "Modo '$MODE' sconosciuto. Usa 'probe', 'lra' o 'delta'."; usage ;;
esac

if [[ "$MODE" == "lra" || "$MODE" == "delta" ]]; then
  info "Metrica: ${MODE^^} | Batch: ${BATCH_CODEC} / keep=${BATCH_KEEP} / ${BATCH_BITRATE}"
fi

# Variabili globali per il Verdetto Stagionale (unificate per entrambe le metriche)
GLOBAL_METRIC_VALUES=()
GLOBAL_METRIC_FILES=()
GLOBAL_METRIC_PATHS=()

# ────────────────────────────────────────────────────────────────────────────────
# Raccolta file (glob allineato al processore + formati solo-analisi)
# ────────────────────────────────────────────────────────────────────────────────
FILES=()
if [[ -n "$INPUT_FILE" ]]; then
    [[ -f "$INPUT_FILE" ]] || { err "File '$INPUT_FILE' inesistente."; exit 1; }
    FILES+=("$INPUT_FILE")
else
    shopt -s nullglob
    FILES+=( *.mkv *.MKV *.mp4 *.MP4 *.avi *.AVI *.mka *.MKA \
             *.m2ts *.M2TS *.ac3 *.AC3 *.eac3 *.EAC3 \
             *.wav *.WAV *.flac *.FLAC )
    shopt -u nullglob
fi

(( ${#FILES[@]} == 0 )) && { err "Nessun file trovato da processare."; exit 1; }

# ────────────────────────────────────────────────────────────────────────────────
# Probe: struttura tracce audio
# ────────────────────────────────────────────────────────────────────────────────
probe_audio_streams() {
  local f="$1"
  info "--- Struttura Audio: $f ---"

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
  echo "------------------------------------------------------------"
}

# ────────────────────────────────────────────────────────────────────────────────
# Selezione stream con sistema a punteggio (allineato al processore)
#
# Score: 6 canali -> +1000, default -> +200, lingua italiana -> +300
# A parita' di score, vince il primo trovato.
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
# Mappa Delta -> Preset (dalla guida Audacity)
#
# Delta = I(SUR) - I(FC) in dB
# Valori negativi = surround piu' deboli del centro (caso tipico)
#
#   Delta < -12 dB  -> AURA   (surround morti/inesistenti)
#   Delta -12/-7 dB -> SONAR  (surround anemici)
#   Delta -7/-4 dB  -> WIDE   (surround medi/normali)
#   Delta -4/0 dB   -> AEGIS  (surround gia' incazzati)
#   Delta > 0 dB    -> VOICE  (muro di suono, sur coprono il centro)
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

# Funzione unificata di mapping
metric_to_preset() {
  if [[ "$MODE" == "delta" ]]; then
    delta_to_preset "$1"
  else
    lra_to_preset "$1"
  fi
}

# ────────────────────────────────────────────────────────────────────────────────
# Misura Integrated Loudness (I:) di un singolo canale estratto via pan=
# Args: file stream_index pan_formula
# Restituisce: valore I in LUFS via stdout
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
# Analisi Delta (bilanciamento canali SUR vs FC)
#
# Estrae FC e media(SL,SR) separatamente, misura I: su ciascuno,
# calcola Delta = I(SUR) - I(FC).
#
# Per il surround si usa la media energetica di SL e SR:
#   I(SUR) = -10*log10( (10^(I_SL/-10) + 10^(I_SR/-10)) / 2 )
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

  # Nomi canali surround in base al layout
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

  # Media energetica SL+SR e Delta (via tmpfile — MINGW64-safe)
  local i_sur delta
  _delta_tmp=$(mktemp)
  awk -v sl="$i_sl" -v sr="$i_sr" -v fc="$i_fc" 'BEGIN { sur=-10*log(((10^(sl/-10))+(10^(sr/-10)))/2)/log(10); d=sur-fc; printf "%.1f %.1f\n",sur,d }' < /dev/null > "$_delta_tmp"
  read -r i_sur delta < "$_delta_tmp"
  rm -f "$_delta_tmp"

  # Preset
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

  # Accumulo
  GLOBAL_METRIC_VALUES+=("$delta")
  GLOBAL_METRIC_FILES+=("$(basename "$f")")
  GLOBAL_METRIC_PATHS+=("$f")

  # Output
  ok "Risultati Delta per: $f"
  echo -e "  \033[1;33mI(FC):    \033[0m  ${i_fc} LUFS"
  echo -e "  \033[1;33mI(SL):    \033[0m  ${i_sl} LUFS"
  echo -e "  \033[1;33mI(SR):    \033[0m  ${i_sr} LUFS"
  echo -e "  \033[1;33mI(SUR):   \033[0m  ${i_sur} LUFS  (media energetica SL+SR)"
  echo -e "  \033[1;37mDelta:    \033[0m  ${p_color}${delta} dB\033[0m  (SUR - FC)"
  echo -e "  \033[1;37mPreset:   \033[0m  ${p_color}${preset}\033[0m  (${preset_desc})"
  echo ""
}

# ────────────────────────────────────────────────────────────────────────────────
# Analisi LRA (EBU R128)
# ────────────────────────────────────────────────────────────────────────────────
scan_lra() {
  local f="$1"
  info "Avvio analisi EBU R128 su: $f"

  local stream_info
  stream_info=$(pick_best_stream "$f")
  local target_stream="${stream_info%% *}"
  local rest="${stream_info#* }"
  local max_ch="${rest%% *}"

  if [[ -z "$target_stream" ]]; then
    warn "Impossibile determinare stream target. File saltato."
    return 1
  fi

  if [[ "$max_ch" =~ ^[0-9]+$ && "$max_ch" -ne 6 ]]; then
    warn "Stream [$target_stream] ha $max_ch canali (non 5.1). Il processore skipperebbe questo file."
    warn "L'analisi procede comunque, ma il preset suggerito non e' applicabile."
  fi

  info "Analisi stream [$target_stream] ($max_ch canali). Attendi..."

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
    warn "Dati EBU R128 non trovati per $f. Stream non supportato o file troppo corto?"
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

  GLOBAL_METRIC_VALUES+=("$lra_val")
  GLOBAL_METRIC_FILES+=("$(basename "$f")")
  GLOBAL_METRIC_PATHS+=("$f")

  ok "Risultati EBU R128 per: $f"
  echo -e "  \033[1;33mLoudness Integrata:\033[0m  ${i_val:-N/A} LUFS"
  echo -e "  \033[1;33mLRA (Dinamica):    \033[0m  ${p_color}${lra_val} LU\033[0m"
  echo -e "  \033[1;33mTrue Peak:         \033[0m  ${peak_val:-N/A} dBTP"
  echo -e "  \033[1;37mPreset Consigliato:\033[0m  ${p_color}${preset}\033[0m  (${preset_desc})"

  if [[ "$max_ch" =~ ^[0-9]+$ && "$max_ch" -ne 6 ]]; then
    echo -e "  \033[0;33m⚠  Preset non applicabile: il processore richiede 5.1 (6 canali)\033[0m"
  fi
  echo ""
}

# ────────────────────────────────────────────────────────────────────────────────
# CICLO PRINCIPALE
# ────────────────────────────────────────────────────────────────────────────────
for CUR_FILE in "${FILES[@]}"; do
  info "Analisi: $CUR_FILE"
  probe_audio_streams "$CUR_FILE" || continue

  case "$MODE" in
    lra)   scan_lra "$CUR_FILE" ;;
    delta) scan_delta "$CUR_FILE" ;;
  esac
done

# ────────────────────────────────────────────────────────────────────────────────
# VERDETTO STAGIONALE (solo se analizzati >= 2 file)
#
# Bias audiofilo:
#   LRA   -> P75 (non sottoutilizzare dinamica alta)
#   Delta -> P25 (proteggere gli episodi con surround piu' deboli:
#            il valore piu' negativo tra il 75% meno estremo)
#
# Spread > 4 (LU o dB) -> stagione eterogenea, tabella per-file.
# ────────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "lra" || "$MODE" == "delta" ]] && [[ "${#GLOBAL_METRIC_VALUES[@]}" -gt 1 ]]; then
  CNT=${#GLOBAL_METRIC_VALUES[@]}

  _vals_tmp=$(mktemp)
  printf '%s\n' "${GLOBAL_METRIC_VALUES[@]}" > "$_vals_tmp"

  _stats_tmp=$(mktemp)
  if [[ "$MODE" == "delta" ]]; then
    # P25 per delta (bias audiofilo: protegge surround deboli)
    awk '{v[NR]=$1+0} END{n=NR; for(i=2;i<=n;i++){k=v[i];j=i-1; while(j>=1&&v[j]>k){v[j+1]=v[j];j--}; v[j+1]=k}; mn=v[1];mx=v[n]; s=0;for(i=1;i<=n;i++)s+=v[i]; avg=s/n; raw=0.25*n;rank=int(raw);if(raw>rank)rank=rank+1; if(rank<1)rank=1;if(rank>n)rank=n; pctl=v[rank]; printf "%.1f %.1f %.1f %.1f\n",mn,mx,avg,pctl}' "$_vals_tmp" > "$_stats_tmp"
  else
    # P75 per LRA (bias audiofilo: non sottoutilizzare dinamica)
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

  echo -e "  Episodi analizzati:  \033[1;37m${CNT}\033[0m"
  echo -e "  Media:               \033[0;37m${m_avg} ${UNIT}\033[0m"
  echo -e "  ${PCTL_LABEL}: ${season_color}${m_pctl} ${UNIT}\033[0m"
  echo -e "  Range:               \033[0;37m${m_min} / ${m_max} ${UNIT}  (spread: ${m_spread} ${UNIT})\033[0m"
  echo -e "  Preset Consigliato:  ${season_color}${season_preset}\033[0m  (${season_desc})"

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
  BATCH_FILE="run_processing.sh"

  {
    echo '#!/usr/bin/env bash'
    echo "# ── Batch generato da audio_analyzer (V4 - ${MODE^^}) ──"
    echo "# Data: $(date '+%Y-%m-%d %H:%M')"
    echo "# Metrica: ${MODE^^} | Percentile: ${PCTL_LABEL}"
    echo '#'
    echo '# Modifica le variabili sotto se necessario, poi lancia:'
    echo "#   ./${BATCH_FILE}"
    echo '#'
    echo ''
    echo '# ── CONFIGURAZIONE (modifica qui) ──'
    echo "CODEC=\"${BATCH_CODEC}\"        # ac3 | eac3"
    echo "KEEP=\"${BATCH_KEEP}\"           # si | no"
    echo "BITRATE=\"${BATCH_BITRATE}\"      # es. 448k, 640k, 768k"
    echo 'PROC="./aegis_sonar_wide_aura_voice.sh"'
    echo ''
    echo '# ── COMANDI ──'

    for (( i=0; i<CNT; i++ )); do
      file_preset=""
      if [[ "$HIGH_SPREAD" -eq 1 ]]; then
        pf_raw=$(metric_to_preset "${GLOBAL_METRIC_VALUES[$i]}")
        file_preset="${pf_raw%%|*}"
      else
        file_preset="$season_preset"
      fi
      file_preset_lower="${file_preset,,}"
      escaped_path=$(printf '%q' "${GLOBAL_METRIC_PATHS[$i]}") 
      printf '"$PROC" "$CODEC" "$KEEP" %s "$BITRATE" %s  # %s %s %s\n' \
        "$escaped_path" "$file_preset_lower" "${MODE^^}" "${GLOBAL_METRIC_VALUES[$i]}" "$UNIT"
    done

    echo ''
    echo 'echo "Batch completato."'
  } > "$BATCH_FILE"

  chmod +x "$BATCH_FILE"
  ok "Batch file generato: ${BATCH_FILE}"

fi
echo -e ""
ok "Analisi completata. Nessun file audio e' stato modificato."
