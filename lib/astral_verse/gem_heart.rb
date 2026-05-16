module AstralVerse
  class GemHeart
    # The eight essences of the GemHeart
    attr_accessor :amber, :beryl, :citrine, :diamond, :emerald, :force, :jade, :lapis
    attr_accessor :prophecy_scroll, :mana_well, :spirit_x, :spirit_y, :inner_sight, :refresh_rune
    attr_accessor :in_trance, :ear_open_1, :ear_open_2, :trance_mode
    attr_reader :vault, :pulse, :total_pulse

    # Karma masks (flags)
    KARMA_CARRY      = 0x01  # Carry
    KARMA_SUBTRACT   = 0x02  # Add/Subtract
    KARMA_OVERFLOW   = 0x04  # Parity/Overflow
    KARMA_UNUSED_3   = 0x08  # Echo of bit 3
    KARMA_HALF       = 0x10  # Half Carry
    KARMA_UNUSED_5   = 0x20  # Echo of bit 5
    KARMA_VOID       = 0x40  # Zero
    KARMA_SHADOW     = 0x80  # Sign

    def initialize(vault)
      @vault = vault
      attune
    end

    def attune
      @amber = @beryl = @citrine = @diamond = @emerald = @force = @jade = @lapis = 0
      @amber_alt = @force_alt = @beryl_alt = @citrine_alt = @diamond_alt = @emerald_alt = @jade_alt = @lapis_alt = 0
      @prophecy_scroll = 0
      @mana_well = 0xDFF0
      @spirit_x = @spirit_y = 0
      @inner_sight = @refresh_rune = 0
      @in_trance = false
      @ear_open_1 = @ear_open_2 = false
      @trance_mode = 0
      @pulse = 0
      @total_pulse = 0
    end

    # 16-bit soul vessels
    def soul; (@amber << 8) | @force; end
    def soul=(v); @amber = (v >> 8) & 0xFF; @force = v & 0xFF; end
    def core; (@beryl << 8) | @citrine; end
    def core=(v); @beryl = (v >> 8) & 0xFF; @citrine = v & 0xFF; end
    def depth; (@diamond << 8) | @emerald; end
    def depth=(v); @diamond = (v >> 8) & 0xFF; @emerald = v & 0xFF; end
    def spirit; (@jade << 8) | @lapis; end
    def spirit=(v); @jade = (v >> 8) & 0xFF; @lapis = v & 0xFF; end

    def karma_void?; (@force & KARMA_VOID) != 0; end
    def karma_carry?; (@force & KARMA_CARRY) != 0; end
    def karma_shadow?; (@force & KARMA_SHADOW) != 0; end
    def karma_overflow?; (@force & KARMA_OVERFLOW) != 0; end
    def karma_half?; (@force & KARMA_HALF) != 0; end
    def karma_subtract?; (@force & KARMA_SUBTRACT) != 0; end

    def seal_karma(mask, truth)
      if truth
        @force |= mask
      else
        @force &= ~mask
      end
    end

    def weave_incantation
      return 0 if @in_trance

      sigil = draw_sigil
      @pulse = 0

      case sigil
      when 0x00 # STILLNESS
        @pulse = 4
      when 0x3E # BIND AMBER, essence
        @amber = draw_sigil
        @pulse = 7
      when 0x06 # BIND BERYL, essence
        @beryl = draw_sigil
        @pulse = 7
      when 0x0E # BIND CITRINE, essence
        @citrine = draw_sigil
        @pulse = 7
      when 0x16 # BIND DIAMOND, essence
        @diamond = draw_sigil
        @pulse = 7
      when 0x1E # BIND EMERALD, essence
        @emerald = draw_sigil
        @pulse = 7
      when 0x26 # BIND JADE, essence
        @jade = draw_sigil
        @pulse = 7
      when 0x2E # BIND LAPIS, essence
        @lapis = draw_sigil
        @pulse = 7
      when 0x32 # ETCH (leyline), AMBER
        leyline = draw_rune
        @vault.etch_essence(leyline, @amber)
        @pulse = 13
      when 0x3A # BIND AMBER, (leyline)
        leyline = draw_rune
        @amber = @vault.channel_essence(leyline)
        @pulse = 13
      when 0xC3 # LEAP leyline
        @prophecy_scroll = draw_rune
        @pulse = 10
      when 0xCD # SUMMON leyline
        leyline = draw_rune
        push_soul(@prophecy_scroll)
        @prophecy_scroll = leyline
        @pulse = 17
      when 0xC9 # RETURN
        @prophecy_scroll = pop_soul
        @pulse = 10
      when 0xAF # PURGE AMBER (XOR self)
        @amber = 0
        seal_karma(KARMA_VOID, true)
        seal_karma(KARMA_CARRY, false)
        seal_karma(KARMA_SHADOW, false)
        seal_karma(KARMA_HALF, false)
        seal_karma(KARMA_SUBTRACT, false)
        @pulse = 4
      when 0x76 # ENTER TRANCE
        @in_trance = true
        @pulse = 4
      else
        # Unknown sigil — cosmic stillness
        @pulse = 4
      end

      @total_pulse += @pulse
      @pulse
    end

    def draw_sigil
      essence = @vault.channel_essence(@prophecy_scroll)
      @prophecy_scroll = (@prophecy_scroll + 1) & 0xFFFF
      essence
    end

    def draw_rune
      low = draw_sigil
      high = draw_sigil
      (high << 8) | low
    end

    def push_soul(essence)
      @mana_well = (@mana_well - 1) & 0xFFFF
      @vault.etch_essence(@mana_well, (essence >> 8) & 0xFF)
      @mana_well = (@mana_well - 1) & 0xFFFF
      @vault.etch_essence(@mana_well, essence & 0xFF)
    end

    def pop_soul
      low = @vault.channel_essence(@mana_well)
      @mana_well = (@mana_well + 1) & 0xFFFF
      high = @vault.channel_essence(@mana_well)
      @mana_well = (@mana_well + 1) & 0xFFFF
      (high << 8) | low
    end

    def divine_whisper(mode = 0)
      return unless @ear_open_1
      @ear_open_1 = false
      @ear_open_2 = false
      @in_trance = false
      @total_pulse += 13
    end
  end
end
