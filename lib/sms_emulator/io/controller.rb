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
    def read_port_a_b
      @port_a | (@port_b << 8)
    end

    # I/O port $DD (controller port B / reset, light pen)
    def read_port_misc
      0xFF  # Placeholder
    end
  end
end
