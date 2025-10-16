#!/usr/bin/env bash

#================================================================================================
# CONVERTI_EAC3-AC3_SONAR.sh - [ARCHITETTURA DINAMICA PER HOME CINEMA]
# ===============================================================================================
#
# DESCRIZIONE:
# Script ottimizzato per conversioni EAC3/AC3/DTS → AC3 640k (5.1), con filtri intelligenti e
# calibrazione dinamica per uniformare il loudness e la percezione spaziale (Upfiring).
#
# CARATTERISTICHE PRINCIPALI:
# • OPT: Nomenclatura preset standardizzata (eac37, eac36).
# • OPT: Calibrazione finale Voce/LFE per uniformità percepita (non matematica).
# • CALIBRAZIONE DINAMICA (Voce/LFE): I parametri sono variabili per compensare le differenze 
#   intrinseche di dinamica tra i master (Atmos, EAC3, DTS, AC3).
# • UPFIRING FOCALIZZATO (Modalità SONAR): Filtri Echo/Delay asimmetrici per simulare l'altezza,
#   con effetto uniforme su tutti i codec.
# ===============================================================================================

# Colori terminale (Minimali per output clean)
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

# Funzione per output minimo e controllo errori
info(){ echo -e "${CYAN}[Info]${NC} $*"; }
warn(){ echo -e "${YELLOW}[Warning]${NC} $*"; }
err(){ echo -e "${RED}[Error]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
cleanup_and_exit() {
    if [ $? -ne 0 ]; then
        err "Errore irreversibile. Uscita."
    fi
    exit 1
}
trap cleanup_and_exit INT TERM

# Summary comandi
if [ "$#" -lt 2 ]; then
cat <<'USAGE'
============================================================================================
UTILIZZO:
  ./script.sh <sonar|nosonar> <si|no> [file.mkv] [preset]

Parametri:
  - Primo:  "sonar"   → Attiva Height/Surround Boost Asimmetrico (Remastering Kenwood)
            "nosonar" → Conversione Clean con Boost minimo
  - Secondo: "si"     → Mantiene l'audio originale nel file output | "no" → Solo AC3
  - Terzo:   [file.mkv] Singolo o lascia vuoto per Batch su tutti i file MKV.
  - Quarto:  [preset] (opzionale) → "atmos" | "eac37" | "eac36" | "ac3" | "auto" (default)

Preset Dinamici (Target Loudness e Filtri Canale per Uniformità Funzionale):
  atmos   → Forza EAC3 Atmos/Alta Dinamica (Globale +3.8dB, LFE -3.6dB, Voce +2.5dB)
  eac37   → Forza EAC3/DTS 768k High-Fidelity (Globale +2.5dB, LFE -2.0dB, Voce +1.8dB)
  eac36   → Forza EAC3 640k Standard (Globale +1.2dB, LFE -1.2dB, Voce +1.2dB)
  ac3     → Forza AC3 Standard (Globale +0.0dB, LFE 0dB, Voce +1.0dB)

Batch:       
  ./converti_2AC3_sonar.sh <MODALITÀ SONAR> <MANTIENI ORIGINALE>
============================================================================================
USAGE
exit 1
fi

# Parsing parametri
SONAR_MODE=$(echo "$1" | tr '[:upper:]' '[:lower:]')
KEEP_ORIG=$(echo "$2" | tr '[:upper:]' '[:lower:]')
INPUT_FILE="$3"
PRESET=$(echo "$4" | tr '[:upper:]' '[:lower:]') 

# Validazione parametri
case "$PRESET" in ""|auto|atmos|eac37|eac36|ac3) ;; *) err "Preset non valido: $PRESET"; exit 1;; esac
case "$SONAR_MODE" in sonar|nosonar) ;; *) err "Modalità non valida: $SONAR_MODE (usa: sonar o nosonar)"; exit 1;; esac
case "$KEEP_ORIG" in si|no) ;; *) err "Parametro keep non valido: $KEEP_ORIG (usa: si o no)"; exit 1;; esac

# Build file list
if [ -n "$INPUT_FILE" ]; then
    FILES=("$INPUT_FILE")
else
    mapfile -d $'\0' -t FILES < <(find . -maxdepth 1 -name "*.mkv" ! -name "*_AC3*.mkv" -print0)
    if [ -z "${FILES[-1]}" ]; then unset 'FILES[${#FILES[@]}-1]'; fi
    [ ${#FILES[@]} -eq 0 ] && { info "Nessun file MKV trovato nella cartella"; exit 0; }
    info "Trovati ${#FILES[@]} file MKV da processare"
fi

# ===============================================================================================
# FUNZIONI FILTRI AUDIO INTELLIGENTI
# ===============================================================================================

# Funzione per rilevare codec e bitrate
get_audio_info() {
    # Rileva codec e bitrate del primo stream audio
    local file="$1"
    local info_string=$(ffprobe -v quiet -select_streams a:0 -show_entries stream=codec_name,bit_rate -of csv=p=0:nk=1 "$file" 2>/dev/null)
    if [ -z "$info_string" ]; then echo "unknown,600000"; else echo "$info_string"; fi
}

# Funzione per determinare i valori di compensazione dinamica (Loudness, Voce, LFE)
get_dynamic_values() {
    local type="$1"; local br="$2"; local preset="$3"
    local boost_global; local boost_voce; local lfe_vol; local lfe_comp_filter
    
    # 1. LOGICA PRESET MANUALE (Override)
    if [ "$preset" = "atmos" ]; then
        boost_global=3.8; boost_voce=2.5; lfe_vol=-3.6; lfe_comp_filter="acompressor=threshold=0.30:ratio=2.8:attack=12:release=90";
    elif [ "$preset" = "eac37" ]; then
        boost_global=2.5; boost_voce=1.8; lfe_vol=-2.0; lfe_comp_filter="";
    elif [ "$preset" = "eac36" ]; then
        boost_global=1.2; boost_voce=1.2; lfe_vol=-1.2; lfe_comp_filter="";
    elif [ "$preset" = "ac3" ]; then
        boost_global=0.0; boost_voce=1.0; lfe_vol=0.0; lfe_comp_filter="";
    
    # 2. LOGICA RILEVAMENTO AUTOMATICO (Default)
    elif [ "$type" = "eac3" ]; then
        if [ "$br" -gt 700000 ]; then
            boost_global=3.8; boost_voce=2.5; lfe_vol=-3.6; lfe_comp_filter="acompressor=threshold=0.30:ratio=2.8:attack=12:release=90";
            info "Rilevato EAC3 Atmos potenziale (${br} bps) → Loudness +3.8dB, Voce +2.5dB, LFE -3.6dB (compresso)";
        else
            boost_global=1.2; boost_voce=1.2; lfe_vol=-1.2; lfe_comp_filter="";
            info "Rilevato EAC3 Standard (${br} bps) → Loudness +1.2dB, Voce +1.2dB, LFE -1.2dB";
        fi
    elif [ "$type" = "dts" ] || [ "$type" = "dts_hd" ]; then
        if [ "$br" -gt 700000 ]; then
            boost_global=2.5; boost_voce=1.8; lfe_vol=-2.0; lfe_comp_filter="";
            info "Rilevato DTS/DTS-HD High-Fidelity (${br} bps) → Loudness +2.5dB, Voce +1.8dB, LFE -2.0dB";
        else
            boost_global=1.2; boost_voce=1.2; lfe_vol=-1.2; lfe_comp_filter="";
            info "Rilevato DTS Standard (${br} bps) → Loudness +1.2dB, Voce +1.2dB, LFE -1.2dB";
        fi
    else # AC3 o altro (fallback)
        boost_global=0.0; boost_voce=1.0; lfe_vol=0.0; lfe_comp_filter="";
        info "Rilevato Audio $type (${br} bps) → Loudness +0.0dB, Voce +1.0dB, LFE 0dB (Riferimento)";
    fi
    
    # Output dei valori in formato CSV
    echo "${boost_global},${boost_voce},${lfe_vol},${lfe_comp_filter}"
}

# should_overwrite (Invariato)
should_overwrite() {
    local file="$1"
    if [ -f "$file" ]; then
        while true; do
            read -p "$(echo -e "${YELLOW}[Warning]${NC}") Il file di output esiste già. Sovrascrivere? [s/n] " CONFIRM
            case "$CONFIRM" in
                [sS]) return 0;;
                [nN]) info "Output saltato per $file"; return 1;;
                *) echo "Rispondi 's' per sì, 'n' per no.";;
            esac
        done
    fi
    return 0
}

# Modalità SONAR (V5.5): Integrazione EQ HRTF + Altezza FOCALIZZATA (Solo filtri standard)
get_sonar_filter_upfiring() {
    # Ritardo massimo uniforme su tutti i codec per massimizzare l'illusione
    local delay_ms=30; local delay_ms_r=35 
    
    # EQ HRTF (PINNA) + Effetto Riverbero/Eco Asimmetrico (Solo filtri standard: 'aecho' e 'adelay' integrato)
    echo "[SL]equalizer=f=2700:t=q:w=1.1:g=2.5,equalizer=f=3300:t=q:w=1.5:g=2.2,equalizer=f=4100:t=q:w=1.2:g=1.7,aecho=0.8:0.88:40:0.4,adelay=${delay_ms}|${delay_ms}:all=1,volume=3.7dB[SL_boost];\
    [SR]equalizer=f=2700:t=q:w=1.1:g=2.5,equalizer=f=3300:t=q:w=1.5:g=2.2,equalizer=f=4100:t=q:w=1.2:g=1.7,aecho=0.8:0.88:40:0.4,adelay=${delay_ms_r}|${delay_ms_r}:all=1,volume=3.4dB[SR_boost];"
}

# Clean: boost bilanciato con correzione asimmetria SL/SR minima
get_boost_clean() {
    echo "[SL]equalizer=f=2800:t=q:w=1.4:g=2.2,volume=3.5dB[SL_boost];[SR]equalizer=f=2800:t=q:w=1.4:g=2.2,volume=3.2dB[SR_boost];"
}

# ===============================================================================================
# MAIN PROCESSING LOOP
# ===============================================================================================

for IN in "${FILES[@]}"; do
    BAS=$(basename "$IN" .mkv); echo ""; info "Elaborazione: ${BAS}.mkv"
    AUDIO_INFO=$(get_audio_info "$IN"); AUDIO_TYPE=$(echo "$AUDIO_INFO" | cut -d',' -f1); AUDIO_BR=$(echo "$AUDIO_INFO" | cut -d',' -f2)
    if ! [[ "$AUDIO_BR" =~ ^[0-9]+$ ]]; then warn "Bitrate non rilevabile, assumo valore standard per filtro LFE."; AUDIO_BR=600000; fi
    
    # 1. CALCOLO VALORI DINAMICI E LFE
    DYN_VALS=$(get_dynamic_values "$AUDIO_TYPE" "$AUDIO_BR" "$PRESET")
    GLOBAL_BOOST_DB=$(echo "$DYN_VALS" | cut -d',' -f1)
    VOCE_BOOST_DB=$(echo "$DYN_VALS" | cut -d',' -f2)
    LFE_VOL_DB=$(echo "$DYN_VALS" | cut -d',' -f3)
    LFE_COMP_FILT=$(echo "$DYN_VALS" | cut -d',' -f4)

    # 2. Genera filtri surround/height
    if [ "$SONAR_MODE" = "sonar" ]; then 
        SURF=$(get_sonar_filter_upfiring); SUFFIX="_Sonar"
        info "Modalità SONAR: Height HRTF MAX ON + Ritardo Asimmetrico (30/35ms)"
    else 
        SURF=$(get_boost_clean); SUFFIX="_Clean"
        info "Modalità Clean: Boost surround bilanciato"
    fi
    
    # 3. File output e controllo sovrascrittura
    OUT="${BAS}_AC3${SUFFIX}.mkv"
    if ! should_overwrite "$OUT"; then continue; fi
    info "Conversione → AC3 640k: $OUT"
    
    # 4. Pipeline filter_complex
    
    # FIltraggio LFE
    if [ -n "$LFE_COMP_FILT" ]; then
        # Se c'è un filtro di compressione, lo eseguiamo prima del volume e del limiter, separati dalla virgola.
        LFE_FILT="[LFE]highpass=f=25,${LFE_COMP_FILT},volume=${LFE_VOL_DB}dB,alimiter=limit=0.90[LFE_clean];"
        LFE_OUT="[LFE_clean]"
    elif [ "$LFE_VOL_DB" != "0.0" ]; then
        # Se c'è solo un volume non nullo (ma nessuna compressione)
        LFE_FILT="[LFE]highpass=f=25,volume=${LFE_VOL_DB}dB,alimiter=limit=0.90[LFE_clean];"
        LFE_OUT="[LFE_clean]"
    else
        # Caso base (AC3): solo highpass e output diretto
        LFE_FILT="[LFE]highpass=f=25[LFE_clean];"
        LFE_OUT="[LFE_clean]"
    fi

    # Costruzione del filtro completo
    FILTER="[0:a:0]channelsplit=channel_layout=5.1[FL][FR][FC][LFE][SL][SR];\
            ${LFE_FILT}\
            ${SURF}\
            [FC]volume=${VOCE_BOOST_DB}dB[FC_boost];\
            [FL][FR][FC_boost]${LFE_OUT}[SL_boost][SR_boost]amerge=inputs=6,volume=${GLOBAL_BOOST_DB}dB,\
            aresample=resampler=soxr:precision=28:dither_method=triangular,alimiter=limit=0.92[aout]"

    # 5. Esecuzione conversione (Costruzione dell'array CMD)
    CMD=(ffmpeg -y -nostdin -loglevel error -stats -hide_banner -hwaccel auto -threads 0 -i "$IN" -filter_complex "$FILTER" -map 0:v -c:v copy -map "[aout]" -c:a ac3 -b:a 640k -ar 48000 -ac 6)
    
    if [ "$KEEP_ORIG" = "si" ]; then 
        CMD+=(-map 0:a:0 -c:a:1 copy -metadata:s:a:1 title="Original Audio" -disposition:a:1 0)
        info "Traccia originale mantenuta"
    fi
    
    # Mappa sottotitoli se esistono
    if ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$IN" | grep -q .; then 
        CMD+=(-map 0:s -c:s copy)
    fi
    
    # Aggiungi i metadati finali e il file di output all'array
    CMD+=(-metadata:s:a:0 title="AC3 5.1 Kenwood${SUFFIX}" -disposition:a:0 default)
    CMD+=("$OUT")
    
    info "Avvio conversione FFmpeg....."
    # Esecuzione dell'array
    "${CMD[@]}"
    
    if [ $? -eq 0 ]; then ok "Conversione completata: $OUT"; else err "Errore durante conversione: $OUT"; fi
done

# Report finale
ok "Batch completato! Processati ${#FILES[@]} file"
echo "====================================================================================="
echo "Conversione AC3 640k ottimizzata per AVR Kenwood RV600 + KS1-300HT + SW40HT"
echo "======================================================================================"

