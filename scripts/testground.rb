#!/usr/bin/env ruby

require_relative '../lib/astral_verse'

puts "🔮 AstralVerse Testground"
puts "═══════════════════════════════════════"
puts

AstralVerse::LastRelicCache.save_rom_dir(ARGV[0]) if ARGV[0] && Dir.exist?(ARGV[0])
stone = AstralVerse::ScryingStone.new
stone.awaken
