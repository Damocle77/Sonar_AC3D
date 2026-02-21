<p align="center">
<img src="sonary_logo.png" width="700" alt="Sonary Suite Logo">
</p>

🎧 Sonary Suite — Sonar / Wide / Aegis / Aura / Voice

Psychoacoustic Surround Toolkit (FFmpeg-based)

Suite di script FFmpeg-based per l’elaborazione offline di tracce audio multicanale e stereo. Progettata per risolvere i disastri dei mix moderni (dialoghi incomprensibili, dinamica fuori controllo, surround muti) migliorando l'intelligibilità del parlato, la coerenza timbrica e la spazialità surround senza stravolgere il master originale.

Pensata per Sintoamplificatori (AVR) usati in modalità Straight / Pure / Direct (testata e ottimizzata su Yamaha RX-V4A).

“Non tutti i supereroi indossano un mantello… a volte basta un -filter_complex per salvare il mondo del 5.1.”

⚡ Sandro (D@mocle77) Sabbioni ⚡

…perception follows physics…

🧠 Filosofia del progetto e "Full Range"

I mix per il cinema sono pensati per sale enormi con diffusori giganteschi. Quando questi mix vengono convertiti per il mercato domestico, il risultato è spesso un pasticcio: esplosioni che fanno tremare i muri e dialoghi sussurrati.

La Sonary Suite nasce da un principio rigoroso: correggere solo ciò che serve, dove serve, e nel modo meno invasivo possibile.

Elaborazione Offline Bit-Perfect: Nessun DSP in tempo reale sul tuo sintoamplificatore che introduce latenza o distorsioni. Il lavoro pesante viene fatto da FFmpeg a monte.

Rispetto dei Frontali (FL/FR): I canali anteriori sinistro e destro restano rigorosamente neutri (pass-through totale). Se il tuo setup stereo suona bene, continuerà a suonare bene.

Architettura Full Range: Abbiamo rimosso i vecchi filtri passa-alto (160Hz). Lo script ora lascia passare l'intero spettro sonoro (20Hz-20kHz) su tutti i canali. Il Bass Management (Crossover) è delegato interamente al tuo AVR.

Chirurgia sul Centrale (FC): Il cuore del sistema è il controllo del Canale Centrale, che viene protetto e ottimizzato solo quando i surround diventano troppo invadenti.

🎛️ I Preset Psicoacustici (5.1 Core)

I preset non si scelgono "a sensazione". Ogni modalità è una catena di filtri (compand, adelay, equalizer) progettata per emulare il comportamento dei costosi DSP commerciali:

Preset

Target Commerciale

Quando usarlo

Cosa fa sotto il cofano

AURA

EXTEND 6.1 LIKE

Surround morti o assenti. Tipico di vecchi rip o streaming ultra-compressi.

Estrae l'ambienza dai canali frontali sfruttando l'Effetto Haas (micro-ritardi) e la spalma sui posteriori per rianimare la stanza (Matrix Mix).

SONAR

Simula ATMOS (5.1.2)

Surround timidi. Il segnale c'è ma è piatto e privo di spazialità.

Applica un boost secco e una curva di equalizzazione sui transienti (micro-dettagli) per dare percezione di verticalità e aria.

WIDE

EXTEND 7.1 LIKE

Mix sano e bilanciato. Vuoi solo espandere la bolla sonora latistante.

Lavora sulla fase dei canali laterali allargando il soundstage senza alterare il volume della voce. Effetto panorama chirurgico.

AEGIS

Simula NEURAL:X

Surround aggressivi (es. film d'azione frenetici, corse d'auto).

Comprime dinamicamente i surround per disciplinarli ed equalizza il Centrale sui 2.5kHz-5kHz per proteggere la voce umana dal caos ambientale.

VOICE

DIALOGUE PLUS

Caos totale / Nolan Style. Muro di suono che rende tutto inudibile.

Chirurgia d'urgenza: applica un limiter aggressivo ai surround per castrarli e sposta i dialoghi drasticamente in primo piano.

🔬 Come scegliere il preset: Analisi Manuale (La via del Sysadmin)

Abbiamo rimosso gli script di analisi automatica. Perché? Perché i container MKV sono pieni di metadati corrotti, fast-seek fallati e mappe dei canali sballate che ingannano il codice. L'unico modo per non farsi fregare è analizzare la forma d'onda reale.

Ti serve Audacity (gratuito, open source, infallibile). La metrica da cercare è l'RMS (potenza media), non il picco.

La Regola d'Oro

Calcola il Delta (differenza di volume) tra i canali Surround e il Centrale.
Formula: Delta = [RMS Surround] - [RMS Centrale]

Procedura Passo-Passo:

Trascina il tuo file video/audio dentro Audacity.

Audacity estrarrà le tracce. Nello standard SMPTE (il 99% dei casi), il Canale Centrale (FC) è la 3ª traccia.

Seleziona la traccia FC, vai su Effetti > Analizza > Misura RMS e segnati il valore (es. -21.0 dB).

Trova una traccia Surround (SL o SR) (di solito la 5ª o 6ª). Misura l'RMS (es. -27.0 dB).

Calcola il Delta: -27.0 - (-21.0) = -6.0 dB.

Il Verdetto (Mappa del Delta):

Delta < -12 dB ➔ Usa AURA (La stanza è vuota, serve vita).

Da -12 a -7 dB ➔ Usa SONAR (La stanza sussurra, serve boost).

Da -7 a -4 dB ➔ Usa WIDE (La stanza è equilibrata, serve aria).

Da -4 a 0 dB ➔ Usa AEGIS (La stanza urla, serve protezione).

Delta > 0 dB ➔ Usa VOICE (L'orchestra sta uccidendo i dialoghi).

🛠️ Moduli della Suite e Sintassi

1. Il Motore Principale 5.1 (aegis_sonar_wide_aura_voice_gemini.sh)

# Sintassi: ./script <ac3|eac3> <si|no> "File.mkv" <bitrate> <preset>
./aegis_sonar_wide_aura_voice_gemini.sh eac3 no "Inception_1080p.mkv" 640k voice


2. Upmix Stereo ➔ 5.1 (stereo251_upmix_gemini.sh)
Per trasformare tracce stereo o musica in 5.1 discreti.

./stereo251_upmix_gemini.sh eac3 "Music_Video.mkv" 640k modern


3. Binaural/VR Processor (asmr_vr_intimate_gemini.sh)
Per tracce ASMR o VR (Applica il Crossfeed J.Meier).

./asmr_vr_intimate_gemini.sh -d whisper "ASMR_Recording.wav"


📐 Layout Stanza e Setup AVR

<p align="left">
<img src="https://www.google.com/search?q=https://i.ibb.co/60q80zP/Screenshot-2023-11-09-150508.png" width="700" alt="Layout stanza consigliato">
</p>

Impostazioni AVR Consigliate:

Modalità DSP: Disattivate (usa Pure Direct o Straight).

Crossover: Configura il taglio sul tuo sinto (es. 80Hz o 120Hz). Lo script manda il segnale intero, sarà il tuo hardware a smistare i bassi al Subwoofer.

🚫 Cosa questi script NON fanno

❌ Non applicano reverberi finti o effetti "stadio".

❌ Non castrano le basse frequenze (Full Range pass-through).

❌ Non sostituiscono la calibrazione ambientale del tuo microfono (YPAO, Audyssey, Dirac).

“Scegli la pillola rossa, resti nel Paese delle Meraviglie... o scegli la Sonary Suite e ti mostro come suona davvero il tuo impianto.”

...questa è la via. 🥃💻