🎧 converti_2AC3_sonar.sh (v5.4 - Final Master Kenwood)

Conversione audio EAC3/AC3 → AC3 5.1 a 640k con Calibrazione Dinamica e Simulazione Upfiring (SONAR)

“L’audio perfetto non è solo udibile... è percepibile come un eco nel Vuoto Spaziale.”

🧠 Descrizione

converti_2AC3_sonar.sh è uno script Bash avanzato che converte tracce audio EAC3 o AC3 in AC3 5.1 a 640kbps, applicando un sistema di filtri psicoacustici dinamici ottimizzati per impianti AVR Kenwood RV-6000 + KC-1 300HT + SW-40HT.

La versione v5.4 è il culmine delle calibrazioni, offrendo un'uniformità spaziale garantita e una compensazione dinamica chirurgica sui canali Vocali e LFE.

⚙️ Caratteristiche principali

⚠️ Compatibilità Garantita: Utilizza solo filtri FFmpeg standard (aecho, adelay, equalizer).

🌊 Modalità SONAR (Height Emulation)

Effetto Upfiring Focalizzato sui canali Surround (SL/SR).

Illusioni HRTF (Pinna) e Ritardo Asimmetrico (30ms/35ms) per simulare l'altezza.

L'effetto spaziale è uniforme per tutti i codec.

🎚️ Preset Dinamici e Nomenclatura Bitrate

Calibrazione Voce/LFE variabile per uniformare il volume percepito.

Tabella Calibrazione Dinamica (Loudness e Canali)

Preset

Sorgente

Loudness Globale

Boost Voce (FC)

Filtro LFE

atmos

EAC3 > 700k (Atmos core)

+3.8 dB

+2.5 dB (chirurgico)

-3.6 dB + Compressor

eac37

EAC3 768k (High-Fidelity)

+2.5 dB

+1.8 dB

-2.0 dB

eac36

EAC3 640k (Standard)

+1.2 dB

+1.2 dB

-1.2 dB

ac3

AC3 (Legacy Riferimento)

+0.0 dB

+1.0 dB

+0.0 dB

🧩 Requisiti

Linux / macOS (ambiente Bash)

FFmpeg (ffprobe incluso)

NON richiede filtri esterni non standard (es. libsoxr o areverb).

🚀 Utilizzo

./converti_2AC3_sonar.sh <sonar|nosonar> <si|no> [file.mkv] [preset]


Parametri

Parametro

Descrizione

1°

sonar → Attiva l'Upfiring/Surround Boost Asimmetrico (Remastering Kenwood)
nosonar → Conversione Clean con Boost minimo

2°

si → Mantiene audio originale
no → Solo AC3 nel file finale

3°

[file.mkv] → File singolo o lascia vuoto per Batch

4° (opz.)

atmos

🎬 Esempi di Comando

# Esempio 1: File Singolo Atmos (Calibrazione massima, elimina originale)
./converti_2AC3_sonar.sh sonar no "Fountain Of Youth.mkv" atmos

# Esempio 2: Conversione Batch (Sonar, mantiene originale, auto-rilevamento)
./converti_2AC3_sonar.sh sonar si

# Esempio 3: Conversione Pulita (Solo Loudness, mantiene originale, forzando 768k non-Atmos)
./converti_2AC3_sonar.sh nosonar si "Film_768k.mkv" eac37


🧠 Note tecniche

L'algoritmo SONAR usa la combinazione di aecho, adelay e equalizer per manipolare il tempo e la fase del suono sui canali surround, inducendo l'illusione di un riflesso dall'alto.

I valori di LFE e Voce sono bilanciati per evitare la saturazione (alimiter=0.92) e per garantire che i dialoghi rimangano chiari anche durante i picchi di effetti sonori dei master ad alta dinamica (come richiesto per l'AVR Kenwood).

📜 Licenza

MIT License.