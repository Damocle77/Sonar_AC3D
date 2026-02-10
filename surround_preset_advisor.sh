#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────────────────────────────────────────────
# surround_preset_advisor.sh
# - One-shot: lanci e basta.
# - Preset consigliato calcolato Δ RMS (SUR - FC) banda 160–7000 Hz.
# - Output: preset consigliato + consigli "intelligenti".
# - Compatibile MSYS2/MinGW.
# ────────────────────────────────────────────────────────────────────

IN=""
AIDX="0"

# Banda analisi FISSA (aderente al bass management crossover ~140–160 Hz)
HP_HZ="160"
LP_HZ="7000"

usage() {
  cat <<USAGE
Uso:
  $0 "file.mkv" [audio_index]
  $0 --input "file.mkv" [--aidx 0]

Esempi:
  $0 "DUNE - Parte 2 1080p.mkv"
  $0 "DUNE - Parte 2 1080p.mkv" 0
USAGE
}

# parsing flessibile: compatibile con chiamata posizionale
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input) IN="$2"; shift 2 ;;
    -a|--aidx|--audio) AIDX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      # fallback posizionale: primo arg = input, secondo numerico = aidx
      if [[ -z "$IN" ]]; then
        IN="$1"; shift
      elif [[ "$AIDX" == "0" && "$1" =~ ^[0-9]+$ ]]; then
        AIDX="$1"; shift
      else
        shift
      fi
      ;;
  esac
done

[[ -z "$IN" ]] && { usage; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ────────────────────────────────────────────────────────────────────
# Helpers MSYS2 / POSIX
# ────────────────────────────────────────────────────────────────────
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

# ────────────────────────────────────────────────────────────────────
# Layout detect + mapping deterministico → 5.1(side)
# ────────────────────────────────────────────────────────────────────
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
  "unknown"|"")
    echo "[WARN] Layout audio '<vuoto/unknown>'. Uso il layout deciso dal decoder FFmpeg."
    MAP_TO_SIDE="anull"
    ;;
  *)
    echo "[ERROR] Layout audio non supportato: '$LAYOUT'"
    exit 1
    ;;
esac

# ────────────────────────────────────────────────────────────────────
# Estrazione FC / SUR (banda rilevante)
# ────────────────────────────────────────────────────────────────────
echo "Estraendo canali FC e SUR..."
ffmpeg -hide_banner -loglevel error -y -i "$IN_NATIVE" \
  -filter_complex "
    [0:a:$AIDX]$MAP_TO_SIDE,
      channelsplit=channel_layout=5.1(side)[FL][FR][FC][LFE][SL][SR];

    [FL]anullsink;
    [FR]anullsink;
    [LFE]anullsink;

    [FC]highpass=f=${HP_HZ},lowpass=f=${LP_HZ}[fc];

    [SL][SR]amerge=2,
      pan=mono|c0=0.5*c0+0.5*c1,
      highpass=f=${HP_HZ},lowpass=f=${LP_HZ}[sur]
  " \
  -map "[fc]"  -ac 1 "$FC_WAV_NATIVE" \
  -map "[sur]" -ac 1 "$SUR_WAV_NATIVE"

# ────────────────────────────────────────────────────────────────────
# RMS via metadata (robusto su MSYS2)
# ────────────────────────────────────────────────────────────────────
rms_once() {
  local wav="$1"
  local wav_native
  wav_native="$(to_native "$wav")"

  ffmpeg -hide_banner -nostats -nostdin -i "$wav_native" \
    -af "asetnsamples=48000,
         astats=metadata=1:reset=0,
         ametadata=print:key=lavfi.astats.Overall.RMS_level" \
    -f null - 2>&1 |
    awk -F'=' '
      /lavfi\.astats\.Overall\.RMS_level=/{
        gsub(/\r/,"",$2);
        if ($2 ~ /^-?[0-9]+(\.[0-9]+)?$/) last=$2;
      }
      END{
        if (last != "") print last;
        else print "-999";
      }' || echo "-999"
}

rms() {
  local v
  v="$(rms_once "$1")"
  if [[ "$v" == "-999" ]]; then
    # raro su Windows/MSYS2: un micro-retry evita il "rilancia e riprova" manuale
    sleep 0.2
    v="$(rms_once "$1")"
  fi
  printf "%s" "$v"
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

MEAN="$(echo "($SUR_RMS + $FC_RMS)/2" | bc -l)"

# Classificazione grezza della "densità" (consigli contestuali)
# - DENSE: mix già pieno nel midrange → SONAR può impastare.
# - SPARSE: mix scarico → SONAR di solito è più "sicuro".
DENSE="0"
SPARSE="0"
if (( $(echo "$MEAN > -28" | bc -l) )); then
  DENSE="1"
elif (( $(echo "$MEAN < -33" | bc -l) )); then
  SPARSE="1"
fi

# ────────────────────────────────────────────────────────────────────
# Decision logic (focus: intelligibilità + coerenza)
# ────────────────────────────────────────────────────────────────────
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

# ────────────────────────────────────────────────────────────────────
# Consigli rapidi
# ────────────────────────────────────────────────────────────────────
TIPS=()
NOTE=""
GOLD=$'Se la voce arretra, scala di uno step:\nSONAR → AEGIS → WIDE → AURA → VOICE.'

# Word-wrap leggero per note/avvisi (output più leggibile a terminale)
# wrap_print <indent> <width> <text>
wrap_print() {
  local indent="$1"; shift
  local width="$1"; shift
  local text="$*"
  printf "%s" "$text" | fold -s -w "$width" | sed "s/^/${indent}/"
}

case "$PROFILE" in
  sonar)
    TIPS+=("Se senti impasto o dialoghi indietro: AEGIS")
    TIPS+=("Se vuoi meno processing: WIDE")
    ;;
  wide)
    TIPS+=("Upgrade sicuro (più cupola con voce stabile): AEGIS")
    TIPS+=("Upgrade spinto (più verticalità, ma rischio): SONAR")
    TIPS+=("Downgrade (extended 5.1 con massima prudenza): AURA")
    if [[ "$DENSE" == "1" ]]; then
      NOTE="Mix denso: SONAR può far arretrare i dialoghi. Puoi test AEGIS per altezza."
    elif [[ "$SPARSE" == "1" ]]; then
      NOTE="Mix relativamente scarico: SONAR dà immersione con meno rischio di impasto."
    fi
    ;;
  aegis)
    TIPS+=("Più verticalità (spinta): SONAR")
    TIPS+=("Più orizzontale / meno campo diffuso: WIDE")
    TIPS+=("Più conservativo: AURA")
    if [[ "$DENSE" == "1" ]]; then
      NOTE="Mix denso: se provi SONAR ascolta i dialoghi; se arretrano, torna ad AEGIS."
    fi
    ;;
  aura)
    TIPS+=("Più scena (orizzontale): WIDE")
    TIPS+=("Più cupola (soft): AEGIS")
    TIPS+=("Solo intelligibilità voce: VOICE")
    if [[ "$DENSE" == "1" ]]; then
      NOTE="Mix bilanciato e denso: evitare SONAR di solito preserva meglio la coerenza."
    fi
    ;;
  voice)
    TIPS+=("Più scena (soft, a basso rischio): AURA")
    TIPS+=("Più scena (orizzontale): WIDE")
    ;;
esac

# ────────────────────────────────────────────────────────────
# Output
# ────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════════════════"
echo "                          ANALISI AUDIO SURROUND                              "
echo "══════════════════════════════════════════════════════════════════════════════"
echo ""
printf "  FC RMS (voce)     : %s dB\n" "$FC_RMS_FMT"
printf "  SUR RMS (ambiente): %s dB\n" "$SUR_RMS_FMT"
printf "  Δ (SUR - FC)      : %s dB\n\n" "$DIFF_FMT"

echo "──────────────────────────────────────────────────────────────────────────────"
printf "  PRESET CONSIGLIATO: %s\n" "${PROFILE^^}"
echo "──────────────────────────────────────────────────────────────────────────────"
echo ""
echo "  $DESCRIPTION"
echo ""
echo "  Motivazione:"
echo "  $RATIONALE"
echo ""
echo "══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Note analisi:"
printf "  • Metodo: Δ RMS bandpass (%s–%s Hz)\n" "$HP_HZ" "$LP_HZ"
echo ""

if (( ${#TIPS[@]} > 0 )); then
  echo "  Consigli rapidi (facoltativi):"
  for tip in "${TIPS[@]}"; do
    echo "    • $tip"
  done
  if [[ -n "$NOTE" ]]; then
    echo ""
    echo "  Nota:"
    wrap_print "    " 110 "$NOTE"
  fi
  echo ""
  echo "  Regola d'oro:"
  # Indenta *tutte* le righe del GOLD, rispettando i \n che abbiamo messo
  # e wrappa ogni riga separatamente.
  while IFS= read -r line; do
    wrap_print "    " 72 "$line"
  done <<< "$GOLD"
  echo ""
fi

echo ""
echo "  Per applicare:"
echo "./aegis_sonar_wide_aura_voice.sh eac3 no \"$IN\" 768k $PROFILE"
echo "──────────────────────────────────────────────────────────────────────────────"
echo ""
