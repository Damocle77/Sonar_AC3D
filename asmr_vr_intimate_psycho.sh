#!/usr/bin/env bash
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   asmr_vr_intimate_psycho.sh - Luglio 2026                                          │
# │   By Sandro (D@mocle77) Sabbioni                                             │
# │                                                                              │
# │   Processing binaurale ottimizzato per ASMR / VR / contenuto intimo.         │
# │   Simula vicinanza della sorgente sonora (20-50cm) con crossfeed BS2B        │
# │   J.Meier, ITD (Interaural Time Difference) e EQ psicoacustico.              │
# │                                                                              │
# │   CHANGELOG V3:                                                              │
# │     - Rimosso set -e (allineato a aegis/analyzer/upmix)                      │
# │     - Selezione stream score-based (stereo, default, ita)                    │
# │     - Output atomico e verifica comparativa prima della pubblicazione        │
# │     - Prompt overwrite da /dev/tty con opzione "tutti" (-f)                  │
# │     - Propagazione language tag                                              │
# │     - LFO fix: tremolo+flanger (la pan= non supporta espressioni t-varianti) │
# │     - Keep originale come traccia secondaria (-k)                            │
# │     - loudnorm post-DSP: il target LUFS descrive davvero l'output finale     │
# │     - ITD disattivabile (-t) per materiale gia' binaurale                    │
# │     - Preflight encoder e parser ffprobe robusto chiave/valore               │
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

# bs2b e' un filtro opzionale (richiede FFmpeg compilato con libbs2b): lo verifichiamo
# subito per dare un errore chiaro invece di un crash a meta' encoding.
FFMPEG_FILTERS="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
if ! grep -qw bs2b <<<"$FFMPEG_FILTERS"; then
  err "Il filtro 'bs2b' non e' disponibile in questo FFmpeg (serve libbs2b). Usa un build completo (es. ffmpeg full)."
  exit 1
fi
unset FFMPEG_FILTERS

OUTDIR=""
KEEP_ORIG=0
FORCE_OVERWRITE=0
USE_LFO=0
DISABLE_ITD=0
DISTANCE_MODE="whisper"
OUT_CODEC="aac"
OUT_BITRATE="320k"

# Guard rail della verifica comparativa stereo input/output.
VERIFY_SILENCE_PEAK_DB="-80.0"
VERIFY_ACTIVE_INPUT_RMS_DB="-65.0"
VERIFY_MAX_OVERALL_DROP_DB="30.0"
VERIFY_MAX_CHANNEL_DROP_DB="30.0"
VERIFY_MIN_SAMPLE_RATIO="0.98"

show_help() {
  cat <<'EOF'
UTILIZZO:
  ./asmr_vr_intimate_psycho.sh [opzioni] <file1> [file2 ...]

OPZIONI:
  -o <dir>    Cartella di output (default: stessa del file)
  -d <mode>   Distanza: whisper (20-30cm) | near (30-50cm) | center (front)
  -k          Mantieni audio originale come traccia secondaria
  -l          Attiva effetto "Breathing LFO" (modulazione lenta ipnotica)
  -t          Disattiva ITD; utile per sorgenti gia' binaurali
  -c <codec>  Codec audio output: aac (default) | opus | flac
  -b <rate>   Bitrate output (default: 320k, ignorato per flac)
  -f          Forza sovrascrittura senza chiedere
  -h          Mostra questa guida

PRESET:
  whisper   Max intimita'. Ottimizzato per sussurri all'orecchio (20-30cm).
            Target -20 LUFS, crossfeed largo, bass boost 85Hz.
  near      Voce vicina ma non sussurrata (30-50cm).
            Target -19 LUFS, crossfeed medio.
  center    Sorgente frontale, leggera spazializzazione.
            Target -18 LUFS, crossfeed contenuto.

NOTE:
  BS2B J.Meier: algoritmo psicoacustico per eliminare la fatica in cuffia.
  Codec/bitrate configurabili: default AAC 320k per massima fedelta'.
  La selezione stream e' score-based (allineata a aegis/analyzer/upmix):
  priorita' a tracce stereo (2ch), lingua italiana, poi flag default.
EOF
  exit 0
}

[[ $# -eq 0 ]] && { show_help; }

while getopts ":o:d:c:b:kfhlt" opt; do
  case "$opt" in
    o) OUTDIR="$OPTARG" ;;
    d) DISTANCE_MODE="$OPTARG" ;;
    c) OUT_CODEC="$OPTARG" ;;
    b) OUT_BITRATE="$OPTARG" ;;
    k) KEEP_ORIG=1 ;;
    f) FORCE_OVERWRITE=1 ;;
    l) USE_LFO=1 ;;
    t) DISABLE_ITD=1 ;;
    h) show_help ;;
    *) err "Opzione non valida: -${OPTARG:-}. Usa -h per l'aiuto."; exit 1 ;;
  esac
done
shift $((OPTIND-1))

# Validazione preset anticipata (fail-fast)
case "$DISTANCE_MODE" in
  whisper|near|center) ;;
  *) err "Distanza '$DISTANCE_MODE' non valida. Usa whisper, near o center."; exit 1 ;;
esac

case "${OUT_CODEC,,}" in
  aac|opus|flac) OUT_CODEC="${OUT_CODEC,,}" ;;
  *) err "Codec '$OUT_CODEC' non valido. Usa aac, opus o flac."; exit 1 ;;
esac

# Mappa il codec all'encoder FFmpeg reale: l'encoder nativo 'opus' e' experimental
# e fallisce senza '-strict -2'; 'libopus' e' quello di produzione.
case "$OUT_CODEC" in
  opus) A_ENCODER="libopus" ;;
  *)    A_ENCODER="$OUT_CODEC" ;;
esac

if ! ffmpeg -hide_banner -encoders 2>/dev/null | \
     grep -E "^[[:space:]]*A[.A-Z]*[[:space:]]+${A_ENCODER}[[:space:]]" >/dev/null; then
  err "Encoder FFmpeg '${A_ENCODER}' non disponibile in questa build."
  exit 1
fi

if [[ "$OUT_CODEC" != "flac" ]]; then
  [[ "$OUT_BITRATE" =~ ^[0-9]+([kKmM])?$ ]] || { err "Bitrate '$OUT_BITRATE' non valido. Es: 192k, 256k, 320k."; exit 1; }
  [[ "$OUT_BITRATE" =~ [kKmM]$ ]] || OUT_BITRATE="${OUT_BITRATE}k"
  OUT_BITRATE="${OUT_BITRATE,,}"
fi

(( $# == 0 )) && { err "Nessun file specificato. Usa -h per l'aiuto."; exit 1; }

if [[ -n "$OUTDIR" ]] && ! mkdir -p "$OUTDIR"; then
  err "Impossibile creare la cartella di output: $OUTDIR"
  exit 1
fi

LFO_STATUS="Disattivo"; [[ "$USE_LFO" -eq 1 ]] && LFO_STATUS="Attivo"
ITD_STATUS="Attivo"; [[ "$DISABLE_ITD" -eq 1 ]] && ITD_STATUS="Disattivo"
info "Preset:  ${DISTANCE_MODE^^}"
info "LFO:     ${LFO_STATUS}"
info "ITD:     ${ITD_STATUS}"
info "Codec:   ${OUT_CODEC^^}"
[[ "$OUT_CODEC" != "flac" ]] && info "Bitrate: ${OUT_BITRATE}"

confirm_overwrite() {
  local target="$1"
  local ans=""
  if [[ ! -e /dev/tty ]]; then
    warn "TTY non disponibile e '$target' esiste gia' -> skip automatico."
    return 1
  fi
  echo -ne "${C_WARN} Il file '$target' esiste. Sovrascrivere? [s/n/t] (s=si, n=no, t=tutti): "
  if ! read -r ans < /dev/tty; then
    warn "Impossibile leggere da /dev/tty -> skip automatico."
    return 1
  fi
  case "${ans,,}" in
    t|tutti) OVERWRITE_ALL=true; info "God mode attivato: sovrascrittura automatica da qui in poi."; return 0 ;;
    s|si|y|yes) info "Sovrascrivo questo file."; return 0 ;;
    *) info "Skip manuale richiesto."; return 1 ;;
  esac
}


# ────────────────────────────────────────────────────────────────────────────────
# Selezione stream score-based (allineata a aegis/analyzer/upmix)
#
# Score: 2 canali (stereo) -> +1000, default -> +200, lingua italiana -> +300
# A parita' di score, vince il primo trovato.
# Restituisce via stdout: idx|ch|lang
# ────────────────────────────────────────────────────────────────────────────────
pick_best_stereo_stream() {
  local f="$1"
  local raw_data
  raw_data=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels:stream_disposition=default:stream_tags=language \
    -of compact=p=0:nk=0 "$f" 2>/dev/null </dev/null || true)
  raw_data="${raw_data//$'\r'/}"

  [[ -z "$raw_data" ]] && return 1

  local best_line="" best_score=-1 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local idx="" ch="0" def="0" lang="" field
    local fields=()
    IFS='|' read -r -a fields <<<"$line"
    for field in "${fields[@]}"; do
      case "$field" in
        index=*)               idx="${field#index=}" ;;&
        channels=*)            ch="${field#channels=}" ;;&
        disposition:default=*) def="${field#disposition:default=}" ;;&
        tag:language=*)        lang="${field#tag:language=}" ;;&
      esac
    done

    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    [[ "$ch" =~ ^[0-9]+$ ]] || ch=0

    local score=0
    [[ "$ch" =~ ^[0-9]+$ && "$ch" -eq 2 ]] && score=$((score + 1000))
    [[ "$def" == "1" ]] && score=$((score + 200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score + 300))

    if (( score > best_score )); then
      best_score=$score
      best_line="${idx}|${ch}|${lang:-und}"
    fi
  done <<< "$raw_data"

  [[ -n "$best_line" ]] || return 1
  printf '%s\n' "$best_line"
}

# ────────────────────────────────────────────────────────────────────────────────
# Configurazione Filtri (BS2B JMEIER INTEGRATED)
#
# Catena:
#   1. Bandpass (HP+LP) — rimuove rumble e ultrasuoni
#   2. aresample 48k — rende deterministici i delay ITD in campioni
#   3. bs2b jmeier — crossfeed binaurale (riduce fatica in cuffia)
#   4. stereotools + pan — width e crosstalk statici
#   5. EQ psicoacustico — rinforza frequenze di prossimita'
#   6. ITD ed eventuale LFO
#   7. loudnorm — misura la catena gia' processata e centra il target del preset
#   8. ritorno esplicito a 48 kHz
#   9. alimiter finale — safety net senza auto-level
# ────────────────────────────────────────────────────────────────────────────────

# WHISPER (20-30cm)
FILTER_WHISPER="highpass=f=60:poles=2,lowpass=f=15000,aresample=48000,bs2b=profile=jmeier,stereotools=balance_in=0:slev=0.75:mlev=1.10:phase=0,pan=stereo|c0=1.04*c0+0.12*c1|c1=0.12*c0+1.04*c1,equalizer=f=85:t=q:w=1.6:g=2.0,equalizer=f=140:t=q:w=1.4:g=1.3,equalizer=f=320:t=q:w=1.2:g=-1.1,equalizer=f=2800:t=q:w=1.8:g=1.6,equalizer=f=5800:t=q:w=2.0:g=-1.7"
LOUDNORM_WHISPER="loudnorm=I=-20:TP=-2.0:LRA=13"

# NEAR (30-50cm)
FILTER_NEAR="highpass=f=70:poles=2,lowpass=f=14500,aresample=48000,bs2b=profile=jmeier,stereotools=balance_in=0:slev=0.70:mlev=1.06:phase=0,pan=stereo|c0=1.05*c0+0.10*c1|c1=0.10*c0+1.05*c1,equalizer=f=100:t=q:w=1.5:g=1.5,equalizer=f=3200:t=q:w=1.6:g=1.2,equalizer=f=6200:t=q:w=2.0:g=-1.5"
LOUDNORM_NEAR="loudnorm=I=-19:TP=-1.8:LRA=12"

# CENTER (Frontal)
FILTER_CENTER="highpass=f=80:poles=2,lowpass=f=14000,aresample=48000,bs2b=profile=jmeier,stereotools=balance_in=0:slev=0.65:mlev=1.04:phase=0,pan=stereo|c0=1.06*c0+0.08*c1|c1=0.08*c0+1.06*c1,equalizer=f=120:t=q:w=1.4:g=1.1,equalizer=f=3200:t=q:w=1.8:g=1.0,equalizer=f=6200:t=q:w=2.2:g=-1.4"
LOUDNORM_CENTER="loudnorm=I=-18:TP=-1.5:LRA=11"

# Limiter per-preset: applicato come ultimo stadio, dopo ITD/LFO.
# level=0 evita il make-up automatico; latency=1 compensa il look-ahead.
LIMITER_WHISPER="alimiter=limit=0.96:attack=2:release=40:level=0:latency=1"
LIMITER_NEAR="alimiter=limit=0.97:attack=2.5:release=45:level=0:latency=1"
LIMITER_CENTER="alimiter=limit=0.97:attack=3:release=50:level=0:latency=1"

# ITD (Interaural Time Difference) — simula la differenza di arrivo tra orecchie
# Sample-delay a 48 kHz: piu' robusto dei millisecondi frazionari.
# 18S ≈ 0.375 ms, 10S ≈ 0.208 ms.
ITD_WHISPER="adelay=delays=0|18S:all=0"
ITD_NEAR="adelay=delays=0|10S:all=0"
ITD_CENTER=""

# LFO Breathing Effect (V2: tremolo + flanger)
# V1 usava pan= con sin(t) — non supportato da ffmpeg (pan accetta solo coefficienti statici).
# V2 usa tremolo (modulazione ampiezza lenta, 0.12 Hz = ~1 respiro ogni 8 sec)
# + flanger (micro-modulazione fase per effetto "movimento" della sorgente).
# Il risultato e' un leggero "respiro" nell'immagine stereo senza artefatti.
LFO_PART="tremolo=f=0.12:d=0.06,flanger=delay=2:depth=1.5:regen=0:width=40:speed=0.15:shape=sinusoidal:phase=50"

# Misura peak, RMS, campioni e RMS L/R in una sola decodifica.
# Output: peak|rms|samples|rms_L|rms_R
measure_stereo_signal() {
  local f="$1" map_spec="$2" probe metrics
  probe="$(
    ffmpeg -hide_banner -nostdin -v info -i "$f" \
      -map "$map_spec" -vn -sn -dn \
      -af "aformat=sample_rates=48000:sample_fmts=fltp,astats=metadata=0:reset=0" \
      -f null - 2>&1 || true
  )"
  probe="${probe//$'\r'/}"

  metrics="$(printf '%s\n' "$probe" | awk '
    /Channel:/ { channel=$NF; overall=0; next }
    /] Overall$/ { overall=1; channel=0; next }
    /Peak level dB:/ { if (overall) overall_peak=$NF; next }
    /RMS level dB:/ {
      if (overall) overall_rms=$NF
      else if (channel >= 1 && channel <= 2) channel_rms[channel]=$NF
      next
    }
    /Number of samples:/ { if (overall) samples=$NF; next }
    END {
      if (overall_peak == "" || overall_rms == "" || samples == "") exit 1
      for (i=1; i<=2; i++) if (channel_rms[i] == "") exit 1
      printf "%s|%s|%s|%s|%s\n", overall_peak, overall_rms, samples, channel_rms[1], channel_rms[2]
    }
  ')" || return 1

  [[ -n "$metrics" ]] || return 1
  printf '%s\n' "$metrics"
}

is_finite_db() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

verify_stereo_output() {
  local f="$1" input_metrics="$2" output_metrics
  local -a in_m out_m channel_names=(L R)
  local input_peak input_rms input_samples output_peak output_rms output_samples
  local i input_channel_rms output_channel_rms

  output_metrics="$(measure_stereo_signal "$f" "0:a:0")" || {
    VERIFY_REASON="astats non ha restituito metriche stereo complete per l'output"
    return 2
  }
  IFS='|' read -r -a in_m <<<"$input_metrics"
  IFS='|' read -r -a out_m <<<"$output_metrics"
  [[ ${#in_m[@]} -eq 5 && ${#out_m[@]} -eq 5 ]] || {
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

  for i in {0..1}; do
    input_channel_rms="${in_m[$((i+3))]}"
    output_channel_rms="${out_m[$((i+3))]}"
    [[ "$input_channel_rms" == "-inf" ]] && continue
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
    if awk -v src="$input_channel_rms" -v dst="$output_channel_rms" -v lim="$VERIFY_MAX_CHANNEL_DROP_DB" \
         'BEGIN { exit !((src-dst) > lim) }'; then
      VERIFY_REASON="canale ${channel_names[$i]} attenuato eccessivamente: input=${input_channel_rms} dBFS, output=${output_channel_rms} dBFS"
      return 1
    fi
  done

  info "Verifica audio: peak ${input_peak}→${output_peak} dBFS; RMS ${input_rms}→${output_rms} dBFS; campioni ${input_samples}→${output_samples}"
  return 0
}

CURRENT_TMP=""
cleanup_tmp() {
  [[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]] && rm -f -- "$CURRENT_TMP"
}
trap cleanup_tmp EXIT INT TERM

# ────────────────────────────────────────────────────────────────────────────────
# CICLO ELABORAZIONE
# ────────────────────────────────────────────────────────────────────────────────
OVERWRITE_ALL=false
OK_COUNT=0
ERR_COUNT=0
SKIP_COUNT=0
[[ "$FORCE_OVERWRITE" -eq 1 ]] && OVERWRITE_ALL=true

for CUR_FILE in "$@"; do
  [[ -f "$CUR_FILE" ]] || { warn "File '$CUR_FILE' non trovato. Salto."; ((SKIP_COUNT+=1)); continue; }

  info "Elaborazione: $CUR_FILE"

  # ── Selezione stream score-based ─────────────────────────────────────────────
  PROBE_RESULT=$(pick_best_stereo_stream "$CUR_FILE") || { warn "Nessuna traccia audio trovata. Salto."; ((SKIP_COUNT+=1)); continue; }

  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LANG <<<"$PROBE_RESULT"

  if [[ "$A_CHANNELS" -ne 2 ]]; then
    warn "Stream selezionato non e' stereo (Canali: $A_CHANNELS). Salto."
    ((SKIP_COUNT+=1))
    continue
  fi

  info "Stream [$A_STREAM_INDEX]: ${A_CHANNELS}ch, lingua: ${A_LANG:-und}"

  # ── Selezione preset ─────────────────────────────────────────────────────────
  case "$DISTANCE_MODE" in
    whisper) F_BASE="$FILTER_WHISPER"; ITD="$ITD_WHISPER"; LOUDNORM="$LOUDNORM_WHISPER"; LIMITER="$LIMITER_WHISPER"; T="Whisper 20-30cm" ;;
    near)    F_BASE="$FILTER_NEAR";    ITD="$ITD_NEAR";    LOUDNORM="$LOUDNORM_NEAR";    LIMITER="$LIMITER_NEAR";    T="Near 30-50cm" ;;
    center)  F_BASE="$FILTER_CENTER";  ITD="$ITD_CENTER";  LOUDNORM="$LOUDNORM_CENTER";  LIMITER="$LIMITER_CENTER";  T="Center Front" ;;
  esac
  [[ "$DISABLE_ITD" -eq 1 ]] && ITD=""

  INPUT_AUDIO_METRICS="$(measure_stereo_signal "$CUR_FILE" "0:$A_STREAM_INDEX")" || {
    err "Impossibile misurare in modo affidabile la traccia stereo sorgente. Salto."
    ((ERR_COUNT+=1))
    continue
  }

  # Assembla catena filtri con stream target
  FINAL_F="[0:${A_STREAM_INDEX}]${F_BASE}"
  [[ -n "$ITD" ]] && FINAL_F="${FINAL_F},${ITD}"
  [[ "$USE_LFO" -eq 1 ]] && FINAL_F="${FINAL_F},${LFO_PART}"
  FINAL_F="${FINAL_F},${LOUDNORM},aresample=48000,${LIMITER}[aout]"

  # ── Output path ──────────────────────────────────────────────────────────────
  VARIANT_SUFFIX=""
  [[ "$DISABLE_ITD" -eq 1 ]] && VARIANT_SUFFIX+="_NOITD"
  [[ "$USE_LFO" -eq 1 ]] && VARIANT_SUFFIX+="_LFO"
  OUT_FILE="${CUR_FILE%.*}_INTIMATE_${DISTANCE_MODE^^}${VARIANT_SUFFIX}.mkv"
  [[ -n "$OUTDIR" ]] && OUT_FILE="$OUTDIR/$(basename "$OUT_FILE")"

  # ── Gestione sovrascrittura (s/n/t) — allineata a aegis/upmix ─────────────
  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      confirm_overwrite "$OUT_FILE" || { info "Skippo '$CUR_FILE'."; ((SKIP_COUNT+=1)); continue; }
    else
      info "Sovrascrittura automatica di '$OUT_FILE'..."
    fi
  fi

  # ── FFmpeg Command ─────────────────────────────────────────────────────────
  # Codifica in un candidato nella stessa directory: l'output precedente resta
  # intatto finche' encoding e verifica audio non sono entrambi riusciti.
  OUT_DIR=$(dirname -- "$OUT_FILE")
  OUT_BASE=$(basename -- "${OUT_FILE%.mkv}")
  CURRENT_TMP="${OUT_DIR}/.${OUT_BASE}.partial.$$.mkv"
  if [[ -e "$CURRENT_TMP" ]]; then
    err "File temporaneo gia' esistente, impossibile procedere: $CURRENT_TMP"
    ((ERR_COUNT+=1))
    continue
  fi

  CMD=(ffmpeg -hide_banner -nostdin -stats -loglevel warning -y)
  CMD+=(
    -i "$CUR_FILE"
    -map_metadata 0 -map_chapters 0
    -filter_complex "$FINAL_F"
    -map "0:V:0?" -c:v copy
    -map "0:s?" -c:s copy
    -map "0:t?" -c:t copy
    -map "[aout]" -c:a:0 "$A_ENCODER" -ac:a:0 2 -ar:a:0 48000
    -metadata:s:a:0 title="VR Intimate (${T}) – BS2B J.Meier"
    -disposition:a:0 default
  )

  if [[ "$OUT_CODEC" != "flac" ]]; then
    CMD+=( -b:a:0 "$OUT_BITRATE" )
  fi

  # Propagazione language tag
  [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:0 language="$A_LANG" )

  # Keep originale come traccia secondaria
  if [[ "$KEEP_ORIG" -eq 1 ]]; then
    CMD+=( -map 0:"$A_STREAM_INDEX" -c:a:1 copy
           -metadata:s:a:1 title="Stereo Originale"
           -disposition:a:1 0 )
    [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:1 language="$A_LANG" )
  fi

  CMD+=( "$CURRENT_TMP" )
  if "${CMD[@]}"; then
    VERIFY_REASON=""
    verify_stereo_output "$CURRENT_TMP" "$INPUT_AUDIO_METRICS"
    VERIFY_RC=$?
    case "$VERIFY_RC" in
      0)
        if mv -f -- "$CURRENT_TMP" "$OUT_FILE"; then
          CURRENT_TMP=""
          ok "Creato e verificato: $OUT_FILE"
          ((OK_COUNT+=1))
        else
          err "Verifica superata, ma pubblicazione fallita: $CURRENT_TMP"
          ((ERR_COUNT+=1))
        fi
        ;;
      1|2)
        err "Candidato rifiutato dalla verifica audio: ${VERIFY_REASON}: $CURRENT_TMP"
        err "Il file finale non viene toccato; il candidato resta per il debug."
        CURRENT_TMP=""
        ((ERR_COUNT+=1))
        ;;
    esac
  else
    warn "Errore su: $CUR_FILE (candidato incompleto rimosso)"
    cleanup_tmp
    CURRENT_TMP=""
    ((ERR_COUNT+=1))
  fi
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
