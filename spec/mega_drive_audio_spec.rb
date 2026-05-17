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
end
