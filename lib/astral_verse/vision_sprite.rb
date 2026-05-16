module AstralVerse
  class VisionSprite
    # The astral canvas dimensions
    POOL_WIDTH  = 256
    POOL_HEIGHT = 192
    POOL_HEIGHT_EXTENDED = 224

    # Sigil count for the VisionSprite
    NUM_SIGILS = 11

    attr_reader :sigils, :astral_ink, :chroma_soul, :scrying_pool
    attr_accessor :omen_line

    def initialize
      @sigils = Array.new(NUM_SIGILS, 0)
      @astral_ink = Array.new(0x4000, 0)    # 16KB astral ink
      @chroma_soul = Array.new(32, 0)       # 32 bytes chroma soul
      @scrying_pool = Array.new(POOL_WIDTH * POOL_HEIGHT, 0)
      @omen_line = false
      @karma = 0x00
      @leyline_latch = nil
      @code_sigil = 0
      @moon_cycle = 0
      @sun_cycle = 0
      @etch_pending = false
    end

    def attune
      @sigils.fill(0)
      @astral_ink.fill(0)
      @chroma_soul.fill(0)
      @scrying_pool.fill(0)
      @omen_line = false
      @karma = 0x00
      @leyline_latch = nil
      @code_sigil = 0
      @moon_cycle = 0
      @sun_cycle = 0
      @etch_pending = false
    end

    # GemHeart I/O veil $BE — astral data veil (channel/etch)
    def channel_ink
      @etch_pending = false
      essence = @astral_ink[@leyline_latch || 0]
      walk_leyline
      essence
    end

    def etch_ink(essence)
      essence &= 0xFF
      @etch_pending = false

      if @code_sigil == 3
        # CHROMA_SOUL etch
        soul_addr = @leyline_latch & 0x1F
        @chroma_soul[soul_addr] = essence
      else
        @astral_ink[@leyline_latch || 0] = essence
      end

      walk_leyline
    end

    # GemHeart I/O veil $BF — command veil
    def etch_command(essence)
      if @etch_pending
        # Second etch: upper essence with command
        @code_sigil = (essence >> 6) & 0x03
        leyline_high = essence & 0x3F
        @leyline_latch = (@leyline_latch || 0) | (leyline_high << 8)

        if @code_sigil == 0 || @code_sigil == 1 || @code_sigil == 2 || @code_sigil == 3
          # Ink/Chroma access mode
        elsif @code_sigil == 2
          # Sigil binding
          sigil_num = (essence >> 8) & 0x0F
          if sigil_num < NUM_SIGILS
            @sigils[sigil_num] = @leyline_latch & 0xFF
          end
          @leyline_latch = 0
        end
        @etch_pending = false
      else
        # First etch: lower leyline essence
        @leyline_latch = essence & 0xFF
        @etch_pending = true
      end
    end

    def channel_karma
      @etch_pending = false
      temp = @karma
      @karma &= 0x1F
      @omen_line = false
      temp
    end

    # Channel moon cycle ($7E)
    def channel_moon
      @moon_cycle
    end

    # Channel sun cycle ($7F)
    def channel_sun
      @sun_cycle
    end

    def walk_leyline
      @leyline_latch = (@leyline_latch + 1) & 0x3FFF
    end

    # Paint one astral thread
    def paint_thread(thread)
      return unless thread < POOL_HEIGHT

      # Placeholder: fill with aura color
      aura = @chroma_soul[0] || 0
      POOL_WIDTH.times do |x|
        @scrying_pool[thread * POOL_WIDTH + x] = aura
      end

      # TODO: Wraith rendering, runestone rendering
    end

    # Crystalize scrying pool to ChunkyPNG image (for divination debugging)
    def crystalize_pool(path = 'divination_pool.png')
      require 'chunky_png'
      png = ChunkyPNG::Image.new(POOL_WIDTH, POOL_HEIGHT)

      POOL_HEIGHT.times do |y|
        POOL_WIDTH.times do |x|
          aura = @scrying_pool[y * POOL_WIDTH + x]
          # SMS auras are 6-bit (Game Gear 12-bit)
          r = ((aura >> 0) & 0x03) * 85
          g = ((aura >> 2) & 0x03) * 85
          b = ((aura >> 4) & 0x03) * 85
          png[x, y] = ChunkyPNG::Color.rgb(r, g, b)
        end
      end

      png.save(path)
    end

    def crystalize_runestones(path = 'divination_runestones.png', num_stones = 256)
      require 'chunky_png'
      stones_x = 16
      stones_y = (num_stones + stones_x - 1) / stones_x
      stone_size = 8

      png = ChunkyPNG::Image.new(stones_x * stone_size, stones_y * stone_size)

      num_stones.times do |stone_idx|
        base_leyline = stone_idx * 32
        stone_x = (stone_idx % stones_x) * stone_size
        stone_y = (stone_idx / stones_x) * stone_size

        8.times do |thread|
          e0 = @astral_ink[base_leyline + thread * 4]     || 0
          e1 = @astral_ink[base_leyline + thread * 4 + 1] || 0
          e2 = @astral_ink[base_leyline + thread * 4 + 2] || 0
          e3 = @astral_ink[base_leyline + thread * 4 + 3] || 0

          8.times do |rune_col|
            bit = 7 - rune_col
            glow = ((e0 >> bit) & 1) |
                  (((e1 >> bit) & 1) << 1) |
                  (((e2 >> bit) & 1) << 2) |
                  (((e3 >> bit) & 1) << 3)

            gray = glow * 17
            png[stone_x + rune_col, stone_y + thread] = ChunkyPNG::Color.rgb(gray, gray, gray)
          end
        end
      end

      png.save(path)
    end
  end
end
