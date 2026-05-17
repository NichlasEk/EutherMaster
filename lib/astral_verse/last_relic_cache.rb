require 'gosu'

module AstralVerse
  class LastRelicCache
    CACHE_FILE = '.astralverse_cache'.freeze
    ROM_DIR_FILE = '.astralverse_rom_dir'.freeze

    def self.last_relic
      return nil unless File.exist?(CACHE_FILE)
      path = File.read(CACHE_FILE).strip
      File.exist?(path) ? path : nil
    rescue
      nil
    end

    def self.save_relic(path)
      File.write(CACHE_FILE, File.expand_path(path))
    rescue => e
      puts "⚠️ Could not save relic cache: #{e.message}"
    end

    def self.rom_dir
      return nil unless File.exist?(ROM_DIR_FILE)

      path = File.read(ROM_DIR_FILE).strip
      Dir.exist?(path) ? path : nil
    rescue
      nil
    end

    def self.save_rom_dir(path)
      expanded = File.expand_path(path)
      return false unless Dir.exist?(expanded)

      File.write(ROM_DIR_FILE, expanded)
      true
    rescue => e
      puts "⚠️ Could not save ROM dir: #{e.message}"
      false
    end

    def self.last_dir
      configured = rom_dir
      return configured if configured

      relic = last_relic
      relic ? File.dirname(relic) : Dir.home
    end
  end
end
