<p align="left">
  <img src="psico_logo.png" width="700" alt="Sonary Suite Logo">
</p>

# 🎧 Psychoacoustic Suite - FFmpeg Toolkit - Giugno 2026

Suite di script **Bash + FFmpeg** per analizzare, correggere e trasformare tracce audio stereo, 5.1 e Atmos/EAC3 in modo offline, ripetibile e controllato.

> Non tutti i supereroi indossano un mantello. Alcuni lanciano `ffmpeg` e salvano i dialoghi dal multiverso del mix sbagliato.

L'idea è semplice: **misurare il mix, capire dov'è sbilanciato e applicare solo il processing necessario**. Niente DSP opaco, niente pulsanti “enhance” usciti da un film poliziesco del 2003. Solo FFmpeg, euristiche dichiarate e preset psicoacustici ragionati.

La suite è tarata per setup domestico a livello medio con diffusori compatti, subwoofer attivo, crossover intorno a **110 Hz**, ascolto a volume medio/basso e priorità all'intelligibilità della voce italiana. *(Testato su: AVR Yamaha RX-4RV, kit 5.1 JBL SCS200, subwoofer attivo Kenwood)*

### Schema di riferimento

La taratura è stata pensata sul seguente layout domestico 5.1: punto d'ascolto centrale, frontali a circa **3,6 m**, centrale sotto TV a circa **140 cm**, surround laterali/posteriori e subwoofer front-left/side-left.

<p align="left">
  <img src="sonar_room_layout.png" width="700" alt="Schema layout stanza 5.1 Sonary Suite">
</p>

Pensata per AVR usati in modalità **Straight / Pure / Direct**, con attenzione a:

- dialoghi intelligibili senza effetto megafono;
- surround presenti ma non invadenti;
- protezione dei piccoli satelliti tramite passa-alto morbidi;
- basso gestito principalmente dall'AVR/sub, senza gonfiare LFE inutilmente;
- make-up gain finale coerente tramite `volamp`, allineato fra analyzer e processore; baseline automatica v2.5 a `2.5 dB`;
- batch ripetibili su film, episodi e cartelle intere.

> Non tutti i supereroi indossano un mantello. Alcuni utilizzano `filter_complex`.

---

## Requisiti

### Software

- **FFmpeg 7+** consigliato (con **libsoxr** opzionale per qualità superiore nel resampling)
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
| `audio_analyzer_volamp_psycho.sh` | Analyzer 5.1 basato su Delta surround/centro, target domestico `-21 LUFS`, fake-5.1 gate, volamp automatico **2.5-4.0 dB** e generazione automatica di `run_processing.sh` |
| `aegis_sonar_wide_aura_voice_volamp_psycho.sh` | Processore 5.1 con preset psicoacustici, diffusori compatti crossover 110 Hz, voce italiana body-safe, master limiter a 192 kHz |
| `stereo251_upmix_psycho.sh` | Upmix stereo → 5.1 con due preset: `to51` e `quad` |
| `asmr_vr_intimate_psycho.sh` | Processing stereo per cuffie, ASMR, VR e sorgenti intime |
| `atmos_to_51_dynaudnorm_psicho.sh` | Conversione EAC3 Atmos/JOC → EAC3 5.1 DynNorm con high-pass subsonico + traccia Atmos originale preservata |

> Nota naming: il file Atmos attuale si chiama `psicho` e non `psycho`. Il README usa il nome reale del file, perché Bash non perdona i refusi e non ha mai avuto senso dell'umorismo.

---

## 🚀 Quick Start (TL;DR)

Hai una cartella piena di episodi 5.1 (es. `ac3` o `eac3`) e non vuoi leggere il manuale? 

```bash
# 1. Analizza la cartella e genera il batch consigliato
./audio_analyzer_volamp_psycho.sh . eac3 no 768k

# 2. Lancia il processing generato
./run_processing.sh
```
Fatto. I tuoi file suoneranno meglio sui dialoghi e saranno bilanciati per il tuo salotto.
Vuoi sapere cosa è successo sotto il cofano? Continua a leggere.

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
- usa la loudness integrata per stimare `volamp` come **make-up gain finale del DSP**;
- usa una base automatica v2.5 di **2.5 dB**, con salita progressiva fino a **4.0 dB** quando il file è realmente basso;
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
| `bitrate` | es. `448k`, `640k`, `768k` | `640k` AC3, `768k` EAC3 | accetta anche numeri senza `k` |

### Esempi

```bash
./audio_analyzer_volamp_psycho.sh "film.mkv"                    # singolo file, default eac3/no/768k
./audio_analyzer_volamp_psycho.sh "film.mkv" eac3 si 768k
./audio_analyzer_volamp_psycho.sh "" eac3 no 448k
./audio_analyzer_volamp_psycho.sh . eac3 si 768k
./audio_analyzer_volamp_psycho.sh --files eac3 si 768k "ep01.mkv" "ep02.mkv" "ep03.mkv"
```

### Width MS

`Width MS = I(SIDE) - I(MID)` sui surround.

| Width MS | Diagnosi |
|---:|---|
| `< -12 dB` | collassato |
| `-12 / -7 dB` | stretto |
| `-7 / -3 dB` | medio |
| `> -3 dB` | largo |

È usato come raffinamento euristico: se i surround risultano stretti/collassati può spostare la scelta verso `wide` nei casi in cui ha più senso ricostruire lateralità. HAL non guida la nave da solo, ma ogni tanto suggerisce la rotta.

### `run_processing.sh`

Il batch generato contiene comandi di questo tipo:

```bash
"$PROC" "$CODEC" "$KEEP" "film.mkv" "$BITRATE" sonar 2.5
```

Il valore finale numerico è il `volamp` consigliato per-file. Se `run_processing.sh` passa quel numero, il valore scritto nel batch prevale sul default interno del processore.

### Mappa Delta → preset

| Delta | Preset | Interpretazione |
|---:|---|---|
| `< -13 dB` | `sonar` | surround molto deboli, ricostruzione psicoacustica |
| `-13 / -10 dB` | `aura` | surround deboli, allargamento prudente |
| `-10 / -6 dB` | `wide` | surround medi, scena laterale |
| `-6 / -2 dB` | `aegis` | surround buoni, controllo e bilanciamento |
| `> -2 dB` | `voice` | surround forti o centrale coperto, priorità voce |

### Volamp

`volamp` è il **make-up gain finale della pipeline DSP**, applicato dal processore **prima del master limiter**.
Non è più pensato come piccolo boost opzionale: serve ad allineare il livello percepito del file processato a quello della sorgente, dopo EQ, compressione mirata del centrale, processing surround e controllo LFE.

L'analyzer lo stima usando la loudness integrata del file intero rispetto a un target domestico di **-21.0 LUFS**. La logica automatica v2.5 parte da **2.5 dB** e può salire fino a **4.0 dB** se il file è realmente basso.

Step automatici usati:

| Volamp | Diagnosi pratica |
|---:|---|
| `2.5 dB` | make-up DSP standard plus / volume sorgente OK o quasi OK |
| `3.0 dB` | basso / recupero netto |
| `3.5 dB` | molto basso / recupero forte |
| `4.0 dB` | estremamente basso / recupero massimo |

Protezione LRA:

| LRA | Cap automatico |
|---:|---:|
| `>= 16 LU` | massimo `3.5 dB` |
| `>= 18 LU` | massimo `3.5 dB` |

Il processore accetta comunque `0 .. 4.0 dB` come valore manuale. `0` resta utile per debug/A-B test, ma non è il comportamento automatico consigliato.

Nota pratica: sopra **3.5 dB** il processor mostra un warning perché il limiter può iniziare a lavorare in modo percepibile sui picchi; `4.0 dB` resta una modalità spinta da validare in ascolto.

---

## 2) `aegis_sonar_wide_aura_voice_volamp_psycho.sh`

Motore principale per tracce **5.1 esistenti**.

Fa processing su centrale e surround, mantenendo LFE coerente con il mix sorgente e lasciando all'AVR/sub il lavoro principale sulle basse. La taratura è ottimizzata per **diffusori compatti con AVR crossover globale a 110 Hz**. *(Baseline hardware: AVR Yamaha RX-4RV, kit JBL SCS200)*

### Resampler di qualità (SOXR)

Lo script utilizza il resampler **SOXR** (28 bit, cutoff=0.97) per il resampling finale a 192 kHz e 48 kHz, se disponibile in FFmpeg. Se FFmpeg non è compilato con libsoxr, cadrà automaticamente sul resampler fallback (qualità inferiore ma compatibile).

**Verifica disponibilità:**
```bash
ffmpeg -hide_banner -h full 2>&1 | grep -i soxr
```

Se non trovi `soxr` nell'output:
- **Linux/macOS**: Rebuilda FFmpeg con `./configure --enable-libsoxr ...`
- **Windows**: Alcuni build pre-compilati includono già SOXR. Verifica il tuo.

### Taratura generale per satelliti compatti

- centrale `FC`: high-pass morbido a **40 Hz** + EQ voce dedicato;
- frontali `FL/FR`: high-pass morbido a **40 Hz** + `FRONT_EQ`;
- surround diretti `SL/SR`: high-pass morbido a **40 Hz** nei preset;
- `LFE`: high-pass **32 Hz** + low-pass **110 Hz** + compressore picchi + limiter;
- il crossover reale dei satelliti resta demandato all'AVR, consigliato intorno a **110 Hz**;
- EQ voce italiana body-safe: lieve controllo del corpo, presenza mirata intorno a `1100/1650/2450/3800 Hz` e contenimento della brillantezza alta;
- air layer psicoacustico a **12/15 ms**, filtrato 1600-9500 Hz;
- `DECORR_GAIN` ridotti per non mascherare il centrale;
- high shelf finale leggero a 12 kHz su canali non-LFE;
- **FRONT_EQ**: EQ psicoacustico opzionale su frontali (−0.8 dB @ 320 Hz, +0.6 dB @ 5000 Hz, +0.7 dB shelf @ 11 kHz; default `g=0.7` sulla shelf per prudenza). Migliora articolazione su driver piccoli senza rubare al centro. Disabilita con `FRONT_EQ="anull"`;
- master limiter finale con `aresample=192000 -> alimiter -> aresample=48000`;
- limiter finale aggiornato: `limit=0.985:attack=2.5:release=50:level=1:latency=1`;
- limiter LFE separato e più prudente: `limit=0.94`, per controllare i picchi del sub senza farlo diventare invadente.

### Caratteristiche

- codec output `ac3` oppure `eac3`;
- preset `aegis`, `sonar`, `wide`, `aura`, `voice`;
- `volamp` finale da `0` a `4.0 dB`, default `2.5 dB`, applicato prima del master limiter;
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
| `volamp` | `0` - `4.0` | `2.5` | make-up gain finale in dB prima del master limiter; `0` = OFF/debug |

### Esempi

```bash
./aegis_sonar_wide_aura_voice_volamp_psycho.sh eac3 no "film.mkv" 768k sonar 2.5
./aegis_sonar_wide_aura_voice_volamp_psycho.sh eac3 no "film.mkv" 768k wide 3.0
./aegis_sonar_wide_aura_voice_volamp_psycho.sh ac3 si "film.mkv" 640k voice 2.5
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
- taratura per diffusori compatti + AVR crossover 110 Hz;
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

## 5) `atmos_to_51_dynaudnorm_psicho.sh`

Prepara materiale **EAC3 Atmos/JOC** per il workflow 5.1.

Produce un MKV dual-track:

1. **EAC3 5.1 Normalized**, ottenuta decodificando il bed 5.1 e applicando un `highpass` subsonico a 20 Hz + `dynaudnorm` prudente;
2. **EAC3 Atmos originale**, copiata bit-perfect.

FFmpeg non renderizza gli oggetti Atmos come un AVR: lavora sul bed multicanale decodificabile. Questo script lo normalizza a `5.1(side)`, applica `dynaudnorm` con `coupling=1` e preserva la traccia Atmos originale. Prudenza e utilità nella stessa stanza: succede raramente, godiamocela.

### Sintassi

```bash
./atmos_to_51_dynaudnorm_psicho.sh <file|directory|""> [bitrate]
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
./atmos_to_51_dynaudnorm_psicho.sh "film.mkv"
./atmos_to_51_dynaudnorm_psicho.sh "film.mkv" 768k
./atmos_to_51_dynaudnorm_psicho.sh /path/to/folder
./atmos_to_51_dynaudnorm_psicho.sh . 768k
./atmos_to_51_dynaudnorm_psicho.sh "" 768k
```

### Output

```text
<nome>-0.mkv
```

Con tracce:

```text
Traccia 1: EAC3 5.1 – Normalized
Traccia 2: EAC3 Atmos (Original)
```

---

## Benchmark orientativo

Non è un benchmark scientifico. È una mappa pratica del costo relativo, così sai dove la CPU inizierà a contemplare il sindacato.

| Script | Costo relativo | Note |
|---|---:|---|
| `audio_analyzer_volamp_psycho.sh` | Medio | misura più canali con EBU R128, quindi non è gratis |
| `stereo251_upmix_psycho.sh` | Medio | upmix + filtri + encoding audio |
| `asmr_vr_intimate_psycho.sh` | Medio | loudnorm, BS2B, EQ e limiter stereo |
| `atmos_to_51_dynaudnorm_psicho.sh` | Medio/Alto | decode EAC3/Atmos bed + dynaudnorm + re-encode EAC3 |
| `aegis_sonar_wide_aura_voice_volamp_psycho.sh` | Alto | filtergraph 5.1 completo, cuore pesante della suite |

Ordine indicativo dal più leggero al più pesante:

```text
audio_analyzer_volamp_psycho
stereo251_upmix_psycho
asmr_vr_intimate_psycho
atmos_to_51_dynaudnorm_psicho
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
./atmos_to_51_dynaudnorm_psicho.sh "film_atmos.mkv" 768k
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

### Il file processato suona troppo basso

Controlla il valore scritto da `audio_analyzer_volamp_psycho.sh` nel batch:

```bash
grep -n 'volamp=' run_processing.sh
```

Il valore finale della riga è quello realmente passato al processore:

```bash
"$PROC" "$CODEC" "$KEEP" "film.mkv" "$BITRATE" sonar 3.0
```

Scala v2.5 consigliata:

```text
2.5 = make-up standard plus
3.0 = recupero netto
3.5 = recupero forte
4.0 = massimo, da ascoltare con attenzione
```

Se arrivi spesso a `4.0 dB`, il file è realmente basso oppure il processing sta togliendo troppo livello percepito: meglio verificare con un confronto A/B contro la traccia originale preservata.

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
