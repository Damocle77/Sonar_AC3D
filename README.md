<p align="left">
  <img src="psico_logo.png" width="700" alt="Sonary Suite Logo">
</p>

# 🎧 Sonary Suite - Psychoacoustic FFmpeg Toolkit - 2026

Suite di script **Bash + FFmpeg** per analizzare, correggere e trasformare tracce audio stereo, 5.1 e Atmos/EAC3 in modo offline, ripetibile e controllato.

L'idea è semplice: **misurare il mix, capire dov'è sbilanciato e applicare solo il processing necessario**. Niente DSP opaco, niente pulsanti “enhance” usciti da un film poliziesco del 2003. Solo FFmpeg, euristiche dichiarate e preset psicoacustici ragionati.

La suite è tarata in modo particolare per un setup li livello medio **JBL SCS200 + AVR Yamaha RX**, diffusori Small, crossover AVR intorno a **100 Hz**, ascolto domestico a volume medio/basso e priorità all'intelligibilità della voce italiana.

Pensata per AVR usati in modalità **Straight / Pure / Direct**, con attenzione a:

- dialoghi intelligibili senza effetto megafono;
- surround presenti ma non invadenti;
- protezione dei piccoli satelliti JBL tramite passa-alto morbidi;
- basso gestito principalmente dall'AVR/sub, senza gonfiare LFE inutilmente;
- loudness domestico prudente tramite `volamp`;
- batch ripetibili su film, episodi e cartelle intere.

> Non tutti i supereroi indossano un mantello. Alcuni utilizzano `filter_complex`.

---

## Indice

- [Requisiti](#requisiti)
- [Installazione](#installazione)
- [Script inclusi](#script-inclusi)
- [Workflow rapido](#workflow-rapido)
- [1. Analyzer 5.1 Delta / Volamp](#1-audio_analyzer_volamp_psychosh)
- [2. Processing 5.1 Aegis / Sonar / Wide / Aura / Voice](#2-aegis_sonar_wide_aura_voice_volamp_psychosh)
- [3. Upmix stereo → 5.1 TO51 / QUAD](#3-stereo251_upmix_psychosh)
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

> Nota pratica: AC3/EAC3 vengono codificati via CPU. L'accelerazione hardware, quando c'è, riguarda quasi sempre il video. Sì, dobbiamo ancora dirlo.

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
awk --version 2>/dev/null || awk -W version
```

---

## Script inclusi

| Script | Scopo |
|---|---|
| `audio_analyzer_volamp_psycho.sh` | Analyzer 5.1 basato su Delta surround/centro, target domestico `-21 LUFS`, fake-5.1 gate e generazione automatica di `run_processing.sh` |
| `aegis_sonar_wide_aura_voice_volamp_psycho.sh` | Processore 5.1 con preset psicoacustici, taratura JBL SCS200/AVR 100 Hz, voce italiana body-safe, master limiter a 192 kHz |
| `stereo251_upmix_psycho.sh` | Upmix stereo → 5.1 con due preset: `to51` e `quad` |
| `asmr_vr_intimate_psycho.sh` | Processing stereo per cuffie, ASMR, VR e sorgenti intime |
| `atmos_to_51_dynaudnorm_volamp_psicho.sh` | Conversione EAC3 Atmos/JOC → EAC3 5.1 DynNorm con high-pass subsonico + traccia Atmos originale preservata |

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

### Stereo → 5.1 TO51 → analisi → processing

```bash
./stereo251_upmix_psycho.sh eac3 no "film_stereo.mkv" 448k to51
./audio_analyzer_volamp_psycho.sh "<file_upmix_generato>.mkv" eac3 no 768k
./run_processing.sh
```

### Stereo → 5.1 QUAD ponderato

```bash
./stereo251_upmix_psycho.sh eac3 no "concert_stereo.mkv" 448k quad
```

### Atmos/EAC3 → 5.1 DynNorm + Atmos originale

```bash
./atmos_to_51_dynaudnorm_volamp_psicho.sh "film_atmos.mkv" 768k
```

---

## 1) `audio_analyzer_volamp_psycho.sh`

Analyzer principale per tracce **5.1**. La metrica unica è **DELTA**:

```text
Delta = I(SUR) - I(FC)
```

Dove:

- `I(FC)` è la loudness integrata del centrale;
- `I(SUR)` è la media energetica dei surround SL/SR oppure BL/BR;
- valori più negativi indicano surround più arretrati rispetto al parlato.

### Caratteristiche principali

- selezione traccia 5.1 score-based: 6 canali, default, lingua italiana;
- misura `I(FC)`, `I(SL)`, `I(SR)`, `I(SUR)`, `Delta`, `I(full)`, `LRA` e `Width MS`;
- target loudness interno fisso: **`-21.0 LUFS`**, pensato per ascolto domestico;
- fake-5.1 gate: se `I(SUR) < -60 LUFS`, forza preset `voice` per evitare SONAR su rumore/dither;
- usa `Delta` per scegliere il preset;
- usa la loudness integrata per stimare `volamp`;
- usa la LRA solo come protezione per limitare `volamp` quando il mix è basso ma molto dinamico;
- usa P25 come verdetto stagionale, con bias verso episodi con surround più deboli;
- se lo spread supera 4 dB, genera preset per-file;
- salva il preset effettivo per-file, inclusi quelli forzati dal fake-5.1 gate;
- genera sempre `run_processing.sh` quando trova almeno un risultato valido.

Niente variabili da esportare prima del lancio: il target domestico `-21.0` è dentro lo script. Meno rituali da shell, più lavoro utile.

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

### Width MS

`Width MS = I(SIDE) - I(MID)` sui surround.

| Width MS | Diagnosi |
|---:|---|
| `< -12 dB` | collassato |
| `-12 / -7 dB` | stretto |
| `-7 / -3 dB` | medio |
| `> -3 dB` | largo |

Per ora è diagnostico: non modifica automaticamente il processore. HAL non deve guidare la nave senza supervisione.

### `run_processing.sh`

Il batch generato contiene comandi di questo tipo:

```bash
"$PROC" "$CODEC" "$KEEP" "film.mkv" "$BITRATE" sonar 1.5
```

Il valore finale numerico è il `volamp` consigliato per-file.

---

## 2) `aegis_sonar_wide_aura_voice_volamp_psycho.sh`

Motore principale per tracce **5.1 esistenti**.

Fa processing su centrale e surround, mantenendo LFE coerente con il mix sorgente e lasciando all'AVR/sub il lavoro principale sulle basse. La taratura è ottimizzata per **JBL SCS200 + Yamaha AVR con crossover globale a 100 Hz**.

### Taratura JBL SCS200 / AVR 100 Hz

- centrale `FC`: high-pass **102 Hz** Butterworth morbido;
- frontali `FL/FR`: high-pass **112 Hz**;
- surround diretti `SL/SR`: high-pass **112 Hz**;
- EQ voce italiana body-safe: `220 Hz -0.8 dB`, `350 Hz -0.6 dB`, `1100 Hz +0.8 dB`, controllo sibilanti intorno a `7200 Hz`;
- air layer psicoacustico a **12/15 ms**, filtrato 1600-9500 Hz;
- `DECORR_GAIN` ridotti per non mascherare il centrale;
- high shelf finale leggero a 12 kHz su canali non-LFE;
- master limiter finale con `aresample=192000 -> alimiter -> aresample=48000`.

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

---

## 3) `stereo251_upmix_psycho.sh`

Upmix offline da **stereo 2.0 a 5.1**, con preset **TO51 / QUAD PSYCHO**.

Questo script taglia il menù da JRPG e tiene due sole lame:

- `to51`: upmix 2.0 → 5.1 controllato, più cinematografico;
- `quad`: quadrifonia ponderata in container 5.1, più naturale e meno invasiva.

FL/FR restano pieni, il phantom center originale non viene sabotato, il centrale diventa un assist filtrato a **102 Hz** e i rear sono filtrati per evitare il classico delitto acustico: attori che parlano dietro la testa.

### Caratteristiche

- input stereo 2 canali;
- output AC3/EAC3 5.1(side);
- preset `to51` e `quad`;
- taratura JBL SCS200 + AVR Yamaha crossover 100 Hz;
- FC assist a 102 Hz;
- LFE sintetico molto prudente;
- psicoacustica leggera: delay Haas + allpass/air a basso livello;
- limiter finale con upsample 192 kHz.

### Sintassi

```bash
./stereo251_upmix_psycho.sh <ac3|eac3> <si|no> [file|""] [bitrate] [to51|quad]
```

### Parametri

| Parametro | Valori | Default | Note |
|---|---|---:|---|
| `codec` | `ac3`, `eac3` | obbligatorio | codec in uscita |
| `keep` | `si`, `no` | obbligatorio | conserva la traccia stereo originale |
| `file` | file o `""` | cartella corrente | se omesso o vuoto processa la directory corrente |
| `bitrate` | es. `448k`, `640k`, `768k`, `512` | `448k` | normalizza `512` in `512k` |
| `preset` | `to51`, `quad` | `to51` | modalità di upmix |

### Preset

| Preset | Filosofia | Uso consigliato |
|---|---|---|
| `to51` | side-matrix L-R + rear-bed psicoacustico leggero | film, serie, anime action, stereo largo |
| `quad` | FL→SL e FR→SR con delay Haas, banda limitata e air layer minimo | concerti, TV stereo, anime/film vecchi, materiale mono-ish |

### Dettaglio rapido preset

`to51`:

```text
FC_MIX=0.38, FC_VOL=0.84, FC_HP=102, LFE_VOL=0.10
rear: side-matrix + rear-bed, HP 150/230 Hz
output: file 5.1 con preset TO51
```

`quad`:

```text
FC_MIX=0.28, FC_VOL=0.78, FC_HP=102, LFE_VOL=0.08
rear: FL->SL / FR->SR, delay 16/19 ms, banda 250-8000 Hz
output: file 5.1 con preset QUAD
```

### Esempi

```bash
./stereo251_upmix_psycho.sh eac3 no "movie.mkv" 448k to51
./stereo251_upmix_psycho.sh eac3 si "concert.mkv" 640k quad
./stereo251_upmix_psycho.sh ac3 no "" 448k to51
./stereo251_upmix_psycho.sh eac3 no
```

### Tuning via variabili ambiente

I default sono già interni allo script. Le variabili restano sovrascrivibili per debug avanzato:

```bash
FC_VOL=0.80 FC_MIX=0.34 ./stereo251_upmix_psycho.sh eac3 no "movie.mkv" 448k to51
QUAD_VOL=0.52 ./stereo251_upmix_psycho.sh eac3 no "concert.mkv" 448k quad
```

Variabili utili:

| Variabile | Effetto |
|---|---|
| `FC_VOL` | volume del centrale assist |
| `FC_MIX` | quantità di mid mono mandata al centrale |
| `FC_HP` | high-pass del centrale |
| `FC_LP` | low-pass del centrale |
| `SUR_VOL` | volume componente side nel preset `to51` |
| `SUR_BED_VOL` | volume rear-bed nel preset `to51` |
| `SUR_DELAY` | ritardo side nel preset `to51` |
| `QUAD_VOL` | volume rear nel preset `quad` |
| `QUAD_DELAY_L/R` | delay rear nel preset `quad` |
| `LFE_VOL` | quantità di LFE sintetico |

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

---

## 5) `atmos_to_51_dynaudnorm_volamp_psicho.sh`

Prepara materiale **EAC3 Atmos/JOC** per il workflow 5.1.

Produce un MKV dual-track:

1. **EAC3 5.1 Dynamic Normalized**, ottenuta decodificando il bed 5.1 e applicando un `highpass` subsonico a 20 Hz + `dynaudnorm` prudente;
2. **EAC3 Atmos originale**, copiata bit-perfect.

FFmpeg non renderizza gli oggetti Atmos come un AVR: lavora sul bed multicanale decodificabile. Questo script lo normalizza a `5.1(side)`, applica `dynaudnorm` con `coupling=1` e preserva la traccia Atmos originale. Prudenza e utilità nella stessa stanza: succede raramente, godiamocela.

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
highpass=f=20:t=q:w=0.707,dynaudnorm=framelen=500:gausssize=31:peak=0.92:maxgain=4:targetrms=0:compress=0:coupling=1:altboundary=0
```

Questa configurazione è conservativa:

- `highpass=20 Hz` rimuove subsoniche inutili prima della normalizzazione;
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
| `voice` | dialoghi in primo piano, surround attenuati | centrale coperto o surround troppo forti/falso 5.1 |
| `aura` | allargamento prudente e morbido | surround deboli ma non morti |
| `wide` | scena laterale più ampia | surround medi, serve più apertura |
| `aegis` | cupola controllata, bilanciamento | surround già buoni ma da rifinire |
| `sonar` | ricostruzione psicoacustica più energica | surround molto deboli ma reali, scena piatta |

---

## Volamp

`volamp` è un gain finale prudente applicato dal processore **prima del limiter**.

L'analyzer lo stima usando la loudness integrata del file intero rispetto a un target domestico di **-21.0 LUFS**, ma limita il valore quando la LRA è alta, perché un mix cinematografico basso e dinamico non è automaticamente un file “da pompare”. Scandaloso, lo so: rispettare la dinamica.

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

### Workflow stereo → 5.1 TO51

```mermaid
flowchart LR
    A[File stereo 2.0] --> B[stereo251_upmix_psycho.sh to51]
    B --> C[File 5.1 TO51]
    C --> D[audio_analyzer_volamp_psycho.sh]
    D --> E[run_processing.sh]
    E --> F[aegis/sonar/wide/aura/voice]
    F --> G[Output finale 5.1]
```

### Workflow stereo → QUAD

```mermaid
flowchart LR
    A[File stereo 2.0] --> B[stereo251_upmix_psycho.sh quad]
    B --> C[5.1 QUAD ponderato]
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
./stereo251_upmix_psycho.sh eac3 no "film_stereo.mkv" 448k to51
```

oppure, per quadrifonia ponderata:

```bash
./stereo251_upmix_psycho.sh eac3 no "film_stereo.mkv" 448k quad
```

### Il file è Atmos/EAC3

Prima prepara il dual-track:

```bash
./atmos_to_51_dynaudnorm_volamp_psicho.sh "film_atmos.mkv" 768k
```

Poi lavora sul core 5.1 generato.

### Il centrale dell'upmix ruba scena

Abbassa prima `FC_VOL` o `FC_MIX`, non i frontali:

```bash
FC_VOL=0.78 FC_MIX=0.34 ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k to51
```

### I surround TO51 sono troppo timidi

Aumenta leggermente `SUR_VOL` o `SUR_BED_VOL`:

```bash
SUR_VOL=1.02 SUR_BED_VOL=0.20 ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k to51
```

### Il QUAD è troppo presente dietro

Riduci `QUAD_VOL`:

```bash
QUAD_VOL=0.50 ./stereo251_upmix_psycho.sh eac3 no "concert.mkv" 448k quad
```

### L'analyzer forza VOICE su alcuni file

Se vedi un warning tipo:

```text
Surround virtualmente muti: falso 5.1 / front-heavy. Forzo VOICE.
```

non è un bug: lo script sta evitando di applicare preset aggressivi su canali surround praticamente muti.

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

> Per riportare ordine nella Forza Sonora serve solo uno script Bash... questa è la via!
