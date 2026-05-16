# AstralVerse — Testguide & UI-dokumentation

> *"Att förstärka kristallerna börjar med att se dem."*

Denna guide visar exakt hur du testar alla delar av projektet.

---

## Förberedelse

```bash
cd /home/nichlas/EutherMaster
bundle install  # Om du inte redan gjort det
```

Skapa en mapp för ROM-filer:
```bash
mkdir -p assets/roms
```

---

## 1. Grundtester (alltid först)

Kör alla 31 automatiska tester för att bekräfta att baslogiken fungerar:

```bash
bundle exec rspec
```

**Förväntat resultat:**
```
31 examples, 0 failures
```

Om något test misslyckas, åtgärda det innan du går vidare.

---

## 2. Headless Debugger (textbaserat, inget fönster)

**Syfte:** Inspektera CPU-register, minne och spara debug-bilder — allt i terminalen.

### Steg 1: Generera ett test-ROM
```bash
bundle exec ruby scripts/forge_relic.rb
```

Detta skapar `test_relic.sms` (32 KB) med ett minimalt program.

### Steg 2: Starta debuggern
```bash
bundle exec ruby scripts/headless_debug.rb test_relic.sms
```

### Steg 3: Användning (interaktivt)
Debuggern visar en prompt: `💎 debug>`

Skriv kommandon och tryck Enter:

| Kommando | Vad händer |
|----------|------------|
| `s` | **Stega** — kör 1 Z80-instruktion och visa register |
| `d` | **Dumpa** — visa alla register (A, B, C, F, PC, SP...) |
| `f` | **Frame** — kör 1 hel frame (~59736 cykler) |
| `r 10` | **Run** — kör 10 frames i rad |
| `m C000 16` | **Memory** — läs 16 bytes från adress $C000 |
| `p` | **PNG** — spara framebuffer som bild |
| `q` | **Quit** — avsluta |

### Exempellogg
```bash
💎 debug> s
📜 PC: 0x0000  |  Sigil: 0x3E (BIND AMBER)  |  Pulses: 7
   Amber: 0x3F  |  Core: 0x0000  |  Depth: 0x0000  |  Spirit: 0x0000
   Karma: 0x00 [Z:· C:· S:·]  |  Mana Well: 0xDFF0

💎 debug> s
📜 PC: 0x0002  |  Sigil: 0x32 (ETCH)  |  Pulses: 13
   ...

💎 debug> p
🖼️  Framebuffer saved to: debug_frame_1234567890.png

💎 debug> q
👋 The debugger fades into the astral mist.
```

### Verifiering
Efter att du kört `p` ska det finnas en ny fil i mappen:
```bash
ls debug_frame_*.png
```

---

## 3. ROM Explorer (grafiskt UI, bläddra hela filsystemet)

**Syfte:** Öppna ett 1000×700 fönster med en riktig filbläddrare. Du kan navigera i hela filsystemet med musen eller tangentbordet, se mappar, och välja ROM-filer var som helst.

### Starta explorers

```bash
# Öppna från hemmappen
bundle exec ruby scripts/rom_explorer.rb

# Eller från en specifik mapp
bundle exec ruby scripts/rom_explorer.rb ~/Downloads

# Eller direkt via bin/crystal (öppnar automatiskt om inget ROM anges)
bundle exec ruby bin/crystal
```

### Användning (grafiskt fönster)

**Layout:**
```
┌──────────────────────────────────────────────────────────┐
│  ► Quick Paths │  A S T R A L   E X P L O R E R          │
│  📁 Home        │  📂 /home/user/Downloads                │
│  📁 Desktop     ├───────────────────────────────────────┤
│  📁 Documents   │ Name          Type     Size            │
│  📁 Downloads   │ 📁 ..         Parent   -               │
│                 │ 📁 roms       Folder   -               │
│                 │ 💎 game.sms   ROM      256.0 KB        │
│                 │ 📄 readme.txt File     1.2 KB          │
├─────────────────┴────────────────────────────────────────┤
│  🖱️ Click = Select | Double-Click = Open | ESC = Cancel  │
└──────────────────────────────────────────────────────────┘
```

**Mus-kontroller:**
| Handling | Funktion |
|----------|----------|
| **Ett klick** | Markera fil/mapp |
| **Dubbelklick** | Öppna mapp / Välj ROM |
| **Klicka i sidofält** | Hoppa till bokmärke (Home/Desktop/etc) |
| **Scroll-hjul upp** | Scrolla uppåt (3 rader) |
| **Scroll-hjul ner** | Scrolla nedåt (3 rader) |
| **Dra i scrollbar** | Dra för att snabbt bläddra i listan |

**Tangentbordskontroller:**
| Tangent | Funktion |
|---------|----------|
| `↑/↓` | Flytta markering (håll ner för snabb repeat) |
| `Enter` | Öppna mapp / Välj ROM |
| `←` | Gå upp en nivå |
| `Page Up/Down` | Bläddra en sida |
| `Home/End` | Hoppa till första/sista |
| `H` | Visa/dölj gömda filer |
| `ESC` | Avbryt och stäng |

> 💡 **Tips:** När du håller ner `↑` eller `↓` repeterar den snabbare och hoppar 3 rader i taget!

### Färger och symboler
| Symbol | Betydelse |
|--------|-----------|
| 📁 | Mapp |
| 💎 | ROM-fil (väljbar!) |
| 📄 | Vanlig fil |

---

## 4. Emulatorfönstret (när ROM är vald)

När du valt ett ROM öppnas emulator-fönstret.

**Storlek:** 512×432 (256×192 skalat 2× + toolbar + statusfält)

**Toolbar (längst upp):**
```
┌────────────────────────────────────────┐
│ [📂 Open] [⏯ Pause] [↻ Reset]          │
└────────────────────────────────────────┘
```
| Knapp | Funktion |
|-------|----------|
| **📂 Open** | Öppna ROM-explorern och välj en ny ROM (pausar automatiskt) |
| **⏯ Pause** | Pausa/Fortsätt emulatorn |
| **↻ Reset** | Återställ emulatorn (motsvarar `R`) |

> 💡 **Tips:** Klicka på "Open" i emulatorn för att byta ROM utan att stänga fönstret!

**Statusfält (längst ner):**
- Vänster: `● LIVE` eller `○ PAUSED`, frame-räknare, PC, Amber-värde
- Höger: `ESC = Exit | Arrows+Z/X = Input`

**Kontroller i emulatorn:**

| Tangent | Funktion |
|---------|----------|
| `↑` | Mystic Touch: GESTURE_NORTH (Upp) |
| `↓` | Mystic Touch: GESTURE_SOUTH (Ner) |
| `←` | Mystic Touch: GESTURE_WEST (Vänster) |
| `→` | Mystic Touch: GESTURE_EAST (Höger) |
| `Z` | Mystic Touch: GESTURE_PRIMUS (Knapp A) |
| `X` | Mystic Touch: GESTURE_SECUNDUS (Knapp B) |
| `SPACE` | Pausa / Fortsätt emulatorn |
| `R` | Återställ (reset) emulatorn |
| `ESC` | **Stäng emulatorn omedelbart** |

> **VIKTIGT:** Om skärmen är svart betyder det att ROM:et inte har någon synlig grafik än (t.ex. VDP-rendering inte implementerad för alla instruktioner). Tryck `ESC` för att stänga.

---

## 5. Demo-läge (grafiskt, utan ROM)

**Syfte:** Testa att Gosu-fönstret fungerar utan att ladda ett ROM.

```bash
bundle exec ruby scripts/demo_scrying.rb
```

**Vad du ska se:**
Ett 512×384 fönster med mystiska blå-lila färggradienter som fyller skärmen.

**Kontroller:**
- `SPACE` — Pausa/Fortsätt (ingenting händer egentligen, men UI-togglen fungerar)
- `ESC` — Stäng fönstret

**Användning:**
Öppna detta först om du är osäker på om Gosu fungerar. Om detta fönster visas, så fungerar grundgrafiken.

---

## 6. Snabbreferens: Alla sätt att köra

```bash
# 1. Tester
bundle exec rspec

# 2. Headless debugger (med ROM)
bundle exec ruby scripts/headless_debug.rb test_relic.sms

# 3. Headless debugger (interaktiv, ladda ROM i CLI)
bundle exec ruby scripts/headless_debug.rb
# → skriv sedan: l din_spel.sms

# 4. ROM Explorer (bläddra hela filsystemet!)
bundle exec ruby scripts/rom_explorer.rb

# 5. Testground (gamla RomPicker — nu ersatt av Explorer)
bundle exec ruby scripts/testground.rb

# 6. Direkt med bin/crystal (frågar om senaste ROM, eller öppnar browser)
bundle exec ruby bin/crystal
bundle exec ruby bin/crystal din_spel.sms

# 7. Demo-fönster (utan ROM)
bundle exec ruby scripts/demo_scrying.rb
```

---

## Remember Last ROM

Projektet sparar automatiskt det senaste ROM du laddade i en cache-fil (`.astralverse_cache`).

**När du kör utan argument:**
```bash
bundle exec ruby bin/crystal
```

Kommer du att få frågan:
```
🔮 A previous relic lingers in memory...
   /home/nichlas/EutherMaster/assets/roms/test_relic.sms
   Press [Y] to reattune, [N] to browse, or [Q] to quit

Choice [y/n/q]:
```

| Val | Händer |
|-----|--------|
| `Y` | Laddar senaste ROM direkt |
| `N` | Öppnar filbläddraren |
| `Q` | Avslutar |

**Filbläddraren** startar också automatiskt i mappen där senaste ROM:et låg.

För att rensa minnet, ta bort cache-filen:
```bash
rm .astralverse_cache
```

**Stödda format:** `.sms`, `.gg`, `.bin`, `.rom`

### Steg 2: Starta testground
```bash
bundle exec ruby scripts/testground.rb
```

### Steg 3: Användning (grafiskt fönster)

När fönstret öppnas ser du en lista med alla ROM-filer i `assets/roms/`.

**Layout:**
```
┌─────────────────────────────────────────────┐
│  A S T R A L V E R S E                      │  ← Header
│  Testground Relic Vault                     │
├─────────────────────────────────────────────┤
│  1.  din_spel.sms              256.0 KB    │  ← Lista
│  2.  ett_till_spel.gg           32.0 KB    │     (markerad = highlightad)
│  3.  test_relic.sms             32.0 KB    │
│   ...                                       │
├─────────────────────────────────────────────┤
│  ↑↓ = Navigate  |  ENTER = Select           │  ← Footer
└─────────────────────────────────────────────┘
```

**Tangentbordskontroller i ROM-väljaren:**

| Tangent | Funktion |
|---------|----------|
| `↑` (pil upp) | Flytta markering uppåt |
| `↓` (pil ner) | Flytta markering nedåt |
| `Page Up` | Bläddra upp en sida |
| `Page Down` | Bläddra ned en sida |
| `Home` | Hoppa till första filen |
| `End` | Hoppa till sista filen |
| `Enter` | **Välj markerad ROM och starta emulatorn** |
| `ESC` | Stäng testground utan att välja |

### Steg 4: Emulatorfönstret

När du trycker `Enter` öppnas emulator-fönstret med den valda ROM-filen.

**Emulatorfönster:**
- Storlek: 512×384 (256×192 skalat 2×)
- Titel: "AstralVerse Scrying Stone - Ruby"

**Emulator-kontroller:**

| Tangent | Funktion |
|---------|----------|
| `↑` | Mystic Touch: GESTURE_NORTH (Upp) |
| `↓` | Mystic Touch: GESTURE_SOUTH (Ner) |
| `←` | Mystic Touch: GESTURE_WEST (Vänster) |
| `→` | Mystic Touch: GESTURE_EAST (Höger) |
| `Z` | Mystic Touch: GESTURE_PRIMUS (Knapp A) |
| `X` | Mystic Touch: GESTURE_SECUNDUS (Knapp B) |
| `SPACE` | Pausa / Fortsätt emulatorn |
| `R` | Återställ (reset) emulatorn |
| `ESC` | Stäng fönstret |

### Felsökning

Om testground inte hittar några ROM-filer:
```
No relics found in assets/roms
Place .sms / .gg / .bin / .rom files in assets/roms/
```
→ Kontrollera att filerna finns och har rätt filändelse.

Om Gosu inte kan öppna fönster:
```
SDL initialization error...
```
→ Installera SDL2 (`sudo apt install libsdl2-dev` på Ubuntu/Debian).

---

## 4. Demo-läge (grafiskt, utan ROM)

**Syfte:** Testa att Gosu-fönstret fungerar utan att ladda ett ROM.

```bash
bundle exec ruby scripts/demo_scrying.rb
```

**Vad du ska se:**
Ett 512×384 fönster med mystiska blå-lila färggradienter som fyller skärmen.

**Kontroller:**
- `SPACE` — Pausa/Fortsätt (ingenting händer egentligen, men UI-togglen fungerar)
- `ESC` — Stäng fönstret

**Användning:**
Öppna detta först om du är osäker på om Gosu fungerar. Om detta fönster visas, så fungerar grundgrafiken.

---

## 5. Snabbreferens: Alla sätt att köra

```bash
# 1. Tester
bundle exec rspec

# 2. Headless debugger (med ROM)
bundle exec ruby scripts/headless_debug.rb din_spel.sms

# 3. Headless debugger (interaktiv, ladda ROM i CLI)
bundle exec ruby scripts/headless_debug.rb
# → skriv sedan: l din_spel.sms

# 4. ROM Picker Testground
bundle exec ruby scripts/testground.rb

# 5. ROM Picker med annan mapp
bundle exec ruby scripts/testground.rb ~/Downloads/roms

# 6. Demo-fönster (utan ROM)
bundle exec ruby scripts/demo_scrying.rb

# 7. Direkt emulator-start (utan filväljare)
bundle exec ruby bin/crystal din_spel.sms
```

---

## Vanliga frågor

**Q: Varför fungerar inte Gosu?**
A: Kontrollera att SDL2 är installerat:
```bash
# Ubuntu/Debian
sudo apt install libsdl2-dev

# macOS
brew install sdl2
```

**Q: Var sparas debug-PNG-bilderna?**
A: I projektets rot-mapp (`/home/nichlas/EutherMaster/`). Filerna heter `debug_frame_<timestamp>.png`.

**Q: Hur skapar jag ett eget test-ROM?**
A: Redigera `scripts/forge_relic.rb` — ändra instruktionerna i `rom`-arrayen. Varje byte är en Z80-instruktion eller operand.

**Q: Kan jag testa utan att ha några ROM-filer?**
A: Ja! Använd `scripts/headless_debug.rb` med det genererade `test_relic.sms`, eller kör `scripts/demo_scrying.rb`.

---

*"Varje test är en divination. Varje frame är en vision."*
