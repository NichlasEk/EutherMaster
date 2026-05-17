#!/usr/bin/env ruby

require_relative '../lib/astral_verse'

puts "🔮 AstralVerse — Relic Explorer"
puts "═══════════════════════════════════════"
puts

# Check for cached last relic
last = AstralVerse::LastRelicCache.last_relic
if last
  puts "✨ Previous relic: #{last}"
  puts ""
end

AstralVerse::LastRelicCache.save_rom_dir(ARGV[0]) if ARGV[0] && Dir.exist?(ARGV[0])
stone = AstralVerse::ScryingStone.new
stone.awaken
