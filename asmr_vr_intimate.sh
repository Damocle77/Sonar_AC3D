#!/usr/bin/env bash
# set -e rimosso: causa exit imprevedibili su pattern && / || e aritmetica bash.
# La gestione errori e' esplicita nei punti critici (|| continue, || true, etc.)
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────╮
# │   asmr_vr_intimate.sh - V2 - Marzo 2026                                     │
# │                                                                              │
# │   Processing binaurale ottimizzato per ASMR / VR / contenuto intimo.         │
# │   Simula vicinanza della sorgente sonora (20-50cm) con crossfeed BS2B       │
# │   J.Meier, ITD (Interaural Time Difference) e EQ psicoacustico.             │
# │                                                                              │
# │   CHANGELOG V2:                                                              │
# │     - Rimosso set -e (allineato a aegis/analyzer/upmix)                     │
# │     - Selezione stream score-based (stereo, default, ita)                   │
# │     - -y condizionale (solo su sovrascrittura confermata)                    │
# │     - Prompt overwrite da /dev/tty con opzione "tutti" (-f)                 │
# │     - Propagazione language tag                                              │
# │     - LFO fix: tremolo+flanger (la pan= non supporta espressioni t-varianti)│
# │     - Keep originale come traccia secondaria (-k)                            │
# │     - loudnorm mantenuto (target LUFS per-preset, coerente con uso ASMR)   │
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

OUTDIR=""
KEEP_ORIG=0
FORCE_OVERWRITE=0
USE_LFO=0
DISTANCE_MODE="whisper"

show_help() {
  cat <<'EOF'
UTILIZZO:
  ./asmr_vr_intimate.sh [opzioni] <file1> [file2 ...]

OPZIONI:
  -o <dir>    Cartella di output (default: stessa del file)
  -d <mode>   Distanza: whisper (20-30cm) | near (30-50cm) | center (front)
  -k          Mantieni audio originale come traccia secondaria
  -l          Attiva effetto "Breathing LFO" (modulazione lenta ipnotica)
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
  Codec AAC 320k: massima fedelta' per i micro-dettagli ASMR.
  La selezione stream e' score-based (allineata a aegis/analyzer/upmix):
  priorita' a tracce stereo (2ch), default, lingua italiana.
EOF
  exit 0
}

[[ $# -eq 0 ]] && { show_help; }

while getopts ":o:d:kfhl" opt; do
  case "$opt" in
    o) OUTDIR="$OPTARG" ;;
    d) DISTANCE_MODE="$OPTARG" ;;
    k) KEEP_ORIG=1 ;;
    f) FORCE_OVERWRITE=1 ;;
    l) USE_LFO=1 ;;
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

(( $# == 0 )) && { err "Nessun file specificato. Usa -h per l'aiuto."; exit 1; }

LFO_STATUS="Disattivo"; [[ "$USE_LFO" -eq 1 ]] && LFO_STATUS="Attivo"
info "Preset:  ${DISTANCE_MODE^^}"
info "LFO:     ${LFO_STATUS}"

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
    -of csv=p=0 "$f" 2>/dev/null </dev/null || true)
  raw_data="${raw_data//$'\r'/}"

  [[ -z "$raw_data" ]] && return 1

  local best_line="" best_score=-1
  local lines
  mapfile -t lines <<< "$raw_data"
  for line in "${lines[@]}"; do
    [[ -z "$line" ]] && continue
    local idx ch def lang
    IFS=',' read -r idx ch def lang <<<"$line"
    ch="${ch:-0}"
    def="${def:-0}"
    lang="${lang:-}"

    local score=0
    [[ "$ch" =~ ^[0-9]+$ && "$ch" -eq 2 ]] && score=$((score + 1000))
    [[ "$def" == "1" ]] && score=$((score + 200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score + 300))

    if (( score > best_score )); then
      best_score=$score
      best_line="${idx}|${ch}|${lang:-und}"
    fi
  done

  [[ -n "$best_line" ]] || return 1
  echo "$best_line"
}

# ────────────────────────────────────────────────────────────────────────────────
# Configurazione Filtri (BS2B JMEIER INTEGRATED)
#
# Catena:
#   1. Bandpass (HP+LP) — rimuove rumble e ultrasuoni
#   2. loudnorm — normalizza al target LUFS del preset (coerente per ASMR:
#      il contenuto ha dinamica molto variabile, loudnorm qui e' giustificato)
#   3. aresample 48k — allinea al sample rate di uscita
#   4. bs2b jmeier — crossfeed binaurale (riduce fatica in cuffia)
#   5. stereotools — regola ampiezza stereo (slev/mlev)
#   6. pan — leggero crosstalk per simulare vicinanza (coefficienti statici)
#   7. EQ psicoacustico — rinforza frequenze di prossimita'
#   8. alimiter — safety net (level non specificato = default, ok per ASMR)
# ────────────────────────────────────────────────────────────────────────────────

# WHISPER (20-30cm)
FILTER_WHISPER="highpass=f=60:order=2,lowpass=f=15000,loudnorm=I=-20:TP=-2.0:LRA=13,aresample=48000,bs2b=profile=jmeier,stereotools=balance_in=0:slev=0.75:mlev=1.12:phase=0,pan=stereo|c0=1.08*c0+0.15*c1|c1=0.15*c0+1.08*c1,equalizer=f=85:t=q:w=1.6:g=2.2,equalizer=f=140:t=q:w=1.4:g=1.6,equalizer=f=320:t=q:w=1.2:g=-1.2,equalizer=f=2800:t=q:w=1.8:g=1.8,equalizer=f=5800:t=q:w=2.0:g=-1.8,alimiter=limit=0.96:attack=2:release=40"

# NEAR (30-50cm)
FILTER_NEAR="highpass=f=70:order=2,lowpass=f=14500,loudnorm=I=-19:TP=-1.8:LRA=12,aresample=48000,bs2b=profile=jmeier,stereotools=balance_in=0:slev=0.70:mlev=1.08:phase=0,pan=stereo|c0=1.10*c0+0.12*c1|c1=0.12*c0+1.10*c1,equalizer=f=100:t=q:w=1.5:g=1.8,equalizer=f=3200:t=q:w=1.6:g=1.4,equalizer=f=6200:t=q:w=2.0:g=-1.6,alimiter=limit=0.97:attack=2.5:release=45"

# CENTER (Frontal)
FILTER_CENTER="highpass=f=80:order=2,lowpass=f=14000,loudnorm=I=-18:TP=-1.5:LRA=11,aresample=48000,bs2b=profile=jmeier,stereotools=balance_in=0:slev=0.65:mlev=1.05:phase=0,pan=stereo|c0=1.12*c0+0.10*c1|c1=0.10*c0+1.12*c1,equalizer=f=120:t=q:w=1.4:g=1.4,equalizer=f=3200:t=q:w=1.8:g=1.1,equalizer=f=6200:t=q:w=2.2:g=-1.5,alimiter=limit=0.97:attack=3:release=50"

# ITD (Interaural Time Difference) — simula la differenza di arrivo tra orecchie
ITD_WHISPER="adelay=delays=0|0.38:all=0"
ITD_NEAR="adelay=delays=0|0.20:all=0"
ITD_CENTER=""

# LFO Breathing Effect (V2: tremolo + flanger)
# V1 usava pan= con sin(t) — non supportato da ffmpeg (pan accetta solo coefficienti statici).
# V2 usa tremolo (modulazione ampiezza lenta, 0.12 Hz = ~1 respiro ogni 8 sec)
# + flanger (micro-modulazione fase per effetto "movimento" della sorgente).
# Il risultato e' un leggero "respiro" nell'immagine stereo senza artefatti.
LFO_PART="tremolo=f=0.12:d=0.06,flanger=delay=2:depth=1.5:regen=0:width=40:speed=0.15:shape=sinusoidal:phase=50"

# ────────────────────────────────────────────────────────────────────────────────
# CICLO ELABORAZIONE
# ────────────────────────────────────────────────────────────────────────────────
OVERWRITE_ALL=false
[[ "$FORCE_OVERWRITE" -eq 1 ]] && OVERWRITE_ALL=true

for CUR_FILE in "$@"; do
  [[ -f "$CUR_FILE" ]] || { warn "File '$CUR_FILE' non trovato. Salto."; continue; }

  info "Elaborazione: $CUR_FILE"

  # ── Selezione stream score-based ─────────────────────────────────────────────
  PROBE_RESULT=$(pick_best_stereo_stream "$CUR_FILE") || { warn "Nessuna traccia audio trovata. Salto."; continue; }

  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LANG <<<"$PROBE_RESULT"

  if [[ "$A_CHANNELS" -ne 2 ]]; then
    warn "Stream selezionato non e' stereo (Canali: $A_CHANNELS). Salto."
    continue
  fi

  info "Stream [$A_STREAM_INDEX]: ${A_CHANNELS}ch, lingua: ${A_LANG:-und}"

  # ── Selezione preset ─────────────────────────────────────────────────────────
  case "$DISTANCE_MODE" in
    whisper) F_BASE="$FILTER_WHISPER"; ITD="$ITD_WHISPER"; T="Whisper 20-30cm" ;;
    near)    F_BASE="$FILTER_NEAR";    ITD="$ITD_NEAR";    T="Near 30-50cm" ;;
    center)  F_BASE="$FILTER_CENTER";  ITD="$ITD_CENTER";  T="Center Front" ;;
  esac

  # Assembla catena filtri con stream target
  FINAL_F="[0:${A_STREAM_INDEX}]${F_BASE}"
  [[ -n "$ITD" ]] && FINAL_F="${FINAL_F},${ITD}"
  [[ "$USE_LFO" -eq 1 ]] && FINAL_F="${FINAL_F},${LFO_PART}"
  FINAL_F="${FINAL_F}[aout]"

  # ── Output path ──────────────────────────────────────────────────────────────
  OUT_FILE="${CUR_FILE%.*}_INTIMATE_${DISTANCE_MODE^^}.mkv"
  [[ -n "$OUTDIR" ]] && {
    mkdir -p "$OUTDIR" 2>/dev/null || true
    OUT_FILE="$OUTDIR/$(basename "$OUT_FILE")"
  }

  # ── Gestione sovrascrittura (s/n/t) — allineata a aegis/upmix ─────────────
  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      echo -ne "${C_WARN} Il file '$OUT_FILE' esiste. Sovrascrivere? [s/n/t] (s=si, n=no, t=tutti): "
      read -r ans < /dev/tty
      case "${ans,,}" in
        t|tutti)
          OVERWRITE_ALL=true
          info "God mode attivato: sovrascrittura automatica da qui in poi."
          ;;
        s|si|y|yes)
          info "Sovrascrivo questo file."
          ;;
        *)
          info "Skippo '$CUR_FILE'."
          continue
          ;;
      esac
    else
      info "Sovrascrittura automatica di '$OUT_FILE'..."
    fi
  fi

  # ── FFmpeg Command ─────────────────────────────────────────────────────────
  # -y solo se il file esiste (l'utente ha confermato la sovrascrittura)
  CMD=(ffmpeg -hide_banner -nostdin -stats -loglevel warning)
  [[ -f "$OUT_FILE" ]] && CMD+=( -y )
  CMD+=(
    -i "$CUR_FILE"
    -map_metadata 0 -map_chapters 0
    -filter_complex "$FINAL_F"
    -map "0:V:0?" -c:v copy
    -map "0:s?" -c:s copy
    -map "0:t?" -c:t copy
    -map "[aout]" -c:a:0 aac -b:a:0 320k -ac:a:0 2 -ar:a:0 48000
    -metadata:s:a:0 title="VR Intimate (${T}) – BS2B J.Meier"
    -disposition:a:0 default
  )

  # Propagazione language tag
  [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:0 language="$A_LANG" )

  # Keep originale come traccia secondaria
  if [[ "$KEEP_ORIG" -eq 1 ]]; then
    CMD+=( -map 0:"$A_STREAM_INDEX" -c:a:1 copy
           -metadata:s:a:1 title="Stereo Originale"
           -disposition:a:1 0 )
  fi

  CMD+=( "$OUT_FILE" )
  "${CMD[@]}" && ok "Creato: $OUT_FILE" || warn "Errore su: $CUR_FILE"
done

ok "Elaborazione completata."
