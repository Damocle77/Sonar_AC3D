<p align="left">
  <img src="psico_logo.png" width="700" alt="Sonary Suite Logo">
</p>

# 🎧 Psychoacoustic Suite - Settembre 2026

Suite di script **Bash + FFmpeg** per analizzare, normalizzare, correggere e trasformare tracce audio stereo, 5.1 ed EAC3 Atmos/JOC in modo offline, ripetibile e controllato.

> Non tutti i supereroi indossano un mantello. Alcuni usano `ffmpeg` per salvare il multiverso del mix audio.

La filosofia è semplice: **misurare prima, processare dopo**. Il Classifier dell'analyzer misura scena full-band, prominenza e timbro della voce centrale, mascheramento, width e dinamica dei surround; sceglie quindi il preset per-file più adatto e può generare un batch riproducibile. Se il file proviene dal pre-stadio Atmos, l'analyzer riconosce inoltre il marker della traccia Atmos originale e lo usa soltanto come **hint conservativo** per SONAR nei casi borderline: l'origine Atmos non forza mai il preset. Gli altri script coprono upmix stereo, preparazione Atmos/EAC3 e processing binaurale per cuffie.

La taratura 5.1 è pensata per un impianto domestico ibrido con frontali a torre 3 vie, centrale e surround compatti, tutti configurati **Small** con crossover AVR unico intorno a **110 Hz**, uno o due subwoofer attivi gestiti dall'AVR, ascolto medio/basso e priorità all'intelligibilità della voce italiana.

Setup di riferimento: **Yamaha RX-V4A**, TV **77"**, frontali **Harman Kardon 3 vie**, centrale/surround **JBL SCS200**, 2x subwoofer **Kenwood ST40**, bass management AVR a **110 Hz**. Geometria di riferimento: punto d'ascolto sul divano a circa **3,5 m** dal fronte, surround laterali a circa **4 m** orientati di circa **45°**, soffitto a circa **4,10 m**, subwoofer distribuiti frontalmente a sinistra e posteriormente a destra. Distanze, livelli, fase e bass management restano comunque responsabilità dell'AVR e della calibrazione reale della stanza.

I frontali a torre vengono comunque utilizzati come diffusori **Small**: il loro vantaggio è principalmente nella maggiore capacità dinamica e nella migliore riproduzione della gamma medio-alta, mentre il contenuto sotto il crossover resta affidato al bass management dell'AVR.

Il `FRONT_EQ` del processore mantiene il carattere del voicing originale ma riduce leggermente l'enfasi sulle alte frequenze rispetto alla taratura nata per satelliti compatti, senza introdurre widening o modifiche alla scena frontale.

## Schema di riferimento

<p align="left">
  <img src="sonar_room_layout.png" width="700" alt="Schema layout stanza 5.1 Sonary Suite">
</p>

Obiettivi principali:

- dialoghi intelligibili senza effetto megafono;
- surround coerenti ed incisivi ma non invadenti;
- basso controllato, con gestione principale demandata ad AVR e subwoofer;
- processing selettivo: SONAR (Atmos like) non viene applicato indiscriminatamente;
- make-up gain finale coerente fra analyzer e processore;
- batch ripetibili su film, episodi e cartelle intere;
- conservazione separata del percorso Atmos originale quando richiesta.

---

## Requisiti

### Software

- **FFmpeg 8.x** richiesto e supportato;
- **ffprobe**;
- **Bash 4.x+**;
- **awk** per l'analyzer;
- build FFmpeg con **libsoxr** per `stereo251_upmix...`;
- build FFmpeg con **libbs2b** per `asmr_vr_intimate...`.

La suite è sviluppata e verificata con **FFmpeg/ffprobe 8.1.2**. Non usare release con major superiore a 8 (`9.x` o successive) finché la suite non viene nuovamente validata: output testuale di `astats`/`ebur128`, opzioni dei filtri e semantica dei channel layout possono cambiare. Anche FFmpeg 7.x e precedenti sono fuori dal perimetro supportato. È consigliato usare `ffmpeg` e `ffprobe` provenienti dalla stessa build.

Gli script che impostano esplicitamente `resampler=soxr` non effettuano un fallback automatico: se il build FFmpeg non include libsoxr, il filtergraph fallisce. Lo script ASMR verifica invece `bs2b` all'avvio e termina con un errore esplicito se il filtro non è disponibile.

Verifiche utili:

```bash
ffmpeg -version
ffprobe -version
ffmpeg -hide_banner -filters 2>/dev/null | grep -w bs2b
ffmpeg -hide_banner -h filter=aresample 2>&1 | grep -i soxr
```

### Sistemi operativi

- Linux;
- macOS;
- Windows tramite MSYS2, Git Bash o WSL2.

AC3/EAC3 vengono codificati via CPU. L'accelerazione hardware, quando disponibile, riguarda normalmente il video, che in questa suite viene copiato senza ricodifica.

---

## Installazione

```bash
git clone https://github.com/Damocle77/Psicoacustics.git
cd Sonary_Suite
chmod +x *.sh
```
---

## Script inclusi

| Script | Scopo |
|---|---|
| `audio_analyzer_volamp_psycho.sh` | Classifier per 5.1: Delta surround/centro, banda e profilo tonale FC, dinamica surround, width, riconoscimento provenienza Atmos via marker, target `-21 LUFS`, volamp automatico **4.0–5.5 dB** e batch opzionale |
| `aegis_sonar_wide_aura_voice_volamp_psycho.sh` | Processore 5.1 con preset `aegis`, `sonar`, `wide`, `aura`, `voice`, profili FC/surround content-aware, peak catcher FC e controllo LFE |
| `stereo251_upmix_psycho.sh` | Upmix stereo → 5.1 plausibile: matrice L-R, centro assist, LFE minimo, output atomico/verificato e preset `quad` dedicato alla musica |
| `asmr_vr_intimate_psycho.sh` | Processing stereo per cuffie/ASMR/VR con BS2B, ITD opzionale, loudnorm post-DSP, LFO e output atomico/verificato |
| `atmos_to_51_dynaudnorm_psicho.sh` | Prepara un MKV con EAC3 5.1 normalizzata come primaria e traccia Atmos/EAC3 originale copiata come secondaria; il titolo stabile della traccia Atmos funge da marker per l'analyzer |

> Nota naming: il file Atmos mantiene il nome storico `psicho`. Il README usa il nome reale del file.

---

## Quick Start

Analisi di una cartella 5.1 e generazione del batch:

```bash
./audio_analyzer_volamp_psycho.sh eac3 no 768k si .
./run_processing.sh
```

Resta accettato anche il vecchio ordine degli argomenti:

```bash
./audio_analyzer_volamp_psycho.sh . eac3 no 768k si
```

Per eseguire solo l'analisi senza creare o modificare `run_processing.sh`:

```bash
./audio_analyzer_volamp_psycho.sh eac3 no 768k no .
```

---

# 1. `audio_analyzer_volamp_psycho.sh`

Analyzer per tracce **5.1**. Non modifica i file audio.

Il classificatore separa la scena full-band dalla banda utile alla voce:

```text
DeltaSur   = RMS(SL/SR) - RMS(FL/FR/FC)
DeltaFC    = RMS(FC) - RMS(FL/FR)
VoiceDelta = RMS 250-5000 Hz(FC) - RMS 250-5000 Hz(FL/FR)
VoiceMask  = RMS 250-5000 Hz(SL/SR) - RMS 250-5000 Hz(FC)
```

`VoiceDelta` misura la prominenza del centrale nella banda del parlato;
`VoiceMask` aumenta quando effetti e ambienza posteriori possono mascherarlo.
Le metriche full-band restano dedicate alla scelta del trattamento spaziale.

## Caratteristiche

- selezione del 5.1 score-based: lingua italiana e flag default, senza confronto con la durata del container;
- misura full-band, banda voce, `Width MS`, profilo tonale FC, dinamica surround, `I(full)`, `LRA` e Sample Peak in una sola decodifica FFmpeg;
- avanzamento leggibile ogni 15 secondi, configurabile con `ANALYZER_PROGRESS_INTERVAL`;
- Sample Peak rapido sulla sorgente; il True Peak viene misurato dove serve, sul candidato già codificato;
- profilo tonale FC `DARK`, `NORMAL`, `BRIGHT` o `SIBILANT`, con fallback prudenziale a `NORMAL`;
- profilo temporale surround `AMBIENT`, `MIXED` o `TRANSIENT`, ricavato da finestre attive da 1 secondo;
- target loudness interno: **`-21.0 LUFS`**;
- fake-5.1 gate: se i surround sono virtualmente muti, forza `voice`;
- priorità a `voice` quando il centro è debole o mascherato nella banda 250-5000 Hz;
- `sonar` per surround molto arretrati, `aura` per arretramento moderato;
- riconoscimento opzionale della provenienza Atmos tramite il titolo stabile della traccia originale `EAC3 Atmos (Original)`;
- bias Atmos prudenziale: può promuovere **solo `AURA` a `SONAR`** in una stretta zona borderline, senza scavalcare `VOICE`, `WIDE` o un profilo surround `TRANSIENT`;
- `wide` quando SL/SR risultano stretti o collassati, `aegis` per mix equilibrati;
- verdetto stagionale modale con almeno **2/3 di consenso**; altrimenti `MIXED`;
- `MIXED` anche quando lo spread di `DeltaSur` supera `4 dB`;
- volamp automatico con base **4.0 dB** e massimo **5.5 dB**;
- cap del volamp a **4.5 dB** quando `LRA >= 18 LU`;
- `run_processing.sh` opzionale tramite parametro `run=si|no`;
- colori distinti in console:
  - SONAR rosso;
  - AEGIS arancione;
  - WIDE verde;
  - AURA viola/magenta;
  - VOICE giallo.

## Sintassi

```bash
./audio_analyzer_volamp_psycho.sh <codec> <keep> <bitrate> <run> <file|directory|"">
./audio_analyzer_volamp_psycho.sh --files <codec> <keep> <bitrate> [run] <file1> [file2 ...]
```

Compatibilità: resta accettato il vecchio ordine `<file|directory|""> [codec] [keep] [bitrate] [run]`.

## Parametri

| Parametro | Valori | Default | Note |
|---|---|---:|---|
| `codec` | `eac3`, `ac3` | `eac3` | codec scritto nel batch |
| `keep` | `si`, `no` | `no` | indica al processore se conservare la traccia sorgente selezionata |
| `bitrate` | es. `448k`, `640k`, `768k` | `640k` AC3, `768k` EAC3 | accetta anche il numero senza suffisso |
| `run` | `si`, `no` | `si` | crea/aggiorna oppure non tocca `run_processing.sh` |
| `file|directory|""` | file, directory o stringa vuota | obbligatorio | `""` usa la cartella corrente |

Con `run=no`, un eventuale `run_processing.sh` già esistente **non viene sovrascritto né cancellato**.

Nella modalità `--files`, il token dopo il bitrate viene interpretato come `run` solo se è esattamente `si` o `no`; altrimenti è trattato come primo filename, mantenendo la compatibilità con la sintassi precedente.

## Esempi

```bash
# Singolo file, EAC3 768k, batch abilitato
./audio_analyzer_volamp_psycho.sh eac3 no 768k si "film.mkv"

# Solo analisi
./audio_analyzer_volamp_psycho.sh eac3 si 768k no "film.mkv"

# Cartella corrente + batch
./audio_analyzer_volamp_psycho.sh eac3 no 768k si ""

# Lista esplicita, nessun batch
./audio_analyzer_volamp_psycho.sh --files eac3 si 768k no \
  "ep01.mkv" "ep02.mkv" "ep03.mkv"

# Sintassi compatibile: run=si implicito
./audio_analyzer_volamp_psycho.sh --files eac3 si 768k \
  "ep01.mkv" "ep02.mkv"
```

## Decisione → preset

| Priorità | Condizione principale | Preset | Interpretazione |
|---:|---|---|---|
| 1 | `DeltaFC < -9 dB` | `voice` | centro full-band anormalmente debole |
| 2 | `VoiceDelta < -4.5 dB` | `voice` | voce centrale poco prominente |
| 3 | `VoiceMask > -1.5 dB` | `voice` | banda voce esposta al mascheramento posteriore |
| 4 | `DeltaSur < -13 dB` | `sonar` | surround molto arretrati, trattamento Atmos-like più energico |
| 5 | `Width MS < -7 dB` | `wide` | surround stretti/collassati, allargamento laterale |
| 6 | `DeltaSur < -7 dB` | `aura` | surround moderatamente arretrati, intervento posteriore morbido |
| 7 | altrimenti | `aegis` | scena equilibrata, trattamento DTS:X-like bilanciato |

Questa tabella descrive il **classifier base**. Se nel container è presente una traccia audio con titolo esatto `EAC3 Atmos (Original)`, l'analyzer imposta internamente `SOURCE_CLASS=ATMOS` e può applicare un bias SONAR esclusivamente dopo la decisione base:

| Provenienza | Profilo SUR | Preset base | `DeltaSur` | Risultato |
|---|---|---|---:|---|
| Atmos | `AMBIENT` | `AURA` | `< -11.5 dB` | `SONAR`, confidenza bassa, alternativa `AURA` |
| Atmos | `MIXED` | `AURA` | `< -12.0 dB` | `SONAR`, confidenza bassa, alternativa `AURA` |
| Atmos | `TRANSIENT` | qualunque | qualunque | nessun bias |
| non Atmos / marker assente | qualunque | qualunque | qualunque | classifier base invariato |

La soglia SONAR ordinaria resta quindi **`-13 dB`**. Il marker Atmos è una prova di provenienza del file intermedio, non una prova che il bed 5.1 sfrutti realmente altezza/oggetti in modo significativo. `VOICE` e `WIDE` non vengono mai sovrascritti dal bias Atmos.

Surround muti, centrale silenzioso o sbilanciamento SL/SR elevato attivano gli override di sicurezza. Se la banda 250-5000 Hz è praticamente vuota, `VoiceDelta` e `VoiceMask` vengono ignorati e resta attivo il controllo full-band.

## Width MS

```text
Width MS = RMS(SIDE) - RMS(MID)
```

| Width MS | Diagnosi |
|---:|---|
| `< -12 dB` | collassato |
| `-12 / -7 dB` | stretto |
| `-7 / -3 dB` | medio |
| `>= -3 dB` | largo |

## Profili content-aware

Il profilo tonale del centrale è indipendente dal suo livello relativo. L'analyzer misura quattro bande FC e ne confronta i rapporti:

| Banda | Intervallo |
|---|---:|
| Body | `250–800 Hz` |
| Mid | `800–1600 Hz` |
| Presence | `1600–4000 Hz` |
| Sibilance | `5000–9000 Hz` |

Da queste misure ricava `PresenceIndex` e `SibilanceIndex`. Le soglie hanno una zona neutra ampia: dati incompleti o ambigui producono `NORMAL`, evitando correzioni arbitrarie.

Per i surround, SL e SR sono analizzati in finestre da un secondo. Le finestre quasi mute vengono escluse; sulle restanti vengono calcolati crest factor combinato, percentili `P50/P90/P95/P99`, code `Tail95/Tail99` e percentuali `Hot22/Hot25`. Il picco massimo resta diagnostico e non decide da solo il profilo:

| Profilo | Interpretazione | Adattamento DSP |
|---|---|---|
| `AMBIENT` | energia diffusa e continua | delay `×1.00`, late `×1.00`, air `×1.00` |
| `MIXED` | comportamento intermedio o incerto | delay `×0.90`, late `×0.85`, air `×0.90` |
| `TRANSIENT` | effetti brevi e crest elevato | delay `×0.70`, late `×0.55`, air `×0.75` |

Servono almeno 10 finestre attive per una decisione affidabile; altrimenti viene usato `MIXED` con confidenza bassa.

## Volamp automatico

Il volamp è il make-up gain applicato dal processore ai singoli canali prima del join 5.1. Sul canale LFE viene applicato prima del limiter dedicato, così i picchi del sub vengono controllati prima del master limiter multicanale. L'analyzer usa la loudness integrata del file rispetto al target `-21 LUFS`.

| Deficit rispetto al target | Volamp |
|---:|---:|
| `< 0.8 dB` | `4.0 dB` |
| `0.8 / <1.8 dB` | `4.5 dB` |
| `1.8 / <3.0 dB` | `5.0 dB` |
| `>= 3.0 dB` | `5.5 dB` |

Protezione per mix molto dinamici:

| LRA | Cap |
|---:|---:|
| `>= 18 LU` | massimo `4.5 dB` |

Il minimo automatico resta quindi **4.0 dB**. Il cap LRA non può scendere sotto questa base.

## `run_processing.sh`

Quando `run=si`, il batch contiene righe simili a:

```bash
FC_PROFILE=normal SUR_PROFILE=ambient SOURCE_CLASS=atmos "$PROC" "$CODEC" "$KEEP" "$BITRATE" sonar 4.5 film.mkv  # Source=ATMOS AtmosBias=sonar | DeltaSur=-12.4 dB | DeltaFC=1.0 dB | VoiceDelta=2.3 dB | VoiceMask=-12.0 dB | Width=-4.1 dB | I=-21.9 LUFS
```

L'ultimo parametro numerico è il volamp realmente passato al processore. Il batch usa:

```bash
PROC="${PROC:-./aegis_sonar_wide_aura_voice_volamp_psycho.sh}"
```

Il batch usa sempre il preset per-file, derivato da `DeltaSur`, `DeltaFC`, `VoiceDelta`, `VoiceMask`, balance, `Width MS` ed eventuali override di sicurezza. Passa inoltre al processore `FC_PROFILE`, `SUR_PROFILE` e `SOURCE_CLASS`, mantenendo nel commento anche `Source=...` e `AtmosBias=...` oltre alle metriche complete. `SOURCE_CLASS` è informativa nel processore: l'eventuale bias Atmos è già stato deciso dall'analyzer e il DSP non applica un secondo override. Il P25 di `DeltaSur` è soltanto diagnostico; il verdetto stagionale richiede almeno 2/3 di consenso e non sostituisce mai il preset scritto nelle singole righe del batch.

---

# 2. `aegis_sonar_wide_aura_voice_volamp_psycho.sh`

Motore principale per tracce **5.1 esistenti**.

## Caratteristiche

- input 5.1, output AC3/EAC3 5.1(side);
- preset `aegis`, `sonar`, `wide`, `aura`, `voice`;
- selezione stream score-based: entrano solo tracce a 6 canali; lingua italiana `+300`, flag default `+200`; la durata del container non entra nel punteggio;
- layout gestiti: `5.1`, `5.1(back)`, `5.1(side)`;
- EQ voce dedicato per ogni preset;
- profilo tonale FC content-aware con correzioni statiche molto contenute e fallback `NORMAL` neutro;
- processing surround differenziato per preset;
- profilo temporale surround che adatta delay, layer tardivi e air/decorrelation senza compressori o transient shaper;
- `SOURCE_CLASS` ricevuta dall'analyzer solo a scopo informativo: nessun secondo bias o override nel processore;
- air/decorrelation layer controllato;
- trattamento LFE: high-pass `32 Hz`, low-pass `110 Hz`, volamp prima del limiter dedicato;
- diffusori mantenuti `Small`, con bass management e crossover a circa `110 Hz` affidati all'AVR; lo script applica ai canali principali solo un high-pass di sicurezza a `40 Hz`;
- `FRONT_EQ` leggermente adattato alle torri senza widening o alterazioni della scena frontale;
- volamp manuale `0–6.0 dB`, default **4.0 dB**;
- warning sopra `4.5 dB`;
- video, sottotitoli, capitoli e allegati copiati;
- keep opzionale della traccia 5.1 selezionata;
- output scritto come candidato temporaneo e pubblicato solo dopo la verifica comparativa input/output;
- peak catcher locale sul centrale, limiter master senza auto-level e controllo True Peak post-codec fail-closed;
- contatori finali ed exit code non zero se almeno un file fallisce.

## Sintassi

```bash
./aegis_sonar_wide_aura_voice_volamp_psycho.sh \
  <ac3|eac3> <si|no> <bitrate> <preset> <volamp> <file|"">
./aegis_sonar_wide_aura_voice_volamp_psycho.sh --files \
  <ac3|eac3> <si|no> <bitrate> <preset> <volamp> <file1> [file2 ...]
```

Compatibilità: resta accettato il vecchio ordine `<codec> <keep> <file|""> [bitrate] [preset] [volamp]`. Nel vecchio formato il parsing è flessibile: l'ultimo valore numerico fra `0` e `6.0` è il volamp; un numero `>=32` può essere interpretato come bitrate senza suffisso.

## Parametri

| Parametro | Valori | Default | Note |
|---|---|---:|---|
| `codec` | `ac3`, `eac3` | obbligatorio | codec in uscita |
| `keep` | `si`, `no` | obbligatorio | conserva la traccia sorgente selezionata |
| `bitrate` | `256k–640k` AC3; `256k–768k` EAC3, step da `64k` | `640k` AC3, `768k` EAC3 | valori fuori range vengono rifiutati prima dell'encoding |
| `preset` | `aegis`, `sonar`, `wide`, `aura`, `voice` | `sonar` | modalità DSP |
| `volamp` | `0–6.0` | `4.0` | make-up gain per-canale prima del join; sul LFE precede il limiter dedicato |
| `file` | file o stringa vuota | cartella corrente | `""` usa la cartella corrente |

## Catena finale

```text
split 5.1
→ EQ frontali / EQ centrale / processing surround
→ volamp individuale FL/FR/FC/SL/SR
→ LFE: HPF 32 Hz + LPF 110 Hz + volamp + limiter dedicato
→ join 5.1(side)
→ high-shelf finale sui canali non-LFE
→ master limiter 5.1
→ formato finale 48 kHz / fltp
→ encoding AC3/EAC3
```

Parametri principali:

```text
FRONT_EQ:
  -0.8 dB @ 320 Hz
  +0.4 dB @ 5 kHz
  +0.4 dB high-shelf @ 11 kHz

LFE:
  highpass 32 Hz
  lowpass 110 Hz
  alimiter limit=0.94, attack=2 ms, release=120 ms, level=0, latency=1

Master:
  high-shelf +0.4 dB @ 12 kHz sui canali non-LFE
  alimiter limit=0.94, attack=2.5 ms, release=50 ms, level=0, latency=1
  output 48 kHz / fltp / 5.1(side)
```

Il centrale usa inoltre un peak catcher locale con `limit=0.94`, attack `1.5 ms`, release `60 ms`, `level=0`. Tutti i limiter lavorano come protezione dei picchi e non come auto-level.

## Profili ricevuti dall'analyzer

Il batch imposta tre variabili d'ambiente per ogni file:

```bash
FC_PROFILE=normal SUR_PROFILE=mixed SOURCE_CLASS=atmos \
  "$PROC" "$CODEC" "$KEEP" "$BITRATE" aegis 4.0 "film.mkv"
```

`FC_PROFILE` accetta `dark`, `normal`, `bright`, `sibilant`; `SUR_PROFILE` accetta `ambient`, `mixed`, `transient`; `SOURCE_CLASS` accetta `atmos`, `unknown` o `standard`. Se il processore viene lanciato direttamente senza variabili, i fallback sono `FC_PROFILE=normal`, `SUR_PROFILE=legacy` e `SOURCE_CLASS=unknown`. `LEGACY` mantiene scale surround `1.00/1.00/1.00` e quindi il comportamento storico. Le correzioni FC sono nell'ordine di pochi decimi di dB; il profilo surround modifica soltanto delay, layer tardivi e decorrelazione. `SOURCE_CLASS` viene soltanto mostrata nel log: non modifica il DSP, perché il bias è già stato applicato dall'analyzer.

Il file prodotto resta **5.1 con un solo canale LFE**. Un eventuale impianto **5.2** distribuisce il canale `.1` ai due subwoofer tramite l'AVR; lo script non crea due canali LFE separati.

## Verifica del candidato

Il processore misura la traccia sorgente, codifica prima un file con suffisso `.partial` e confronta poi input/output. Il candidato viene pubblicato con il nome finale soltanto se supera i guard rail:

| Controllo | Soglia |
|---|---:|
| True Peak post-codec massimo | `-0.1 dBTP` provvisorio |
| Sample peak output quasi muto | `<= -80 dBFS` |
| Perdita RMS globale massima | `18 dB` |
| Rapporto minimo campioni output/input | `0.98` |
| Canale principale attivo in input | `> -65 dBFS` |
| Perdita massima FL/FR/FC/SL/SR | `24 dB` |
| Perdita massima LFE | `36 dB` |

Se la verifica fallisce o non è conclusiva, compreso un True Peak non misurabile, il comportamento è fail-closed: il file finale non viene toccato e il candidato `.partial` resta disponibile per il debug. Non viene invece confrontata la durata audio con quella del container.

## Decorrelazione

| Preset | `DECORR_GAIN` |
|---|---:|
| `sonar` | `0.055` |
| `aura` | `0.048` |
| `wide` | `0.042` |
| `aegis` | `0.034` |
| `voice` | `0` |

## Esempi

```bash
./aegis_sonar_wide_aura_voice_volamp_psycho.sh \
  eac3 no 768k sonar 4.0 "film.mkv"

./aegis_sonar_wide_aura_voice_volamp_psycho.sh \
  eac3 no 768k wide 4.5 "film.mkv"

./aegis_sonar_wide_aura_voice_volamp_psycho.sh \
  ac3 si 640k voice 4.0 "film.mkv"

# Batch nella cartella corrente
./aegis_sonar_wide_aura_voice_volamp_psycho.sh eac3 no 768k sonar 4.0 ""
```

## Output

```text
<nome>_EAC3_Sonar.mkv
<nome>_EAC3_Aegis.mkv
<nome>_EAC3_Wide.mkv
<nome>_EAC3_Aura.mkv
<nome>_EAC3_Voice.mkv
```

---

# 3. `stereo251_upmix_psycho.sh`

Upmix offline da **stereo 2.0 a 5.1**, progettato per ottenere una scena multicanale plausibile senza simulare informazioni discrete che non esistono nella sorgente.

Il preset principale è `to51`:

- FL/FR restano full-band e mantengono il ruolo principale, con `FRONT_VOL=0.96` per creare headroom;
- il centrale è un assist ricavato da `L+R`, non sostituisce completamente il phantom center;
- i surround derivano soprattutto dalla componente laterale `L-R`;
- il rear bed mono è fortemente attenuato e filtrato nella banda vocale;
- il LFE sintetico è quasi nullo, perché il bass management resta affidato all'AVR;
- delay asimmetrici e all-pass producono una decorrelazione leggera senza attività posteriore artificiale costante.

Su una sorgente mono, dual-mono o molto stretta, surround quasi silenziosi sono un risultato corretto: lo script evita deliberatamente di spostare dialoghi e musica dietro l'ascoltatore.

Il preset `quad` replica invece FL verso SL e FR verso SR con banda limitata e delay Haas. È destinato soprattutto a **musica e concerti**; non è consigliato come default per film, serie, anime o cartoon perché può trascinare dialoghi nei posteriori.

## Sintassi

```bash
./stereo251_upmix_psycho.sh \
  <ac3|eac3> <si|no> [file|""] [bitrate] [to51|quad]
```

## Parametri

| Parametro | Valori | Default | Note |
|---|---|---:|---|
| `codec` | `ac3`, `eac3` | obbligatorio | codec in uscita; la disponibilità dell'encoder viene verificata prima del processing |
| `keep` | `si`, `no` | obbligatorio | conserva la traccia stereo originale come secondaria |
| `file` | file o `""` | cartella corrente | batch se omesso o vuoto |
| `bitrate` | step da `256k` a `640k` per AC3; fino a `768k` per EAC3 | `448k` | incrementi di `64k` |
| `preset` | `to51`, `quad` | `to51` | tipo di upmix |

Il parser accetta anche `448`, `448K` o valori con suffisso `M`, poi normalizza in kbps. Valori fuori range o non allineati agli step previsti vengono rifiutati prima dell'encoding.

La selezione della traccia è score-based:

```text
stereo:   +1000
italiano: +300
default:  +200
```

Il parsing di `ffprobe` usa coppie chiave/valore e non dipende dall'ordine posizionale dei campi.

## Preset

| Preset | Filosofia | Uso indicativo |
|---|---|---|
| `to51` | side matrix `L-R`, centro assist e rear bed mono appena percettibile | film, serie, anime, cartoon e fiction stereo |
| `quad` | FL→SL e FR→SR con Haas delay e banda limitata | musica e concerti stereo |

Valori principali:

```text
COMUNE:
  FRONT_VOL=0.96

TO51:
  FC_MIX=0.32
  FC_VOL=0.86
  FC_HP=60 Hz
  FC_LP=6500 Hz
  LFE_VOL=0.035

  SUR_PAN=0.50
  SUR_VOL=0.86
  SUR_BED_VOL=0.06

  delay side L/R=14/20 ms
  delay bed  L/R=24/33 ms

  banda side=170–8500 Hz
  banda bed=320–5600 Hz
  attenuazione marcata del bed nella banda vocale

QUAD:
  FC_MIX=0.28
  FC_VOL=0.78
  FC_HP=60 Hz
  FC_LP=5200 Hz
  LFE_VOL=0.03

  QUAD_VOL=0.58
  delay L/R=16/19 ms
  banda rear=250–8000 Hz
  air layer=0.035
```

Il filtro del centrale parte da `60 Hz`, invece dei precedenti `102 Hz`, per evitare una doppia attenuazione quando l'AVR applica già il crossover globale intorno a `110 Hz`.

## Catena finale

```text
selezione stereo score-based
→ split FL/FR
→ centro assist L+R
→ LFE sintetico minimo
→ surround matrix/decorrelati
→ join 5.1(side)
→ SOXR 192 kHz / precision 28
→ alimiter limit=0.97, attack=3 ms, release=60 ms, level=0, latency=1
→ SOXR 48 kHz / precision 28 / cutoff 0.91
→ AC3/EAC3 con dialnorm -31
```

Il limiter è una protezione finale dei picchi, non un auto-level: `level=0`.

La scrittura è atomica e fail-closed. Prima del processing viene verificata la disponibilità di SOXR; dopo l'encoding il candidato nascosto viene pubblicato soltanto se supera il controllo comparativo stereo/5.1: segnale non muto, almeno il `98%` dei campioni, perdita globale/frontale entro `18 dB`, FL/FR preservati e almeno uno fra FC/SL/SR realmente sintetizzato. Un candidato non valido resta con suffisso `.part` per il debug e non sostituisce l'output precedente.

## Output

```text
<nome>_UPMIX_5.1_TO51.mkv
<nome>_UPMIX_5.1_QUAD.mkv
```

La lingua viene propagata sia alla traccia processata sia, quando `keep=si`, alla traccia stereo originale. Lo script mantiene i contatori `OK/FALLITI/SALTATI` e restituisce exit code `1` se almeno un encoding fallisce.

## Esempi

```bash
# Film, serie, anime o cartoon: preset raccomandato
./stereo251_upmix_psycho.sh eac3 si "episodio.mkv" 448k to51

# Musica o concerto
./stereo251_upmix_psycho.sh eac3 si "concerto.mkv" 640k quad

# Batch nella cartella corrente
./stereo251_upmix_psycho.sh ac3 no "" 448k to51

# Default: EAC3, 448k, TO51
./stereo251_upmix_psycho.sh eac3 no
```

## Tuning tramite ambiente

Riduzione moderata del centrale assist:

```bash
FC_VOL=0.82 FC_MIX=0.28 \
  ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k to51
```

Incremento prudente dei surround laterali, senza aumentare subito il bed mono:

```bash
SUR_VOL=0.92 \
  ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k to51
```

Riduzione dei posteriori nel preset musicale:

```bash
QUAD_VOL=0.50 \
  ./stereo251_upmix_psycho.sh eac3 no "concerto.mkv" 448k quad
```

Variabili principali:

| Variabile | Effetto |
|---|---|
| `FRONT_VOL` | livello FL/FR e headroom preventiva |
| `FC_VOL` | livello del centrale assist |
| `FC_MIX` | quantità di `L+R` inviata al centrale |
| `FC_HP`, `FC_LP` | banda del centrale |
| `SUR_PAN`, `SUR_VOL` | componente laterale `L-R` del preset `to51` |
| `SUR_BED_VOL` | livello del rear bed mono |
| `SUR_DELAY_L`, `SUR_DELAY_R` | delay asimmetrici della componente side |
| `BED_DELAY_L`, `BED_DELAY_R` | delay asimmetrici del rear bed |
| `QUAD_VOL` | livello rear del preset `quad` |
| `QUAD_DELAY_L`, `QUAD_DELAY_R` | delay rear del preset `quad` |
| `QUAD_HP`, `QUAD_LP` | banda rear del preset `quad` |
| `QUAD_AIR_VOL` | livello dell'air layer del preset `quad` |
| `LFE_VOL` | quantità di LFE sintetico |

---

# 4. `asmr_vr_intimate_psycho.sh`

Processing stereo per cuffie, ASMR, VR e sorgenti ravvicinate.

## Funzioni

- selezione stream stereo score-based;
- parser `ffprobe` chiave/valore e verifica preventiva dell'encoder scelto;
- high-pass a due poli e low-pass differenziati per preset;
- loudnorm post-DSP con target per distanza;
- crossfeed **BS2B J. Meier**;
- regolazione Mid/Side e crosstalk controllato;
- ITD tramite delay in campioni;
- EQ psicoacustico di prossimità;
- LFO opzionale `tremolo + flanger`;
- ITD disattivabile indipendentemente con `-t`;
- limiter finale posizionato **dopo ITD e LFO**;
- codec `aac`, `opus` tramite `libopus`, oppure `flac`;
- keep opzionale della traccia stereo originale;
- scrittura atomica con verifica comparativa stereo input/output;
- contatori ed exit code reali.

Lo script verifica `bs2b` e la disponibilità dell'encoder scelto prima di iniziare. Il filtro è obbligatorio per questo workflow.

## Sintassi

```bash
./asmr_vr_intimate_psycho.sh [opzioni] <file1> [file2 ...]
```

## Opzioni

```text
-o <dir>     directory di output
-d <mode>    whisper | near | center
-k           conserva la traccia originale
-l           abilita Breathing LFO
-t           disattiva ITD; consigliato per sorgenti gia' binaurali
-c <codec>   aac | opus | flac
-b <rate>    bitrate, default 320k; ignorato con FLAC
-f           forza overwrite
-h           help
```

La directory indicata con `-o` viene creata se non esiste; un errore di creazione interrompe lo script.

## Preset

| Preset | Target | Distanza | Limiter finale |
|---|---:|---:|---|
| `whisper` | `-20 LUFS`, `TP=-2.0`, `LRA=13` | 20–30 cm | `limit=0.96`, attack `2`, release `40`, `level=0`, `latency=1` |
| `near` | `-19 LUFS`, `TP=-1.8`, `LRA=12` | 30–50 cm | `limit=0.97`, attack `2.5`, release `45`, `level=0`, `latency=1` |
| `center` | `-18 LUFS`, `TP=-1.5`, `LRA=11` | frontale | `limit=0.97`, attack `3`, release `50`, `level=0`, `latency=1` |

Sequenza:

```text
band-pass
→ 48 kHz
→ BS2B
→ Mid/Side
→ crosstalk
→ EQ
→ ITD
→ LFO opzionale
→ loudnorm sul segnale gia' processato
→ 48 kHz
→ limiter finale
```

Nota: il processing è progettato per materiale stereo. Su una sorgente già binaurale, BS2B e crosstalk possono modificare gli indizi interaurali originali; usare `-t` per evitare anche il ritardo ITD aggiuntivo e verificare con confronto A/B.

La verifica rifiuta output quasi muti (`peak <= -80 dBFS`), troncati sotto il `98%` dei campioni o con perdita globale/per-canale superiore a `30 dB`. Il candidato viene scritto nella stessa directory e sostituisce atomicamente il file finale solo dopo il controllo.

## Esempi

```bash
./asmr_vr_intimate_psycho.sh \
  -d whisper -c aac -b 320k "asmr.mkv"

./asmr_vr_intimate_psycho.sh \
  -d near -k -l -o output "clip01.mkv" "clip02.mkv"

./asmr_vr_intimate_psycho.sh \
  -d center -c flac "voce.wav"
```

## Output

```text
<nome>_INTIMATE_WHISPER.mkv
<nome>_INTIMATE_NEAR.mkv
<nome>_INTIMATE_CENTER.mkv
<nome>_INTIMATE_WHISPER_NOITD.mkv
<nome>_INTIMATE_WHISPER_LFO.mkv
<nome>_INTIMATE_WHISPER_NOITD_LFO.mkv
```

---

# 5. `atmos_to_51_dynaudnorm_psicho.sh`

Pre-stadio per materiale **EAC3 Atmos/JOC**.

Lo scopo non è sostituire Atmos, ma creare due percorsi nello stesso MKV:

1. **EAC3 5.1 normalizzata**, primaria e `default`, destinata all'analyzer e agli script psicoacustici;
2. **EAC3 Atmos/EAC3 originale**, copiata bit-perfect come seconda traccia non default.

In termini tecnici FFmpeg decodifica il bed multicanale disponibile; non esegue il rendering degli oggetti Atmos come farebbe un AVR.

## Workflow previsto

```text
EAC3 Atmos/JOC originale
├─ decode bed/core multicanale
│  → 5.1(side)
│  → high-pass 20 Hz + dynaudnorm
│  → EAC3 5.1 normalizzata, traccia 1/default
└─ stream copy
   → traccia originale, traccia 2/non-default
```

Da qui si può scegliere:

```text
A. Riproduzione Atmos originale:
   selezionare la seconda traccia del file intermedio.

B. Percorso psicoacustico:
   usare la traccia EAC3 5.1 normalizzata come input di analyzer/aegis.
```

Lo script non tenta di reinserire automaticamente l'Atmos originale nei file prodotti da `aegis`; i due percorsi restano distinti.

## Sintassi

```bash
./atmos_to_51_dynaudnorm_psicho.sh [bitrate] <file|directory|"">
./atmos_to_51_dynaudnorm_psicho.sh --files <bitrate> <file1> [file2 ...]
```

Resta accettato per compatibilità il vecchio ordine `<file|directory|""> [bitrate]`.

## Parametri

| Parametro | Valori | Default | Note |
|---|---|---:|---|
| `file|directory|""` | file, directory o stringa vuota | obbligatorio | `""` usa la cartella corrente |
| `bitrate` | `256k–768k` in step da `64k` | `640k` | bitrate della EAC3 5.1 normalizzata |

## Selezione della traccia

Lo script:

- considera solo stream EAC3 con almeno 6 canali;
- cerca prima un'indicazione Atmos tramite profilo o `joc_complexity`;
- preferisce traccia default e lingua italiana;
- se Atmos non è rilevabile, usa il miglior EAC3 multicanale come fallback;
- invia il warning di fallback su `stderr`, senza contaminare il valore restituito dalla funzione di probe.

Quando Atmos è verificato, la seconda traccia riceve il titolo stabile:

```text
EAC3 Atmos (Original)
```

Questo titolo è anche il **marker di provenienza** letto dall'analyzer. Se il fallback non è verificato come Atmos, il titolo della seconda traccia diventa invece:

```text
EAC3 Multichannel (Original - Atmos non verificato)
```

e in questo caso l'analyzer non applica alcun bias Atmos.

## Integrazione con l'analyzer

L'analyzer continua ad analizzare la **prima traccia 5.1 normalizzata**. La seconda traccia non entra nelle misure RMS/EBU/FC/SUR: viene interrogato soltanto il suo titolo per determinare la provenienza.

```text
Traccia 1  EAC3 5.1 – Normalized   → misure + classifier
Traccia 2  EAC3 Atmos (Original)    → marker SOURCE_CLASS=ATMOS
```

Il marker Atmos non impone SONAR. Viene usato solo per promuovere un risultato base `AURA` a `SONAR` quando `DeltaSur` è già vicino alla soglia SONAR e la dinamica surround è compatibile: fino a `-11.5 dB` con `AMBIENT`, fino a `-12.0 dB` con `MIXED`; nessun bias con `TRANSIENT`. Questo evita di trattare come equivalente un Atmos realmente immersivo e un Atmos formalmente presente ma poco sfruttato nel mix.

## Dynaudnorm

```text
highpass=f=20:t=q:w=0.707,
dynaudnorm=
  framelen=500:
  gausssize=31:
  peak=0.92:
  maxgain=4:
  targetrms=0:
  compress=0:
  coupling=1:
  altboundary=0
```

Interpretazione:

- `highpass=20 Hz`: rimuove componente subsonica prima della normalizzazione;
- `framelen=500`: finestra da 500 ms;
- `gausssize=31`: smoothing ampio;
- `peak=0.92`: target di picco con headroom;
- `maxgain=4`: **fattore lineare massimo**, non `4 dB`; nominalmente equivale a circa `+12 dB` di ampiezza;
- `targetrms=0`: target RMS disabilitato;
- `compress=0`: compressione aggiuntiva disabilitata;
- `coupling=1`: stesso fattore di gain sui canali, preservando il bilanciamento surround;
- `altboundary=0`: modalità boundary standard.

Non viene applicato un trattamento specifico al solo LFE. Il successivo script `aegis` gestisce high-pass `32 Hz`, low-pass `110 Hz` e limiter del canale `.1`.

## Output

```text
<nome>-0.mkv
```

Con:

```text
Traccia 1: EAC3 5.1 – Normalized
           default, dialnorm -31

Traccia 2: EAC3 Atmos (Original)
           oppure EAC3 Multichannel (Original - Atmos non verificato)
           stream copy, non default
```

Lingua e metadata principali vengono propagati. Lo script mantiene contatori `OK/FALLITI/SALTATI` e restituisce exit code `1` se almeno un file fallisce.

## Esempi

```bash
./atmos_to_51_dynaudnorm_psicho.sh 640k "film.mkv"
./atmos_to_51_dynaudnorm_psicho.sh 768k "film.mkv"
./atmos_to_51_dynaudnorm_psicho.sh 640k /path/to/folder
./atmos_to_51_dynaudnorm_psicho.sh 768k ""
./atmos_to_51_dynaudnorm_psicho.sh --files 768k "film1.mkv" "film2.mkv"
```

---

# Workflow consigliati

## Sorgente 5.1 già utilizzabile

```text
AC3/EAC3 5.1
→ audio_analyzer_volamp_psycho.sh
→ run_processing.sh
→ aegis/sonar/wide/aura/voice
```

## Sorgente Atmos/JOC

```text
Atmos/JOC
→ atmos_to_51_dynaudnorm_psicho.sh
→ file dual-track:
   - 5.1 normalizzata default
   - Atmos originale secondaria
→ analyzer
   - analizza la 5.1 normalizzata
   - legge il marker della seconda traccia
   - usa Atmos solo come bias SONAR borderline
→ processing psicoacustico opzionale
```

Il file dual-track resta il riferimento per la riproduzione Atmos non alterata. Il file psicoacustico è un'alternativa separata. Il fatto che la sorgente sia Atmos non implica automaticamente l'uso di SONAR: il contenuto misurato resta il criterio principale.

## Sorgente stereo destinata al 5.1

```text
Stereo
→ stereo251_upmix_psycho.sh
→ EAC3/AC3 5.1 plausibile
```

Per film, serie, anime e cartoon usare normalmente `to51`. Il risultato dell'upmix è già un prodotto finale: un successivo passaggio con Aegis non è raccomandato come default, perché rischia di amplificare nuovamente surround sintetici e decorrelazione. Analyzer e Aegis vanno usati solo dopo misure e confronto A/B, senza boost manuali aggiuntivi non giustificati.

## Sorgente stereo per cuffie

```text
Stereo
→ asmr_vr_intimate_psycho.sh
→ AAC/Opus/FLAC stereo processato
```

---

# Benchmark orientativo

| Script | Costo relativo | Motivo principale |
|---|---:|---|
| `audio_analyzer_volamp_psycho.sh` | Medio | una sola decodifica con rami paralleli per EBU R128, RMS, bande FC e finestre surround |
| `stereo251_upmix_psycho.sh` | Medio | upmix, filtri, SOXR e encoding |
| `asmr_vr_intimate_psycho.sh` | Medio | loudnorm, BS2B, EQ, ITD/LFO e encoding |
| `atmos_to_51_dynaudnorm_psicho.sh` | Medio/Alto | decode multicanale, dynaudnorm e re-encode EAC3 |
| `aegis_sonar_wide_aura_voice_volamp_psycho.sh` | Alto | filtergraph 5.1 completo, decorrelazione, limiter e verifica comparativa dell'output |

Il costo effettivo dipende da durata, codec sorgente, CPU, storage e build FFmpeg.

---

# Troubleshooting

## Lo script non parte

```bash
chmod +x *.sh
bash -n nome_script.sh
ffmpeg -version
ffprobe -version
```

Su Windows/MSYS2/Git Bash:

```bash
which bash
which ffmpeg
which ffprobe
which awk
```

## `soxr` non disponibile

Sintomo tipico: errore nel filtro `aresample`.

Verifica:

```bash
ffmpeg -hide_banner -h filter=aresample 2>&1 | grep -i soxr
```

Serve un build FFmpeg compilato con libsoxr.

## `bs2b` non disponibile

Lo script ASMR termina prima dell'encoding.

```bash
ffmpeg -hide_banner -filters 2>/dev/null | grep -w bs2b
```

Serve un build con libbs2b.

## Non voglio creare `run_processing.sh`

```bash
./audio_analyzer_volamp_psycho.sh eac3 no 768k no .
```

Il file esistente resta intatto.

## Voglio analizzare solo alcuni episodi

```bash
./audio_analyzer_volamp_psycho.sh --files eac3 no 768k si \
  "ep01.mkv" "ep04.mkv" "ep08.mkv"
```

## `run_processing.sh` punta al processore sbagliato

Controlla:

```bash
grep -n '^PROC=' run_processing.sh
```

Valore previsto:

```bash
PROC="${PROC:-./aegis_sonar_wide_aura_voice_volamp_psycho.sh}"
```

## Il file è stereo, non 5.1

```bash
./stereo251_upmix_psycho.sh eac3 no "film_stereo.mkv" 448k to51
```

Oppure:

```bash
./stereo251_upmix_psycho.sh eac3 no "film_stereo.mkv" 448k quad
```

## Il file è Atmos/EAC3

```bash
./atmos_to_51_dynaudnorm_psicho.sh 768k "film_atmos.mkv"
```

Il risultato contiene la 5.1 normalizzata come traccia default e l'originale come seconda traccia. Se Atmos è stato verificato, la seconda traccia è marcata `EAC3 Atmos (Original)`; l'analyzer riconosce questo titolo automaticamente e segnala in console `Origine: ATMOS`. Per Atmos non alterato selezionare la seconda; per il processing usare la prima. Il marker non forza SONAR: abilita soltanto il bias borderline documentato sopra.

## L'analyzer forza VOICE

```text
Surround virtualmente muti: falso 5.1 / front-heavy. Forzo VOICE.
```

È una protezione: evita preset di ricostruzione aggressivi su canali surround quasi silenziosi.

## Il volamp sembra alto

Il minimo automatico è ora `4.0 dB`, allineato al default del processore. I valori possibili sono:

```text
4.0 = make-up DSP standard
4.5 = sorgente bassa
5.0 = sorgente molto bassa
5.5 = sorgente estremamente bassa
```

Sopra `4.5 dB` il processore mostra un warning perché il limiter può lavorare in modo più percepibile. Il gain nominale non coincide necessariamente con l'aumento LUFS finale: dipende da picchi, EQ e intervento del limiter.

## Il centrale dell'upmix ruba scena

Ridurre prima `FC_MIX`, poi eventualmente `FC_VOL`:

```bash
FC_MIX=0.28 FC_VOL=0.82 \
  ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k to51
```

## I surround TO51 sono troppo timidi

Aumentare prima la componente laterale `L-R`, senza alzare subito il bed mono:

```bash
SUR_VOL=0.92 \
  ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k to51
```

Solo se l'ambienza resta insufficiente:

```bash
SUR_VOL=0.92 SUR_BED_VOL=0.08 \
  ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k to51
```

Valori molto più alti di `SUR_BED_VOL` aumentano il rischio di udire dialoghi nei posteriori.

## I surround sono quasi muti su una sorgente mono

È il comportamento previsto. La matrice `L-R` tende ad annullare il contenuto identico sui due canali e impedisce di creare attività posteriore artificiale. Non usare `quad` per compensare su film o serie mono-ish.

## Si sentono dialoghi nei posteriori

Verificare innanzitutto di usare `to51`, non `quad`. Per ridurre ulteriormente il rear bed:

```bash
SUR_BED_VOL=0.03 \
  ./stereo251_upmix_psycho.sh eac3 no "film.mkv" 448k to51
```

## Il QUAD è troppo presente dietro

```bash
QUAD_VOL=0.50 \
  ./stereo251_upmix_psycho.sh eac3 no "concerto.mkv" 448k quad
```

## Output già esistente

Gli script principali usano:

```text
[s/n/t]
```

- `s`: sovrascrive il singolo file;
- `n`: salta;
- `t`: sovrascrive tutti i successivi.

In sessione non interattiva, un output già esistente viene normalmente saltato.

---

# Cosa la suite non fa

- non crea Atmos reale da materiale non Atmos;
- non sostituisce calibrazione, distanze, livelli e bass management dell'AVR;
- non ricostruisce informazioni assenti dalla sorgente;
- non garantisce lo stesso risultato su casse, stanza e volume differenti;

---

# Licenza

MIT License

---

# Autore

**Sandro (D@mocle77) Sabbioni**

> Per riportare ordine nella Forza Sonora serve solo uno script Bash. Questa è la via...
