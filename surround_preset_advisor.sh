#!/usr/bin/env bash
set -euo pipefail

IN="${1:-}"
AIDX="${2:-0}"

[[ -z "$IN" ]] && { echo "Uso: $0 <file.mkv> [audio_index]"; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ────────────────────────────────────────────────────────────
# Helpers MSYS2 / POSIX
# ────────────────────────────────────────────────────────────
is_msys() {
  uname | tr '[:upper:]' '[:lower:]' | grep -Eq 'mingw|msys|cygwin'
}

to_native() {
  if is_msys && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf "%s" "$1"
  fi
}

IN_NATIVE="$(to_native "$IN")"

FC_WAV="$tmpdir/fc.wav"
SUR_WAV="$tmpdir/sur.wav"
FC_WAV_NATIVE="$(to_native "$FC_WAV")"
SUR_WAV_NATIVE="$(to_native "$SUR_WAV")"

# ────────────────────────────────────────────────────────────
# Layout detect + mapping deterministico → 5.1(side)
# ────────────────────────────────────────────────────────────
LAYOUT="$(ffprobe -v error -select_streams a:"$AIDX" \
  -show_entries stream=channel_layout -of default=nw=1:nk=1 "$IN_NATIVE" | head -1 || true)"

MAP_TO_SIDE="anull"

case "$LAYOUT" in
  "5.1")
    MAP_TO_SIDE="channelmap=FL-FL|FR-FR|FC-FC|LFE-LFE|BL-SL|BR-SR:5.1(side)"
    ;;
  "5.1(back)")
    MAP_TO_SIDE="channelmap=FL-FL|FR-FR|FC-FC|LFE-LFE|BL-SL|BR-SR:5.1(side)"
    ;;
  "5.1(side)")
    MAP_TO_SIDE="anull"
    ;;
  "unknown")
    echo "[WARN] Layout audio 'unknown'. Uso il layout deciso dal decoder FFmpeg."
    MAP_TO_SIDE="anull"
    ;;
  *)
    echo "[ERROR] Layout audio non supportato: '$LAYOUT'"
    exit 1
    ;;
esac

# ────────────────────────────────────────────────────────────
# Estrazione FC / SUR (banda rilevante)
# ────────────────────────────────────────────────────────────
echo "Estraendo canali FC e SUR..."
ffmpeg -hide_banner -loglevel error -y -i "$IN_NATIVE" \
  -filter_complex "
    [0:a:$AIDX]$MAP_TO_SIDE,
      channelsplit=channel_layout=5.1(side)[FL][FR][FC][LFE][SL][SR];

    [FL]anullsink;
    [FR]anullsink;
    [LFE]anullsink;

    [FC]highpass=f=120,lowpass=f=7000[fc];

    [SL][SR]amerge=2,
      pan=mono|c0=0.5*c0+0.5*c1,
      highpass=f=120,lowpass=f=7000[sur]
  " \
  -map "[fc]"  -ac 1 "$FC_WAV_NATIVE" \
  -map "[sur]" -ac 1 "$SUR_WAV_NATIVE"

# ────────────────────────────────────────────────────────────
# RMS via metadata (robusto MSYS2)
# ────────────────────────────────────────────────────────────
rms() {
  local wav="$1"
  local wav_native
  wav_native="$(to_native "$wav")"

  ffmpeg -hide_banner -nostats -i "$wav_native" \
    -af "asetnsamples=48000,
         astats=metadata=1:reset=0,
         ametadata=print:key=lavfi.astats.Overall.RMS_level" \
    -f null - 2>&1 |
    grep -oE '\-?[0-9]+(\.[0-9]+)?' |
    tail -1 || echo "-999"
}

echo "Calcolando RMS..."
FC_RMS="$(rms "$FC_WAV")"
SUR_RMS="$(rms "$SUR_WAV")"

[[ "$FC_RMS" == "-999" || "$SUR_RMS" == "-999" ]] && {
  echo "[ERROR] RMS non calcolabile"
  exit 1
}

DIFF="$(echo "$SUR_RMS - $FC_RMS" | bc -l)"
FC_RMS_FMT="$(awk -v v="$FC_RMS" 'BEGIN{gsub(",",".",v); printf "%.2f", v}')"
SUR_RMS_FMT="$(awk -v v="$SUR_RMS" 'BEGIN{gsub(",",".",v); printf "%.2f", v}')"
DIFF_FMT="$(awk -v v="$DIFF"    'BEGIN{gsub(",",".",v); printf "%.2f", v}')"

# ────────────────────────────────────────────────────────────
# Decision logic + motivazioni livello 3
# ────────────────────────────────────────────────────────────
PROFILE=""
DESCRIPTION=""
RATIONALE=""

if (( $(echo "$DIFF < -10" | bc -l) )); then
  PROFILE="sonar"
  DESCRIPTION="Illusione verticale 5.1.2 - Massima energia"
  RATIONALE=$(cat <<EOF
  L’energia dei surround è nettamente inferiore alla voce (Δ=$DIFF_FMT dB).
  La spazialità originale risulta insufficiente o schiacciata.
  SONAR ricostruisce profondità e altezza per compensare la
  mancanza di informazione ambientale nel mix (full 5.1.2 virtual).
EOF
)

elif (( $(echo "$DIFF < -5" | bc -l) )); then
  PROFILE="wide"
  DESCRIPTION="Illusione orizzontale 7.1"
  RATIONALE=$(cat <<EOF
  I surround risultano significativamente più deboli della voce (Δ=$DIFF_FMT dB).
  L’ambienza è presente ma non sufficiente a sostenere la scena.
  WIDE amplia la spazialità orizzontale senza introdurre
  componenti verticali o energia eccessiva (full 7.1 virtual).
EOF
)

elif (( $(echo "$DIFF < -2" | bc -l) )); then
  PROFILE="aegis"
  DESCRIPTION="Cupola coerente - energia intermedia"
  RATIONALE=$(cat <<EOF
  I surround sono presenti ma leggermente sottodimensionati (Δ=$DIFF_FMT dB).
  La scena è coerente ma manca di continuità spaziale.
  AEGIS rinforza l’ambienza in modo uniforme, senza alterare 
  l’equilibrio timbrico del mix audio (half 5.1.2 virtual).
EOF
)

elif (( $(echo "$DIFF < 2" | bc -l) )); then
  PROFILE="aura"
  DESCRIPTION="Wide Light - intervento soft"
  RATIONALE=$(cat <<EOF
  FC e surround mostrano energia equivalente (Δ=$DIFF_FMT dB).
  Il mix presenta già una spazialità coerente e stabile.
  AURA preserva l’equilibrio esistente, evitando over-processing 
  e introduzione di energia artificiale (half 7.1 virtual).
EOF
)

else
  PROFILE="voice"
  DESCRIPTION="Solo EQ Voce - passthrough surround"
  RATIONALE=$(cat <<EOF
  I surround risultano già dominanti rispetto alla voce (Δ=$DIFF_FMT dB).
  Qualsiasi ulteriore elaborazione spaziale sarebbe ridondante.
  VOICE interviene esclusivamente sull'intelleggibilità del parlato,
  lasciando intatta la scena originale (safe 5.1).
EOF
)
fi

# ────────────────────────────────────────────────────────────
# Output
# ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "                    ANALISI AUDIO SURROUND                      "
echo "════════════════════════════════════════════════════════════════"
echo ""
printf "  FC RMS (voce)     : %s dB\n" "$FC_RMS_FMT"
printf "  SUR RMS (ambiente): %s dB\n" "$SUR_RMS_FMT"
printf "  Δ (SUR - FC)      : %s dB\n\n" "$DIFF_FMT"

echo "────────────────────────────────────────────────────────────────"
printf "  PRESET CONSIGLIATO: %s\n" "${PROFILE^^}"
echo "────────────────────────────────────────────────────────────────"
echo ""
echo "  $DESCRIPTION"
echo ""
echo "  Motivazione:"
echo "$RATIONALE"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Per applicare:"
echo "./aegis_sonar_wide_aura_voice.sh eac3 no \"$IN\" 768k $PROFILE"
echo ""
