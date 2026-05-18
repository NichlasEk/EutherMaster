require 'spec_helper'

RSpec.describe 'Mega Drive audio' do
  it 'routes YM2612 port writes through the 68k bus' do
    ym2612 = MegaDrive::YM2612.new
    bus = MegaDrive::M68KBus.new(ym2612: ym2612)

    bus.write_word(0xA04000, 0xA034)

    expect(ym2612.registers[0][0xA0]).to eq(0x34)
    expect(ym2612.read_register & 0x80).to eq(0x80)

    ym2612.tick(32)
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
