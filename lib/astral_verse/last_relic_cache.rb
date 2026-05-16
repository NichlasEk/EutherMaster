require 'gosu'

module AstralVerse
  class LastRelicCache
    CACHE_FILE = '.astralverse_cache'.freeze

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

    def self.last_dir
      relic = last_relic
      relic ? File.dirname(relic) : Dir.home
    end
  end
end
