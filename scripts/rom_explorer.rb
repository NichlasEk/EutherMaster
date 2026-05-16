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

# Start from last directory or provided path or home
start_dir = ARGV[0] || AstralVerse::LastRelicCache.last_dir

require_relative '../lib/astral_verse/ui/file_browser'

browser = AstralVerse::UI::FileBrowser.new(start_dir)
browser.show

if browser.selected_path
  relic_path = browser.selected_path
  AstralVerse::LastRelicCache.save_relic(relic_path)
  puts "💎 Selected relic: #{File.basename(relic_path)}"
  puts "   Path: #{relic_path}"
  puts "   (Remembered for next time)"

  stone = AstralVerse::ScryingStone.new
  stone.absorb_codex(relic_path)
  stone.awaken
else
  puts "❌ No relic selected. The vault remains sealed."
end
