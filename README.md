<p align="left">
  <img src="psico_logo.png" width="700" alt="Sonary Suite Logo">
</p>

# 🎧 Sonary Suite — Psychoacoustic Surround Toolkit (FFmpeg)

Suite di script **FFmpeg-based** per lavorare **offline** sull’audio stereo, 5.1 e sui workflow **Atmos → 5.1 + preservazione traccia originale**, con un obiettivo molto concreto: **capire cosa c’è nel mix, misurarlo, e correggere solo dove serve**.

Pensata per AVR usati in modalità **Straight / Pure / Direct** (testata e ottimizzata su **Yamaha RX‑V4A con crossover 160 Hz**) e compatibile con correzione ambientale tipo **YPAO**.

> “Non tutti i supereroi indossano un mantello… a volte basta un `-filter_complex`.”   
> ⚡ Sandro (D@mocle77) Sabbioni ⚡…perception follows physics…

---

## 🧠 Filosofia del progetto

Principio guida:

> *correggere solo ciò che serve, dove serve, e nel modo meno invasivo possibile.*

Scelte conseguenti:

- Elaborazione **offline**: niente DSP “magico” in tempo reale sull’AVR
- **FL / FR neutri** nei processing 5.1: non si rifà il mix
- Canale **centrale (FC)** con **EQ voce** dedicata
- **Surround** come elemento realmente variabile: Sonar / Wide / Aegis / Aura / Voice
- Workflow **misura → decisione → processing**
- Gain finale separato dal processing: prima si sceglie il preset, poi si valuta il **volamp**
- Pipeline **Atmos-aware** dove serve: possibilità di lavorare sul core 5.1 e decidere se **preservare** o **scartare** la traccia Atmos/originale

---

## ✅ Requisiti

### Software
- **FFmpeg 7+**
- **ffprobe** (di solito incluso con FFmpeg)
- **Bash 4.x+**
- **awk** (richiesto dagli analyzer)

### Sistemi operativi
- Linux
- macOS
- Windows: **WSL2**, **Git-Bash**, **MSYS2**

> Nota pratica: **AC3 / E-AC3 si codificano sempre via CPU**. L’eventuale accelerazione hardware riguarda tipicamente solo il video.

---

## 🚀 Installazione

```bash
git clone https://github.com/Damocle77/Sonary_Suite.git
cd Sonary_Suite
chmod +x *.sh
```

---

## 🧩 Script inclusi

- `audio_analyzer_volamp.sh` → analyzer generico per file audio/video, suggerimento preset, stima volamp, generazione `run_processing.sh`
- `aegis_sonar_wide_aura_voice_volamp.sh` → processore principale per tracce **5.1 già esistenti**
- `stereo251_upmix.sh` → upmix **stereo → 5.1**
- `asmr_vr_intimate.sh` → processing binaurale / ASMR / VR / cuffie
- `atmos_to_51_dynaudnorm_volamp.sh` → conversione **EAC3 Atmos → dual-track** con **5.1 DynNorm + Atmos originale**
- `atmos_audio_analyzer_volamp.sh` → analyzer specializzato per workflow Atmos, con generazione `run_processing_atmos.sh`

---

## 🎚️ Preset 5.1 disponibili

| Preset | Filosofia | Energia effettiva (indicativa) |
|-------|-----------|-------------------------------|
| **VOICE** | Solo tailoring voce sul centrale, surround attenuati e quasi pass-through | ~1.08× |
| **AURA** | Wide light, spazio soft, poco affaticante | ~1.37× |
| **WIDE** | Ampiezza orizzontale, illusione 7.1 | ~1.97× |
| **AEGIS** | Cupola controllata, Neural‑X like | ~2.18× |
| **SONAR** | Altezza psicoacustica, illusione 5.1.2 | ~3.69× |

---

## 📦 Suite completa

### 1) `audio_analyzer_volamp.sh` — Analyzer generico + preset + volamp

Sonda euristica per container multimediali. Elenca le tracce audio e, se richiesto, misura il contenuto per suggerire il preset ottimale per `aegis_sonar_wide_aura_voice_volamp.sh`.

Supporta due metriche:

- **`lra`** → dinamica temporale (EBU R128 Loudness Range)
- **`delta`** → bilanciamento surround/centro: `Delta = I(SUR) − I(FC)`

In più:

- misura la **Loudness Integrata**
- stima un **volamp** prudente a step `0 / 1.5 / 2 / 2.5 dB`
- produce un **Verdetto Stagionale**
- genera `run_processing.sh` con **preset e volamp per-file**

**Utilizzo**
```bash
./audio_analyzer_volamp.sh <file|""> [probe|lra|delta] [codec] [keep] [bitrate]
```

**Esempi**
```bash
./audio_analyzer_volamp.sh "episodio.mkv" probe
./audio_analyzer_volamp.sh "episodio.mkv" delta
./audio_analyzer_volamp.sh "" delta
./audio_analyzer_volamp.sh "" delta eac3 no 448k
./run_processing.sh
```

---

### 2) `aegis_sonar_wide_aura_voice_volamp.sh` — Processing 5.1 esistente + volamp finale

Motore di processing per tracce **5.1 già presenti**. Mantiene LFE e frontali coerenti, lavora sul centrale con EQ voce e sui surround con preset psicoacustici.

Caratteristiche principali:

- supporto a preset `aegis | sonar | wide | aura | voice`
- supporto a **`volamp` finale opzionale**
- `keep=si|no` per mantenere o meno la traccia originale
- selezione stream score-based
- gestione coerente di layout `5.1`, `5.1(back)`, `5.1(side)`

**Utilizzo**
```bash
./aegis_sonar_wide_aura_voice_volamp.sh <ac3|eac3> <si|no> [file] [bitrate] [preset] [volamp]
```

**Esempi**
```bash
./aegis_sonar_wide_aura_voice_volamp.sh eac3 no "film.mkv" 768k sonar 1.5
./aegis_sonar_wide_aura_voice_volamp.sh eac3 no "film.mkv" 768k wide 0
./aegis_sonar_wide_aura_voice_volamp.sh ac3 si "film.mkv" 640k voice 2
```

---

### 3) `stereo251_upmix.sh` — Upmix Stereo → 5.1

Converte tracce stereo in 5.1 con:

- estrazione del canale centrale
- derivazione LFE dedicata
- surround decorrelati con effetto Haas
- due preset: `modern` e `vintage`

**Utilizzo**
```bash
./stereo251_upmix.sh <ac3|eac3> <si|no> [file|""] [bitrate] [modern|vintage]
```

**Esempi**
```bash
./stereo251_upmix.sh eac3 no "film_stereo.mkv" 448k modern
./stereo251_upmix.sh ac3 si "" 640k vintage
```

---

### 4) `asmr_vr_intimate.sh` — Binaurale / VR / ASMR / cuffie

Processing stereo pensato per contenuti ravvicinati, ascolto in cuffia e resa “intima”.

Include:

- crossfeed **BS2B J. Meier**
- ITD
- EQ psicoacustico
- target LUFS per preset
- opzione keep originale
- opzione LFO

**Utilizzo**
```bash
./asmr_vr_intimate.sh [opzioni] <file1> [file2 ...]
```

**Opzioni principali**
```text
-o <dir>    Cartella output
-d <mode>   whisper | near | center
-k          Mantieni originale come seconda traccia
-l          Attiva Breathing LFO
-f          Forza overwrite
-h          Help
```

---

## 🌩️ Workflow Atmos-specifici

Qui entrano in scena i due script nuovi dedicati all’universo Atmos. Sono pensati per una pipeline dove vuoi:

1. estrarre e produrre un **core 5.1 utilizzabile**
2. analizzarlo con le stesse logiche di preset/volamp
3. decidere se il file finale debba contenere anche la **traccia Atmos/originale** oppure solo la 5.1 processata

---

### 5) `atmos_to_51_dynaudnorm_volamp.sh` — Atmos → 5.1 DynNorm + Atmos originale

Prende un file con traccia **EAC3 Atmos (JOC)** e produce un MKV dual-track con:

- **Traccia 1**: `EAC3 5.1` standard con **dynaudnorm**
- **Traccia 2**: `EAC3 Atmos originale` in copia bit-perfect

Serve come **primo stadio** del workflow Atmos: crea un file di lavoro dove il core 5.1 è già pronto per essere analizzato e processato, ma la traccia Atmos originale resta conservata.

**Utilizzo**
```bash
./atmos_to_51_dynaudnorm_volamp.sh <file|directory> [bitrate]
```

**Parametri**
- `file|directory` → file sorgente oppure cartella da processare in batch
- `bitrate` → bitrate della traccia 5.1 generata, default `640k`

**Esempi**
```bash
./atmos_to_51_dynaudnorm_volamp.sh film.mkv
./atmos_to_51_dynaudnorm_volamp.sh film.mkv 768k
./atmos_to_51_dynaudnorm_volamp.sh /path/to/folder
./atmos_to_51_dynaudnorm_volamp.sh . 768k
```

**Output**
```text
<nome>_EAC3_51_DynNorm.mkv
```

con:

- Traccia 1: `EAC3 5.1 – Dynamic Normalized`
- Traccia 2: `EAC3 Atmos (Original)`

**Quando usarlo**
- quando parti da file Atmos e vuoi creare una base 5.1 già “domata” per ascolto notturno o sistemi con dinamica limitata
- quando vuoi una pipeline ordinata: prima conversione, poi analisi, poi processing surround finale

---

### 6) `atmos_audio_analyzer_volamp.sh` — Analyzer Atmos-aware + batch Atmos

Variante specializzata dell’analyzer, progettata per file prodotti da `atmos_to_51_dynaudnorm_volamp.sh` oppure per file con singola traccia EAC3 Atmos.

Analizza **solo la traccia target 5.1 (`a:0`)**, non la Atmos originale, e genera `run_processing_atmos.sh`.

**Funzioni principali**

- supporta `probe`, `lra`, `delta`
- stima il **volamp**
- produce il **Verdetto Stagionale**
- genera batch Atmos-aware
- introduce il parametro:

```text
keep_atmos = si | no
```

che permette di scegliere il comportamento finale.

**Utilizzo**
```bash
./atmos_audio_analyzer_volamp.sh <file|""> [modo] [codec] [keep_atmos] [bitrate]
```

**Significato di `keep_atmos`**
- `si` → mantiene la traccia Atmos/originale come seconda traccia quando disponibile
- `no` → produce output con **sola traccia processata**

**Esempi**
```bash
./atmos_audio_analyzer_volamp.sh film_EAC3_51_DynNorm.mkv probe
./atmos_audio_analyzer_volamp.sh film_EAC3_51_DynNorm.mkv delta
./atmos_audio_analyzer_volamp.sh "" delta eac3 si 768k
./atmos_audio_analyzer_volamp.sh "" delta eac3 no 640k
./run_processing_atmos.sh
```

**Comportamento operativo**

#### Caso A: file dual-track
Tipico output di `atmos_to_51_dynaudnorm_volamp.sh`

- `a:0` = 5.1 DynNorm
- `a:1` = Atmos originale

Se `keep_atmos=si`:
1. processa solo la 5.1
2. rimuxa la traccia Atmos originale nel file finale

Se `keep_atmos=no`:
1. processa la 5.1
2. **non** rimuxa la Atmos
3. output finale con sola traccia processata

#### Caso B: file single-track
File con una sola traccia EAC3 Atmos / EAC3 5.1 compatibile

- se `keep_atmos=si`, il processore viene invocato in modo da preservare l’originale come seconda traccia
- se `keep_atmos=no`, l’output contiene solo la traccia processata

**Quando usarlo**
- quando vuoi una pipeline dedicata all’Atmos senza gestire il remux a mano
- quando vuoi poter scegliere, caso per caso, se l’output finale debba restare “ibrido” (5.1 processata + Atmos originale) oppure “pulito” (solo 5.1 processata)

---

## 🔊 Volamp heuristic

Gli analyzer stimano un **boost finale prudente** guardando la Loudness Integrata del file intero.

Step correnti:

```text
0 dB   -> nessun incremento necessario
1.5 dB -> lieve recupero loudness
2 dB   -> boost consigliato
2.5 dB -> boost massimo prudente
```

Il processore applica questo gain finale **prima** del limiter. In pratica:

- il preset decide il carattere timbrico/spaziale
- il `volamp` regola il livello globale
- il limiter resta una rete di sicurezza, non una scorciatoia opaca

---

## 🧪 Workflow consigliati

### Workflow A — File 5.1 normali
```bash
./audio_analyzer_volamp.sh "" delta eac3 no 768k
./run_processing.sh
```

### Workflow B — Atmos completo con preservazione traccia originale
```bash
# 1) Crea il dual-track
./atmos_to_51_dynaudnorm_volamp.sh film.mkv 768k

# 2) Analizza il core 5.1 e genera il batch
./atmos_audio_analyzer_volamp.sh "" delta eac3 si 768k

# 3) Esegui il batch
./run_processing_atmos.sh
```

### Workflow C — Atmos ma output finale solo 5.1 processata
```bash
# 1) Crea il dual-track di lavoro
./atmos_to_51_dynaudnorm_volamp.sh film.mkv 640k

# 2) Analizza e scegli di NON preservare l'Atmos
./atmos_audio_analyzer_volamp.sh "" delta eac3 no 640k

# 3) Esegui il batch
./run_processing_atmos.sh
```

### Workflow D — Singolo file, controllo manuale
```bash
./audio_analyzer_volamp.sh "episodio.mkv" delta
./aegis_sonar_wide_aura_voice_volamp.sh eac3 no "episodio.mkv" 768k sonar 1.5
```

---

## 🚫 Cosa questi script NON fanno

- Non rifanno il mix cinematografico da zero
- Non sostituiscono la calibrazione ambientale
- Non usano AI o DSP opachi
- Non promettono “Atmos vero” su catene che Atmos vero non possono renderizzare
- Non reinventano la fisica: lavorano con DSP classico, misurabile e debuggabile

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

### Vuoi solo la 5.1 finale nei workflow Atmos
Usa:

```bash
./atmos_audio_analyzer_volamp.sh "" delta eac3 no 640k
```

### Vuoi tenere anche la traccia Atmos/originale
Usa:

```bash
./atmos_audio_analyzer_volamp.sh "" delta eac3 si 768k
```

### Il file Atmos non viene rilevato bene
Prima genera il dual-track con:

```bash
./atmos_to_51_dynaudnorm_volamp.sh file.mkv
```

Poi lavora su quello. È il percorso più pulito e meno litigioso.

---

## 📄 Licenza

MIT License — vedi `LICENSE`

---

## 👤 Autore

**Sandro (D@mocle77) Sabbioni**

> *Per riportare ordine nella Forza Sonora serve solo uno script Bash… questa è la via.*
