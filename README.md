
# 🎙️ ClearVoice Simple - Audio Enhancement System

Sistema di ottimizzazione audio per file MKV/MP4 5.1. Migliora la chiarezza dei dialoghi e bilancia l'audio per un'esperienza ottimale su soundbar e TV. Utilizza processing audio di alta qualità con SoXR 28-bit e gestione intelligente di voci, bassi e surround.

![Version](https://img.shields.io/badge/Versione-10.1-blue) 
![Audio](https://img.shields.io/badge/Audio-5.1-green) 
![FFmpeg](https://img.shields.io/badge/FFmpeg-Required-orange) 
![Author](https://img.shields.io/badge/Author-Sandro_Sabbioni-blue)

---

## Indice

- [Caratteristiche principali](#caratteristiche-principali)
- [Tecnologia Anti-Vibrazione](#tecnologia-anti-vibrazione)
- [Profili Audio](#profili-audio)
- [Requisiti](#requisiti)
- [Installazione](#installazione)
- [Utilizzo](#utilizzo)
- [Guida Bitrate](#guida-bitrate---la-regola-doro)
- [Parametri di Elaborazione](#parametri-di-elaborazione)
- [Perché ClearVoice](#perché-clearvoice)

---

## Caratteristiche principali

ClearVoice è uno script bash che ottimizza l'audio dei tuoi contenuti multimediali:

- **🎯 Ottimizzazione dialoghi**: Migliora la chiarezza delle voci mantenendo un suono naturale
- **� Gestione bassi intelligente**: Controlla i bassi evitando rimbombi e vibrazioni
- **🎵 Surround bilanciato**: Aumenta l'immersione senza compromettere i dialoghi
- **✨ Processing di alta qualità**: Utilizza SoXR 28-bit per la massima fedeltà
- **🛠️ Facile da usare**: Configurazione automatica con parametri personalizzabili
- **⚡ SoXR 28-bit + oversampling 2×**: Precisione massima, audio ultra-clean
- **🔬 LFE chirurgico**: Boost bilanciato, cut selettivi, anti sub-bomba
- **🛡️ Processing pulito**: Highpass progressivo, eliminazione artifacts
- **🌍 Compatibilità cross-platform**: Linux, macOS, Windows (Git Bash)

## Tecnologia Anti-Vibrazione & True Peak

La tecnologia V10 elimina artefatti vocali e gestisce dinamica e headroom:

| Componente | Tecnologia V10 | Beneficio |
|------------|----------------|-----------|
| **True Peak Analysis** | Conservative Mode, Limiter adattivo | Protezione da clipping, compliance broadcast |
| **Voice Protection Plus** | Voice boost adattivo (-0.1/-0.2dB) | Voci naturali anche su contenuti "caldi" |
| **Multi-Segment Analysis** | LUFS/LRA/TP su 3-7 segmenti | Profilo dinamico sempre ottimale |
| **SoXR 28-bit** | Oversampling 2× | Audio ultra-clean, zero aliasing |
| **LFE chirurgico** | Boost 2.2-2.4dB, cut selettivi | Bassi definiti, niente sub-bomba |
| **Processing pulito** | Highpass progressivo 88-95Hz | Eliminazione rumble/artifacts |

## Requisiti

- **FFmpeg** >= 7.0 (con supporto filtergraph avanzato e codec E-AC3)
- **Bash** (Linux, macOS, WSL2 o Windows con Git Bash)
- **ffprobe**
- **awk**

## Profili Audio V10

Lo script analizza LUFS, LRA e True Peak per selezionare il profilo ottimale:

| Profilo         | Algoritmo di Selezione                | Tipo di Contenuto           | Parametri Calibrati |
|-----------------|---------------------------------------|-----------------------------|---------------------|
| **Alta Dinamica** | LRA > 12 & LUFS < -17                | Cinema/Premium/HD           | Highpass 88Hz, Voice boost 2.36, LFE 2.2dB |
| **Media Dinamica** | 7 < LRA < 12 & LUFS -16/-17         | Streaming/Standard          | Highpass 92Hz, Voice boost 2.34, LFE 2.3dB |
| **Bassa Dinamica** | LRA < 7 OR LUFS > -16               | Broadcast/Compresso         | Highpass 95Hz, Voice boost 2.32, LFE 2.4dB |

Lo script effettua analisi multi-segmento e adatta dinamica, limiter e voice boost in base al contenuto. Attiva protezione LFE avanzata per Serie TV ad alta dinamica.

---

## Installazione

```bash
# Windows (Git Bash)
winget install ffmpeg -e
winget install Git.Git -e

# Debian/Ubuntu
sudo apt install ffmpeg

# macOS
brew install ffmpeg

# Clona il progetto
git clone https://github.com/Damocle77/ClearVoice_Auto_Full.git
cd ClearVoice_Auto_Full
chmod +x *.sh
```
Assicurati che ffmpeg sia nel tuo PATH.

---

## Utilizzo

Lo script è semplice da usare e richiede solo ffmpeg come dipendenza:

```bash
./clearvoice_simple.sh "file.mkv" [bitrate] [originale] [codec]
```

### Parametri
- **file.mkv**: File video MKV/MP4 con audio 5.1
- **bitrate**: Qualità audio (256k-1024k, default: 768k)
- **originale**: Mantenere traccia originale (si/no, default: si)
- **codec**: Formato audio (eac3/ac3, default: eac3)

### Esempi
```bash
# Utilizzo base
./clearvoice_simple.sh "film.mkv"

# Configurazione personalizzata
./clearvoice_simple.sh "serie.mkv" 448k no ac3
```

---

## Script Batch per Elaborazione Multipla

Per elaborare più file MKV in una cartella, usa lo script batch `clearvoice_simple_batch.sh` (compatibile Windows/Bash).

### Utilizzo dello Script Batch

```bash
bash clearvoice_simple_batch.sh [bitrate] [originale] [formato]
```

Parametri:
- `bitrate`: Bitrate audio di output (opzionale, default: 768k)
- `originale`: yes/no (includi traccia originale, default: yes)
- `formato`: eac3/ac3 (default: eac3)

Esempi:
```bash
bash clearvoice_simple_batch.sh                     # Elabora tutti i file MKV nella cartella
bash clearvoice_simple_batch.sh 384k no             # Con bitrate e opzione originale
bash clearvoice_simple_batch.sh 384k no ac3         # Con bitrate, opzione originale e formato
bash clearvoice_simple_batch.sh "nome file.mkv" 448k no eac3  # Elabora solo un file specifico
```

Lo script batch esegue automaticamente `clearvoice_simple.sh` su ogni file MKV trovato, escludendo quelli già processati (con suffisso `_clearvoice`). Al termine, mostra un riepilogo del tempo totale impiegato e del numero di file elaborati.

## Calibrazione Parametri Avanzati

Ogni profilo utilizza parametri calibrati dal sistema adattivo V10:

- **Alta Dinamica**: Highpass 88Hz, Voice boost 2.36, LFE 2.2dB, Limiter adattivo, Conservative Mode
- **Media Dinamica**: Highpass 92Hz, Voice boost 2.34, LFE 2.3dB, Limiter adattivo
- **Bassa Dinamica**: Highpass 95Hz, Voice boost 2.32, LFE 2.4dB, Limiter adattivo

Tecnologie:
- **True Peak Analysis**: Limiter dinamico, Conservative Mode, Voice Protection Plus
- **SoXR 28-bit**: Oversampling 2×, audio ultra-clean
- **LFE chirurgico**: Boost bilanciato, cut selettivi
- **Processing pulito**: Highpass progressivo, eliminazione artifacts

---

## Guida Bitrate - La Regola d'Oro

Per risultati ottimali, segui la guida bitrate ClearVoice V10:

### E-AC-3 (raccomandato): Originale +192k
- 256k → 448k | 384k → 576k | 512k → 704k | 640k+ → 768k (optimal)

### AC-3 (compatibilità): Originale +256k
- 256k → 512k | 384k → 576k | 512k+ → 640k (limite hardware standard)

> Il bitrate aggiuntivo compensa perdite da reprocessing, artefatti lossy-to-lossy, headroom per transitori vocali e spazio per dettagli EQ recuperati.

## Parametri di Elaborazione

Lo script applica le seguenti ottimizzazioni:

- **Voce Centrale**: Filtro passa-alto e boost volume per dialoghi cristallini
- **Subwoofer**: Controllo frequenze basse per evitare vibrazioni
- **Surround**: Potenziamento bilanciato per maggiore immersione
- **Processing**: SoXR 28-bit per massima qualità audio
- **Limiter**: Prevenzione distorsioni e controllo dinamico

## Perché ClearVoice

- **🎭 Dialoghi sempre perfetti**: Sistema adattivo, profili automatici, True Peak Analysis
- **🚀 Tecnologia avanzata**: Voice boost intelligente, LFE chirurgico, limiter dinamico, SoXR 28-bit
- **🧠 Zero pensieri**: Nessuna configurazione manuale, tuning sempre ottimale
- **⚡ Compatibilità universale**: Output compatibile con ogni sistema, da soundbar a hi-end
- **🎬 Ottimizzato per contenuti moderni**: Streaming, cinema, broadcast, anime
- **🔧 Parametri dinamici**: Front, FC, LFE, Surround calibrati per ogni scenario
- **🛠️ Facile da usare**: Una semplice riga di comando per audio cinematografico perfetto

> "Quando la potenza audio reclama ordine, il terminale è la tua spada laser... Questa è la via"

---

## Autore

Sviluppato da Sandro Sabbioni (Audio Processing Engineer)
