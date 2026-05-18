module AstralVerse
  class MysticTouch
    GESTURE_NORTH   = 0x01
    GESTURE_SOUTH   = 0x02
    GESTURE_WEST    = 0x04
    GESTURE_EAST    = 0x08
    GESTURE_PRIMUS  = 0x10
    GESTURE_SECUNDUS = 0x20
    GESTURE_TERTIUS = 0x40
    GESTURE_START   = 0x80

    attr_accessor :left_palm, :right_palm

    def initialize
      @left_palm  = 0xFF  # All gestures released = high (at rest)
      @right_palm = 0xFF
      @aura_a = true
      @aura_b = true
    end

    def attune
      @left_palm  = 0xFF
      @right_palm = 0xFF
      @aura_a = true
      @aura_b = true
    end

    def invoke(gesture, palm = :left)
      target = palm == :left ? @left_palm : @right_palm
      target &= ~gesture
      if palm == :left
        @left_palm = target
      else
        @right_palm = target
      end
    end

    def release(gesture, palm = :left)
      target = palm == :left ? @left_palm : @right_palm
      target |= gesture
      if palm == :left
        @left_palm = target
      else
        @right_palm = target
      end
    end

    # I/O veil $DC (mystic palms A/B)
    def channel_palms
      @left_palm | (@right_palm << 8)
    end

    # I/O veil $DD (misc / reset)
    def channel_aura
      0xFF  # Placeholder
    end
  end
end
