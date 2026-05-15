<p align="left">
  <img src="psico_logo.png" width="700" alt="Sonary Suite Logo">
</p>

# 🎧 Sonary Suite - Psychoacoustic FFMPEG Toolkit

Suite di script **Bash + FFmpeg** per analizzare, correggere e trasformare tracce audio stereo, 5.1 e Atmos/EAC3 in modo offline, ripetibile e controllato.

L'idea è semplice: **misurare il mix, capire dov'è sbilanciato e applicare solo il processing necessario**. Niente magia nera da DSP opaco, niente pulsanti “enhance” da film poliziesco del 2003. Solo FFmpeg, euristiche dichiarate e preset psicoacustici ragionati.

Pensata per AVR usati in modalità **Straight / Pure / Direct**, con particolare attenzione a:

- intelligibilità dei dialoghi a basso volume;
- surround presenti ma non invadenti;
- frontali FL/FR il più possibile neutri;
- centrale più leggibile senza effetto megafono;
- gestione prudente del loudness tramite `volamp`;
- workflow batch per stagioni, film e cartelle intere.

> Non tutti i supereroi indossano un mantello. Alcuni litigano con `filter_complex`.

---

## Indice

- [Requisiti](#requisiti)
- [Installazione](#installazione)
- [Script inclusi](#script-inclusi)
- [Workflow rapido](#workflow-rapido)
- [1. Analyzer 5.1 Delta / Volamp](#1-audio_analyzer_volamp_psychosh)
- [2. Processing 5.1 Aegis / Sonar / Wide / Aura / Voice](#2-aegis_sonar_wide_aura_voice_volamp_psychosh)
- [3. Upmix stereo → 5.1 V7 PSY120](#3-stereo251_upmix_psychosh)
- [4. ASMR / VR Intimate stereo](#4-asmr_vr_intimate_psychosh)
- [5. Atmos/EAC3 → 5.1 DynNorm + Atmos originale](#5-atmos_to_51_dynaudnorm_volamp_psichosh)
- [Preset 5.1](#preset-51)
- [Volamp](#volamp)
- [Diagrammi pipeline](#diagrammi-pipeline)
- [Benchmark orientativo](#benchmark-orientativo)
- [Troubleshooting](#troubleshooting)

---

## Requisiti

### Software

- **FFmpeg 7+** consigliato
- **ffprobe**
- **Bash 4.x+**
- **awk** per l'analyzer

### Sistemi operativi

- Linux
- macOS
- Windows tramite **MSYS2**, **Git Bash** o **WSL2**

> Nota pratica: AC3/EAC3 vengono codificati via CPU. L'accelerazione hardware, quando c'è, riguarda quasi sempre il video. Sì, anche nel 2026 dobbiamo ancora dirlo.

---

## Installazione

```bash
git clone https://github.com/Damocle77/Sonary_Suite.git
cd Sonary_Suite
chmod +x *.sh
```

Verifica base:

```bash
ffmpeg -version
ffprobe -version
bash --version
```

---

## Script inclusi

Questa versione del README è allineata ai nomi degli script attuali:

| Script | Scopo |
|---|---|
| `audio_analyzer_volamp_psycho.sh` | Analyzer 5.1 basato su Delta surround/centro, genera sempre `run_processing.sh` se trova risultati validi |
| `aegis_sonar_wide_aura_voice_volamp_psycho.sh` | Processore 5.1 con preset psicoacustici e `volamp` finale opzionale |
| `stereo251_upmix_psycho.sh` | Upmix stereo → 5.1 V7, tarato per crossover AVR 110-120 Hz |
| `asmr_vr_intimate_psycho.sh` | Processing stereo per cuffie, ASMR, VR e sorgenti intime |
| `atmos_to_51_dynaudnorm_volamp_psicho.sh` | Conversione EAC3 Atmos/JOC → EAC3 5.1 DynNorm + traccia Atmos originale preservata |

> Nota naming: il file Atmos attuale si chiama `psicho` e non `psycho`. Il README usa il nome reale del file, perché Bash non perdona i refusi e non ha mai avuto senso dell'umorismo.

---

## Workflow rapido

### File 5.1 già esistente

```bash
./audio_analyzer_volamp_psycho.sh "film.mkv" eac3 no 768k
./run_processing.sh
```

### Intera cartella con file 5.1

```bash
./audio_analyzer_volamp_psycho.sh "" eac3 no 768k
./run_processing.sh
```

### Solo 2-3 file campione

```bash
./audio_analyzer_volamp_psycho.sh --files eac3 no 768k "ep01.mkv" "ep02.mkv" "ep03.mkv"
./run_processing.sh
```

### Stereo → 5.1 → analisi → processing

```bash
./stereo251_upmix_psycho.sh eac3 no "film_stereo.mkv" 448k modern
./audio_analyzer_volamp_psycho.sh "film_stereo_UPMIX_5.1_V7_MODERN.mkv" eac3 no 768k
./run_processing.sh
```

### Atmos/EAC3 → 5.1 DynNorm + Atmos originale

```bash
./atmos_to_51_dynaudnorm_volamp_psicho.sh "film_atmos.mkv" 768k
```

---

## 1) `audio_analyzer_volamp_psycho.sh`

Analyzer principale per tracce **5.1**. La metrica unica è ora **DELTA**:

```text
Delta = I(SUR) - I(FC)
```

Dove:

- `I(FC)` è la loudness integrata del centrale;
- `I(SUR)` è la media energetica dei surround SL/SR oppure BL/BR;
- valori più negativi indicano surround più arretrati rispetto al parlato.

L'analyzer:

- seleziona la traccia 5.1 migliore con score su canali, default e lingua italiana;
- misura `I(FC)`, `I(SL)`, `I(SR)`, `I(SUR)`, `Delta`, `I(full)`, `LRA` e `Width MS`;
- usa `Delta` per scegliere il preset;
- usa la loudness integrata per stimare `volamp`;
- usa la LRA solo come protezione per limitare `volamp` quando il mix è basso ma molto dinamico;
- usa P25 come verdetto stagionale, con bias verso gli episodi con surround più deboli;
- se lo spread supera 4 dB, genera preset per-file;
- genera sempre `run_processing.sh` quando trova almeno un risultato valido.

### Sintassi

```bash
./audio_analyzer_volamp_psycho.sh <file|directory|""> [codec] [keep] [bitrate]
./audio_analyzer_volamp_psycho.sh --files <codec> <keep> <bitrate> <file1> [file2 ...]
```

### Parametri

| Parametro | Valori | Default | Note |
|---|---|---:|---|
| `file|directory|""` | file, directory o stringa vuota | obbligatorio | `""` analizza la cartella corrente |
| `codec` | `eac3`, `ac3` | `eac3` | codec usato nel batch generato |
| `keep` | `si`, `no` | `no` | mantiene o meno la traccia originale nel processing finale |
| `bitrate` | es. `448k`, `640k`, `768k` | `448k` | accetta anche numeri senza `k` |

### Esempi

```bash
./audio_analyzer_volamp_psycho.sh "film.mkv"
./audio_analyzer_volamp_psycho.sh "film.mkv" eac3 si 768k
./audio_analyzer_volamp_psycho.sh "" eac3 no 448k
./audio_analyzer_volamp_psycho.sh . eac3 si 768k
./audio_analyzer_volamp_psycho.sh --files eac3 si 768k "ep01.mkv" "ep02.mkv" "ep03.mkv"
```

### Mappa Delta → preset

| Delta | Preset | Interpretazione |
|---:|---|---|
| `< -15 dB` | `sonar` | surround molto deboli, ricostruzione psicoacustica |
| `-15 / -10 dB` | `aura` | surround deboli, allargamento prudente |
| `-10 / -6 dB` | `wide` | surround medi, scena laterale |
| `-6 / -2 dB` | `aegis` | surround buoni, controllo e bilanciamento |
| `> -2 dB` | `voice` | surround forti o centrale coperto, priorità voce |

### `run_processing.sh`

Il batch generato contiene comandi di questo tipo:

```bash
"$PROC" "$CODEC" "$KEEP" "film.mkv" "$BITRATE" sonar 1.5
```

Il valore finale numerico è il `volamp` consigliato per-file.

---

## 2) `aegis_sonar_wide_aura_voice_volamp_psycho.sh`

Motore principale per tracce **5.1 esistenti**.

Fa processing su centrale e surround, mantenendo FL/FR e LFE il più possibile coerenti con il mix sorgente. È tarato per sistemi small/satellite con crossover intorno a **110-120 Hz**, quindi l'EQ del centrale evita il classico fango da dialogo impastato. L'umanità forse non è perduta, almeno finché taglia il centrale con criterio.

### Caratteristiche

- codec output `ac3` oppure `eac3`;
- preset `aegis`, `sonar`, `wide`, `aura`, `voice`;
- `volamp` finale opzionale da `0` a `2.5 dB`, applicato prima del limiter;
- selezione stream score-based: 6 canali, default, lingua italiana;
- layout gestiti: `5.1`, `5.1(back)`, `5.1(side)`;
- keep opzionale della traccia audio originale;
- video, sottotitoli, capitoli e allegati copiati quando presenti;
- prompt di overwrite con scelta `s/n/t`.

### Sintassi

```bash
./aegis_sonar_wide_aura_voice_volamp_psycho.sh <ac3|eac3> <si|no> [file] [bitrate] [preset] [volamp]
```

### Parametri

| Parametro | Valori | Default | Note |
|---|---|---:|---|
| `codec` | `ac3`, `eac3` | obbligatorio | codec audio in uscita |
| `keep` | `si`, `no` | obbligatorio | conserva la traccia originale come seconda traccia |
| `file` | file singolo | cartella corrente | se omesso processa i file compatibili nella directory |
| `bitrate` | es. `640k`, `768k` | `640k` AC3, `768k` EAC3 | accetta anche numeri senza suffisso |
| `preset` | `aegis`, `sonar`, `wide`, `aura`, `voice` | `sonar` | modalità surround |
| `volamp` | `0` - `2.5` | `0` | gain finale in dB prima del limiter |

### Esempi

```bash
./aegis_sonar_wide_aura_voice_volamp_psycho.sh eac3 no "film.mkv" 768k sonar 1.5
./aegis_sonar_wide_aura_voice_volamp_psycho.sh eac3 no "film.mkv" 768k wide 0
./aegis_sonar_wide_aura_voice_volamp_psycho.sh ac3 si "film.mkv" 640k voice 2
./aegis_sonar_wide_aura_voice_volamp_psycho.sh eac3 no
```

### Output

```text
<nome>_EAC3_Sonar.mkv
<nome>_EAC3_Aegis.mkv
<nome>_EAC3_Wide.mkv
<nome>_EAC3_Aura.mkv
<nome>_EAC3_Voice.mkv
```

La forma cambia in base a codec e preset.

---

## 3) `stereo251_upmix_psycho.sh`

Upmix offline da **stereo 2.0 a 5.1**, versione **V7 PSY120 Center-Body / Rear-Fill**.

Questa versione corregge il problema classico degli upmix aggressivi: non ruba la voce ai frontali per metterla tutta nel centrale. FL/FR restano pieni, il centrale diventa un **center-assist** e i surround sono costruiti con doppio motore:

- **side matrix**, quando esiste differenza L/R reale;
- **rear bed decorrelato dal mid**, utile sui contenuti quasi mono o poco spaziali.

### Caratteristiche

- input stereo 2 canali;
- output AC3/EAC3 5.1;
- preset `modern` e `vintage`;
- centrale tarato per crossover AVR **110-120 Hz**;
- HP centrale 115/120 Hz e LP dedicato;
- LFE sintetico prudente;
- nessun limiter intermedio sui surround;
- limiter finale post-join;
- parametri chiave sovrascrivibili via variabili ambiente.

### Sintassi

```bash
./stereo251_upmix_psycho.sh <ac3|eac3> <si|no> [file|""] [bitrate] [modern|vintage]
```

### Parametri

| Parametro | Valori | Default | Note |
|---|---|---:|---|
| `codec` | `ac3`, `eac3` | obbligatorio | codec in uscita |
| `keep` | `si`, `no` | obbligatorio | conserva la traccia stereo originale |
| `file` | file o `""` | cartella corrente | se omesso o vuoto processa la directory corrente |
| `bitrate` | es. `448k`, `640k`, `768k`, `512` | `448k` | normalizza `512` in `512k` |
| `preset` | `modern`, `vintage` | `modern` | carattere dei surround |

### Preset

| Preset | Uso consigliato |
|---|---|
| `modern` | rear più presenti, ariosi e decorrelati |
| `vintage` | rear più morbidi, ritardati, stile Pro Logic evoluto |

### Esempi

```bash
./stereo251_upmix_psycho.sh eac3 no "movie.mkv" 448k modern
./stereo251_upmix_psycho.sh ac3 si "" 640k vintage
./stereo251_upmix_psycho.sh eac3 no
```

### Tuning via variabili ambiente

Puoi ritoccare il comportamento senza modificare lo script:

```bash
FC_VOL=0.84 FC_MIX=0.38 ./stereo251_upmix_psycho.sh eac3 no "movie.mkv" 448k modern
```

Esempi utili:

| Variabile | Effetto |
|---|---|
| `FC_VOL` | volume del centrale |
| `FC_MIX` | quantità di mid mono mandata al centrale |
| `FC_HP` | high-pass del centrale |
| `FC_LP` | low-pass del centrale |
| `SUR_VOL` | volume componente side dei surround |
| `SUR_BED_VOL` | volume del rear bed decorrelato |
| `SUR_DELAY` | ritardo della componente surround |
| `LFE_VOL` | quantità di LFE sintetico |

### Output

```text
<nome>_UPMIX_5.1_V7_MODERN.mkv
<nome>_UPMIX_5.1_V7_VINTAGE.mkv
```

---

## 4) `asmr_vr_intimate_psycho.sh`

Processing stereo per cuffie, ASMR, VR e contenuti ravvicinati.

Integra:

- crossfeed **BS2B J. Meier**;
- ITD, Interaural Time Difference;
- EQ psicoacustico di prossimità;
- loudnorm per target LUFS coerente con il preset;
- LFO opzionale tipo “breathing”; 
- output `aac`, `opus` o `flac`;
- keep opzionale della traccia originale.

### Sintassi

```bash
./asmr_vr_intimate_psycho.sh [opzioni] <file1> [file2 ...]
```

### Opzioni

```text
-o <dir>     Cartella output, default: stessa del file
-d <mode>    whisper | near | center
-k           Mantieni audio originale come seconda traccia
-l           Attiva Breathing LFO
-c <codec>   aac | opus | flac
-b <rate>    bitrate output, default 320k, ignorato con flac
-f           Forza overwrite senza chiedere
-h           Mostra help
```

### Preset

| Preset | Target | Descrizione |
|---|---:|---|
| `whisper` | `-20 LUFS` | massima intimità, sussurri a 20-30 cm |
| `near` | `-19 LUFS` | voce vicina ma non sussurrata, 30-50 cm |
| `center` | `-18 LUFS` | sorgente frontale, spazializzazione leggera |

### Esempi

```bash
./asmr_vr_intimate_psycho.sh -d whisper -c aac -b 320k "asmr.mkv"
./asmr_vr_intimate_psycho.sh -d near -k -l -o output "clip01.mkv" "clip02.mkv"
./asmr_vr_intimate_psycho.sh -d center -c flac "voce.wav"
```

### Output

```text
<nome>_INTIMATE_WHISPER.mkv
<nome>_INTIMATE_NEAR.mkv
<nome>_INTIMATE_CENTER.mkv
```

---

## 5) `atmos_to_51_dynaudnorm_volamp_psicho.sh`

Prepara materiale **EAC3 Atmos/JOC** per il workflow 5.1.

Produce un MKV dual-track:

1. **EAC3 5.1 Dynamic Normalized**, ottenuta decodificando il bed 5.1 e applicando `dynaudnorm` prudente;
2. **EAC3 Atmos originale**, copiata bit-perfect.

FFmpeg non renderizza gli oggetti Atmos come un AVR: decodifica il bed multicanale. Questo script lo normalizza a `5.1(side)`, applica `dynaudnorm` con `coupling=1` e preserva la traccia Atmos originale per sicurezza. Per una volta, prudenza e utilità nella stessa stanza.

### Sintassi

```bash
./atmos_to_51_dynaudnorm_volamp_psicho.sh <file|directory|""> [bitrate]
```

### Parametri

| Parametro | Valori | Default | Note |
|---|---|---:|---|
| `file|directory|""` | file, directory o stringa vuota | obbligatorio | `""` usa la cartella corrente |
| `bitrate` | es. `640k`, `768k` | `640k` | bitrate della traccia EAC3 5.1 generata |

### Dynaudnorm usato

```text
dynaudnorm=framelen=500:gausssize=31:peak=0.92:maxgain=4:targetrms=0:compress=0:coupling=1:altboundary=0
```

Questa configurazione è conservativa:

- `peak=0.92` lascia headroom;
- `maxgain=4` evita boost assurdi su silenzi e code;
- `targetrms=0` disabilita il target RMS;
- `compress=0` evita compressione aggiuntiva;
- `coupling=1` preserva l'immagine surround applicando lo stesso gain ai canali.

### Esempi

```bash
./atmos_to_51_dynaudnorm_volamp_psicho.sh "film.mkv"
./atmos_to_51_dynaudnorm_volamp_psicho.sh "film.mkv" 768k
./atmos_to_51_dynaudnorm_volamp_psicho.sh /path/to/folder
./atmos_to_51_dynaudnorm_volamp_psicho.sh . 768k
./atmos_to_51_dynaudnorm_volamp_psicho.sh "" 768k
```

### Output

```text
<nome>_EAC3_51_DynNorm.mkv
```

Con tracce:

```text
Traccia 1: EAC3 5.1 – Dynamic Normalized
Traccia 2: EAC3 Atmos (Original)
```

---

## Preset 5.1

| Preset | Filosofia | Quando usarlo |
|---|---|---|
| `voice` | dialoghi in primo piano, surround attenuati | centrale coperto o surround troppo forti |
| `aura` | allargamento prudente e morbido | surround deboli ma non morti |
| `wide` | scena laterale più ampia | surround medi, serve più apertura |
| `aegis` | cupola controllata, bilanciamento | surround già buoni ma da rifinire |
| `sonar` | ricostruzione psicoacustica più energica | surround molto deboli o scena piatta |

---

## Volamp

`volamp` è un gain finale prudente applicato dal processore **prima del limiter**.

L'analyzer lo stima usando la loudness integrata del file intero, ma limita il valore quando la LRA è alta, perché un mix cinematografico basso e dinamico non è automaticamente un file “da pompare”. Scandaloso, lo so: rispettare la dinamica.

Step usati:

```text
0 dB   -> nessun incremento necessario
1.5 dB -> lieve recupero loudness
2 dB   -> boost consigliato
2.5 dB -> boost massimo prudente
```

Esempio manuale:

```bash
./aegis_sonar_wide_aura_voice_volamp_psycho.sh eac3 no "film.mkv" 768k sonar 1.5
```

---

## Diagrammi pipeline

### Workflow 5.1 standard

```mermaid
flowchart LR
    A[File con traccia 5.1] --> B[audio_analyzer_volamp_psycho.sh]
    B --> C[Delta + preset + volamp]
    C --> D[run_processing.sh]
    D --> E[aegis_sonar_wide_aura_voice_volamp_psycho.sh]
    E --> F[Output AC3/EAC3 processato]
```

### Workflow lista manuale

```mermaid
flowchart LR
    A[2-3 episodi campione] --> B[audio_analyzer --files]
    B --> C[Preset stagionale o per-file]
    C --> D[run_processing.sh]
    D --> E[Processing mirato]
```

### Workflow stereo → 5.1

```mermaid
flowchart LR
    A[File stereo 2.0] --> B[stereo251_upmix_psycho.sh]
    B --> C[File 5.1 upmixato V7]
    C --> D[audio_analyzer_volamp_psycho.sh]
    D --> E[run_processing.sh]
    E --> F[aegis/sonar/wide/aura/voice]
    F --> G[Output finale 5.1]
```

### Workflow Atmos/EAC3

```mermaid
flowchart LR
    A[File EAC3 Atmos/JOC] --> B[atmos_to_51_dynaudnorm_volamp_psicho.sh]
    B --> C[MKV dual-track: 5.1 DynNorm + Atmos originale]
    C --> D[audio_analyzer sul core 5.1]
    D --> E[run_processing.sh]
    E --> F[Processing 5.1]
```

### Workflow ASMR / VR

```mermaid
flowchart LR
    A[File stereo] --> B[asmr_vr_intimate_psycho.sh]
    B --> C[BS2B + ITD + EQ prossimità + loudnorm]
    C --> D[Output stereo cuffie]
```

---

## Benchmark orientativo

Non è un benchmark scientifico. È una mappa pratica del costo relativo, così sai dove la CPU inizierà a contemplare il sindacato.

| Script | Costo relativo | Note |
|---|---:|---|
| `audio_analyzer_volamp_psycho.sh` | Medio | misura più canali con EBU R128, quindi non è gratis |
| `stereo251_upmix_psycho.sh` | Medio | upmix + filtri + encoding audio |
| `asmr_vr_intimate_psycho.sh` | Medio | loudnorm, BS2B, EQ e limiter stereo |
| `atmos_to_51_dynaudnorm_volamp_psicho.sh` | Medio/Alto | decode EAC3/Atmos bed + dynaudnorm + re-encode EAC3 |
| `aegis_sonar_wide_aura_voice_volamp_psycho.sh` | Alto | filtergraph 5.1 completo, cuore pesante della suite |

Ordine indicativo dal più leggero al più pesante:

```text
audio_analyzer_volamp_psycho
stereo251_upmix_psycho
asmr_vr_intimate_psycho
atmos_to_51_dynaudnorm_volamp_psicho
aegis_sonar_wide_aura_voice_volamp_psycho
```

---

## Troubleshooting

### Lo script non parte

```bash
chmod +x *.sh
ffmpeg -version
ffprobe -version
```

Su Windows/MSYS2 verifica anche:

```bash
which ffmpeg
which ffprobe
which awk
```

### `run_processing.sh` punta allo script sbagliato

Controlla questa riga dentro `run_processing.sh`:

```bash
PROC="${PROC:-./aegis_sonar_wide_aura_voice_volamp_psycho.sh}"
```

Se serve, correggila manualmente.

### Voglio analizzare solo alcuni episodi, non tutta la cartella

```bash
./audio_analyzer_volamp_psycho.sh --files eac3 no 768k "ep01.mkv" "ep04.mkv" "ep08.mkv"
./run_processing.sh
```

### Il file è stereo, non 5.1

Prima fai upmix:

```bash
./stereo251_upmix_psycho.sh eac3 no "film_stereo.mkv" 448k modern
```

Poi analizza il file generato.

### Il file è Atmos/EAC3

Prima prepara il dual-track:

```bash
./atmos_to_51_dynaudnorm_volamp_psicho.sh "film_atmos.mkv" 768k
```

Poi lavora sul core 5.1 generato.

### Il centrale dell'upmix ruba scena

Abbassa prima `FC_VOL` o `FC_MIX`, non i frontali:

```bash
FC_VOL=0.82 FC_MIX=0.36 ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k modern
```

### I surround dell'upmix sono troppo timidi

Aumenta leggermente `SUR_VOL` o `SUR_BED_VOL`:

```bash
SUR_VOL=1.24 SUR_BED_VOL=0.32 ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k modern
```

### Output già esistente

Gli script principali chiedono conferma:

```text
[s/n/t]
```

Dove:

- `s` sovrascrive il singolo file;
- `n` salta;
- `t` sovrascrive tutti i successivi.

---

## Cosa questi script NON fanno

- non creano Atmos reale da materiale non Atmos;
- non sostituiscono calibrazione AVR, distanza casse e livelli corretti;
- non rifanno il mix cinematografico da zero;
- non promettono miracoli su sorgenti massacrate;
- non usano AI o DSP opachi;
- non reinventano la fisica, anche se a volte FFmpeg ci prova.

---

## Licenza

MIT License

---

## Autore

**Sandro (D@mocle77) Sabbioni**

> Per riportare ordine nella Forza Sonora serve solo uno script Bash...questa è la via!
