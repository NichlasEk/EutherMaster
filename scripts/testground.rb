#!/usr/bin/env ruby

require_relative '../lib/astral_verse'

puts "🔮 AstralVerse Testground"
puts "═══════════════════════════════════════"
puts

# If a directory is given, use it; otherwise open the file browser
start_dir = ARGV[0] || Dir.home

require_relative '../lib/astral_verse/ui/file_browser'
browser = AstralVerse::UI::FileBrowser.new(start_dir)
browser.show

if browser.selected_path
  puts "💎 Selected relic: #{File.basename(browser.selected_path)}"
  puts "   Path: #{browser.selected_path}"

  stone = AstralVerse::ScryingStone.new
  stone.absorb_codex(browser.selected_path)
  stone.awaken
else
  puts "❌ No relic selected. The vault remains sealed."
end
