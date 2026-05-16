module AstralVerse
  class ScryingStone
    attr_reader :gem_heart, :vision_sprite, :crystal_vault, :mystic_touch

    # Master System pulses: GemHeart ~3.58 MHz, VisionSprite ~10.7 MHz
    # One full vision: 262 astral threads (NTSC), 313 (PAL)
    PULSES_PER_VISION = 59736
    PULSES_PER_THREAD = 228

    def initialize
      @crystal_vault = CrystalVault.new
      @gem_heart = GemHeart.new(@crystal_vault)
      @vision_sprite = VisionSprite.new
      @mystic_touch = MysticTouch.new
      @vision_count = 0
      @codex_present = false
    end

    def absorb_codex(path)
      @crystal_vault.inscribe_codex_from_path(path)
      @codex_present = true
      attune
    end

    def absorb_codex_essence(essence)
      @crystal_vault.inscribe_codex(essence)
      @codex_present = true
      attune
    end

    def attune
      @gem_heart.attune
      @vision_sprite.attune
      @mystic_touch.attune
      @vision_count = 0
    end

    def gaze_frame
      return unless @codex_present

      pulses_this_vision = 0
      thread = 0

      while pulses_this_vision < PULSES_PER_VISION
        pulses = @gem_heart.weave_incantation
        pulses_this_vision += pulses

        thread += (pulses / PULSES_PER_THREAD)

        if thread >= 262
          thread = 0
          @vision_sprite.omen_line = true
        end

        if @vision_sprite.omen_line && @gem_heart.ear_open_1
          @gem_heart.divine_whisper
        end
      end

      @vision_count += 1
    end

    def awaken
      require_relative 'ui/crystal_window'
      window = CrystalWindow.new(self)
      window.show
    end
  end
end
