module AstralVerse
  class LastRelicCache
    CACHE_FILE = '.astralverse_cache'.freeze
    ROM_DIR_FILE = '.astralverse_rom_dir'.freeze
    CONFIG_FILE = '.astralverse.toml'.freeze

    DEFAULT_CONFIG = {
      paths: {
        last_relic: nil,
        rom_dir: nil
      },
      ui: {
        volume: 1.0,
        debug_mask: false,
        autostart: true
      },
      key_bindings: {}
    }.freeze

    def self.last_relic
      path = config[:paths][:last_relic] || legacy_path(CACHE_FILE)
      File.exist?(path) ? path : nil
    rescue
      nil
    end

    def self.save_relic(path)
      update_config(paths: { last_relic: File.expand_path(path) })
    rescue => e
      puts "⚠️ Could not save relic cache: #{e.message}"
    end

    def self.rom_dir
      path = config[:paths][:rom_dir] || legacy_path(ROM_DIR_FILE)
      Dir.exist?(path) ? path : nil
    rescue
      nil
    end

    def self.save_rom_dir(path)
      expanded = File.expand_path(path)
      return false unless Dir.exist?(expanded)

      update_config(paths: { rom_dir: expanded })
      true
    rescue => e
      puts "⚠️ Could not save ROM dir: #{e.message}"
      false
    end

    def self.volume
      config[:ui][:volume].to_f.clamp(0.0, 1.0)
    rescue
      1.0
    end

    def self.save_volume(value)
      update_config(ui: { volume: value.to_f.clamp(0.0, 1.0) })
    rescue => e
      puts "⚠️ Could not save volume: #{e.message}"
    end

    def self.debug_mask?
      !!config[:ui][:debug_mask]
    rescue
      false
    end

    def self.save_debug_mask(value)
      update_config(ui: { debug_mask: !!value })
    rescue => e
      puts "⚠️ Could not save debug mask: #{e.message}"
    end

    def self.autostart?
      config[:ui].key?(:autostart) ? !!config[:ui][:autostart] : true
    rescue
      true
    end

    def self.key_bindings
      config[:key_bindings] || {}
    rescue
      {}
    end

    def self.save_key_bindings(bindings)
      update_config(key_bindings: bindings.transform_keys(&:to_sym))
    rescue => e
      puts "⚠️ Could not save key bindings: #{e.message}"
    end

    def self.last_dir
      configured = rom_dir
      return configured if configured

      relic = last_relic
      relic ? File.dirname(relic) : Dir.home
    end

    def self.config
      merged = deep_merge(DEFAULT_CONFIG, read_config)
      merged[:paths][:last_relic] ||= legacy_path(CACHE_FILE)
      merged[:paths][:rom_dir] ||= legacy_path(ROM_DIR_FILE)
      merged
    end

    def self.update_config(patch)
      merged = deep_merge(config, patch)
      File.write(config_file, to_toml(merged))
      merged
    end

    def self.config_file
      ENV.fetch('ASTRAL_CONFIG', CONFIG_FILE)
    end
    private_class_method :config_file

    def self.legacy_path(file)
      return nil unless File.exist?(file)

      path = File.read(file).strip
      path.empty? ? nil : path
    end
    private_class_method :legacy_path

    def self.read_config
      path = config_file
      return {} unless File.exist?(path)

      current = nil
      File.readlines(path, chomp: true).each_with_object({}) do |line, result|
        line = line.sub(/\s+#.*\z/, '').strip
        next if line.empty?

        if line.start_with?('[') && line.end_with?(']')
          current = line[1...-1].to_sym
          result[current] ||= {}
          next
        end

        key, raw = line.split('=', 2).map(&:strip)
        next unless current && key && raw

        result[current][key.to_sym] = parse_value(raw)
      end
    rescue
      {}
    end
    private_class_method :read_config

    def self.parse_value(raw)
      case raw
      when /\A"(.*)"\z/m
        Regexp.last_match(1).gsub('\"', '"').gsub('\\\\', '\\')
      when 'true'
        true
      when 'false'
        false
      else
        raw.include?('.') ? raw.to_f : raw.to_i
      end
    end
    private_class_method :parse_value

    def self.to_toml(data)
      sections = []
      data.each do |section, values|
        sections << "[#{section}]"
        values.each do |key, value|
          next if value.nil?

          sections << "#{key} = #{toml_value(value)}"
        end
        sections << ''
      end
      sections.join("\n")
    end
    private_class_method :to_toml

    def self.toml_value(value)
      case value
      when String
        escaped = value.gsub('\\', '\\\\').gsub('"', '\"')
        "\"#{escaped}\""
      when true, false
        value.to_s
      else
        value.to_s
      end
    end
    private_class_method :toml_value

    def self.deep_merge(base, patch)
      base.merge(patch) do |_key, old_value, new_value|
        old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
      end
    end
    private_class_method :deep_merge
  end
end
