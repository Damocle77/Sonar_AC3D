#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# stereo251_upmix.sh — Stereo → 5.1 REACTIVE (PAN / SURROUND)
#
# Filosofia:
# - LFE derivato (coerente con aegis/sonar/wide/aura)
# - Spazialità psicoacustica su surround
# - Niente normalizzazione: eseguire esternamente (es. ffmediamaster)
#
# Ambiente tipico:
# - MSYS2/Windows
# - AVR con crossover alto (~160 Hz), YPAO/room correction ON
# -----------------------------------------------------------------------------
set -Eeuo pipefail
trap '' PIPE

log() { printf '%s\n' "$*" >&2 || true; }

on_err() {
  local rc=$?
  printf '💥 ERRORE: riga %s: %s (rc=%s)\n' \
    "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" "$rc" >&2 || true
  exit "$rc"
}
trap on_err ERR

usage() {
cat >&2 <<'EOF'
───────────────────────────────────────────────────────────────────────────────────────────
USO:
  ./stereo251_upmix.sh pan|surround [codec] [bitrate] [keep] file1.mkv [file2.mkv ...]
MODALITÀ:
  pan        - Spazio stabile / dialoghi
  surround   - Spazio reattivo / cinema moderno
CODEC:
  ac3        - Dolby Digital (max 640k)
  eac3       - Dolby Digital Plus (default)
BITRATE:
  es. 448k (default), 640k, ...
OPZIONE:
  keep       - Mantiene audio originale (copy) e aggiunge upmix come ultima traccia audio
NOTE:
- LFE neutro (nessun boost artificiale)
- Layout coerente: output 5.1(side) (SL/SR)
- Subtitles e metadata copiati (quando supportati dal container)
- Attachments MKV (font ASS) copiati (se presenti)
───────────────────────────────────────────────────────────────────────────────────────────
EOF
}

need_bin() {
  command -v "$1" >/dev/null 2>&1 || { log "❌ Richiesto '$1' nel PATH"; exit 127; }
}
need_bin ffmpeg
need_bin ffprobe
need_bin awk
need_bin wc
need_bin tr

[[ $# -ge 2 ]] || { usage; exit 2; }

MODE="${1,,}"; shift
case "$MODE" in
  pan|surround) ;;
  *) log "❌ Mode non valido: '$MODE'"; usage; exit 2 ;;
esac

CODEC="eac3"
BITRATE="448k"
KEEP_ORIG="no"

[[ "${1:-}" =~ ^(ac3|eac3)$ ]] && { CODEC="${1,,}"; shift; }
[[ "${1:-}" =~ ^[0-9]+k$ ]] && { BITRATE="$1"; shift; }
[[ "${1:-}" == "keep" || "${1:-}" == "KEEP" ]] && { KEEP_ORIG="yes"; shift; }

if [[ "$CODEC" == "ac3" && "${BITRATE%k}" -gt 640 ]]; then
  log "❌ AC3 max 640k"
  exit 2
fi

db2lin() { awk -v d="$1" 'BEGIN{ printf "%.6f", (10^(d/20)) }'; }

# Seleziona:
# - prima traccia stereo disponibile
# - preferenza: language=it*
# Nota: NO PIPE per evitare subshell (MSYS2/Bash)
pick_audio_stream() {
  local in="$1" first=""
  while IFS=',' read -r idx ch lang; do
    [[ "$ch" == "2" ]] || continue
    [[ -z "$first" ]] && first="$idx"
    [[ "${lang,,}" =~ ^it ]] && { printf '%s\n' "$idx"; return 0; }
  done < <(
    ffprobe -v error -select_streams a \
      -show_entries stream=index,channels:stream_tags=language \
      -of csv=p=0 "$in"
  )

  [[ -n "$first" ]] || return 1
  printf '%s\n' "$first"
}

count_audio_streams() {
  local in="$1"
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$in" \
    | wc -l | tr -d '[:space:]'
}

for IN in "$@"; do
  [[ -f "$IN" ]] || { log "⚠️ Skip (non trovato): $IN"; continue; }

  OUT="${IN%.*}_5.1_${MODE}.${IN##*.}"

  if ! aidx="$(pick_audio_stream "$IN")"; then
    log "❌ Nessuna traccia stereo trovata: $IN"
    continue
  fi
  [[ "$aidx" =~ ^[0-9]+$ ]] || { log "❌ aidx non valido: '$aidx'"; continue; }

  log "──────────────────────────────────────────────"
  log "Input:   $IN"
  log "Mode:    ${MODE^^}"
  log "Audio:   a:$aidx (stereo)"
  log "Codec:   ${CODEC^^}"
  log "Bitrate: $BITRATE"
  log "Keep:    $KEEP_ORIG"
  log "Output:  $OUT"
  log "──────────────────────────────────────────────"

  if [[ "$MODE" == "pan" ]]; then
    ENV_VOL=0.11; ENV_RATIO=1.18; ENV_ATTACK=420; ENV_RELEASE=1250
    ENV_THR=0.18; SUR_VOL=0.65; DL=10; DR=14; APH_S=0.28; APH_D=2.2
    SUR_TRIM_DB=0.2
  else
    ENV_VOL=0.17; ENV_RATIO=1.38; ENV_ATTACK=220; ENV_RELEASE=780
    ENV_THR=0.16; SUR_VOL=0.70; DL=12; DR=16; APH_S=0.32; APH_D=2.3
    SUR_TRIM_DB=0.6
  fi

  SUR_TRIM="$(db2lin "$SUR_TRIM_DB")"

  FILTER="$(cat <<EOF
# Blindiamo lo stereo (container "misteriosi" friendly)
[0:${aidx}]aformat=channel_layouts=stereo,aresample=48000,asplit=4[aLR][aC][aLFE][aS];

[aLR]asplit=2[aLRf][aLRenv];

[aLRf]pan=stereo|c0=c0+0.02*c1|c1=c1+0.02*c0,
       channelsplit=channel_layout=stereo[FL][FR];

[aLRenv]pan=mono|c0=0.5*c0+0.5*c1,
        lowpass=300,
        compand=attacks=0.45:decays=0.90:points=-60/-60|-32/-23|0/-12,
        volume=${ENV_VOL}[env];

# Centro: "mid" filtrato (dialoghi)
[aC]pan=mono|c0=0.5*c0+0.5*c1,
    highpass=100,lowpass=7500,volume=1.08[FC];

# LFE neutro (no boost)
[aLFE]pan=mono|c0=0.5*c0+0.5*c1,
      lowpass=120[LFE];

# Surround: highpass alto (crossover ~160Hz)
[aS]highpass=160,lowpass=6200,asplit=2[sL0][sR0];

[sL0]pan=mono|c0=0.75*c0-0.75*c1,
      aphaser=speed=${APH_S}:delay=${APH_D},
      adelay=${DL}|${DL},volume=${SUR_VOL}[sL1];

[sR0]pan=mono|c0=0.75*c1-0.75*c0,
      aphaser=speed=${APH_S}:delay=${APH_D},
      adelay=${DR}|${DR},volume=${SUR_VOL}[sR1];

# Sidechain upward: i surround "respirano" con la scena, ma schivano la voce
[sL1][env]sidechaincompress=mode=upward:threshold=${ENV_THR}:ratio=${ENV_RATIO}:attack=${ENV_ATTACK}:release=${ENV_RELEASE}[sL2];
[sR1][env]sidechaincompress=mode=upward:threshold=${ENV_THR}:ratio=${ENV_RATIO}:attack=${ENV_ATTACK}:release=${ENV_RELEASE}[sR2];

[sL2]volume=${SUR_TRIM}[SL];
[sR2]volume=${SUR_TRIM}[SR];

# Join finale: 5.1(side) esplicito per coerenza SL/SR
[FL][FR][FC][LFE][SL][SR]join=inputs=6:channel_layout=5.1(side),aformat=channel_layouts=5.1(side),volume=1.10[aout]
EOF
)"

  if [[ "$KEEP_ORIG" == "yes" ]]; then
    orig_audio_count="$(count_audio_streams "$IN")"
    [[ "$orig_audio_count" =~ ^[0-9]+$ ]] || orig_audio_count=0

    # upmix index in output = numero di tracce audio originali (mappate prima)
    upmix_idx="$orig_audio_count"

    ffmpeg -hide_banner -avoid_negative_ts 1 -loglevel warning -stats -y \
      -probesize 100M -analyzeduration 100M \
      -i "$IN" \
      -map 0:v? -map 0:a? -map 0:s? -map 0:t? \
      -map_metadata 0 -map_chapters 0 \
      -filter_complex "$FILTER" -map "[aout]" \
      -c:v copy -c:s copy -c:t copy \
      -c:a copy \
      -c:a:${upmix_idx} "$CODEC" -b:a:${upmix_idx} "$BITRATE" \
      -metadata:s:a:${upmix_idx} title="Upmix 5.1(${MODE})" \
      "$OUT"
  else
    ffmpeg -hide_banner -avoid_negative_ts 1 -loglevel warning -stats -y \
      -probesize 100M -analyzeduration 100M \
      -i "$IN" \
      -map 0:v? -map 0:s? -map 0:t? \
      -map_metadata 0 -map_chapters 0 \
      -filter_complex "$FILTER" -map "[aout]" \
      -c:a "$CODEC" -b:a "$BITRATE" \
      -metadata:s:a:0 title="Upmix 5.1(${MODE})" \
      -c:v copy -c:s copy -c:t copy \
      "$OUT"
  fi

  log "✅ OK: $OUT"
done

log "🎬 Elaborazione completata!"
