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
    expect(vdp.framebuffer.any? { |pixel| pixel != 0 }).to be(true)
  end

  it 'binds the UI-visible framebuffer to the Mega Drive VDP' do
    emulator = MegaDrive::Emulator.new

    expect(emulator.vdp.framebuffer).to equal(emulator.framebuffer)
  end

  it 'renders scroll-plane tiles before CRAM has been populated' do
    vdp = MegaDrive::VDP.new
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
  end
end
