<p align="left">
  <img src="psico_logo.png" width="700" alt="Sonary Suite Logo">
</p>

# 🎧 Sonary Suite - Psychoacoustic Toolkit (FFmpeg-based)
Suite di script **FFmpeg-based** per lavorare **offline** sull’audio (stereo e 5.1) con un obiettivo molto poco romantico e molto utile: **capire cosa c’è nel mix, misurarlo, e correggere solo dove serve**.

Pensata per AVR usati in modalità **Straight / Pure / Direct** (testata e ottimizzata su **Yamaha RX‑V4A con crossover 160 Hz**) e compatibile con correzione ambientale tipo **YPAO**.

> “Non tutti i supereroi indossano un mantello… a volte basta un `-filter_complex`.” ⚡ Sandro (D@mocle77) Sabbioni ⚡  
> …perception follows physics…

---

## 🧠 Filosofia del progetto

Principio guida:

> *correggere solo ciò che serve, dove serve, e nel modo meno invasivo possibile.*

Scelte conseguenti:
- Elaborazione **offline** (niente DSP “magico” in tempo reale sull’AVR)
- **FL / FR neutri** nei processing 5.1 (non si “rifà il mix”)
- Canale **Centrale (FC)** con **EQ voce** dedicata (base comune + delta per preset)
- **Surround** = unico elemento davvero “variabile” (Sonar / Wide / Aegis / Aura oppure bypass in Voice)
- Niente preset “a sensazione”: prima si **misura**, poi si **decide**

---

## ✅ Requisiti

### Software
- **FFmpeg 7+**
- **ffprobe** (di solito incluso con FFmpeg)
- **Bash 4.x+**
- **awk** (richiesto dall’analyzer)

### Sistemi operativi
- Linux
- macOS
- Windows: **WSL2**, **Git-Bash**, **MSYS2**

> Nota “fisica non negoziabile”: **AC3 / E‑AC3 si codificano sempre via CPU**. L’eventuale accelerazione HW riguarda tipicamente solo il video.

---

## 🚀 Installazione

```bash
git clone https://github.com/Damocle77/Sonary_Suite.git
cd Sonary_Suite
chmod +x *.sh
```

---

## 🧩 Script inclusi (versioni)

- `audio_analyzer.sh` — **V4 (Feb 2026)** → analisi e suggerimento preset (LRA o Delta SUR‑FC)
- `aegis_sonar_wide_aura_voice.sh` — **V3 (Feb 2026)** → processing **5.1 già esistente**
- `stereo251_upmix.sh` — **V2 (Feb 2026)** → upmix **stereo → 5.1**
- `asmr_vr_intimate.sh` — **V2 (Mar 2026)** → binaurale “ravvicinato” per cuffie / VR / ASMR

---

## 🎚️ Preset 5.1 disponibili (processing)

| Preset | Filosofia | Energia effettiva (indicativa) |
|-------|-----------|-------------------------------|
| **VOICE** | Tailoring vFC (surround pass‑through) | ~1.08× |
| **AURA** | Wide light sound (illusione 6.1) | ~1.37× |
| **WIDE** | Ampiezza orizzontale (illusione 7.1) | ~1.97× |
| **AEGIS** | Cupola controllata (Neural‑X like) | ~2.18× |
| **SONAR** | Altezza psicoacustica (illusione 5.1.2) | ~3.69× |

---

## 📦 Suite completa — 4 script

### 1️⃣ `audio_analyzer.sh` — Analisi + suggerimento preset (LRA / Delta)

Sonda euristica per container multimediali: elenca le tracce audio e, se richiesto, calcola una metrica per suggerire il preset ottimale per `aegis_sonar_wide_aura_voice.sh`.

Metriche:
- **`lra`** → dinamica temporale (EBU R128 Loudness Range)
- **`delta`** → **bilanciamento surround/centro**: `Delta = I(SUR) − I(FC)` (più diretto per scegliere i preset)

**Utilizzo**
```bash
./audio_analyzer.sh <file|""> [probe|lra|delta] [codec] [keep] [bitrate]
```

**Note importanti**
- `probe` (default) non misura nulla: stampa solo la struttura delle tracce.
- `delta` richiede **5.1 (6 canali)**. Se il file non è 5.1 viene skippato per quella metrica.
- A fine analisi (se hai analizzato ≥ 2 file) genera `run_processing.sh` con i comandi pronti.  
  Se la stagione è eterogenea (spread > 4), propone preset **per‑file**.

**Esempi**
```bash
# Struttura tracce
./audio_analyzer.sh "episodio.mkv" probe

# Analisi Delta (consigliata)
./audio_analyzer.sh "episodio.mkv" delta

# Batch su cartella (delta, default: eac3/no/448k)
./audio_analyzer.sh "" delta

# Batch esplicito
./audio_analyzer.sh "" delta eac3 no 448k

# Analisi LRA (legacy)
./audio_analyzer.sh "" lra ac3 si 640k

# Dopo il batch:
./run_processing.sh
```

---

### 2️⃣ `aegis_sonar_wide_aura_voice.sh` — Processing 5.1 esistente

Elabora tracce **5.1 già presenti** (AC3/E‑AC3 tipicamente) con DSP psicoacustico sui surround + EQ voce sul centrale, senza stravolgere i frontali.

**Utilizzo**
```bash
./aegis_sonar_wide_aura_voice.sh <ac3|eac3> <si|no> [file|""] [bitrate] [sonar|wide|aegis|aura|voice]
```

**Dettagli “da officina” (in breve)**
- Selezione stream **score‑based**: priorità a 6 canali, default, lingua `it`.
- Normalizzazione layout: gestisce `5.1`, `5.1(back)` e `5.1(side)` rimappando i surround in modo coerente.
- Overwrite interattivo `[s/n/t]` via `/dev/tty` e `-y` **solo** quando serve (sovrascrittura confermata).
- `alimiter` con `level=0`: niente auto‑leveling, solo safety net sui picchi.

**Esempi**
```bash
# Sci‑fi / fantasy → SONAR (altezza)
./aegis_sonar_wide_aura_voice.sh eac3 no "blockbuster.mkv" 768k sonar

# Action moderno → WIDE (ampiezza laterale)
./aegis_sonar_wide_aura_voice.sh eac3 no "action.mkv" 768k wide

# Thriller / dinamica variabile → AEGIS (controllo)
./aegis_sonar_wide_aura_voice.sh eac3 no "cinecomic.mkv" 640k aegis

# Drama / dialoghi → AURA (spazio discreto)
./aegis_sonar_wide_aura_voice.sh ac3 si "drammedy.mkv" 640k aura

# Mix piatti / surround inutili → VOICE (surround pass‑through)
./aegis_sonar_wide_aura_voice.sh ac3 no "vecchio_film.mkv" 640k voice

# Batch cartella con WIDE
./aegis_sonar_wide_aura_voice.sh eac3 no "" 768k wide
```

---

### 3️⃣ `stereo251_upmix.sh` — Upmix Stereo → 5.1

Converte tracce **stereo** in 5.1 con:
- estrazione **centrale** (mid) + crossover FC/LFE (FC HP 80 Hz, LFE LP 120 Hz + −6 dB)
- surround decorrelati (Haas) da side (FL−FR / FR−FL)
- limiter con `level=0` (coerente col processore 5.1)

**Utilizzo**
```bash
./stereo251_upmix.sh <ac3|eac3> <si|no> [file|""] [bitrate] [modern|vintage]
```

Preset:
- `modern` (default) → surround più reattivi + EQ brillante (azione/sci‑fi)
- `vintage` → surround più ritardati + roll‑off alto (stile Pro Logic)

**Esempi**
```bash
# Film moderno stereo → 5.1 (modern)
./stereo251_upmix.sh eac3 no "film_stereo.mkv" 448k modern

# Vecchio film → 5.1 più “stabile”
./stereo251_upmix.sh ac3 si "classico_1960.mkv" 640k vintage

# Batch sulla cartella (default 448k modern)
./stereo251_upmix.sh eac3 no "" 448k modern
```

---

### 4️⃣ `asmr_vr_intimate.sh` — Binaurale intimo / VR / ASMR / Cuffie

Processing **stereo** pensato per contenuti “vicini” (20–50 cm): crossfeed BS2B (J. Meier), ITD (interaural time difference), EQ psicoacustico e target LUFS per preset.

**Utilizzo**
```bash
./asmr_vr_intimate.sh [opzioni] <file1> [file2 ...]
```

**Opzioni**
```
-o <dir>      Cartella di output (default: stessa del file)
-d <mode>     Distanza simulata: whisper|near|center (default: whisper)
-k            Mantieni traccia audio originale come secondaria
-l            Attiva “Breathing LFO” (tremolo + flanger)
-f            Forza overwrite senza chiedere
-h            Help
```

Preset:
- `whisper` → target **−20 LUFS** (massima intimità, sussurro)
- `near`    → target **−19 LUFS**
- `center`  → target **−18 LUFS**

---

## 🎛️ EQ Voce Sartoriale (Canale Centrale — FC)

L’EQ voce è applicata nel processing 5.1 (e parte del concetto anche nello stereo→5.1).

### Base (comune)
- **−2.5 dB @ 230 Hz (Q 2.0)** → pulizia “fango” / bleed
- **−1.2 dB @ 350 Hz (Q 1.5)** → riduzione boxiness
- **+1.6 dB @ 1.0 kHz (Q 1.2)** → intelligibilità / chiarezza
- **+1.6 dB @ 2.5 kHz (Q 1.0)** → attacco consonanti
- **−1.2 dB @ 7.2 kHz (Q 2.5)** → controllo sibilanti

### Delta per preset (sopra la base)
- **AURA**: +1.4 dB gain + presenza lieve (1.8k/2.5k)
- **WIDE**: +2.2 dB gain + presenza media
- **AEGIS**: +1.9 dB gain + warmth a 300 Hz + presenza
- **SONAR**: +2.4 dB gain + warmth a 300 Hz + presenza più aggressiva
- **VOICE**: +3.0 dB gain + presenza massima (solo EQ “dialogue plus”, surround quasi neutri)

---

## 🧪 Workflow consigliato: misura → processa

### Opzione A: “semi‑automatica” (consigliata)
```bash
# 1) Analizza (delta è la metrica più predittiva per i preset)
./audio_analyzer.sh "" delta eac3 no 768k

# 2) Lancia il batch che viene generato
./run_processing.sh
```

### Opzione B: manuale con Audacity (quick & dirty)
1. Importa traccia 5.1
2. Isola **FC** e **SL+SR**
3. `Analyze → RMS` (o misure equivalenti)
4. Calcola Δ (SUR − FC)
5. Scegli preset coerente (AURA/SONAR/WIDE/AEGIS/VOICE)

---

## 📊 Schema decisionale (Delta SUR − FC)

<p align="left">
  <img src="guida_voice_schema.png" width="700" alt="Schema decisionale RMS">
</p>

---

## 🛋️ Layout consigliato della stanza

<p align="left">
  <img src="sonar_room_layout.png" width="700" alt="Layout stanza consigliato">
</p>

- **Front L/R**: ±30° rispetto al centro
- **Center**: centrato sotto/sopra TV, inclinato verso il punto d’ascolto
- **Surround L/R**: laterali o leggermente arretrati, non troppo alti
- **Subwoofer**: “sub crawl” per trovare la posizione ottimale

---

## 🚫 Cosa questi script NON fanno

- ❌ Non “rimixano” i frontali L/R nei processing 5.1
- ❌ Non fanno compressione aggressiva della dinamica (solo guardia su picchi)
- ❌ Non sostituiscono la calibrazione ambientale (YPAO ecc.)
- ❌ Non usano neural networks o AI: solo DSP classico, misurabile, debuggabile

---

## 🔧 Troubleshooting

### Script non parte / permessi
```bash
chmod +x *.sh
ffmpeg -version
./audio_analyzer.sh "test.mkv" probe
```

### Prompt overwrite e automazioni
Gli script usano un prompt overwrite `[s/n/t]` su `/dev/tty` (così non si rompe se stdin è reindirizzato).  
Se li lanci da un contesto senza TTY (alcuni wrapper/GUI), avviali da terminale.

### Audio troppo forte/basso
- Nel processing 5.1 il limiter ha `level=0`: **non** fa auto‑gain.
- Se serve, gestisci il gain a monte (o ritocca i `volume=` nei blocchi EQ/preset).

### Surround troppo invasivi
- Prova **AURA** invece di WIDE/SONAR
- Oppure **VOICE** (surround quasi pass‑through, focus sul parlato)

---

## 📄 Licenza
MIT License — vedi `LICENSE`

---

## 👤 Autore
**Sandro (D@mocle77) Sabbioni**

> *Per riportare ordine nella Forza Sonora serve solo uno script Bash… questa è la via.*
