require 'js'

module SmsWeb
  WIDTH = SmsEmulator::VDP::SMS_WIDTH
  HEIGHT = SmsEmulator::VDP::SMS_HEIGHT
  BUTTONS = {
    'up' => SmsEmulator::Controller::BUTTON_UP,
    'down' => SmsEmulator::Controller::BUTTON_DOWN,
    'left' => SmsEmulator::Controller::BUTTON_LEFT,
    'right' => SmsEmulator::Controller::BUTTON_RIGHT,
    'a' => SmsEmulator::Controller::BUTTON_A,
    'b' => SmsEmulator::Controller::BUTTON_B
  }.freeze
  RGBA_PALETTE = Array.new(64) do |value|
    r = ((value >> 0) & 0x03) * 85
    g = ((value >> 2) & 0x03) * 85
    b = ((value >> 4) & 0x03) * 85
    [r, g, b, 255].pack('C4')
  end.freeze

  module_function

  def emulator
    @emulator ||= SmsEmulator::Emulator.new.tap do |emu|
      emu.fast_idle_enabled = true
    end
  end

  def load_rom(js_bytes)
    length = js_bytes[:length].to_i
    bytes = Array.new(length)
    index = 0
    while index < length
      bytes[index] = js_bytes[index].to_i
      index += 1
    end

    emulator.load_rom_data(bytes)
    JS.global.call(:smsSetStatus, "ROM loaded: #{length} bytes")
    true
  rescue => e
    JS.global.call(:smsSetStatus, "ROM load failed: #{e.class}: #{e.message}")
    false
  end

  def step_frame(input_mask)
    apply_input(input_mask.to_i)
    started = now_ms
    emulator.run_frame
    rendered = now_ms
    rgba = rgba_frame
    packed = now_ms
    perf = emulator.perf_summary
    JS.global.call(:smsDrawRgbaFrame, rgba, emulator.frame_count, rendered - started, packed - rendered, perf[:last_cpu_ms], perf[:last_vdp_ms], perf[:last_cpu_steps])
    true
  rescue => e
    JS.global.call(:smsSetStatus, "Emulator error: #{e.class}: #{e.message}")
    false
  end

  def apply_input(mask)
    port = 0xFF
    BUTTONS.each_value do |button|
      port &= ~button if (mask & button) != 0
    end
    emulator.controller.port_a = port
  end

  def rgba_frame
    framebuffer = emulator.vdp.framebuffer
    packed = String.new(capacity: WIDTH * HEIGHT * 4, encoding: Encoding::BINARY)
    index = 0
    while index < framebuffer.length
      packed << RGBA_PALETTE[framebuffer[index] & 0x3F]
      index += 1
    end
    packed
  end

  def now_ms
    JS.global[:performance].call(:now).to_f
  end
end

JS.global[:smsLoadRom] = proc { |bytes| SmsWeb.load_rom(bytes) }
JS.global[:smsStepFrame] = proc { |input_mask| SmsWeb.step_frame(input_mask) }
JS.global.call(:smsRubyReady)
