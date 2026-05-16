module AstralVerse
  class CrystalVault
    # Dimensions of the ethereal planes
    SHARD_POOL = 0x2000   # 8KB crystal shards (RAM)
    CODEX_SIZE = 0xC000   # 48KB ancient codex (ROM)

    attr_reader :crystal_shards, :ancient_codex, :relic_path

    def initialize
      @crystal_shards = Array.new(SHARD_POOL, 0)
      @ancient_codex  = Array.new(CODEX_SIZE, 0)
      @relic = nil
    end

    def inscribe_codex(essence)
      @relic = essence.dup
      size = [@relic.length, CODEX_SIZE].min
      @ancient_codex[0, size] = @relic[0, size]
    end

    def inscribe_codex_from_path(path)
      @relic_path = path
      essence = File.binread(path).bytes
      inscribe_codex(essence)
    end

    # Leyline map of the GemHeart's world:
    # $0000-$BFFF : Ancient Codex / Relic
    # $C000-$DFFF : Crystal Shards (8KB, mirrored at $E000)
    # $FFFC-$FFFF : Sigil binders
    def channel_essence(leyline)
      leyline &= 0xFFFF

      case leyline
      when 0x0000..0xBFFF
        @ancient_codex[leyline] || 0
      when 0xC000..0xDFFF
        @crystal_shards[leyline - 0xC000] || 0
      when 0xE000..0xFFFF
        @crystal_shards[leyline - 0xE000] || 0
      else
        0
      end
    end

    def channel_word(leyline)
      low = channel_essence(leyline)
      high = channel_essence(leyline + 1)
      (high << 8) | low
    end

    def etch_essence(leyline, essence)
      leyline &= 0xFFFF
      essence &= 0xFF

      case leyline
      when 0x0000..0xBFFF
        # The ancient codex is immutable
      when 0xC000..0xDFFF
        @crystal_shards[leyline - 0xC000] = essence
      when 0xE000..0xFFFF
        @crystal_shards[leyline - 0xE000] = essence
      end
    end

    def etch_word(leyline, essence)
      etch_essence(leyline, essence & 0xFF)
      etch_essence(leyline + 1, (essence >> 8) & 0xFF)
    end
  end
end
