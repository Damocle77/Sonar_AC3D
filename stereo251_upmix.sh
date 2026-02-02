#!/usr/bin/env bash
# stereo251_upmix.sh — Stereo → 5.1 REACTIVE (PAN + SURROUND)
# Fix sottotitoli: -c:s copy (PGS/SSA safe)
# Stanza 4x5 m, soffitto 4.2 m, YPAO ON

set -Eeuo pipefail
trap '' PIPE

log() { printf '%s\n' "$*" >&2 || true; }

on_err() {
  local rc=$?
  printf '💥 ERRORE: riga %s: %s (rc=%s)\n' "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" "$rc" >&2 || true
  exit "$rc"
}
trap on_err ERR

usage() {
cat >&2 <<'EOF'
USO:
  ./stereo251_upmix.sh pan|surround [codec] [bitrate] file1.mkv [file2.mkv ...]

MODALITÀ:
  pan      - Spazio stabile / dialoghi
  surround - Spazio reattivo / cinema moderno

CODEC:
  ac3      - Dolby Digital (max 640k)
  eac3     - Dolby Digital Plus (default)

NOTE:
- Selezione automatica traccia stereo (ITA preferita)
- Sottotitoli copiati senza ricodifica (PGS/SSA safe)
EOF
}

[[ $# -ge 2 ]] || { usage; exit 2; }

MODE="${1,,}"; shift
case "$MODE" in
  pan|surround) ;;
  *) log "❌ Mode non valido"; usage; exit 2 ;;
esac

CODEC="eac3"
BITRATE="448k"

[[ "${1,,}" =~ ^(ac3|eac3)$ ]] && { CODEC="${1,,}"; shift; }
[[ "${1:-}" =~ ^[0-9]+k$ ]] && { BITRATE="$1"; shift; }

if [[ "$CODEC" == "ac3" && "${BITRATE%k}" -gt 640 ]]; then
  log "❌ AC3 max 640k"; exit 2
fi

db2lin() { awk -v d="$1" 'BEGIN{ printf "%.6f", (10^(d/20)) }'; }

pick_audio_stream() {
  local in="$1" first=""
  ffprobe -v error -select_streams a \
    -show_entries stream=index,channels:stream_tags=language \
    -of csv=p=0 "$in" |
  while IFS=',' read -r idx ch lang; do
    [[ "$ch" == "2" ]] || continue
    [[ -z "$first" ]] && first="$idx"
    [[ "${lang,,}" =~ ^it ]] && { echo "$idx"; return; }
  done
  echo "${first:-0}"
}

for IN in "$@"; do
  [[ -f "$IN" ]] || continue
  OUT="${IN%.*}_5.1_${MODE}.${IN##*.}"
  aidx="$(pick_audio_stream "$IN")"

  log "──────────────────────────────────────────────"
  log "Input:  $IN"
  log "Mode:   ${MODE^^}"
  log "Audio:  a:$aidx"
  log "Codec:  ${CODEC^^}"
  log "Bitrate:$BITRATE"
  log "Output: $OUT"
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
[0:${aidx}]aresample=48000,asplit=4[aLR][aC][aLFE][aS];

[aLR]asplit=2[aLRf][aLRenv];

[aLRf]pan=stereo|c0=c0+0.02*c1|c1=c1+0.02*c0,
       channelsplit[FL][FR];

[aLRenv]pan=mono|c0=0.5*c0+0.5*c1,
        lowpass=300,
        compand=attacks=0.45:decays=0.90:points=-60/-60|-32/-23|0/-12,
        volume=${ENV_VOL}[env];

[aC]pan=mono|c0=0.5*c0+0.5*c1,
    highpass=100,lowpass=7500,volume=1.08[FC];

[aLFE]pan=mono|c0=0.5*c0+0.5*c1,
      lowpass=140,volume=1.5[LFE];

[aS]highpass=160,lowpass=6200,asplit=2[sL0][sR0];

[sL0]pan=mono|c0=0.75*c0-0.75*c1,
      aphaser=speed=${APH_S}:delay=${APH_D},
      adelay=${DL}|${DL},volume=${SUR_VOL}[sL1];

[sR0]pan=mono|c0=0.75*c1-0.75*c0,
      aphaser=speed=${APH_S}:delay=${APH_D},
      adelay=${DR}|${DR},volume=${SUR_VOL}[sR1];

[sL1][env]sidechaincompress=mode=upward:threshold=${ENV_THR}:ratio=${ENV_RATIO}:attack=${ENV_ATTACK}:release=${ENV_RELEASE}[sL2];
[sR1][env]sidechaincompress=mode=upward:threshold=${ENV_THR}:ratio=${ENV_RATIO}:attack=${ENV_ATTACK}:release=${ENV_RELEASE}[sR2];

[sL2]volume=${SUR_TRIM}[SL];
[sR2]volume=${SUR_TRIM}[SR];

[FL][FR][FC][LFE][SL][SR]join=inputs=6:channel_layout=5.1,volume=1.10[aout]
EOF
)"

  ffmpeg -hide_banner -avoid_negative_ts 1 -loglevel warning -stats -y \
    -i "$IN" \
    -map 0:v? -map 0:s? -map_metadata 0 -map_chapters 0 \
    -filter_complex "$FILTER" -map "[aout]" \
    -c:a "$CODEC" -b:a "$BITRATE" \
    -c:v copy \
    -c:s copy \
    "$OUT"

  log "✅ OK: $OUT"
done

log "🎬 Elaborazione completata!"
