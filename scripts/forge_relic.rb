#!/usr/bin/env ruby

# Forge a minimal test relic (SMS ROM) for the AstralVerse
# This creates a simple ROM that the GemHeart can execute

require_relative '../lib/astral_verse'

OUTPUT_PATH = File.join(__dir__, '../test_relic.sms')

# Minimal SMS ROM structure:
# - TMR SEGA header at $7FF0 (not strictly needed for basic boot)
# - Some simple Z80 code
# - HALT at the end

rom = Array.new(0x8000, 0)  # 32KB minimal ROM

# Entry point at $0000 (after boot)
# We'll put some simple instructions:
# LD A, $3F       ; 3E 3F
# LD ($C000), A   ; 32 00 C0 — write to RAM
# LD B, $15       ; 06 15
# HALT            ; 76

entry = 0x0000
rom[entry + 0] = 0x3E   # LD A, n
rom[entry + 1] = 0x3F   # color value
rom[entry + 2] = 0x32   # LD (nn), A
rom[entry + 3] = 0x00   # low addr
rom[entry + 4] = 0xC0   # high addr ($C000)
rom[entry + 5] = 0x06   # LD B, n
rom[entry + 6] = 0x15   # value
rom[entry + 7] = 0x76   # HALT

# Add SMS header signature at $7FF0 for authenticity
header_offset = 0x7FF0
header = "TMR SEGA".bytes
header.each_with_index do |b, i|
  rom[header_offset + i] = b
end

# Checksum placeholder
rom[0x7FFA] = 0x00
rom[0x7FFB] = 0x00
rom[0x7FFC] = 0x00  # Region: 4 = Export, 5 = Japan
rom[0x7FFD] = 0x10  # ROM size: $10 = 256KB (we lie a bit for header)

# Product code & version
rom[0x7FF0] = 0x54  # T
rom[0x7FF1] = 0x4D  # M
rom[0x7FF2] = 0x52  # R

File.binwrite(OUTPUT_PATH, rom.pack('C*'))
puts "✨ Ett nytt relik har smiddits: #{OUTPUT_PATH}"
puts "   Storlek: #{rom.length} bytes (#{rom.length / 1024} KB)"
puts "   Kan nu användas med: bin/crystal #{OUTPUT_PATH}"
