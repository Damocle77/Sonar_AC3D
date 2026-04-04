<p align="left">
  <img src="psico_logo.png" width="700" alt="Sonary Suite Logo">
</p>

# 🎧 Sonary Suite — Psychoacoustic Surround Toolkit (FFmpeg)

Suite di script **FFmpeg-based** per lavorare **offline** sull’audio stereo, 5.1 e sul workflow **Atmos → 5.1 DynNorm + preservazione traccia originale**, con un obiettivo semplice e brutale: **capire cosa c’è nel mix, misurarlo, e correggere solo dove serve**.

Pensata per AVR usati in modalità **Straight / Pure / Direct** e per chi preferisce una pipeline trasparente, ragionata e replicabile, invece di DSP opachi che fanno cose “perché sì”.

> “Non tutti i supereroi indossano un mantello… a volte basta un `-filter_complex`.”

---

## 🧠 Filosofia del progetto

Principio guida:

> *correggere solo ciò che serve, dove serve, e nel modo meno invasivo possibile.*

Scelte conseguenti:

- elaborazione **offline**
- **FL / FR neutri** nei processing 5.1
- canale **centrale (FC)** con EQ voce dedicata
- surround come elemento davvero variabile: **Sonar / Wide / Aegis / Aura / Voice**
- workflow **misura → decisione → processing**
- gain finale separato dal processing tramite **volamp**
- pipeline Atmos gestita come **conversione in dual-track di lavoro**, con core 5.1 pronto per analisi e processing

---

## ✅ Requisiti

### Software
- **FFmpeg 7+**
- **ffprobe**
- **Bash 4.x+**
- **awk** (richiesto dagli analyzer)

### Sistemi operativi
- Linux
- macOS
- Windows: **WSL2**, **Git-Bash**, **MSYS2**

> Nota pratica: **AC3 / E-AC3 vengono codificati via CPU**. L’eventuale accelerazione hardware riguarda in genere solo il video.

---

## 🚀 Installazione

```bash
git clone https://github.com/Damocle77/Sonary_Suite.git
cd Sonary_Suite
chmod +x *.sh
```

---

## 🧩 Script inclusi

Questa versione del README è allineata ai file della suite che stai usando ora:

- `audio_analyzer_volamp.sh`
- `aegis_sonar_wide_aura_voice_volamp.sh`
- `stereo251_upmix.sh`
- `asmr_vr_intimate.sh`
- `atmos_to_51_dynaudnorm_volamp.sh`

---

## 🎚️ Preset 5.1 disponibili

| Preset | Filosofia | Energia effettiva (indicativa) |
|-------|-----------|-------------------------------|
| **VOICE** | Solo tailoring voce sul centrale, surround attenuati e quasi pass-through | ~1.08× |
| **AURA** | Wide light, spazio soft, poco affaticante | ~1.37× |
| **WIDE** | Ampiezza orizzontale, illusione 7.1 | ~1.97× |
| **AEGIS** | Cupola controllata, Neural-X like | ~2.18× |
| **SONAR** | Altezza psicoacustica, illusione 5.1.2 | ~3.69× |

---

## 📦 1) `audio_analyzer_volamp.sh`

Analyzer principale per container audio/video.

Funzioni:

- elenca la struttura audio
- misura il contenuto
- suggerisce il preset ottimale per `aegis_sonar_wide_aura_voice_volamp.sh`
- stima un **volamp** prudente
- genera `run_processing.sh`

### Metriche supportate
- **`lra`** → dinamica temporale (EBU R128 Loudness Range)
- **`delta`** → bilanciamento surround/centro: `Delta = I(SUR) - I(FC)`

### Utilizzo
```bash
./audio_analyzer_volamp.sh <file|""> [probe|lra|delta] [codec] [keep] [bitrate]
```

### Esempi
```bash
./audio_analyzer_volamp.sh "episodio.mkv" probe
./audio_analyzer_volamp.sh "episodio.mkv" delta
./audio_analyzer_volamp.sh "" delta
./audio_analyzer_volamp.sh "" delta eac3 no 448k
./run_processing.sh
```

> Nota: il quarto parametro opzionale è `keep`, quindi se vuoi specificare il bitrate devi passare anche `si` oppure `no`.

---

## 🔊 2) `aegis_sonar_wide_aura_voice_volamp.sh`

Motore di processing per tracce **5.1 già esistenti**.

Caratteristiche principali:

- preset `aegis | sonar | wide | aura | voice`
- supporto a **volamp finale opzionale**
- `keep=si|no` per mantenere o meno la traccia originale
- selezione stream score-based
- gestione coerente dei layout `5.1`, `5.1(back)`, `5.1(side)`

### Utilizzo
```bash
./aegis_sonar_wide_aura_voice_volamp.sh <ac3|eac3> <si|no> [file] [bitrate] [preset] [volamp]
```

### Esempi
```bash
./aegis_sonar_wide_aura_voice_volamp.sh eac3 no "film.mkv" 768k sonar 1.5
./aegis_sonar_wide_aura_voice_volamp.sh eac3 no "film.mkv" 768k wide 0
./aegis_sonar_wide_aura_voice_volamp.sh ac3 si "film.mkv" 640k voice 2
```

---

## 🔁 3) `stereo251_upmix.sh`

Converte tracce stereo in 5.1 con:

- estrazione del canale centrale
- derivazione LFE dedicata
- surround decorrelati con effetto Haas
- due preset: `modern` e `vintage`

### Utilizzo
```bash
./stereo251_upmix.sh <ac3|eac3> <si|no> [file|""] [bitrate] [modern|vintage]
```

### Esempi
```bash
./stereo251_upmix.sh eac3 no "film_stereo.mkv" 448k modern
./stereo251_upmix.sh ac3 si "" 640k vintage
```

---

## 🎧 4) `asmr_vr_intimate.sh`

Processing stereo dedicato a cuffie, ASMR, VR e contenuti ravvicinati.

Include:

- crossfeed **BS2B J. Meier**
- ITD
- EQ psicoacustico
- target LUFS per preset
- keep originale opzionale
- LFO opzionale
- codec/bitrate configurabili

### Utilizzo
```bash
./asmr_vr_intimate.sh [opzioni] <file1> [file2 ...]
```

### Opzioni principali
```text
-o <dir>    Cartella output
-d <mode>   whisper | near | center
-k          Mantieni originale come seconda traccia
-l          Attiva Breathing LFO
-c <codec>  aac | opus | flac
-b <rate>   bitrate output
-f          Forza overwrite
-h          Help
```

---

## 🌩️ 5) `atmos_to_51_dynaudnorm_volamp.sh`

Prende un file con traccia **EAC3 Atmos (JOC)** e produce un file di lavoro dual-track con:

- **Traccia 1**: `EAC3 5.1` standard con **dynaudnorm**
- **Traccia 2**: `EAC3 Atmos originale` in copia bit-perfect

Serve come stadio di preparazione quando parti da materiale Atmos ma vuoi lavorare in modo controllato sul core 5.1.

### Utilizzo
```bash
./atmos_to_51_dynaudnorm_volamp.sh <file|directory> [bitrate]
```

### Esempi
```bash
./atmos_to_51_dynaudnorm_volamp.sh film.mkv
./atmos_to_51_dynaudnorm_volamp.sh film.mkv 768k
./atmos_to_51_dynaudnorm_volamp.sh /path/to/folder
./atmos_to_51_dynaudnorm_volamp.sh . 768k
```

### Output
```text
<nome>_EAC3_51_DynNorm.mkv
```

con:

- Traccia 1: `EAC3 5.1 – Dynamic Normalized`
- Traccia 2: `EAC3 Atmos (Original)`

> Nota importante: in questa suite ridotta il workflow Atmos si ferma qui come stadio dedicato. Il processing successivo è centrato sulla traccia 5.1. Se vuoi mantenere anche la traccia Atmos nel file finale dopo il processing, quella parte va gestita separatamente.

---

## 🔊 Volamp heuristic

L’analyzer stima un **boost finale prudente** guardando la Loudness Integrata del file intero.

Step correnti:

```text
0 dB   -> nessun incremento necessario
1.5 dB -> lieve recupero loudness
2 dB   -> boost consigliato
2.5 dB -> boost massimo prudente
```

Il processore applica questo gain finale **prima** del limiter.

---

## 🗺️ Diagramma pipeline

### Workflow 5.1 standard

```mermaid
flowchart LR
    A[File con traccia 5.1] --> B[audio_analyzer_volamp.sh]
    B --> C[Scelta preset + volamp]
    C --> D[run_processing.sh]
    D --> E[aegis_sonar_wide_aura_voice_volamp.sh]
    E --> F[Output finale AC3 / EAC3 processato]
```

### Workflow stereo → 5.1

```mermaid
flowchart LR
    A[File stereo] --> B[stereo251_upmix.sh]
    B --> C[File 5.1 upmixato]
    C --> D[audio_analyzer_volamp.sh]
    D --> E[run_processing.sh]
    E --> F[aegis_sonar_wide_aura_voice_volamp.sh]
    F --> G[Output finale 5.1 processato]
```

### Workflow Atmos ridotto

```mermaid
flowchart LR
    A[File EAC3 Atmos] --> B[atmos_to_51_dynaudnorm_volamp.sh]
    B --> C[Dual-track di lavoro: 5.1 DynNorm + Atmos originale]
    C --> D[audio_analyzer_volamp.sh sul file generato]
    D --> E[run_processing.sh]
    E --> F[aegis_sonar_wide_aura_voice_volamp.sh]
    F --> G[Output finale centrato sul core 5.1]
```

---

## 📊 Mini benchmark orientativo

Questo **non è un benchmark scientifico in secondi assoluti**.  
È una stima pratica della complessità relativa, utile per capire quali script “pesano” di più su CPU e tempo.

| Script | Passaggi / filtri | Costo relativo | Note pratiche |
|-------|--------------------|----------------|---------------|
| `audio_analyzer_volamp.sh` | Probe + EBU R128 | Basso / Medio | `delta` costa più di `lra` perché misura FC + SL + SR + full stream |
| `aegis_sonar_wide_aura_voice_volamp.sh` | Filtergraph 5.1 completo | Alto | È il cuore della suite, qui lavora davvero la CPU |
| `stereo251_upmix.sh` | Upmix + limiter | Medio | Più leggero del processing 5.1 completo |
| `asmr_vr_intimate.sh` | Stereo DSP + loudnorm + BS2B | Medio | Meno pesante del 5.1, ma non banale |
| `atmos_to_51_dynaudnorm_volamp.sh` | Decode Atmos core + dynaudnorm + remux | Medio / Alto | Dipende molto dalla durata del file |

### Ordine indicativo di “peso”
Dal più leggero al più pesante:

```text
audio_analyzer (lra)
audio_analyzer (delta)
stereo251_upmix
asmr_vr_intimate
atmos_to_51_dynaudnorm_volamp
aegis_sonar_wide_aura_voice_volamp
```

### Osservazione pratica
Se devi processare una stagione intera:

- il collo di bottiglia principale è quasi sempre `aegis_sonar_wide_aura_voice_volamp.sh`
- `delta` è la misura più utile, ma costa più di `lra`
- `stereo251_upmix.sh` conviene usarlo solo dove serve davvero
- `atmos_to_51_dynaudnorm_volamp.sh` è un ottimo pre-step, ma è comunque una ricodifica audio vera

---

## 🧪 Workflow consigliati

### Workflow A — File 5.1 normali
```bash
./audio_analyzer_volamp.sh "" delta eac3 no 768k
./run_processing.sh
```

### Workflow B — Stereo → 5.1 → processing finale
```bash
./stereo251_upmix.sh eac3 no "" 448k modern
./audio_analyzer_volamp.sh "" delta eac3 no 768k
./run_processing.sh
```

### Workflow C — Atmos → dual-track di lavoro
```bash
./atmos_to_51_dynaudnorm_volamp.sh film.mkv 768k
```

### Workflow D — Singolo file, controllo manuale
```bash
./audio_analyzer_volamp.sh "episodio.mkv" delta
./aegis_sonar_wide_aura_voice_volamp.sh eac3 no "episodio.mkv" 768k sonar 1.5
```

---

## 🚫 Cosa questi script NON fanno

- non rifanno il mix cinematografico da zero
- non sostituiscono la calibrazione ambientale
- non usano AI o DSP opachi
- non promettono “Atmos vero” su catene che Atmos vero non possono renderizzare
- non reinventano la fisica

---

## 🔧 Troubleshooting

### Lo script non parte
```bash
chmod +x *.sh
ffmpeg -version
ffprobe -version
```

### Il batch punta allo script sbagliato
Controlla che il batch generato usi:

```bash
PROC="./aegis_sonar_wide_aura_voice_volamp.sh"
```

### Vuoi lavorare su materiale Atmos
Prima genera il dual-track con:

```bash
./atmos_to_51_dynaudnorm_volamp.sh file.mkv
```

Poi ragiona sul core 5.1 generato.

### Errore comune nell’analyzer
Questo **non** va bene:

```bash
./audio_analyzer_volamp.sh file.mkv delta eac3 448k
```

Perché `448k` viene interpretato come parametro `keep`.

Usa invece:

```bash
./audio_analyzer_volamp.sh file.mkv delta eac3 no 448k
```

oppure:

```bash
./audio_analyzer_volamp.sh file.mkv delta eac3 si 448k
```

---

## 📄 Licenza

MIT License — vedi `LICENSE`

---

## 👤 Autore

**Sandro (D@mocle77) Sabbioni**

> *Per riportare ordine nella Forza Sonora serve solo uno script Bash.*
