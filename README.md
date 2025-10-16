# 🎧 converti_2AC3_onar.sh

> “L’audio perfetto non è solo udibile... è percepibile come un eco nel Vuoto Spaziale.”

**converti_2AC3_sonar.sh** è uno script Bash avanzato per la conversione di tracce audio **EAC3 o AC3** in **AC3 5.1 a 640kbps**, con filtri psicoacustici dinamici ottimizzati per impianti **Kenwood RV-6000 + KC-1 300HT + SW-40HT**.  
La versione **v5.4** garantisce uniformità spaziale e compensazione dinamica chirurgica su **canali vocali e LFE**, offrendo una resa sonora da vero Padawan del 5.1.

---

## ⚙️ Caratteristiche principali

- **Compatibilità Garantita**: utilizza solo filtri FFmpeg standard (`aecho`, `adelay`, `equalizer`).  
- **🌊 Modalità SONAR (Height Emulation)**  
  - Upfiring focalizzato sui canali surround (SL/SR).  
  - Illusioni HRTF (pinna) e ritardo asimmetrico (30ms/35ms) per simulare altezza.  
  - Effetto spaziale uniforme su tutti i codec.  
- **🎚️ Preset Dinamici e Nomenclatura Bitrate**  
  - Calibrazione voce/LFE variabile per uniformare il volume percepito.

---

## 🧩 Tabella Calibrazione Dinamica

| Preset   | Sorgente                  | Loudness Globale | Boost Voce (FC) | Filtro LFE           |
|----------|--------------------------|----------------|----------------|--------------------|
| atmos    | EAC3 > 700k (Atmos core) | +3.8 dB        | +2.5 dB        | -3.6 dB + Compressor |
| eac37    | EAC3 768k (High-Fidelity)| +2.5 dB        | +1.8 dB        | -2.0 dB            |
| eac36    | EAC3 640k (Standard)     | +1.2 dB        | +1.2 dB        | -1.2 dB            |
| ac3      | AC3 (Legacy Riferimento) | +0.0 dB        | +1.0 dB        | +0.0 dB            |

---

## 🧩 Requisiti

- Linux / macOS con ambiente Bash  
- **FFmpeg** (con `ffprobe`)  
- Nessun filtro esterno richiesto (no `libsoxr` o `areverb`)  

---

## 🚀 Utilizzo

```bash
./converti_2AC3_sonar.sh <sonar|nosonar> <si|no> [file.mkv] [preset]
```

### Parametri

| Parametro | Descrizione |
|-----------|------------|
| 1°        | `sonar` → Attiva Upfiring/Surround Boost Asimmetrico (Remastering Kenwood) <br> `nosonar` → Conversione clean con boost minimo |
| 2°        | `si` → Mantiene audio originale <br> `no` → Solo AC3 nel file finale |
| 3°        | `[file.mkv]` → File singolo o lascia vuoto per batch |
| 4° (opz.) | `atmos`, `eac37`, `eac36`, `ac3` → Seleziona preset di conversione |

### Esempi

- **File Singolo Atmos (Calibrazione massima, elimina originale)**

```bash
./converti_2AC3_sonar.sh sonar no "Fountain Of Youth.mkv" atmos
```

- **Conversione Batch (Sonar, mantiene originale, auto-rilevamento)**

```bash
./converti_2AC3_sonar.sh sonar si
```

- **Conversione Pulita (Solo Loudness, mantiene originale, forzando 768k)**

```bash
./converti_2AC3_sonar.sh nosonar si "Film_768k.mkv" eac37
```

---

## 🧠 Note Tecniche

- L’algoritmo SONAR combina `aecho`, `adelay` e `equalizer` per manipolare tempo e fase sui canali surround.  
- LFE e voce sono bilanciati per evitare saturazione (`alimiter=0.92`) e mantenere dialoghi chiari anche nei picchi dei master ad alta dinamica.  

---

## 📜 Licenza

MIT License

