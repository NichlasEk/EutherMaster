require 'spec_helper'

RSpec.describe 'Mega Drive audio' do
  it 'routes YM2612 port writes through the 68k bus' do
    ym2612 = MegaDrive::YM2612.new
    bus = MegaDrive::M68KBus.new(ym2612: ym2612)

    bus.write_word(0xA04000, 0xA034)

    expect(ym2612.registers[0][0xA0]).to eq(0x34)
    expect(ym2612.read_register & 0x80).to eq(0x80)

    ym2612.tick(MegaDrive::YM2612::WRITE_BUSY_CYCLES)
    expect(ym2612.read_register & 0x80).to eq(0)
  end

  it 'routes PSG writes through the VDP data window' do
    psg = MegaDrive::PSG.new
    bus = MegaDrive::M68KBus.new(psg: psg)

    bus.write_word(0xC00010, 0x009F)

    expect(psg.writes).to eq(1)
    expect(psg.write_log.last[:value]).to eq(0x9F)
  end

  it 'renders a keyed-on YM2612 carrier' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0x4C)
    ym2612.write_data(0x00)
    ym2612.write_address_1(0xA0)
    ym2612.write_data(0x6A)
    ym2612.write_address_1(0xA4)
    ym2612.write_data((4 << 3) | 0x02)
    ym2612.write_address_1(0xB4)
    ym2612.write_data(0xC0)
    ym2612.begin_frame
    ym2612.write_address_1(0x28)
    ym2612.write_data(0xF0)

    samples = ym2612.render_frame_samples(128, 1_000)

    expect(samples.flatten.any? { |sample| sample.abs > 0.001 }).to be(true)
  end

  it 'advances YM2612 timers and clears status flags through timer control' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0x24)
    ym2612.write_data(0xFF)
    ym2612.write_address_1(0x25)
    ym2612.write_data(0x03)
    ym2612.write_address_1(0x27)
    ym2612.write_data(0x05)

    ym2612.tick(MegaDrive::YM2612::TIMER_TICK_CYCLES)
    expect(ym2612.read_register & 0x01).to eq(0x01)

    ym2612.write_address_1(0x27)
    ym2612.write_data(0x10)
    expect(ym2612.read_register & 0x01).to eq(0)
  end

  it 'does not raise YM timer flags unless timer flag bits are enabled' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0x24)
    ym2612.write_data(0xFF)
    ym2612.write_address_1(0x25)
    ym2612.write_data(0x03)
    ym2612.write_address_1(0x27)
    ym2612.write_data(0x01)

    ym2612.tick(MegaDrive::YM2612::TIMER_TICK_CYCLES)

    expect(ym2612.read_register & 0x01).to eq(0)
  end

  it 'does not let audio rendering roll back live YM busy and timer state' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.begin_frame
    ym2612.write_address_1(0xA0)
    ym2612.write_data(0x34)
    ym2612.tick(MegaDrive::YM2612::WRITE_BUSY_CYCLES)

    ym2612.render_frame_samples(64, 1_000)

    expect(ym2612.read_register & 0x80).to eq(0)
  end

  it 'exposes combined MD audio through the existing PSG player hook' do
    emulator = MegaDrive::Emulator.new

    expect(emulator.psg).to be_a(MegaDrive::Audio)
    expect(emulator.psg).to respond_to(:render_frame_samples)
  end

  it 'grants the Z80 bus immediately for 68k-side boot code' do
    bus = MegaDrive::M68KBus.new

    expect(bus.read_byte(0xA11100) & 0x01).to eq(1)

    bus.write_word(0xA11100, 0x0100)

    expect(bus.read_byte(0xA11100) & 0x01).to eq(0)
  end

  it 'maps 68k-side byte writes into mirrored Z80 RAM' do
    emulator = MegaDrive::Emulator.new

    emulator.bus.write_byte(0xA00000, 0x3E)
    emulator.bus.write_byte(0xA02001, 0xA0)
    emulator.bus.write_byte(0xA00002, 0x32)
    emulator.bus.write_byte(0xA02003, 0x00)

    expect(emulator.z80_bus.read_byte(0x0000)).to eq(0x3E)
    expect(emulator.z80_bus.read_byte(0x0001)).to eq(0xA0)
    expect(emulator.z80_bus.read_byte(0x0002)).to eq(0x32)
    expect(emulator.z80_bus.read_byte(0x0003)).to eq(0x00)
  end

  it 'maps 68k-side word writes into Z80 RAM as high-byte-only writes' do
    emulator = MegaDrive::Emulator.new

    emulator.bus.write_word(0xA00000, 0x3EA0)
    emulator.bus.write_word(0xA00002, 0x3200)

    expect(emulator.z80_bus.read_byte(0x0000)).to eq(0x3E)
    expect(emulator.z80_bus.read_byte(0x0001)).to eq(0x00)
    expect(emulator.z80_bus.read_byte(0x0002)).to eq(0x32)
    expect(emulator.z80_bus.read_byte(0x0003)).to eq(0x00)
    expect(emulator.bus.read_word(0xA00000)).to eq(0x3E3E)
  end

  it 'leaves Mega Drive Z80 I/O ports unwired' do
    emulator = MegaDrive::Emulator.new

    emulator.z80_bus.write_io(0x7F11, 0x9F)

    expect(emulator.z80_bus.read_io(0x7F11)).to eq(0xFF)
    expect(emulator.instance_variable_get(:@sms_psg).writes).to eq(0)
  end

  it 'pulses the Mega Drive Z80 IM1 interrupt once per frame' do
    emulator = MegaDrive::Emulator.new
    rom = Array.new(0x200, 0)
    rom[0, 8] = [0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00]
    emulator.load_rom_data(rom)
    program = [
      0xF3,             # DI
      0x31, 0xFD, 0x1F, # LD SP,$1FFD
      0xED, 0x56,       # IM 1
      0x3E, 0x00,       # LD A,0
      0x32, 0x00, 0x10, # LD ($1000),A
      0xFB,             # EI
      0x18, 0xFE        # JR $
    ]
    isr = [
      0x3A, 0x00, 0x10, # LD A,($1000)
      0x3C,             # INC A
      0x32, 0x00, 0x10, # LD ($1000),A
      0xFB,             # EI
      0xC9              # RET
    ]
    program.each_with_index { |byte, index| emulator.bus.write_byte(0xA00000 + index, byte) }
    isr.each_with_index { |byte, index| emulator.bus.write_byte(0xA00038 + index, byte) }
    emulator.bus.write_byte(0xA11200, 0x01)

    4.times do
      emulator.bus.run_z80_cycles(200)
      emulator.z80_cpu.interrupt(0xFF)
    end

    expect(emulator.z80_bus.read_byte(0x1000)).to be > 0
  end

  it 'runs Z80 audio code against memory-mapped YM2612 ports' do
    emulator = MegaDrive::Emulator.new
    program = [
      0x3E, 0xA0,       # LD A,$A0
      0x32, 0x00, 0x40, # LD ($4000),A
      0x3E, 0x34,       # LD A,$34
      0x32, 0x01, 0x40, # LD ($4001),A
      0x76              # HALT
    ]
    program.each_with_index { |byte, index| emulator.bus.write_byte(0xA00000 + index, byte) }

    emulator.bus.write_byte(0xA11200, 0x01)
    emulator.bus.run_z80_cycles(80)

    expect(emulator.ym2612.registers[0][0xA0]).to eq(0x34)
  end

  it 'halts Z80 execution while the 68k owns the Z80 bus' do
    emulator = MegaDrive::Emulator.new
    emulator.bus.write_byte(0xA00000, 0x00) # NOP
    emulator.bus.write_byte(0xA00001, 0x00) # NOP
    emulator.bus.write_byte(0xA11200, 0x01)
    emulator.bus.write_byte(0xA11100, 0x01)

    emulator.bus.run_z80_cycles(32)

    expect(emulator.z80_cpu.pc).to eq(0)
  end

  it 'resets the YM2612 when the Z80 reset line is asserted' do
    emulator = MegaDrive::Emulator.new
    emulator.ym2612.write_address_1(0xA0)
    emulator.ym2612.write_data(0x34)

    emulator.bus.write_byte(0xA11200, 0x00)

    expect(emulator.ym2612.registers[0][0xA0]).to eq(0)
  end

  it 'routes 68k-side VDP ports to the Mega Drive VDP' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)

    bus.write_word(0xC00004, 0x8F02)
    bus.write_word(0xC00004, 0xC000)
    bus.write_word(0xC00004, 0x0000)
    bus.write_word(0xC00000, 0x0EEE)
    vdp.render_frame

    expect(vdp.registers[15]).to eq(2)
    expect(vdp.cram[0]).to eq(0x0EEE)
    expect(vdp.palette_rgba[0].bytes[0, 3]).to eq([255, 255, 255])
  end

  it 'decodes full Mega Drive VDP data-port command targets' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)

    bus.write_word(0xC00004, 0xC000) # CRAM write address 0
    bus.write_word(0xC00004, 0x0000)
    bus.write_word(0xC00000, 0x1EEE)
    expect(vdp.cram[0]).to eq(0x0EEE)

    bus.write_word(0xC00004, 0x4000) # VSRAM write address 0
    bus.write_word(0xC00004, 0x0010)
    bus.write_word(0xC00000, 0x0BEE)
    expect(vdp.vsram[0]).to eq(0x03EE)

    bus.write_word(0xC00004, 0x0000) # CRAM read address 0
    bus.write_word(0xC00004, 0x0020)
    expect(bus.read_word(0xC00000)).to eq(0x0EEE)
  end

  it 'binds the UI-visible framebuffer to the Mega Drive VDP' do
    emulator = MegaDrive::Emulator.new

    expect(emulator.vdp.framebuffer).to equal(emulator.framebuffer)
  end

  it 'renders scroll-plane tiles before CRAM has been populated' do
    vdp = MegaDrive::VDP.new
    vdp.write_control(0x8144)
    vdp.write_control(0x8200 | 0x30)
    vdp.write_control(0x8F02)
    vdp.write_control(0x4000)
    vdp.write_control(0x0000)
    4.times { vdp.write_data(0x1111) }
    vdp.write_control(0x4000 | 0xC000)
    vdp.write_control(0x0000)
    vdp.write_data(0x0000)
    vdp.render_frame

    expect(vdp.cram.all?(&:zero?)).to be(true)
    expect(vdp.framebuffer.any? { |pixel| pixel != 0 }).to be(true)
  end

  it 'performs memory-to-CRAM DMA through the VDP control port' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    bus.write_word(0x200, 0x000E)
    bus.write_word(0x202, 0x00E0)

    bus.write_word(0xC00004, 0x8114) # DMA enable
    bus.write_word(0xC00004, 0x9312) # length low
    bus.write_word(0xC00004, 0x9400) # length high
    bus.write_word(0xC00004, 0x9500) # source bits 9-1
    bus.write_word(0xC00004, 0x9601) # source bits 16-9
    bus.write_word(0xC00004, 0x9700) # memory-to-VRAM/CRAM
    bus.write_word(0xC00004, 0xC000) # CRAM write address 0
    bus.write_word(0xC00004, 0x0080) # DMA start

    expect(vdp.cram[0]).to eq(0x000E)
    expect(vdp.cram[1]).to eq(0x00E0)
    expect(vdp.registers[19]).to eq(0)
    expect(vdp.registers[20]).to eq(0)
    expect(vdp.registers[21]).to eq(0x12)
    expect(vdp.registers[22]).to eq(0x01)
  end

  it 'performs VRAM fill DMA through the VDP data port' do
    bus = MegaDrive::M68KBus.new(vdp: MegaDrive::VDP.new)

    bus.write_word(0xC00004, 0x8114) # DMA enable
    bus.write_word(0xC00004, 0x9302) # length low
    bus.write_word(0xC00004, 0x9400) # length high
    bus.write_word(0xC00004, 0x9780) # VRAM fill
    bus.write_word(0xC00004, 0x4000) # VRAM write address 0
    bus.write_word(0xC00004, 0x0080) # DMA start
    bus.write_word(0xC00000, 0xAA00)

    expect(bus.vdp.vram[1]).to eq(0xAA)
    expect(bus.vdp.vram[3]).to eq(0xAA)
  end

  it 'performs VRAM copy DMA' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    vdp.vram[0] = 0x5A
    vdp.vram[1] = 0xA5
    vdp.vram[2] = 0xC3
    vdp.vram[3] = 0x3C

    bus.write_word(0xC00004, 0x8114) # DMA enable
    bus.write_word(0xC00004, 0x9302) # length low
    bus.write_word(0xC00004, 0x9400) # length high
    bus.write_word(0xC00004, 0x9500) # source bits 9-1
    bus.write_word(0xC00004, 0x9600)
    bus.write_word(0xC00004, 0x97C0) # VRAM copy
    bus.write_word(0xC00004, 0x4004) # VRAM write address 4
    bus.write_word(0xC00004, 0x0080) # DMA start

    expect(vdp.vram[4]).to eq(0x5A)
    expect(vdp.vram[5]).to eq(0xA5)
    expect(vdp.vram[6]).to eq(0xC3)
    expect(vdp.vram[7]).to eq(0x3C)
  end

  it 'maps zero MD CRAM entries to black instead of the SMS fallback palette' do
    vdp = MegaDrive::VDP.new

    expect(vdp.palette_rgba[0].bytes[0, 3]).to eq([0, 0, 0])
    expect(vdp.palette_rgba[17].bytes[0, 3]).to eq([0, 0, 0])
  end

  it 'keeps the VBlank status bit until VBlank ends' do
    vdp = MegaDrive::VDP.new

    vdp.request_vblank!
    expect(vdp.read_control & 0x0080).to eq(0x0080)

    vdp.acknowledge_interrupt(6)
    expect(vdp.read_control & 0x0080).to eq(0x0080)

    vdp.end_vblank!
    expect(vdp.read_control & 0x0080).to eq(0)
  end

  it 'reports HBlank while a Mega Drive VBlank interrupt is pending' do
    vdp = MegaDrive::VDP.new

    vdp.request_vblank!

    expect(vdp.read_control & 0x0008).to eq(0x0008)
  end

  it 'renders basic sprites from the sprite attribute table' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    bus.write_word(0xC00004, 0x8144)
    bus.write_word(0xC00004, 0x8500) # sprite table at $0000
    bus.write_word(0xC00004, 0x4000)
    bus.write_word(0xC00004, 0x0000)
    bus.write_word(0xC00000, 0x0080) # Y
    bus.write_word(0xC00000, 0x0000) # 1x1, end link
    bus.write_word(0xC00000, 0x0001) # tile 1
    bus.write_word(0xC00000, 0x0080) # X

    bus.write_word(0xC00004, 0x4020) # tile 1 pattern
    bus.write_word(0xC00004, 0x0000)
    4.times { bus.write_word(0xC00000, 0x1111) }
    vdp.render_frame

    expect(vdp.framebuffer[0]).not_to eq(0)
    expect(vdp.framebuffer[7]).not_to eq(0)
  end

  it 'routes the first controller through the Genesis I/O ports' do
    controller = MegaDrive::Controller.new
    bus = MegaDrive::M68KBus.new(controller: controller)
    controller.port_a = 0xFF &
      ~MegaDrive::Controller::START &
      ~MegaDrive::Controller::BUTTON_A &
      ~MegaDrive::Controller::BUTTON_B &
      ~MegaDrive::Controller::BUTTON_C

    bus.write_byte(0xA10009, 0x40)
    bus.write_byte(0xA10003, 0x40)
    expect(bus.read_byte(0xA10002) & 0x10).to eq(0)
    expect(bus.read_byte(0xA10002) & 0x20).to eq(0)
    expect(bus.read_byte(0xA10003) & 0x10).to eq(0)

    bus.write_byte(0xA10003, 0x00)
    expect(bus.read_byte(0xA10002) & 0x10).to eq(0)
    expect(bus.read_byte(0xA10002) & 0x20).to eq(0)
    expect(bus.read_byte(0xA10003) & 0x20).to eq(0)
    expect(bus.read_word(0xA10002) & 0x20).to eq(0)
  end

  it 'duplicates byte writes to Mega Drive VDP ports like the 16-bit bus' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)

    bus.write_byte(0xC00004, 0x8F)
    expect(vdp.registers[15]).to eq(0x8F)

    bus.write_word(0xC00004, 0x4000)
    bus.write_byte(0xC00000, 0xA5)
    expect(vdp.vram[0]).to eq(0xA5)
    expect(vdp.vram[1]).to eq(0xA5)
  end

  it 'mirrors normal cartridge ROM reads across the MD cart window' do
    bus = MegaDrive::M68KBus.new
    bus.load_rom([0x12, 0x34, 0x56, 0x78])

    expect(bus.read_word(0)).to eq(0x1234)
    expect(bus.read_word(0x80000)).to eq(0x1234)
    expect(bus.read_word(0x9FFFFE)).to eq(0x5678)
  end

  it 'mirrors the 68k work RAM across the E00000-FFFFFF range' do
    bus = MegaDrive::M68KBus.new

    bus.write_word(0xE00000, 0x1234)
    expect(bus.read_word(0xFF0000)).to eq(0x1234)

    bus.write_word(0xFFFFFE, 0xABCD)
    expect(bus.read_word(0xE0FFFE)).to eq(0xABCD)
  end

  it 'reports configured Mega Drive timing and region through the version register' do
    emulator = MegaDrive::Emulator.new

    expect(emulator.bus.read_byte(0xA10001)).to eq(0xA0)

    emulator.configure_region(timing: :pal, region: :eu)
    expect(emulator.bus.read_byte(0xA10001)).to eq(0xE0)

    emulator.configure_region(timing: :ntsc, region: :jp)
    expect(emulator.bus.read_byte(0xA10001)).to eq(0x80)
  end

  it 'uses the Genesis VRAM odd-address word lane mapping' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)

    bus.write_word(0xC00004, 0x4001)
    bus.write_word(0xC00004, 0x0000)
    bus.write_word(0xC00000, 0x1234)

    expect(vdp.vram[1]).to eq(0x12)
    expect(vdp.vram[0]).to eq(0x34)
    bus.write_word(0xC00004, 0x0001)
    bus.write_word(0xC00004, 0x0000)
    expect(vdp.read_data).to eq(0x1234)
  end

end
