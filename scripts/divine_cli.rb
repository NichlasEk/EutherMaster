#!/usr/bin/env ruby

require_relative '../lib/astral_verse'

puts "═" * 50
puts "   🔮 ASTRALVERSE — Headless Divination"
puts "═" * 50

# Create or use test relic
relic_path = File.join(__dir__, '../test_relic.sms')

unless File.exist?(relic_path)
  puts "\n🛠️  No relic found. Forging one..."
  system("ruby #{File.join(__dir__, 'forge_relic.rb')}")
end

stone = AstralVerse::ScryingStone.new
stone.absorb_codex(relic_path)

puts "\n📜 Relic absorbed: #{relic_path}"
puts "   ROM size: #{stone.crystal_vault.ancient_codex.length} bytes"
puts "\n🌙 Attuning the GemHeart..."
stone.attune

puts "\n✨ Running 3 divine visions (frames)..."
puts "-" * 50

3.times do |i|
  stone.gaze_frame
  heart = stone.gem_heart
  puts "Vision #{i + 1}:"
  puts "  Amber: 0x%02X | Beryl: 0x%02X | Citrine: 0x%02X" % [heart.amber, heart.beryl, heart.citrine]
  puts "  Prophecy Scroll (PC): 0x%04X | Mana Well (SP): 0x%04X" % [heart.prophecy_scroll, heart.mana_well]
  puts "  Karma (F): 0x%02X | In Trance: #{heart.in_trance}" % heart.force
  puts "  Total Pulses: #{heart.total_pulse}"
  puts
end

puts "✅ Divination complete!"
puts "   The GemHeart processed #{stone.gem_heart.total_pulse} pulses across 3 visions."
puts
puts "💡 Try with graphics: ruby scripts/demo_scrying.rb"
puts "   Or with a real ROM:  bin/crystal <path_to_rom.sms>"
