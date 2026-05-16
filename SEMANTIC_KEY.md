# AstralVerse — Semantisk Nyckel

> *"För att tala med kristallerna måste man förstå deras språk."*

Detta dokument kartlägger alla mystiska/ädelstens-baserade termer i projektet till deras tekniska motsvarigheter i en Sega Master System-emulator.

---

## Projekt & Namnrymd

| Mystiskt Namn     | Teknisk Betydelse              |
|-------------------|--------------------------------|
| **AstralVerse**   | Modul/namespace för emulatorn  |
| **Scrying Stone** | Huvudemulatorn (main loop)     |
| **CrystalWindow** | Gosu-fönster (rendering/UI)    |

---

## Hårdvarukomponenter

| Mystiskt Namn     | Teknisk Betydelse                        |
|-------------------|------------------------------------------|
| **GemHeart**      | Z80 CPU — processorns "hjärta"           |
| **CrystalVault**  | Minneshanterare (RAM/ROM/mappers)        |
| **VisionSprite**  | VDP (Video Display Processor) — TMS9918A |
| **MysticTouch**   | Handkontroll / I/O-portar                |

---

## CPU — GemHeart (Z80 Register)

### 8-bitars Essenser (registers)

| Ädelsten | Z80 Register | Beskrivning                      |
|----------|-------------|-----------------------------------|
| **amber**     | A (Accumulator) | Primär aritmetisk essens          |
| **beryl**     | B               | Loop-/räknar-registret            |
| **citrine**   | C               | Kanal-/port-registret             |
| **diamond**   | D               | Djup-/data-hållare                |
| **emerald**   | E               | Edge-/adress-komplement           |
| **force**     | F (Flags)       | Karma-masken (statusflaggor)      |
| **jade**      | H               | Höjd-/high-byte i HL             |
| **lapis**     | L               | Ljus-/low-byte i HL              |

### 16-bitars Själ-kärl (register-pairs)

| Själ    | Registerpair | Består av          |
|---------|-------------|-------------------|
| **soul**   | AF          | amber + force     |
| **core**   | BC          | beryl + citrine   |
| **depth**  | DE          | diamond + emerald |
| **spirit** | HL          | jade + lapis      |

### Övriga mystiska tillstånd

| Mystiskt Namn     | Teknisk Betydelse                        |
|-------------------|------------------------------------------|
| **prophecy_scroll** | PC (Program Counter)                     |
| **mana_well**       | SP (Stack Pointer)                       |
| **spirit_x**        | IX (Index Register X)                    |
| **spirit_y**        | IY (Index Register Y)                    |
| **inner_sight**     | I (Interrupt Vector)                     |
| **refresh_rune**    | R (Memory Refresh)                       |
| **ear_open_1**      | IFF1 (Interrupt Flip-Flop 1)           |
| **ear_open_2**      | IFF2 (Interrupt Flip-Flop 2)             |
| **trance_mode**     | IM (Interrupt Mode: 0/1/2)               |
| **in_trance**       | HALT (CPU är stoppad)                    |
| **pulse**           | Cycles (klockcykler per instruktion)    |
| **total_pulse**     | Totala klockcykler sedan reset           |

### Karma-masker (Flags)

| Karma        | Bit | Z80 Flag | Betydelse              |
|-------------|-----|----------|------------------------|
| **KARMA_CARRY**    | 0   | C        | Carry/Borrow           |
| **KARMA_SUBTRACT** | 1   | N        | Add/Subtract           |
| **KARMA_OVERFLOW** | 2   | P/V      | Parity/Overflow        |
| **KARMA_UNUSED_3** | 3   | —        | (bit 3 echo)           |
| **KARMA_HALF**     | 4   | H        | Half Carry             |
| **KARMA_UNUSED_5** | 5   | —        | (bit 5 echo)           |
| **KARMA_VOID**     | 6   | Z        | Zero                   |
| **KARMA_SHADOW**   | 7   | S        | Sign (negativ)         |

---

## Minne — CrystalVault

| Mystiskt Namn     | Teknisk Betydelse                        |
|-------------------|------------------------------------------|
| **crystal_shards** | RAM (8KB, $C000-$DFFF, speglad)         |
| **ancient_codex**  | ROM/Cartridge-space ($0000-$BFFF)        |
| **relic**          | Raw ROM-data (bytes)                     |
| **leyline**        | Minnesadress (16-bit)                    |
| **essence**        | Byte-värde (8-bit data)                  |
| **rune**           | Word-värde (16-bit data/address)         |
| **channel**        | `read_byte` / `read_word`                |
| **etch**           | `write_byte` / `write_word`              |
| **inscribe_codex** | Ladda ROM från array/fil                 |

---

## Grafik — VisionSprite (VDP)

| Mystiskt Namn     | Teknisk Betydelse                        |
|-------------------|------------------------------------------|
| **astral_ink**     | VRAM (16KB Video RAM)                    |
| **chroma_soul**    | CRAM (32 bytes Color RAM)                |
| **scrying_pool**   | Framebuffer (256×192 pixlar)             |
| **sigils**         | VDP Register (0–10)                     |
| **omen_line**      | IRQ-line (V-blank / H-blank interrupt)  |
| **karma**          | Status register                          |
| **moon_cycle**     | V-counter (vertikal rasterposition)       |
| **sun_cycle**      | H-counter (horisontal rasterposition)    |
| **paint_thread**   | Render scanline                          |
| **crystalize_pool**| Dumpa framebuffer till PNG (debug)       |
| **crystalize_runestones** | Dumpa tiles till PNG (debug)        |
| **runestones**     | Tiles (8×8 eller 8×16 pixelmönster)      |
| **wraiths**        | Sprites (max 64 på SMS)                  |

### VDP I/O-veilar (portar)

| Veil   | Port | Riktning | Syfte                         |
|--------|------|----------|-------------------------------|
| **$BE** | 0xBE | RW       | Data-port (VRAM/CRAM)         |
| **$BF** | 0xBF | W        | Kontroll-port (adress/register)|
| **$7E** | 0x7E | R        | V-counter                     |
| **$7F** | 0x7F | R        | H-counter                     |

---

## Inmatning — MysticTouch (Controller)

| Mystiskt Namn     | Teknisk Betydelse                        |
|-------------------|------------------------------------------|
| **left_palm**      | Joypad 1 / Port A                        |
| **right_palm**     | Joypad 2 / Port B                        |
| **gesture**        | Knapptryck                               |
| **invoke**         | `press` (knapp ned)                      |
| **release**        | `release` (knapp upp)                    |
| **channel_palms**  | Läs I/O-port $DC                         |
| **channel_aura**   | Läs I/O-port $DD (misc/reset/pen)       |

### Gester (knappar)

| Geste              | Hex  | Fysisk Knapp               |
|-------------------|------|----------------------------|
| **GESTURE_NORTH**  | 0x01 | Upp (Up)                   |
| **GESTURE_SOUTH**  | 0x02 | Ner (Down)                 |
| **GESTURE_WEST**   | 0x04 | Vänster (Left)             |
| **GESTURE_EAST**   | 0x08 | Höger (Right)              |
| **GESTURE_PRIMUS** | 0x10 | Knapp 1 / A                |
| **GESTURE_SECUNDUS**| 0x20 | Knapp 2 / B                |

---

## CPU-Instruktioner — Incantationer (urval)

| Sigil (Hex) | Mystiskt Namn      | Z80 Instruktion | Beskrivning                          |
|------------|--------------------|-----------------|--------------------------------------|
| 0x00       | **STILLNESS**      | NOP             | Gör inget, slösar 4 pulser           |
| 0x3E       | **BIND AMBER**     | LD A, n         | Ladda amber med nästa essence         |
| 0x06       | **BIND BERYL**     | LD B, n         | Ladda beryl med nästa essence         |
| 0x0E       | **BIND CITRINE**   | LD C, n         | Ladda citrine med nästa essence       |
| 0x16       | **BIND DIAMOND**   | LD D, n         | Ladda diamond med nästa essence     |
| 0x1E       | **BIND EMERALD**   | LD E, n         | Ladda emerald med nästa essence       |
| 0x26       | **BIND JADE**      | LD H, n         | Ladda jade med nästa essence          |
| 0x2E       | **BIND LAPIS**     | LD L, n         | Ladda lapis med nästa essence         |
| 0x32       | **ETCH**           | LD (nn), A      | Skriv amber till leyline nn           |
| 0x3A       | **CHANNEL AMBER**  | LD A, (nn)      | Läs leyline nn till amber             |
| 0xC3       | **LEAP**           | JP nn           | Hoppa till leyline nn                 |
| 0xCD       | **SUMMON**         | CALL nn         | Anropa subrutin på leyline nn         |
| 0xC9       | **RETURN**         | RET             | Återvänd från subrutin               |
| 0xAF       | **PURGE AMBER**    | XOR A           | Nollställ amber, sätt VOID-karma      |
| 0x76       | **ENTER TRANCE**   | HALT            | Stoppa GemHeart till omen kommer     |

---

## Metaforer & Koncept

| Mystisk Metafor           | Tekniskt Koncept                          |
|---------------------------|-------------------------------------------|
| **draw_sigil**            | Fetch byte (hämta nästa opcode/operand)  |
| **draw_rune**             | Fetch word (16-bit hämtning)              |
| **push_soul / pop_soul**  | Stack-operation (push/pop 16-bit)         |
| **seal_karma**            | Sätt/rens flag-bit                        |
| **divine_whisper**        | Interrupt / avbrottshantering             |
| **walk_leyline**          | Increment VDP address register            |
| **etch_command**          | VDP register/address setup (2 writes)     |
| **etch_ink**              | VDP VRAM/CRAM write                       |
| **channel_ink**           | VDP VRAM read                             |
| **absorb_codex**          | Ladda ROM-fil                             |
| **gaze_frame**            | Kör en komplett frame (CPU + VDP-loop)   |
| **awaken**                | Starta Gosu-fönstret                      |
| **attune**                | Reset / initialisera komponent            |

---

## Bygg & Kör

| Kommando | Beskrivning |
|----------|-------------|
| `bundle install` | Sammankalla alla gem-beroenden |
| `bundle exec rspec` | Kör de heliga testerna (31 st) |
| `bin/crystal <rom>` | Väck Scrying Stone med en relic |

---

*"Varje kristall pulserar i takt med klockan. Varje leyline leder till en ny vision."*
