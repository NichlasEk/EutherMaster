module MegaDrive
  class Controller
    UP = 0x01
    DOWN = 0x02
    LEFT = 0x04
    RIGHT = 0x08
    BUTTON_A = 0x10
    BUTTON_B = 0x20
    BUTTON_C = 0x40
    START = 0x80

    attr_accessor :port_a, :port_b

    def initialize
      reset
    end

    def reset
      @port_a = 0xFF
      @port_b = 0xFF
      @data = 0x40
      @control = 0x40
    end

    def read_data
      th_high? ? read_high_th : read_low_th
    end

    def write_data(value)
      @data = value & 0x7F
    end

    def read_control
      @control
    end

    def write_control(value)
      @control = value & 0x7F
    end

    private

    def th_high?
      (@data & 0x40) != 0
    end

    def pressed?(button)
      (@port_a & button).zero?
    end

    def read_high_th
      value = 0xFF
      value &= ~0x01 if pressed?(UP)
      value &= ~0x02 if pressed?(DOWN)
      value &= ~0x04 if pressed?(LEFT)
      value &= ~0x08 if pressed?(RIGHT)
      value &= ~0x10 if pressed?(BUTTON_B)
      value &= ~0x20 if pressed?(BUTTON_C)
      value |= 0x40
      value
    end

    def read_low_th
      value = 0xFF
      value &= ~0x01 if pressed?(UP)
      value &= ~0x02 if pressed?(DOWN)
      value &= ~0x10 if pressed?(BUTTON_A)
      value &= ~0x20 if pressed?(START)
      value &= 0xF3
      value &= ~0x40
      value
    end
  end
end
