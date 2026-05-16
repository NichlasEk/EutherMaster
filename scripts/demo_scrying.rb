#!/usr/bin/env ruby

require_relative '../lib/astral_verse'

puts "🔮 Väcker AstralVerse i demo-läge..."
puts "Tryck ESC för att stänga, SPACE för att pausa/fortsätta"

stone = AstralVerse::ScryingStone.new

# Demo: fyll scrying pool med en mystisk aurafärg
# (Detta simulerar vad VDPn skulle målat utan ROM)
demo_colors = [0x00, 0x15, 0x2A, 0x3F]  # olika blå-lila nyanser
demo_colors.each_with_index do |aura, idx|
  stone.vision_sprite.chroma_soul[idx] = aura
end

# Fyll poolen med en gradient
AstralVerse::VisionSprite::POOL_HEIGHT.times do |thread|
  AstralVerse::VisionSprite::POOL_WIDTH.times do |rune|
    # Skapa en mystisk gradient
    color_idx = ((thread + rune) / 32) % 4
    stone.vision_sprite.scrying_pool[thread * AstralVerse::VisionSprite::POOL_WIDTH + rune] = demo_colors[color_idx]
  end
end

stone.awaken
