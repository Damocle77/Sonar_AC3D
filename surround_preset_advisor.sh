#!/usr/bin/env bash
set -euo pipefail

IN="${1:-}"
AIDX="${2:-0}"

[[ -z "$IN" ]] && { echo "Uso: $0 <file.mkv> [audio_index]"; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ────────────────────────────────────────────────────────────
# Helpers: path conversion (MSYS2/MINGW) + normal POSIX
# ────────────────────────────────────────────────────────────
is_msys() {
  uname | tr '[:upper:]' '[:lower:]' | grep -Eq 'mingw|msys|cygwin'
}

to_native() {
  # Converti /g/... e /tmp/... in C:/... quando siamo in MSYS/MINGW
  if is_msys && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"   # C:/... (slash forward)
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
# 1) Estrazione FC e SUR (media SL+SR) in banda "voce/spazio"
# ────────────────────────────────────────────────────────────
echo "Estraendo canali FC e SUR..."
ffmpeg -hide_banner -loglevel error -y -i "$IN_NATIVE" \
  -filter_complex "
    [0:a:$AIDX]aformat=channel_layouts=5.1,
      channelsplit=channel_layout=5.1[FL][FR][FC][LFE][SL][SR];

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

# Sanity check
[[ -s "$FC_WAV" ]] || { echo "[ERROR] Non ho creato FC wav: $FC_WAV"; exit 1; }
[[ -s "$SUR_WAV" ]] || { echo "[ERROR] Non ho creato SUR wav: $SUR_WAV"; exit 1; }

# ────────────────────────────────────────────────────────────
# 2) RMS medio (astats → parsing log) + fallback volumedetect
# ────────────────────────────────────────────────────────────
rms() {
  local wav="$1"
  local wav_native
  local tmplog
  wav_native="$(to_native "$wav")"
  tmplog="$tmpdir/rms_$(basename "$wav").log"

  # astats (log su file, così non impazzisce MSYS2 con pipe/encoding)
  ffmpeg -hide_banner -nostats -i "$wav_native" \
    -af "astats=reset=0" \
    -f null - >"$tmplog" 2>&1

  # Pattern comuni: "Overall RMS level" oppure "RMS level dB"
  local rms_value=""
  rms_value=$(
    grep -iE "(Overall RMS level|RMS level dB)" "$tmplog" | \
      grep -oE '\-?[0-9]+\.[0-9]+' | \
      head -1 || true
  )

  if [[ -n "$rms_value" ]]; then
    echo "$rms_value"
    return 0
  fi

  # fallback: mean_volume (non è RMS puro, ma meglio di niente)
  ffmpeg -hide_banner -nostats -i "$wav_native" \
    -af "volumedetect" \
    -f null - >"${tmplog}.vol" 2>&1

  rms_value=$(
    grep -E "mean_volume:" "${tmplog}.vol" | \
      grep -oE '\-?[0-9]+\.[0-9]+' | \
      head -1 || true
  )

  if [[ -n "$rms_value" ]]; then
    echo "$rms_value"
    return 0
  fi

  echo "[DEBUG] Contenuto log astats:" >&2
  cat "$tmplog" >&2
  echo "[DEBUG] Contenuto log volumedetect:" >&2
  cat "${tmplog}.vol" >&2
  echo "-999"
}

echo "Calcolando RMS..."
FC_RMS="$(rms "$FC_WAV")"
SUR_RMS="$(rms "$SUR_WAV")"

if [[ "$FC_RMS" == "-999" ]] || [[ "$SUR_RMS" == "-999" ]]; then
  echo ""
  echo "[ERROR] Impossibile calcolare RMS. Verifica l'output sopra."
  echo "Possibili cause:"
  echo "  - L'audio index $AIDX non esiste / non è 5.1"
  echo "  - Build ffmpeg/ffprobe incoerenti (MSYS2 vs Windows)"
  echo ""
  echo "Prova:"
  echo "  ffprobe -v error -select_streams a -show_entries stream=index,codec_name,channels,channel_layout -of table \"$IN\""
  exit 1
fi

FC_RMS_FMT="$(LC_NUMERIC=C printf "%.2f" "$FC_RMS")"
SUR_RMS_FMT="$(LC_NUMERIC=C printf "%.2f" "$SUR_RMS")"

DIFF="$(echo "$SUR_RMS - $FC_RMS" | bc -l)"
DIFF_FMT="$(LC_NUMERIC=C printf "%.2f" "$DIFF")"

# ────────────────────────────────────────────────────────────
# 3) Decisione preset (calibrata sui tuoi gain/layer)
# ────────────────────────────────────────────────────────────
# Energia effettiva percepita (layer+pesi+gain):
# VOICE: 1.08x < AURA: 1.37x < WIDE: 1.97x < AEGIS: 2.18x < SONAR: 3.69x

PROFILE=""
DESCRIPTION=""
RATIONALE=""
ALT_CHOICE=""

if (( $(echo "$DIFF < -10" | bc -l) )); then
  PROFILE="sonar"
  DESCRIPTION="Illusione verticale 5.1.2 - Massima energia e altezza psicoacustica"

  RATIONALE=$(cat <<EOF
I surround sono quasi inesistenti (Δ=$DIFF_FMT dB).

SONAR, con energia ~3.69x e 4 layer aggressivi, ricostruisce completamente lo spazio
e spinge forte l'illusione di altezza (tipo “5.1.2 mentale”).

È perfetto per un mix voice-centrico che ha bisogno di surround artificiali potenti.
EOF
)

  ALT_CHOICE=$(cat <<EOF
WIDE (~1.97x) se preferisci ampiezza orizzontale invece dell'altezza (meno energia),
oppure AEGIS (~2.18x) per un compromesso più controllato.
EOF
)

elif (( $(echo "$DIFF < -5" | bc -l) )); then
  PROFILE="wide"
  DESCRIPTION="Illusione orizzontale 7.1 - Boost alto con ampiezza laterale"

  RATIONALE=$(cat <<EOF
I surround sono poco presenti (Δ=$DIFF_FMT dB).

WIDE, con energia effettiva ~1.97x e 3 layer, apre la scena in orizzontale:
movimento laterale, impatto, sensazione “larga” (perfetto per action/sport/concerti).
EOF
)

  ALT_CHOICE=$(cat <<EOF
AEGIS (~2.18x) se vuoi più energia con 4 layer (ma più controllata),
oppure SONAR (~3.69x) se vuoi massimo boost e “altezza”.
EOF
)

elif (( $(echo "$DIFF < -2" | bc -l) )); then
  PROFILE="aegis"
  DESCRIPTION="Intermedia - 4 layer bilanciati con energia controllata"

  RATIONALE=$(cat <<EOF
I surround sono poco presenti (Δ=$DIFF_FMT dB).

AEGIS (~2.18x) usa 4 layer con gain moderato: rinforza lo spazio senza diventare invadente.
È un compromesso solido per film moderni quando vuoi “più cupola” ma con controllo.
EOF
)

  ALT_CHOICE=$(cat <<EOF
WIDE (~1.97x) se preferisci meno energia ma più ampiezza,
oppure SONAR (~3.69x) se vuoi spingere davvero.
EOF
)

elif (( $(echo "$DIFF < 1" | bc -l) )); then
  PROFILE="aura"
  DESCRIPTION="Wide Light - Boost minimo con decorrelazione soft"

  RATIONALE=$(cat <<EOF
I surround sono limitati ma presenti (Δ=$DIFF_FMT dB).

AURA (~1.37x) aggiunge un “respiro” laterale soft senza stravolgere il mix.
Ottimo per drama, dialoghi, e contenuti dove vuoi spazio ma zero tamarrate.
EOF
)

  ALT_CHOICE=$(cat <<EOF
AEGIS (~2.18x) se vuoi più energia con 4 layer,
oppure WIDE (~1.97x) se vuoi più ampiezza.
EOF
)

elif (( $(echo "$DIFF < 4" | bc -l) )); then
  PROFILE="sonar"
  DESCRIPTION="Illusione verticale 5.1.2 - Altezza psicoacustica su mix già buono"

  RATIONALE=$(cat <<EOF
Mix già ben bilanciato (Δ=$DIFF_FMT dB).

SONAR (~3.69x) sfrutta i surround esistenti per creare l'illusione di canali height.
È la scelta “sci-fi/fantasy”: quando vuoi verticalità e scena alta.
EOF
)

  ALT_CHOICE=$(cat <<EOF
AURA (~1.37x) per approccio conservativo,
oppure VOICE (1.08x) se il mix originale è già perfetto.
EOF
)

else
  PROFILE="voice"
  DESCRIPTION="Minimo boost (1.08x) - Solo EQ Voce Sartoriale su FC"

  RATIONALE=$(cat <<EOF
I surround sono già forti e ben presenti (Δ=$DIFF_FMT dB).

Il mix originale è ottimo: non serve pompare spazio, basta migliorare intelligibilità e presenza.
VOICE applica soprattutto EQ sartoriale al canale centrale.
EOF
)

  ALT_CHOICE=$(cat <<EOF
AURA (~1.37x) se vuoi comunque un filo di decorrelazione laterale soft.
EOF
)
fi

# ────────────────────────────────────────────────────────────
# 4) Output finale (con a-capo reali)
# ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "                    ANALISI AUDIO SURROUND                      "
echo "════════════════════════════════════════════════════════════════"
echo ""
printf "  FC RMS (voce)     : %s dB\n" "$FC_RMS_FMT"
printf "  SUR RMS (ambiente): %s dB\n" "$SUR_RMS_FMT"
printf "  Δ (SUR - FC)      : %s dB\n" "$DIFF_FMT"
echo ""
echo "────────────────────────────────────────────────────────────────"
printf "  PRESET CONSIGLIATO: %s\n" "${PROFILE^^}"
echo "────────────────────────────────────────────────────────────────"
echo ""
printf "  %s\n\n" "$DESCRIPTION"
echo "  Motivazione:"
# indent manuale: prefisso due spazi + due in più per testo
# (sed aggiunge "  " davanti a ogni riga)
printf "%s\n\n" "$RATIONALE" | sed 's/^/  /'
if [[ -n "$ALT_CHOICE" ]]; then
  echo "  Alternativa:"
  printf "%s\n\n" "$ALT_CHOICE" | sed 's/^/  /'
fi

echo "════════════════════════════════════════════════════════════════"
echo ""
echo "ENERGIA SURROUND EFFETTIVA (layer + pesi + gain):"
echo "  • VOICE : 1.08x (minimo boost)"
echo "  • AURA  : 1.37x (2 layer soft)"
echo "  • WIDE  : 1.97x (3 layer ampiezza)"
echo "  • AEGIS : 2.18x (4 layer, gain 0.95)"
echo "  • SONAR : 3.69x (4 layer altezza, gain 1.35)"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Per applicare il preset consigliato:"
echo "  ./aegis_sonar_wide_aura_voice.sh eac3 no \"$IN\" 768k $PROFILE"
echo ""
echo "════════════════════════════════════════════════════════════════"
