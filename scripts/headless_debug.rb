#!/usr/bin/env ruby

require_relative '../lib/astral_verse'

class AstralDebugger
  PROMPT = "💎 debug> ".freeze

  def initialize
    @stone = AstralVerse::ScryingStone.new
    @breakpoints = Set.new
    @running = false
    @verbose = true
  end

  def load_relic(path)
    unless File.exist?(path)
      puts "❌ Relic not found: #{path}"
      return false
    end
    @stone.absorb_codex(path)
    puts "✨ Relic absorbed: #{path}"
    puts "   Size: #{@stone.crystal_vault.ancient_codex.length} bytes"
    true
  end

  def start
    puts "═" * 60
    puts "   🔮 ASTRALVERSE — Headless Debugger"
    puts "═" * 60
    puts
    puts "Commands:"
    puts "  l <path>       — Load relic (ROM)"
    puts "  s              — Step one incantation (instruction)"
    puts "  f              — Run one vision (frame)"
    puts "  r [n]          — Run n visions (default: 1)"
    puts "  d / dump       — Dump GemHeart state (registers)"
    puts "  m <addr> [n]   — Read memory at leyline (hex)"
    puts "  v / vram       — Dump VRAM state"
    puts "  c / cram       — Dump CRAM (color) state"
    puts "  b <addr>       — Set breakpoint at leyline"
    puts "  bl             — List breakpoints"
    puts "  bc             — Clear all breakpoints"
    puts "  p / png        — Dump framebuffer to PNG"
    puts "  t / tiles      — Dump tiles to PNG"
    puts "  q / quit       — Exit debugger"
    puts

    loop do
      print PROMPT
      input = $stdin.gets
      break unless input
      input = input.encode('UTF-8', invalid: :replace, undef: :replace).strip
      next if input.empty?

      cmd, *args = input.split
      next if cmd.nil? || cmd.empty?

      case cmd.downcase
      when 'l', 'load'      then cmd_load(args)
      when 's', 'step'      then cmd_step
      when 'f', 'frame'     then cmd_frame
      when 'r', 'run'       then cmd_run(args)
      when 'd', 'dump'      then cmd_dump
      when 'm', 'mem'       then cmd_mem(args)
      when 'v', 'vram'      then cmd_vram
      when 'c', 'cram'      then cmd_cram
      when 'b', 'break'     then cmd_break(args)
      when 'bl'             then cmd_break_list
      when 'bc'             then cmd_break_clear
      when 'p', 'png'       then cmd_png
      when 't', 'tiles'     then cmd_tiles
      when 'q', 'quit', 'exit' then break
      else
        puts "? Unknown command. Type 'q' to quit."
      end
    end

    puts "\n👋 The debugger fades into the astral mist."
  end

  private

  def heart
    @stone.gem_heart
  end

  def vault
    @stone.crystal_vault
  end

  def sprite
    @stone.vision_sprite
  end

  def cmd_load(args)
    path = args.join(' ')
    if path.empty?
      puts "Usage: l <path_to_relic.sms>"
      return
    end
    load_relic(path)
  end

  def cmd_step
    if heart.in_trance
      puts "💤 GemHeart is in trance (HALT). No incantation woven."
      return
    end

    pc_before = heart.prophecy_scroll
    pulse = heart.weave_incantation
    pc_after = heart.prophecy_scroll

    opcode = vault.channel_essence(pc_before)
    mnemonic = decode_mnemonic(opcode)

    puts "📜 PC: 0x%04X  |  Sigil: 0x%02X (%s)  |  Pulses: %d" % [pc_before, opcode, mnemonic, pulse]
    puts "   Amber: 0x%02X  |  Core: 0x%04X  |  Depth: 0x%04X  |  Spirit: 0x%04X" % [
      heart.amber, heart.core, heart.depth, heart.spirit
    ]
    puts "   Karma: 0x%02X [Z:%s C:%s S:%s]  |  Mana Well: 0x%04X" % [
      heart.force,
      heart.karma_void? ? '✓' : '·',
      heart.karma_carry? ? '✓' : '·',
      heart.karma_shadow? ? '✓' : '·',
      heart.mana_well
    ]
  end

  def decode_mnemonic(opcode)
    {
      0x00 => 'STILLNESS',
      0x3E => 'BIND AMBER',
      0x06 => 'BIND BERYL',
      0x0E => 'BIND CITRINE',
      0x16 => 'BIND DIAMOND',
      0x1E => 'BIND EMERALD',
      0x26 => 'BIND JADE',
      0x2E => 'BIND LAPIS',
      0x32 => 'ETCH',
      0x3A => 'CHANNEL AMBER',
      0xC3 => 'LEAP',
      0xCD => 'SUMMON',
      0xC9 => 'RETURN',
      0xAF => 'PURGE AMBER',
      0x76 => 'ENTER TRANCE',
    }[opcode] || 'UNKNOWN'
  end

  def cmd_frame
    unless @stone.instance_variable_get(:@codex_present)
      puts "⚠️ No relic loaded. Use 'l <path>' first."
      return
    end

    @stone.gaze_frame
    puts "🌙 One vision complete. Total visions: #{@stone.instance_variable_get(:@vision_count)}"
    puts "   Total pulses: #{heart.total_pulse}"
  end

  def cmd_run(args)
    n = (args[0] || 1).to_i
    n = 1 if n < 1

    unless @stone.instance_variable_get(:@codex_present)
      puts "⚠️ No relic loaded. Use 'l <path>' first."
      return
    end

    puts "🏃 Running #{n} vision(s)..."

    n.times do |i|
      @stone.gaze_frame
      puts "   Vision #{i + 1}/#{n} done (total pulses: #{heart.total_pulse})"
    end

    puts "✅ Run complete. Total visions: #{@stone.instance_variable_get(:@vision_count)}"
  end

  def cmd_dump
    puts "═" * 50
    puts "   💎 GEMHEART STATE"
    puts "═" * 50
    puts "  Amber (A)   : 0x%02X (%d)          Beryl (B)  : 0x%02X (%d)" % [heart.amber, heart.amber, heart.beryl, heart.beryl]
    puts "  Citrine (C) : 0x%02X (%d)          Diamond (D): 0x%02X (%d)" % [heart.citrine, heart.citrine, heart.diamond, heart.diamond]
    puts "  Emerald (E) : 0x%02X (%d)          Jade (H)   : 0x%02X (%d)" % [heart.emerald, heart.emerald, heart.jade, heart.jade]
    puts "  Lapis (L)   : 0x%02X (%d)          Force (F)  : 0x%02X" % [heart.lapis, heart.lapis, heart.force]
    puts "  ─────────────────────────────────────────────"
    puts "  Soul (AF)   : 0x%04X        Core (BC)  : 0x%04X" % [heart.soul, heart.core]
    puts "  Depth (DE)  : 0x%04X        Spirit (HL): 0x%04X" % [heart.depth, heart.spirit]
    puts "  ─────────────────────────────────────────────"
    puts "  Prophecy (PC): 0x%04X       Mana (SP)  : 0x%04X" % [heart.prophecy_scroll, heart.mana_well]
    puts "  Spirit X (IX): 0x%04X       Spirit Y (IY): 0x%04X" % [heart.spirit_x, heart.spirit_y]
    puts "  ─────────────────────────────────────────────"
    puts "  Karma: [S:%s Z:%s H:%s P:%s N:%s C:%s]" % [
      heart.karma_shadow? ? '✓' : '·',
      heart.karma_void? ? '✓' : '·',
      heart.karma_half? ? '✓' : '·',
      heart.karma_overflow? ? '✓' : '·',
      heart.karma_subtract? ? '✓' : '·',
      heart.karma_carry? ? '✓' : '·',
    ]
    puts "  Trance: #{heart.in_trance ? 'YES 💤' : 'NO ⚡'}  |  Ears: #{heart.ear_open_1 ? 'OPEN 👂' : 'closed'}"
    puts "  Total Pulses: #{heart.total_pulse}"
    puts "═" * 50
  end

  def cmd_mem(args)
    addr = args[0] ? args[0].to_i(16) : nil
    count = (args[1] || 16).to_i

    unless addr
      puts "Usage: m <hex_address> [count]"
      return
    end

    puts "📖 Memory at 0x%04X:" % addr
    count.times do |i|
      a = (addr + i) & 0xFFFF
      val = vault.channel_essence(a)
      print "%02X " % val
      puts if (i + 1) % 16 == 0
    end
    puts if count % 16 != 0
  end

  def cmd_vram
    puts "🎨 VRAM (Astral Ink) — first 64 bytes:"
    64.times do |i|
      val = sprite.astral_ink[i]
      print "%02X " % val
      puts if (i + 1) % 16 == 0
    end
  end

  def cmd_cram
    puts "🌈 CRAM (Chroma Soul) — 32 bytes:"
    32.times do |i|
      val = sprite.chroma_soul[i]
      print "%02X " % val
      puts if (i + 1) % 8 == 0
    end
  end

  def cmd_break(args)
    addr = args[0] ? args[0].to_i(16) : nil
    unless addr
      puts "Usage: b <hex_address>"
      return
    end
    @breakpoints.add(addr)
    puts "🛑 Breakpoint set at 0x%04X" % addr
  end

  def cmd_break_list
    if @breakpoints.empty?
      puts "🚫 No breakpoints set."
    else
      puts "🛑 Breakpoints:"
      @breakpoints.each { |bp| puts "   0x%04X" % bp }
    end
  end

  def cmd_break_clear
    @breakpoints.clear
    puts "🧹 All breakpoints cleared."
  end

  def cmd_png
    path = "debug_frame_#{Time.now.to_i}.png"
    sprite.crystalize_pool(path)
    puts "🖼️  Framebuffer saved to: #{path}"
  end

  def cmd_tiles
    path = "debug_tiles_#{Time.now.to_i}.png"
    sprite.crystalize_runestones(path)
    puts "🧱 Tiles saved to: #{path}"
  end
end

# Main entry
if ARGV[0]
  debugger = AstralDebugger.new
  if debugger.load_relic(ARGV[0])
    debugger.start
  end
else
  puts "Usage: ruby scripts/headless_debug.rb <path_to_relic.sms>"
  puts "Or run without args to enter interactive debugger (load relic with 'l <path>')"
  puts

  debugger = AstralDebugger.new
  debugger.start
end
