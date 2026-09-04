#!/usr/bin/env bash
# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   atmos_to_51_dynaudnorm_psicho.sh - Settembre 2026                          │
# │   By Sandro (D@mocle77) Sabbioni                                             │
# │                                                                              │
# │   Prende un file con traccia EAC3 Atmos (JOC) e produce un MKV con:          │
# │     • Traccia 1: EAC3 5.1 standard con normalizzazione dinamica (default)    │
# │     • Traccia 2: EAC3 Atmos originale (copia bit-perfect)                    │
# │                                                                              │
# │   La decodifica FFmpeg di EAC3 JOC espone il bed 5.1 compatibile; FFmpeg     │
# │   non esegue il rendering degli oggetti Atmos. dynaudnorm applica una        │
# │   normalizzazione dinamica conservativa al bed, che resta lo stadio          │
# │   primario da analizzare/elaborare con i preset psicoacustici.               │
# │                                                                              │
# │   UTILIZZO:                                                                  │
# │     ./atmos_to_51_dynaudnorm_psicho.sh [bitrate] <file|directory|"">         │
# │     ./atmos_to_51_dynaudnorm_psicho.sh --files <bitrate> <file1> [...]       │
# │                                                                              │
# │   PARAMETRI:                                                                 │
# │     file    : File sorgente (mkv/mp4/m2ts), directory da processare          │
# │               oppure "" per batch nella cartella corrente.                   │
# │     bitrate : Bitrate traccia 5.1 (default: 640k).                           │
# │                                                                              │
# │   DIPENDENZE: ffmpeg, ffprobe (con supporto EAC3 JOC)                        │
# ╰──────────────────────────────────────────────────────────────────────────────╯
set -uo pipefail

# Colori
C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"

# Funzioni di log
info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

# Guard rail della verifica comparativa tra bed sorgente e traccia normalizzata.
VERIFY_SILENCE_PEAK_DB="-80.0"
VERIFY_MAX_SAMPLE_DELTA_RATIO="0.02"

# Marker stabile letto dall'analizzatore per riconoscere la provenienza Atmos
# del bed 5.1 normalizzato. Cambiarlo richiede aggiornare anche l'analizzatore.
ATMOS_ORIGINAL_TITLE="EAC3 Atmos (Original)"

# Funzione per confermare sovrascrittura
confirm_overwrite() {
  local target="$1"
  local ans=""
  if [[ ! -e /dev/tty ]]; then
    warn "TTY non disponibile e '$target' esiste gia' -> skip automatico."
    return 1
  fi
  echo -ne "${C_WARN} '$target' esiste gia'. Sovrascrivere? [s/n/t]: "
  if ! read -r ans < /dev/tty; then
    warn "Impossibile leggere da /dev/tty -> skip automatico."
    return 1
  fi
  case "${ans,,}" in
    t|tutti) OVERWRITE_ALL=true; info "Sovrascrittura automatica attivata."; return 0 ;;
    s|si|y|yes) info "Sovrascrivo."; return 0 ;;
    *) info "Skip manuale richiesto."; return 1 ;;
  esac
}

usage() {
  local rc="${1:-0}"
  cat <<'USAGE'
----------------------------------------------------------------------------------------
UTILIZZO:
  ./atmos_to_51_dynaudnorm_psicho.sh [bitrate] <file|directory|"">
  ./atmos_to_51_dynaudnorm_psicho.sh --files <bitrate> <file1> [file2 ...]

PARAMETRI:
  file|directory : File sorgente (mkv/mp4/m2ts), cartella contenente
                   file video da processare in batch, oppure "" per la
                   cartella corrente.
  bitrate        : Bitrate traccia EAC3 5.1 in uscita (default: 640k).

MODALITA' --files:
  Analizza e converte soltanto i file elencati. Il bitrate e' obbligatorio
  per separare in modo non ambiguo i parametri dai nomi dei file.

ESEMPI:
  ./atmos_to_51_dynaudnorm_psicho.sh 640k film.mkv       # singolo file
  ./atmos_to_51_dynaudnorm_psicho.sh 768k /path/folder   # batch su cartella
  ./atmos_to_51_dynaudnorm_psicho.sh 768k ""             # batch nella cartella corrente
  ./atmos_to_51_dynaudnorm_psicho.sh --files 768k ep1.mkv ep4.mkv

COMPATIBILITA': resta accettato anche il vecchio ordine <file> [bitrate].

OUTPUT:
  <nome>-0.mkv con:
    • Traccia 1: EAC3 5.1 normalizzata (dynaudnorm, default)
    • Traccia 2: EAC3 Atmos originale (copia bit-perfect)

DIPENDENZE: ffmpeg, ffprobe (con supporto EAC3 JOC)
----------------------------------------------------------------------------------------
USAGE
  exit "$rc"
}

# Help: nessun argomento o flag esplicito
[[ $# -eq 0 || "${1:-}" =~ ^(-h|--help)$ ]] && usage
# Check dipendenze
for _bin in ffmpeg ffprobe; do
  command -v "$_bin" &>/dev/null || { err "$_bin non trovato nel PATH"; exit 1; }
done

# Parametri. In modalita' --files la sintassi e' volutamente fissa:
# --files <bitrate> <file1> [file2 ...].
MULTI_FILES_MODE=false
MULTI_FILES=()
if [[ "${1:-}" == "--files" ]]; then
  (( $# >= 3 )) || { err "Uso --files non valido: servono bitrate e almeno un file."; usage 1; }
  MULTI_FILES_MODE=true
  BITRATE="${2:-}"
  shift 2
  MULTI_FILES=("$@")
  INPUT_ARG=""
else
  # Sintassi canonica: [bitrate] <input>. Se il primo token non e' un bitrate,
  # mantengo la compatibilita' con il vecchio ordine <input> [bitrate].
  if (( $# == 2 )) && [[ "${1:-}" =~ ^[0-9]+([kKmM])?$ ]]; then
    BITRATE="${1:-640k}"
    INPUT_ARG="${2:-}"
  else
    INPUT_ARG="${1:-}"
    BITRATE="${2:-640k}"
  fi
fi
# Normalizzazione e validazione bitrate EAC3 5.1.
[[ "$BITRATE" =~ ^[0-9]+([kKmM])?$ ]] || { err "Bitrate '$BITRATE' non valido. Es: 640k, 768k."; exit 1; }
BITRATE_LC="${BITRATE,,}"
if [[ "$BITRATE_LC" =~ ^([0-9]+)$ ]]; then
  BITRATE_KBPS="${BASH_REMATCH[1]}"
elif [[ "$BITRATE_LC" =~ ^([0-9]+)k$ ]]; then
  BITRATE_KBPS="${BASH_REMATCH[1]}"
elif [[ "$BITRATE_LC" =~ ^([0-9]+)m$ ]]; then
  BITRATE_KBPS="$(( ${BASH_REMATCH[1]} * 1000 ))"
else
  err "Bitrate '$BITRATE' non valido. Es: 640k, 768k."
  exit 1
fi
if (( BITRATE_KBPS < 256 || BITRATE_KBPS > 768 || ((BITRATE_KBPS - 256) % 64) != 0 )); then
  err "Bitrate EAC3 5.1 non consentito: ${BITRATE_KBPS}k"
  err "Consentiti: 256k, 320k, 384k, 448k, 512k, 576k, 640k, 704k, 768k"
  exit 1
fi
BITRATE="${BITRATE_KBPS}k"

# Dynaudnorm: parametri conservativi per normalizzazione domestica/notturna
# framelen=500   : finestra 500ms — buon compromesso reattività/smoothness
# gausssize=31   : finestra gaussiana 31 frame — smoothing ampio (no pumping)
# peak=0.92      : picco target lineare del normalizzatore
# maxgain=4      : fattore lineare massimo (non 4 dB; circa +12 dB nominali)
# targetrms=0    : target RMS disabilitato; controllo guidato dai picchi
# compress=0     : compressione opzionale interna disabilitata
# coupling=1     : canali accoppiati — preserva l'immagine stereo/surround
# altboundary=0  : boundary mode standard
DYNAUDNORM="highpass=f=20:t=q:w=0.707,dynaudnorm=framelen=500:gausssize=31:peak=0.92:maxgain=4:targetrms=0:compress=0:coupling=1:altboundary=0"

# NB: nessun filtro LFE qui. Questo script e' solo pre-stadio di aegis_sonar_wide_aura_voice_volamp_psycho.sh,
# che gestisce interamente l'LFE (highpass 32 + lowpass 110 + limiter picchi sub). Applicare qui gli stessi
# highpass/lowpass creerebbe un doppio band-pass (ordine raddoppiato, -6 dB ai corner 32/110 Hz): ridondante e dannoso.

# Probe: trova traccia EAC3 Atmos (JOC)
find_atmos_stream() {
  local f="$1"
  local raw_data

  # Un solo probe per i dati stabili. L'ordinale audio viene conservato per
  # interrogare profile/joc_complexity sui singoli stream.
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,codec_name,channels:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null | tr -d '\r' || true)
  [[ -n "$raw_data" ]] || return 1

  local best_atmos="" best_atmos_score=-1
  local best_fallback="" best_fallback_score=-1
  local audio_ord=0
  local lines
  mapfile -t lines <<< "$raw_data"

  for line in "${lines[@]}"; do
    [[ -z "$line" ]] && continue

    local idx codec ch def lang
    IFS=',' read -r idx codec ch def lang <<<"$line"
    codec="${codec:-}"
    ch="${ch:-0}"
    def="${def:-0}"
    lang="${lang:-und}"

    # L'ordinale audio va incrementato per ogni stream audio, anche non EAC3.
    if [[ "$codec" != "eac3" || ! "$ch" =~ ^[0-9]+$ || "$ch" -lt 6 ]]; then
      ((audio_ord+=1))
      continue
    fi

    local is_atmos=false profile_str joc
    profile_str=$(ffprobe -v error -select_streams "a:${audio_ord}" \
      -show_entries stream=profile -of csv=p=0 "$f" 2>/dev/null | head -1 | tr -d '\r' || true)
    [[ "${profile_str,,}" == *"atmos"* ]] && is_atmos=true

    if [[ "$is_atmos" == false ]]; then
      joc=$(ffprobe -v error -select_streams "a:${audio_ord}" \
        -show_entries frame_side_data=joc_complexity -read_intervals "%+#1" \
        -of csv=p=0 "$f" 2>/dev/null | head -1 | tr -d '\r' || true)
      [[ -n "$joc" && "$joc" != "0" ]] && is_atmos=true
    fi

    local score=0
    [[ "$def" == "1" ]] && score=$((score + 200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score + 300))

    if [[ "$is_atmos" == true ]]; then
      if (( score > best_atmos_score )); then
        best_atmos_score=$score
        best_atmos="${idx}|${ch}|${lang}|atmos"
      fi
    elif (( score > best_fallback_score )); then
      best_fallback_score=$score
      best_fallback="${idx}|${ch}|${lang}|fallback"
    fi

    ((audio_ord+=1))
  done

  if [[ -n "$best_atmos" ]]; then
    echo "$best_atmos"
    return 0
  fi

  if [[ -n "$best_fallback" ]]; then
    local fb_idx fb_ch fb_lang fb_type
    IFS='|' read -r fb_idx fb_ch fb_lang fb_type <<<"$best_fallback"
    warn "Nessun flag Atmos esplicito trovato — uso traccia EAC3 ${fb_ch}ch (idx:${fb_idx}) come fallback" >&2
    echo "$best_fallback"
    return 0
  fi

  return 1
}

# Misura picco e numero di campioni in una singola decodifica.
# Formato: peak_dbfs|samples
measure_audio_signal() {
  local f="$1" map_spec="$2" probe metrics

  probe="$(
    ffmpeg -hide_banner -nostdin -v info -i "$f" \
      -map "$map_spec" -vn -sn -dn \
      -af "aformat=sample_rates=48000:sample_fmts=fltp,astats=metadata=0:reset=0" \
      -f null - 2>&1 || true
  )"
  probe="${probe//$'\r'/}"

  metrics="$(printf '%s\n' "$probe" | awk '
    /] Overall$/ { overall=1; next }
    /Peak level dB:/ { if (overall) peak=$NF; next }
    /Number of samples:/ { if (overall) samples=$NF; next }
    END {
      if (peak == "" || samples == "") exit 1
      printf "%s|%s\n", peak, samples
    }
  ')" || return 1

  [[ -n "$metrics" ]] || return 1
  printf '%s\n' "$metrics"
}

is_finite_db() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

# Verifica che la traccia prodotta non sia muta e non risulti troncata o
# inaspettatamente piu' lunga rispetto al bed EAC3 selezionato.
verify_output_audio_signal() {
  local f="$1" input_metrics="$2" output_metrics
  local input_peak input_samples output_peak output_samples

  output_metrics="$(measure_audio_signal "$f" "0:a:0")" || {
    VERIFY_REASON="astats non ha restituito metriche complete per l'output"
    return 2
  }
  IFS='|' read -r input_peak input_samples <<<"$input_metrics"
  IFS='|' read -r output_peak output_samples <<<"$output_metrics"

  if [[ "$output_peak" == "-inf" ]]; then
    VERIFY_REASON="output digitalmente silenzioso"
    return 1
  fi
  if ! is_finite_db "$input_peak" || ! is_finite_db "$output_peak" || \
     ! [[ "$input_samples" =~ ^[0-9]+([.][0-9]+)?$ && "$output_samples" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    VERIFY_REASON="metriche input/output non numeriche"
    return 2
  fi
  if awk -v v="$output_peak" -v lim="$VERIFY_SILENCE_PEAK_DB" 'BEGIN { exit !(v <= lim) }'; then
    VERIFY_REASON="picco output troppo basso (${output_peak} dBFS)"
    return 1
  fi
  if awk -v i="$input_samples" -v o="$output_samples" -v d="$VERIFY_MAX_SAMPLE_DELTA_RATIO" \
       'BEGIN { exit !(o < i*(1-d) || o > i*(1+d)) }'; then
    VERIFY_REASON="durata incoerente: campioni input=${input_samples}, output=${output_samples}"
    return 1
  fi

  info "Verifica audio: peak ${input_peak}→${output_peak} dBFS; campioni ${input_samples}→${output_samples}"
  return 0
}

# Raccolta file
FILES=()
if [[ "$MULTI_FILES_MODE" == true ]]; then
  for f in "${MULTI_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      FILES+=("$f")
    else
      warn "File inesistente, salto: $f"
    fi
  done
elif [[ -z "$INPUT_ARG" ]]; then
  shopt -s nullglob
  FILES+=( *.mkv *.MKV *.mp4 *.MP4 *.m2ts *.M2TS )
  shopt -u nullglob
elif [[ -d "$INPUT_ARG" ]]; then
  shopt -s nullglob
  FILES+=( "$INPUT_ARG"/*.mkv "$INPUT_ARG"/*.MKV "$INPUT_ARG"/*.mp4 "$INPUT_ARG"/*.MP4 "$INPUT_ARG"/*.m2ts "$INPUT_ARG"/*.M2TS )
  shopt -u nullglob
elif [[ -f "$INPUT_ARG" ]]; then
  FILES+=("$INPUT_ARG")
else
  err "File o cartella non esiste: $INPUT_ARG"; exit 1
fi

# Filtra file gia' normalizzati (evita doppioni)
FILTERED_FILES=()
for f in "${FILES[@]}"; do
  case "$f" in
    *-0.mkv)
      info "Skip output gia' normalizzato: $f"
      continue
      ;;
    *)
      FILTERED_FILES+=("$f")
      ;;
  esac
done
FILES=("${FILTERED_FILES[@]}")

# Check se ci sono file da processare
(( ${#FILES[@]} == 0 )) && { err "Nessun file trovato."; exit 1; }
# Mostra info
info "Bitrate 5.1: $BITRATE"
info "dynaudnorm:  $DYNAUDNORM"
echo ""

# Ciclo elaborazione
OVERWRITE_ALL=false
OK_COUNT=0
ERR_COUNT=0
SKIP_COUNT=0

# Ciclo sui file
for CUR_FILE in "${FILES[@]}"; do
  info "━━━ Input: $CUR_FILE"

  # Trova traccia Atmos/EAC3
  PROBE_RESULT=$(find_atmos_stream "$CUR_FILE") || {
    warn "Nessuna traccia EAC3 multichannel trovata → salto."
    ((SKIP_COUNT+=1))
    continue
  }
  # Split probe result: idx|ch|lang|type
  IFS='|' read -r A_IDX A_CH A_LANG A_TYPE <<<"$PROBE_RESULT"
  A_IDX="${A_IDX//[$'\r\n ']/}"
  A_CH="${A_CH//[$'\r\n ']/}"
  A_LANG="${A_LANG//$'\r'/}"

  info "Traccia audio: idx=$A_IDX, canali=$A_CH, lingua=$A_LANG, tipo=$A_TYPE"

  # Determina layout per il pan filter
  # EAC3 Atmos decodificato esce tipicamente come 5.1(side)
  A_LAYOUT=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channel_layout -of csv=p=0 "$CUR_FILE" 2>/dev/null | \
    tr -d '\r' | awk -F',' -v idx="$A_IDX" '$1==idx { print $2; exit }' || true)

  # Come nel motore principale, il pan usa indici di canale espliciti. In questo
  # modo aformat non puo' rimappare automaticamente i sei canali quando il layout
  # e' assente, non standard oppure dichiarato come 5.1(back).
  case "$A_LAYOUT" in
    "5.1(side)")
      info "Layout input: 5.1(side) → copia posizionale pura c0..c5"
      ;;
    "5.1"|"5.1(back)")
      info "Layout input: ${A_LAYOUT} → copia posizionale pura; c4/c5 diventano SL/SR"
      ;;
    *)
      warn "Layout '${A_LAYOUT:-vuoto}' non dichiarato/non standard → mapping posizionale c0..c5"
      ;;
  esac

  # Filename output
  OUT_FILE="${CUR_FILE%.*}-0.mkv"

  # Gestione sovrascrittura
  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      confirm_overwrite "$OUT_FILE" || { info "Salto '$CUR_FILE'."; ((SKIP_COUNT+=1)); continue; }
    else
      info "Sovrascrittura automatica: '$OUT_FILE'"
    fi
  fi

  # Filter complex per traccia 5.1: mapping posizionale non distruttivo, poi
  # dynaudnorm con coupling attivo. Nessun trattamento LFE: lo fa aegis.
  FILTER_COMPLEX="[0:${A_IDX}]aformat=sample_rates=48000:sample_fmts=fltp,pan=5.1(side)|FL=c0|FR=c1|FC=c2|LFE=c3|SL=c4|SR=c5,${DYNAUDNORM}[aout]"

  # Il riferimento viene misurato prima dell'encode. Se la sorgente non e'
  # misurabile in modo affidabile, non produciamo un output non verificabile.
  INPUT_AUDIO_METRICS="$(measure_audio_signal "$CUR_FILE" "0:${A_IDX}")" || {
    err "Impossibile misurare la traccia sorgente → salto: $CUR_FILE"
    ((ERR_COUNT+=1))
    continue
  }

  # Scrittura transazionale: il nome finale viene sostituito soltanto dopo che
  # il candidato ha superato la verifica audio.
  TMP_OUT_FILE="${OUT_FILE%.mkv}.partial.$$.${RANDOM}.mkv"
  if [[ -e "$TMP_OUT_FILE" ]]; then
    err "File temporaneo gia' esistente: $TMP_OUT_FILE"
    ((ERR_COUNT+=1))
    continue
  fi

  # Titolo accurato: nel fallback la natura Atmos non e' stata verificata.
  if [[ "$A_TYPE" == "atmos" ]]; then
    ORIG_TITLE="$ATMOS_ORIGINAL_TITLE"
  else
    ORIG_TITLE="EAC3 Multichannel (Original - Atmos non verificato)"
  fi

  # FFmpeg command
  CMD=(ffmpeg -hide_banner -nostdin -stats -loglevel warning -y)
  CMD+=(
    -i "$CUR_FILE"
    -map_metadata 0 -map_chapters 0

    # Video, sottotitoli, allegati: copia
    -map "0:V:0?" -c:v copy
    -map "0:s?" -c:s copy
    -map "0:t?" -c:t copy

    # Traccia 1: EAC3 5.1 con dynaudnorm
    -filter_complex "$FILTER_COMPLEX"
    -map "[aout]"
    -c:a:0 eac3 -b:a:0 "$BITRATE" -dialnorm -31 -ar:a:0 48000 -ac:a:0 6
    -metadata:s:a:0 "title=EAC3 5.1 – Normalized"
    -disposition:a:0 default

    # Traccia 2: Atmos originale (copia bit-perfect)
    -map "0:${A_IDX}"
    -c:a:1 copy
    -metadata:s:a:1 "title=${ORIG_TITLE}"
    -disposition:a:1 0
  )

  # Lingua
  if [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]]; then
    CMD+=( -metadata:s:a:0 "language=$A_LANG" )
    CMD+=( -metadata:s:a:1 "language=$A_LANG" )
  fi
  # Output file
  CMD+=( "$TMP_OUT_FILE" )

  # Esecuzione
  info "Avvio encoding..."
  if "${CMD[@]}"; then
    VERIFY_REASON=""
    verify_output_audio_signal "$TMP_OUT_FILE" "$INPUT_AUDIO_METRICS"
    VERIFY_RC=$?
    if (( VERIFY_RC == 0 )); then
      if mv -f -- "$TMP_OUT_FILE" "$OUT_FILE"; then
        ok "Creato e verificato: $OUT_FILE"
        ((OK_COUNT+=1))
      else
        err "Verifica superata, ma pubblicazione fallita: $TMP_OUT_FILE"
        ((ERR_COUNT+=1))
      fi
    elif (( VERIFY_RC == 1 )); then
      err "Candidato rifiutato: ${VERIFY_REASON}: $TMP_OUT_FILE"
      err "Il file finale non viene toccato; il candidato .partial resta per il debug."
      ((ERR_COUNT+=1))
    else
      err "Verifica non conclusiva: ${VERIFY_REASON}: $TMP_OUT_FILE"
      err "Fail-closed: il file finale non viene toccato."
      ((ERR_COUNT+=1))
    fi
  else
    warn "Errore su: $CUR_FILE (eventuale candidato incompleto: $TMP_OUT_FILE)"
    ((ERR_COUNT+=1))
  fi
  echo ""
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
