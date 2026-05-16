module AstralVerse
  class Testground
    def self.open(rom_dir = 'assets/roms')
      require_relative 'ui/rom_picker'

      picker = UI::RomPicker.new(rom_dir)
      picker.show

      if picker.selected_rom
        rom_path = picker.selected_rom[:path]
        puts "🔮 Selected relic: #{picker.selected_rom[:name]}"
        puts "   Path: #{rom_path}"
        puts "   Size: #{picker.selected_rom[:size_str]}"

        stone = ScryingStone.new
        stone.absorb_codex(rom_path)
        stone.awaken
      else
        puts "❌ No relic selected. The vault remains sealed."
      end
    end
  end
end
