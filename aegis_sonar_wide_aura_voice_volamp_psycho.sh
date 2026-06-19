#!/usr/bin/env bash
# set -e rimosso: causa exit imprevedibili su pattern && / || e aritmetica bash.
# La gestione errori è esplicita nei punti critici (|| continue, || true, etc.)
set -uo pipefail

# ╭──────────────────────────────────────────────────────────────────────────────────╮
# │   aegis_sonar_wide_aura_voice_volamp_psycho.sh - Giugno 2026                     │
# │   By Sandro (D@mocle77) Sabbioni                                                 │
# │                                                                                  │
# │   Motore di processing audio offline per tracce 5.1 (EAC3/AC3).                  │
# │   Corregge dinamicamente mix sbilanciati tramite preset psicoacustici,           │
# │   migliorando l'intelligibilità dei dialoghi e ripristinando la bolla            │
# │   surround (Aegis, Sonar, Wide, Aura), con controllo mirato dei picchi LFE.      │
# │                                                                                  │
# │   - DSP ottimizzato per satelliti compatti, crossover 110-120 Hz (tutti Small)   │
# │   - Voce: compressore dinamico FC per intelligibilità a basso volume             │
# │   - Surround psicoacustici controllati                                           │
# │   - LFE: lowpass 120 Hz + compressore picchi + limiter di sicurezza              │
# │   - Pipeline leggibile: input -> split -> voice -> surround -> output            │
# ╰──────────────────────────────────────────────────────────────────────────────────╯

# Color codes per log: info, warning, error, ok. Usati per distinguere i livelli di messaggio in console.
C_INFO="\033[0;36m[INFO]\033[0m"
C_WARN="\033[0;33m[WARNING]\033[0m"
C_ERR="\033[0;31m[ERROR]\033[0m"
C_OK="\033[0;32m[OK]\033[0m"

# Funzioni di log: info, warn, err, ok. Usano colori per distinguere i livelli di messaggio.
info(){ echo -e "${C_INFO} $*"; }
warn(){ echo -e "${C_WARN} $*"; }
err(){  echo -e "${C_ERR}  $*"; }
ok(){   echo -e "${C_OK}  $*"; }

# ── DECORR_GAIN: "aria" di ri-espansione del foldown Atmos->5.1, per preset. ──
# Curva MONOTONA col grado di collasso dei surround: piu' il foldown e' schiacciato
# (Delta molto negativo) piu' ri-espansione serve. Modifica qui per il tuning fine.
#   SONAR (collasso max) > AURA > WIDE > AEGIS (surround gia' pieni) > VOICE (off).
DECORR_GAIN_SONAR="0.055"
DECORR_GAIN_AURA="0.048"
DECORR_GAIN_WIDE="0.042"
DECORR_GAIN_AEGIS="0.034"
DECORR_GAIN_VOICE="0"

# ── FRONT_EQ: rifinitura dei frontali (FL/FR), condivisa da tutti i preset. ──
# Obiettivo: piu' presenza/dettaglio senza rubare scena al centrale. Filosofia
# principalmente sottrattiva, tarata per satelliti compatti (driver di piccolo diametro).
#   -0.8 dB @ 320 Hz  -> toglie impasto/congestione low-mid (piu' articolato)
#   +0.6 dB @ 5000 Hz -> presenza/incisivita' SOPRA la banda dialoghi (1-4 kHz)
#   +1.2 dB shelf 11k -> aria e dettaglio in alto (dove i satelliti calano)
# Per disattivarla: FRONT_EQ="anull". Per tarare, modifica solo questa riga.
FRONT_EQ="equalizer=f=320:t=q:w=1.1:g=-0.8,equalizer=f=5000:t=q:w=1.4:g=0.6,highshelf=f=11000:t=q:w=0.7:g=0.7"

# Controllo dipendenze: ffmpeg e ffprobe sono essenziali per il funzionamento dello script. Se non sono nel PATH, esco con errore.
for _bin in ffmpeg ffprobe; do
  command -v "$_bin" &>/dev/null || { err "$_bin non trovato nel PATH"; exit 1; }
done

usage() {
  cat <<'USAGE'
---------------------------------------------------------------------------------------------------------
UTILIZZO:
  ./aegis_sonar_wide_aura_voice_volamp_psycho.sh <ac3|eac3> <si|no> [file] [bitrate] [preset] [volamp]

PARAMETRI:
  ac3|eac3  : Codec audio in uscita.
  si|no     : Conserva file audio originale.
  file      : File input singolo. Se omesso, processa tutti file compatibili nella cartella.
  bitrate   : Es. 640k o 768k (default: 640k per AC3, 768k per EAC3).
  preset    : aegis | sonar | wide | aura | voice (default: sonar).
  volamp    : Gain finale opzionale in dB prima del limiter.
              Valori consentiti: 0, da 0.1 a 2.5.
              Esempi pratici: 0 | 1.5 | 2 | 2.5

PRESET DISPONIBILI:
  aegis     -> Simula NEURAL:X (DTS:X)  | Cupola Sonora
  sonar     -> Simula ATMOS (5.1.2)     | Boost Verticale
  wide      -> Simula Dolby 7.1         | Allargamento Laterale
  aura      -> Simula Dolby 6.1         | Allargamento Posteriore
  voice     -> Esalta i dialoghi (FC)   | EQ Sartoriale Voce
---------------------------------------------------------------------------------------------------------
USAGE
  exit 1
}

# Controllo se un token è un preset valido: deve essere uno dei nomi riconosciuti (aegis, sonar, wide, aura, voice).
is_preset_name() {
  case "$1" in
    aegis|sonar|wide|aura|voice) return 0 ;;
    *) return 1 ;;
  esac
}
# Controllo se un token è un bitrate valido: deve essere un numero con optional k/M, es. 640k, 768k, 1M, 1.5M, etc.
is_bitrate_token() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?([kKmM])?$ ]]
}

# Controllo argomenti: almeno codec e keep_orig sono obbligatori. Il resto è opzionale e flessibile.
[[ $# -lt 2 ]] && usage

# Parsing argomenti obbligatori: codec di output e flag per conservare l'originale. Il resto dei parametri è opzionale e può essere in qualsiasi ordine.
OUT_CODEC="${1:-}"
KEEP_ORIG="${2:-}"
shift 2

# Parsing flessibile dei parametri: file, bitrate, preset, volamp possono essere in qualsiasi ordine. In base al formato (bitrate, preset name, volamp) o alla posizione (file).
INPUT_FILE=""
BITRATE=""
SUR_MODE=""
VOLAMP_DB="0"
POSITIONAL=("$@")

# Ultimo parametro opzionale = volamp (0 .. 2.5 dB)
if (( ${#POSITIONAL[@]} > 0 )); then
  LAST_IDX=$((${#POSITIONAL[@]} - 1))
  LAST_ARG="${POSITIONAL[$LAST_IDX]}"
  LAST_ARG="${LAST_ARG/,/.}"

  # Controllo se è un numero valido e nel range consentito
  if [[ "$LAST_ARG" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk -v v="$LAST_ARG" 'BEGIN { exit !(v >= 0 && v <= 2.5) }'; then
      VOLAMP_DB="$LAST_ARG"
      unset 'POSITIONAL[$LAST_IDX]'
      POSITIONAL=("${POSITIONAL[@]}")
    else
      err "volamp fuori range: '$LAST_ARG' (consentito: 0 .. 2.5 dB)"
      exit 1
    fi
  fi
fi

# Parsing flessibile dei rimanenti parametri
for arg in "${POSITIONAL[@]}"; do
  if [[ -z "$BITRATE" ]] && is_bitrate_token "$arg"; then
    BITRATE="$arg"
  elif [[ -z "$SUR_MODE" ]] && is_preset_name "$arg"; then
    SUR_MODE="$arg"
  elif [[ -z "$INPUT_FILE" ]]; then
    INPUT_FILE="$arg"
  else
    err "Troppi argomenti o ordine non valido: '$arg'"
    usage
  fi
done

# Se il preset non è stato specificato, uso il default sonar. Se è stato specificato, deve essere uno dei nomi validi (controllo fatto più avanti).
SUR_MODE="${SUR_MODE:-sonar}"

# Controllo preset: deve essere uno dei nomi validi.
case "$SUR_MODE" in
  aegis|sonar|wide|aura|voice) ;;
  *) err "Preset '$SUR_MODE' non riconosciuto. Validi: aegis, sonar, wide, aura, voice."; exit 1 ;;
esac
# Controllo bitrate opzionale: se specificato, deve essere un numero con optional k/M.
case "$OUT_CODEC" in ac3|eac3) ;; *) err "Codec deve essere ac3 o eac3"; exit 1 ;; esac
[[ "$KEEP_ORIG" =~ ^(si|no)$ ]] || { err "Parametro 2: si|no"; exit 1; }

# Se il bitrate è specificato, deve essere un numero con optional k/M. Se non specificato, default 640k per AC3 e 768k per EAC3.
[[ -z "$BITRATE" ]] && {
  [[ "$OUT_CODEC" = "ac3" ]] && BITRATE="640k" || BITRATE="768k"
}
[[ "$BITRATE" =~ [kKmM]$ ]] || BITRATE="${BITRATE}k"

# Controllo volamp opzionale: se specificato, deve essere un numero da 0 a 2.5 (con optional decimale).
case "$VOLAMP_DB" in
  0|0.0|0.00|0.000)
    FINAL_GAIN_FILTER=""
    VOLAMP_LABEL="OFF"
    ;;
  *)
    FINAL_GAIN_FILTER="volume=${VOLAMP_DB}dB,"
    VOLAMP_LABEL="+${VOLAMP_DB} dB"
    ;;
esac

# Resampling finale HQ con SoX Resampler / SOXR. Precisione 28 bit, cutoff conservativo.
ARESAMPLE_192K="aresample=192000:resampler=soxr:precision=28:cutoff=0.97"
ARESAMPLE_48K="aresample=48000:resampler=soxr:precision=28:cutoff=0.97"

# Descrizioni preset per log: non sono parte del processing, ma aiutano a capire cosa fa ogni preset senza dover leggere il codice.
case "$SUR_MODE" in
  aegis) DESC="Simula NEURAL:X (DTS:X) | Cupola Sonora" ;;
  sonar) DESC="Simula ATMOS (5.1.2) | Boost Verticale" ;;
  wide)  DESC="Simula Dolby 7.1 | Allargamento Laterale" ;;
  aura)  DESC="Simula Dolby 6.1 | Allargamento Posteriore" ;;
  voice) DESC="Esalta la voce   | EQ Sartoriale Voce" ;;
esac

# Log dei parametri finali: utile per confermare cosa è stato interpretato dallo script, soprattutto con parsing flessibile.
info "Codec output:   $OUT_CODEC"
info "Surround mode:  $SUR_MODE ($DESC)"
info "Bitrate Target: $BITRATE"
info "Final volamp:   $VOLAMP_LABEL"

# Funzione per identificare la traccia audio migliore da processare, con preferenza per 5.1, default, italiano.
probe_audio_stream() {
  local f="$1" line
  local _lines
  mapfile -t _lines < <(ffprobe -v error -select_streams a \
    -show_entries stream=index,channels,channel_layout:stream_disposition=default:stream_tags=language \
    -of csv=p=0 "$f" 2>/dev/null || true)

  [[ ${#_lines[@]} -gt 0 ]] || return 1

  # Scoring semplice: +1000 per 5.1, +200 se default, +300 se italiano. Il resto è secondario.
  local best_line="" best_score=-1
  for line in "${_lines[@]}"; do
    [[ -z "$line" ]] && continue
    local idx ch layout def lang
    IFS=',' read -r idx ch layout def lang <<<"$line"
    ch="${ch:-0}"
    def="${def:-0}"
    lang="${lang:-}"
    layout="${layout:-}"

    # Scoring: preferisco 5.1, poi default, poi italiano. Se più tracce hanno lo stesso punteggio, scelgo la prima (di solito è la migliore).
    local score=0
    [[ "$ch" =~ ^[0-9]+$ && "$ch" -eq 6 ]] && score=$((score+1000))
    [[ "$def" == "1" ]] && score=$((score+200))
    [[ "${lang,,}" =~ ^it ]] && score=$((score+300))

    # Se questo stream ha un punteggio migliore del migliore finora, lo salvo come best_line. In caso di parità, mantengo il primo trovato (di solito è il migliore).
    if (( score > best_score )); then
      best_score=$score
      best_line="$line"
    fi
  done
  # Se non ho trovato tracce valide, esco con errore. Altrimenti, best_line contiene la traccia migliore da processare.
  [[ -n "$best_line" ]] || return 1

  # Estraggo i campi della traccia migliore, con fallback per evitare campi vuoti.
  local o_idx o_ch o_layout o_def o_lang
  IFS=',' read -r o_idx o_ch o_layout o_def o_lang <<<"$best_line"
  echo "${o_idx}|${o_ch:-0}|${o_layout:-}|${o_def:-0}|${o_lang:-}"
}

# Funzione per ottenere il titolo della traccia audio (se presente), utile per log e debug. Non è critica, quindi errori vengono silenziati.
get_audio_title_by_index() {
  ffprobe -v error -select_streams a \
    -show_entries stream=index:stream_tags=title \
    -of default=nw=1 "$1" 2>/dev/null | awk -v idx="$2" '
    $0=="index="idx{f=1;next} f&&/^TAG:title=/{sub(/^TAG:title=/,"");print;exit} f&&/^index=/{exit}'
}

# Costruisco la lista dei file da processare: se è stato specificato un file, lo uso. Altrimenti, cerco tutti i file compatibili nella cartella.
FILES=()
if [[ -n "$INPUT_FILE" ]]; then
  [[ -f "$INPUT_FILE" ]] || { err "File non esiste"; exit 1; }
  FILES+=("$INPUT_FILE")
else
  shopt -s nullglob
  FILES+=( *.mkv *.MKV *.mp4 *.MP4 *.m2ts *.M2TS *.ac3 *.eac3 )
  shopt -u nullglob
fi
# Controllo se ho trovato file da processare: se la cartella è vuota o non ci sono file compatibili, esco con errore.
(( ${#FILES[@]} == 0 )) && { err "Nessun file trovato."; exit 1; }


# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# BLOCCHI VOCE
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Processing voce: HPF subsonico a 40 Hz (anti-rumble) + EQ parametrico + compressore dinamico.
# Il crossover verso il sub lo gestisce l'AVR (Small, 110 Hz): lo script NON taglia in quella regione
# per evitare il doppio filtro che svuotava i bassi. Calore di petto via bell a 150 Hz (focalizzato),
# con dip anti-inscatolamento a 450 Hz per togliere il "boxy" senza intaccare il corpo della voce.
# Obiettivo: dialoghi più leggibili senza effetto megafono, con controllo statico delle sibilanti.
# Il compressore (threshold=-20dB, ratio=2.5) solleva il parlato debole/sussurrato senza toccare i picchi,
# ottimizzato per ascolto a basso volume e distanze >3 m. Compatibile con dynaudnorm upstream (makeup contenuto).

read -r -d '' VOICE_EQ_BASE <<'EOF' || true
[FC]highpass=f=40:t=q:w=0.707,equalizer=f=150:t=q:w=1.1:g=0.5,equalizer=f=450:t=q:w=1.2:g=-0.6,equalizer=f=1100:t=q:w=1.4:g=0.8,equalizer=f=7200:t=q:w=2.5:g=-0.9,acompressor=threshold=-20dB:ratio=2.5:attack=15:release=200:makeup=1.4[FC_pre];
EOF
read -r -d '' VOICE_DELTA_SONAR <<'EOF' || true
[FC_pre]volume=2.2dB,equalizer=f=1650:t=q:w=1.6:g=0.9,equalizer=f=2450:t=q:w=1.3:g=1.6,equalizer=f=3800:t=q:w=2.0:g=1.0,equalizer=f=6800:t=q:w=2.0:g=-1.0,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_AEGIS <<'EOF' || true
[FC_pre]volume=2.2dB,equalizer=f=1650:t=q:w=1.6:g=0.9,equalizer=f=2450:t=q:w=1.3:g=1.5,equalizer=f=3800:t=q:w=2.0:g=1.0,equalizer=f=6800:t=q:w=2.0:g=-1.0,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_WIDE <<'EOF' || true
[FC_pre]volume=2.3dB,equalizer=f=1650:t=q:w=1.6:g=0.9,equalizer=f=2450:t=q:w=1.3:g=1.6,equalizer=f=3800:t=q:w=2.0:g=1.0,equalizer=f=6800:t=q:w=2.0:g=-0.9,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_AURA <<'EOF' || true
[FC_pre]volume=2.0dB,equalizer=f=1650:t=q:w=1.6:g=0.8,equalizer=f=2450:t=q:w=1.3:g=1.4,equalizer=f=3800:t=q:w=2.0:g=0.9,equalizer=f=6800:t=q:w=2.0:g=-1.0,volume=0.96[FCv];
EOF
read -r -d '' VOICE_DELTA_VOICEONLY <<'EOF' || true
[FC_pre]volume=2.4dB,equalizer=f=1650:t=q:w=1.6:g=1.0,equalizer=f=2450:t=q:w=1.3:g=1.8,equalizer=f=3800:t=q:w=2.0:g=1.1,equalizer=f=5200:t=q:w=2.0:g=-0.5,equalizer=f=6800:t=q:w=2.0:g=-1.1,volume=0.95[FCv];
EOF
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# BLOCCHI SURROUND
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Preset psicoacustici per surround: differenziazione in base alla modalità, con mix di sub-bande filtrate e pesate per creare l'effetto desiderato.

# SONAR: boost verticale con delay differenziati per SL/SR, piu' presenza medio-alta per SL/SR, e un layer di decorrelazione a basso livello per aria.
# Cue di elevazione (P1, prudente): sul layer alto un lieve lift +0.8 dB a 8 kHz (banda di Blauert "above")
# invece del vecchio taglio -3.0 dB. Per tornare al comportamento originale: rimettere g=-3.0 sui due [S?h_in].
read -r -d '' SUR_FILTERS_SONAR <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,highpass=f=40:t=q:w=0.707,volume=0.95[SLd];
[SLp_in]adelay=18,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SLp];
[SLh_in]adelay=32,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=2.5:g=0.8,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SLh];
[SLlate_in]adelay=38,highpass=f=150,lowpass=f=1500,volume=0.58[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1 0.6 0.4 0.2':normalize=0,volume=1.05[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,highpass=f=40:t=q:w=0.707,volume=0.95[SRd];
[SRp_in]adelay=18,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=2.0,equalizer=f=11000:t=q:w=1.0:g=-1.2,volume=1.00[SRp];
[SRh_in]adelay=32,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=2.5:g=0.8,equalizer=f=11000:t=q:w=1.2:g=1.0,volume=0.60[SRh];
[SRlate_in]adelay=41,highpass=f=150,lowpass=f=1500,volume=0.58[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1 0.6 0.4 0.2':normalize=0,volume=1.05[SR_out];
EOF

# AEGIS: cupola sonora con boost più bilanciato e meno artificiale, più presenza medio-alta per SL/SR, e un layer di decorrelazione a basso livello per aria.
read -r -d '' SUR_FILTERS_AEGIS <<'EOF' || true
[SL]asplit=4[SLd_in][SLp_in][SLh_in][SLlate_in];
[SLd_in]adelay=0,highpass=f=40:t=q:w=0.707,volume=0.95[SLd];
[SLp_in]adelay=18,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SLp];
[SLh_in]adelay=32,highpass=f=2500,lowpass=f=14000,allpass=f=900:t=q:w=0.70,allpass=f=2200:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SLh];
[SLlate_in]adelay=39,highpass=f=150,lowpass=f=1300,volume=0.42[SLlate];
[SLd][SLp][SLh][SLlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SL_out];
[SR]asplit=4[SRd_in][SRp_in][SRh_in][SRlate_in];
[SRd_in]adelay=0,highpass=f=40:t=q:w=0.707,volume=0.95[SRd];
[SRp_in]adelay=18,highpass=f=1500,equalizer=f=6500:t=q:w=1.2:g=1.6,equalizer=f=11000:t=q:w=1.0:g=-1.4,volume=0.95[SRp];
[SRh_in]adelay=32,highpass=f=2500,lowpass=f=14000,allpass=f=1050:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,equalizer=f=8000:t=q:w=3.0:g=-4.0,equalizer=f=11000:t=q:w=1.2:g=0.6,volume=0.48[SRh];
[SRlate_in]adelay=42,highpass=f=150,lowpass=f=1300,volume=0.42[SRlate];
[SRd][SRp][SRh][SRlate]amix=inputs=4:weights='1.05 0.80 0.70 0.45':normalize=0,volume=0.95[SR_out];
EOF

# WIDE: allargamento laterale più marcato, con boost più evidente sulle sub-bande filtrate, e un layer di decorrelazione a basso livello per aria.
read -r -d '' SUR_FILTERS_WIDE <<'EOF' || true
[SL]asplit=3[SLd_in][SLe_in][SLx_in];
[SLd_in]adelay=1,highpass=f=40:t=q:w=0.707,volume=1.00[SLd];
[SLe_in]adelay=9,highpass=f=280,lowpass=f=7000,allpass=f=1200:t=q:w=0.65,volume=0.42[SLe];
[SLx_in]adelay=22,highpass=f=600,lowpass=f=5000,allpass=f=700:t=q:w=0.70,allpass=f=2600:t=q:w=0.70,volume=0.17[SLx];
[SLd][SLe][SLx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=250:g=0.5:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.00[SL_out];
[SR]asplit=3[SRd_in][SRe_in][SRx_in];
[SRd_in]adelay=1,highpass=f=40:t=q:w=0.707,volume=1.00[SRd];
[SRe_in]adelay=10,highpass=f=280,lowpass=f=7000,allpass=f=1350:t=q:w=0.65,volume=0.42[SRe];
[SRx_in]adelay=24,highpass=f=600,lowpass=f=5000,allpass=f=820:t=q:w=0.70,allpass=f=2400:t=q:w=0.70,volume=0.17[SRx];
[SRd][SRe][SRx]amix=inputs=3:weights='1.00 0.90 0.80':normalize=0,lowshelf=f=250:g=0.5:t=q:w=0.7,highshelf=f=3500:g=0.1:t=q:w=0.8,volume=1.00[SR_out];
EOF

#AURA: allargamento posteriore più marcato, con boost più evidente sulle sub-bande filtrate, e un layer di decorrelazione a basso livello per aria.
read -r -d '' SUR_FILTERS_AURA <<'EOF' || true
[SL]asplit=2[SLd_in][SLa_in];
[SLd_in]adelay=1,highpass=f=40:t=q:w=0.707,volume=1.00[SLd];
[SLa_in]adelay=8,highpass=f=800,lowpass=f=4500,allpass=f=1400:t=q:w=0.65,volume=0.22[SLa];
[SLd][SLa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=0.95[SL_out];
[SR]asplit=2[SRd_in][SRa_in];
[SRd_in]adelay=1,highpass=f=40:t=q:w=0.707,volume=1.00[SRd];
[SRa_in]adelay=9,highpass=f=800,lowpass=f=4500,allpass=f=1550:t=q:w=0.65,volume=0.22[SRa];
[SRd][SRa]amix=inputs=2:weights='1.00 0.85':normalize=0,volume=0.95[SR_out];
EOF

# VOICE-ONLY: preset rescue per esaltare i dialoghi quando il mix è critico.
# I surround vengono mantenuti, ma leggermente abbassati per dare priorità al centrale.
read -r -d '' SUR_FILTERS_VOICEONLY <<'EOF' || true
[SL]highpass=f=40:t=q:w=0.707,volume=0.88[SL_out];
[SR]highpass=f=40:t=q:w=0.707,volume=0.88[SR_out];
EOF

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# PROFILI PRESET
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# La funzione set_preset_profile imposta le variabili globali per il processing in base al preset scelto. Ogni preset ha un blocco di filtri surround specifico, 
# un blocco di filtri voce specifico, un guadagno di decorrelazione per l'aria, e opzioni del limiter finale.
#
# DECORR_GAIN segue una curva MONOTONA col grado di collasso del foldown Atmos->5.1:
# piu' i surround sono schiacciati (Delta molto negativo) piu' "aria" di ri-espansione serve.
#   SONAR (collasso max) 0.055 > AURA 0.048 > WIDE 0.042 > AEGIS (surround gia' pieni) 0.034 > VOICE 0.
# NB: il n. di layer e i volumi SL/SR restano specifici di ogni preset: sono il "flavor"
# spaziale (verticale/posteriore/laterale), non l'intensita' di ri-espansione.

set_preset_profile() {
  case "$SUR_MODE" in
    sonar)
      SUR_BLOCK="$SUR_FILTERS_SONAR"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_SONAR}"
      DECORR_GAIN="$DECORR_GAIN_SONAR"
      LIMITER_OPTS="limit=0.97:attack=3.5:release=65:level=0"
      MODE_TITLE="Sonar (Atmos Like)"
      ;;
    aegis)
      SUR_BLOCK="$SUR_FILTERS_AEGIS"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AEGIS}"
      DECORR_GAIN="$DECORR_GAIN_AEGIS"
      LIMITER_OPTS="limit=0.98:attack=2.5:release=50:level=0"
      MODE_TITLE="AEGIS (Neural:X Like)"
      ;;
    aura)
      SUR_BLOCK="$SUR_FILTERS_AURA"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_AURA}"
      DECORR_GAIN="$DECORR_GAIN_AURA"
      LIMITER_OPTS="limit=0.975:attack=3.0:release=60:level=0"
      MODE_TITLE="AURA (Dolby 6.1 Like)"
      ;;
    wide)
      SUR_BLOCK="$SUR_FILTERS_WIDE"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_WIDE}"
      DECORR_GAIN="$DECORR_GAIN_WIDE"
      LIMITER_OPTS="limit=0.97:attack=3.5:release=65:level=0"
      MODE_TITLE="Wide (7.1 Like)"
      ;;
    voice)
      SUR_BLOCK="$SUR_FILTERS_VOICEONLY"
      VOICE_BLOCK="${VOICE_EQ_BASE}${VOICE_DELTA_VOICEONLY}"
      DECORR_GAIN="$DECORR_GAIN_VOICE"
      LIMITER_OPTS="limit=0.95:attack=2.0:release=40:level=0"
      MODE_TITLE="VOICE (Dialogue Plus)"
      ;;
    *)
      err "Preset '$SUR_MODE' non riconosciuto."
      exit 1
      ;;
  esac
}

# La funzione build_filter_complex costruisce dinamicamente il filtergraph di ffmpeg in base al preset scelto, concatenando i blocchi di input split, processing voce, processing surround, e output join.
build_input_split_graph() {
  cat <<EOF
[0:${A_STREAM_INDEX}]aformat=sample_rates=48000:sample_fmts=fltp:channel_layouts=${IN_LAYOUT},
pan=5.1(side)|FL=FL|FR=FR|FC=FC|LFE=LFE|SL=${SUR_L_CH}|SR=${SUR_R_CH}[base];
[base]channelsplit=channel_layout=5.1(side)[FL][FR][FC][LFE][SL][SR];
[FL]highpass=f=40:t=q:w=0.707,${FRONT_EQ}[FLp];
[FR]highpass=f=40:t=q:w=0.707,${FRONT_EQ}[FRp];
EOF
}

# Il blocco di processing surround psicoacustico: se DECORR_GAIN è 0, salto completamente la decorrelazione e lascio i canali SL/SR inalterati. Altrimenti applico un layer di decorrelazione per creare aria/lateralità.
build_surround_psycho_graph() {
  if [[ "${DECORR_GAIN:-0}" = "0" ]]; then
    cat <<EOF
[SL_out]anull[SL_final];
[SR_out]anull[SR_final];
EOF
  else
    cat <<EOF
[SL_out]asplit=2[SL_main][SL_air_in];
[SL_air_in]highpass=f=1600,lowpass=f=9500,adelay=12,allpass=f=1400:t=q:w=0.60,allpass=f=3400:t=q:w=0.65,equalizer=f=7200:t=q:w=2.0:g=-1.0,volume=${DECORR_GAIN}[SL_air];
[SL_main][SL_air]amix=inputs=2:weights='1 1':normalize=0[SL_final];
[SR_out]asplit=2[SR_main][SR_air_in];
[SR_air_in]highpass=f=1600,lowpass=f=9500,adelay=15,allpass=f=1650:t=q:w=0.60,allpass=f=3150:t=q:w=0.65,equalizer=f=7200:t=q:w=2.0:g=-1.0,volume=${DECORR_GAIN}[SR_air];
[SR_main][SR_air]amix=inputs=2:weights='1 1':normalize=0[SR_final];
EOF
  fi
}

# Il blocco di join finale: unisco tutti i canali processati, applico un high-shelf molto leggero (aria),
# tenuto basso perche' YPAO compensa gia' stanza/distanza in posizione d'ascolto, poi il volamp finale (se attivo).
# LFE: catena a 4 stadi → highpass 30 Hz (protegge SCS 200 dagli infrasuoni che sprecano escursione)
#                       → lowpass 120 Hz (pulizia sub-banda, coerente col crossover AVR ~110 Hz)
#                       → acompressor (guardiano dei picchi: ratio 3.0 + attack 8 ms lasciano passare il
#                         transiente/punch dei colpi proteggendo comunque il sub 100W; makeup 1.1 minimo,
#                         perche' il LIVELLO lo dà il trim sub dell'AVR, non lo script)
#                       → alimiter (rete di sicurezza finale sui clipping peaks)
build_output_join_graph() {
  cat <<EOF
[FLp]aformat=channel_layouts=mono[FLf];
[FRp]aformat=channel_layouts=mono[FRf];
[FCv]aformat=channel_layouts=mono[FCf];
[LFE]aformat=channel_layouts=mono,highpass=f=30,lowpass=f=120,acompressor=threshold=-6dB:ratio=3.0:attack=8:release=150:makeup=1.1,alimiter=limit=0.94:attack=2.0:release=120:level=0[LFEf];
[SL_final]aformat=channel_layouts=mono[SLf];
[SR_final]aformat=channel_layouts=mono[SRf];
[FLf][FRf][FCf][LFEf][SLf][SRf]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR,
highshelf=f=12000:g=0.4:w=0.5:c=FL|FR|FC|SL|SR,${FINAL_GAIN_FILTER}${ARESAMPLE_192K},alimiter=${LIMITER_OPTS},${ARESAMPLE_48K},aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=5.1(side)[aout]
EOF
}

# La funzione build_filter_complex assembla il filtergraph completo concatenando i 4 blocchi:
# input_split → voice (EQ+compressore FC) → surround (preset psicoacustico) → output_join (LFE chain + mix finale).
build_filter_complex() {
  local input_graph psycho_graph output_graph
  input_graph="$(build_input_split_graph)"
  psycho_graph="$(build_surround_psycho_graph)"
  output_graph="$(build_output_join_graph)"
  printf '%s\n%s\n%s\n%s\n%s\n' "$input_graph" "$VOICE_BLOCK" "$SUR_BLOCK" "$psycho_graph" "$output_graph"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# CICLO ELABORAZIONE
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Ciclo principale di elaborazione: per ogni file, identifico la traccia audio migliore, costruisco dinamicamente il filtergraph in base al preset scelto, e lancio ffmpeg. 
# Se il file di output esiste già, chiedo conferma prima di sovrascrivere (con opzione "tutti" per sovrascrivere tutto senza chiedere).

OVERWRITE_ALL=false

for CUR_FILE in "${FILES[@]}"; do
  info "Input: $CUR_FILE"

  # Identifico la traccia audio migliore da processare, con preferenza per 5.1, default, italiano. Se non trovo tracce valide, skippo il file.
  PROBE_RESULT=$(probe_audio_stream "$CUR_FILE") || { warn "Nessuna traccia audio valida"; continue; }
  IFS='|' read -r A_STREAM_INDEX A_CHANNELS A_LAYOUT A_IS_DEFAULT A_LANG <<<"$PROBE_RESULT"

  # Determino il layout di input e i nomi dei canali surround in base al channel layout rilevato. Se il layout non è standard o non è 5.1, uso 5.1(side) come fallback e avverto.
  case "$A_LAYOUT" in
    "5.1(side)")
      IN_LAYOUT="5.1(side)"; SUR_L_CH="SL"; SUR_R_CH="SR"
      ;;
    "5.1"|"5.1(back)")
      IN_LAYOUT="5.1"; SUR_L_CH="BL"; SUR_R_CH="BR"
      ;;
    *)
      IN_LAYOUT="5.1(side)"; SUR_L_CH="SL"; SUR_R_CH="SR"
      warn "Layout input non standard: '${A_LAYOUT:-unknown}' → fallback: 5.1(side)"
      ;;
  esac

  # Se non è un 5.1, skippo il file: il processing è ottimizzato per 5.1, e altri layout potrebbero non suonare correttamente o richiedere adattamenti specifici.
  if [[ "$A_CHANNELS" -ne 6 ]]; then
    warn "Non è un 5.1 (Canali: $A_CHANNELS) → Salto."
    continue
  fi

  # Imposto il profilo preset per questo file, costruisco il filter_complex dinamicamente, e preparo il comando ffmpeg. Se il file esiste già, chiedo conferma prima di sovrascrivere.
  set_preset_profile
  OUT_FILE="${CUR_FILE%.*}_${OUT_CODEC^^}_${SUR_MODE^}.mkv"

  # Se il file di output esiste già, chiedo conferma prima di sovrascrivere (con opzione "tutti" per sovrascrivere tutto senza chiedere).
  if [[ -f "$OUT_FILE" ]]; then
    if [[ "$OVERWRITE_ALL" == false ]]; then
      echo -ne "${C_WARN} Il file '$OUT_FILE' esiste già. Sovrascrivere? [s/n/t] (s=sì, n=no, t=tutti): "
      read -r ans < /dev/tty
      case "${ans,,}" in
        t|tutti)
          OVERWRITE_ALL=true
          info "God mode attivato: sovrascriverò tutto da qui in poi senza pietà."
          ;;
        s|si|y|yes)
          info "Piallo e sovrascrivo questo file."
          ;;
        *)
          info "Skippo '$CUR_FILE' e passo al prossimo."
          continue
          ;;
      esac
    else
      info "Sovrascrittura automatica di '$OUT_FILE'..."
    fi
  fi

  # Costruisco dinamicamente il filter_complex in base al preset scelto, concatenando i blocchi di input split, processing voce, processing surround, e output join.
  FILTER_COMPLEX="$(build_filter_complex)"

  # Preparo il comando ffmpeg con i parametri dinamici: input, filter_complex, mappatura tracce, codec audio, bitrate, metadata, e output.
  CMD=(ffmpeg -hide_banner -nostdin -stats -loglevel warning)
  [[ -f "$OUT_FILE" ]] && CMD+=( -y )
  CMD+=(
    -i "$CUR_FILE"
    -map_metadata 0 -map_chapters 0
    -filter_complex "$FILTER_COMPLEX"
    -map "0:V:0?" -c:v copy
    -map "0:s?" -c:s copy
    -map "0:t?" -c:t copy
    -map "[aout]" -c:a:0 "$OUT_CODEC" -b:a:0 "$BITRATE" -ar:a:0 48000 -ac:a:0 6
    -metadata:s:a:0 title="${OUT_CODEC^^} 5.1 – ${MODE_TITLE}"
    -disposition:a:0 default
  )

  # Imposto la lingua della traccia audio principale, se specificata.
  [[ -n "$A_LANG" && "${A_LANG,,}" != "und" ]] && CMD+=( -metadata:s:a:0 language="$A_LANG" )

  # Se l'opzione KEEP_ORIG è attiva, mantengo la traccia audio originale come secondaria, copiandola senza ricodifica e disattivando la flag di default.
  if [[ "$KEEP_ORIG" = "si" ]]; then
    ORIG_TITLE=$(get_audio_title_by_index "$CUR_FILE" "$A_STREAM_INDEX" || echo "Original Audio")
    CMD+=( -map 0:"$A_STREAM_INDEX" -c:a:1 copy -metadata:s:a:1 title="$ORIG_TITLE" -disposition:a:1 0 )
  fi

  # Lancio ffmpeg con il comando costruito dinamicamente. Se il comando riesce, loggo "Creato: $OUT_FILE". Altrimenti, loggo "Errore su: $CUR_FILE".
  CMD+=( "$OUT_FILE" )
  "${CMD[@]}" && ok "Creato: $OUT_FILE" || warn "Errore su: $CUR_FILE"
done
# Log finale: elaborazione completata.
ok "Elaborazione completata"