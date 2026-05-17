module AstralVerse
  class Testground
    def self.open(rom_dir = 'assets/roms')
      LastRelicCache.save_rom_dir(rom_dir) if Dir.exist?(rom_dir)
      ScryingStone.new.awaken
    end
  end
end
