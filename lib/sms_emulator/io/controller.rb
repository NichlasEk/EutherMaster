module SmsEmulator
  class Controller
    BUTTON_UP     = 0x01
    BUTTON_DOWN   = 0x02
    BUTTON_LEFT   = 0x04
    BUTTON_RIGHT  = 0x08
    BUTTON_A      = 0x10
    BUTTON_B      = 0x20

    attr_accessor :port_a, :port_b

    def initialize
      @port_a = 0xFF  # All buttons released = high
      @port_b = 0xFF
      @th_a = true
      @th_b = true
    end

    def reset
      @port_a = 0xFF
      @port_b = 0xFF
      @th_a = true
      @th_b = true
    end

    def press(button, port = :a)
      target = port == :a ? @port_a : @port_b
      target &= ~button
      if port == :a
        @port_a = target
      else
        @port_b = target
      end
    end

    def release(button, port = :a)
      target = port == :a ? @port_a : @port_b
      target |= button
      if port == :a
        @port_a = target
      else
        @port_b = target
      end
    end

    # I/O port $DC (controller port A/B)
    def read_port_a
      (@port_a & 0x3F) | ((@port_b & 0x03) << 6)
    end

    def read_port_a_b
      read_port_a | (read_port_misc << 8)
    end

    # I/O port $DD (controller port B / reset, light pen)
    def read_port_misc
      value = 0xF0
      value |= (@port_b >> 2) & 0x0F
      value |= 0x40 if @th_a
      value |= 0x80 if @th_b
      value
    end

    # SMS I/O control port. Bits 0/1 are TR direction, bits 2/3 are TH
    # direction, and bits 4/5 drive TH output when configured.
    def write_control(value)
      @th_a = (value & 0x10) != 0 if (value & 0x04) != 0
      @th_b = (value & 0x20) != 0 if (value & 0x08) != 0
    end
  end
end
