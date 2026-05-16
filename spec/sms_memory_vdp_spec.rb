require 'spec_helper'

RSpec.describe SmsEmulator::Memory do
  it 'maps Sega cartridge banks through mapper registers' do
    data = Array.new(0x10000, 0)
    data[0x0400] = 0x10
    data[0x4400] = 0x20

    memory = described_class.new
    memory.load_rom(data)

    expect(memory.read_byte(0x0400)).to eq(0x10)
    memory.write_byte(0xFFFD, 1)
    expect(memory.read_byte(0x0400)).to eq(0x20)
  end

  it 'routes VDP ports through the memory bus' do
    vdp = SmsEmulator::VDP.new
    memory = described_class.new(vdp)

    memory.write_io(0xBF, 0xE0)
    memory.write_io(0xBF, 0x81)

    expect(vdp.registers[1]).to eq(0xE0)
  end

  it 'mirrors controller reads on the alternate SMS input ports' do
    controller = SmsEmulator::Controller.new
    memory = described_class.new(nil, controller)
    controller.press(SmsEmulator::Controller::BUTTON_A)

    expect(memory.read_io(0xDC) & SmsEmulator::Controller::BUTTON_A).to eq(0)
    expect(memory.read_io(0xDE) & SmsEmulator::Controller::BUTTON_A).to eq(0)
  end
end

RSpec.describe SmsEmulator::VDP do
  it 'renders mode 4 background tiles into the framebuffer' do
    vdp = described_class.new
    vdp.write_control(0x00)
    vdp.write_control(0x78) # VRAM write at $3800
    vdp.write_data(0x01)
    vdp.write_data(0x08) # tile 1, palette 1

    tile_base = 32
    vdp.vram[tile_base] = 0x80
    vdp.cram[17] = 0x2A
    vdp.registers[1] = 0x40
    vdp.registers[2] = 0x0E

    vdp.render_scanline(0)

    expect(vdp.framebuffer[0]).to eq(0x2A)
  end

  it 'renders sprites over the background using sprite palette colors' do
    vdp = described_class.new
    vdp.registers[1] = 0x40
    vdp.registers[5] = 0x7E
    vdp.cram[17] = 0x15
    sprite_base = 0x3F00

    vdp.vram[sprite_base] = 9
    vdp.vram[sprite_base + 0x80] = 20
    vdp.vram[sprite_base + 0x81] = 1
    vdp.vram[32] = 0x80

    vdp.render_scanline(10)

    expect(vdp.framebuffer[10 * described_class::SMS_WIDTH + 20]).to eq(0x15)
  end

  it 'sets sprite collision and overflow status bits' do
    vdp = described_class.new
    vdp.registers[1] = 0x40
    vdp.registers[5] = 0x7E
    vdp.cram[17] = 0x15
    sprite_base = 0x3F00
    vdp.vram[32] = 0x80

    9.times do |index|
      vdp.vram[sprite_base + index] = 9
      vdp.vram[sprite_base + 0x80 + index * 2] = 20
      vdp.vram[sprite_base + 0x81 + index * 2] = 1
    end

    vdp.render_frame

    expect(vdp.read_status & 0x60).to eq(0x60)
  end

  it 'uses backdrop color when display is disabled' do
    vdp = described_class.new
    vdp.cram[18] = 0x2C
    vdp.registers[7] = 0x02

    vdp.render_scanline(0)

    expect(vdp.framebuffer[0]).to eq(0x2C)
  end

  it 'blanks the leftmost column when register 0 requests it' do
    vdp = described_class.new
    vdp.registers[0] = 0x20
    vdp.registers[1] = 0x40
    vdp.registers[2] = 0x0E
    vdp.registers[7] = 0x02
    vdp.cram[1] = 0x11
    vdp.cram[18] = 0x22
    vdp.vram[0x3800] = 1
    vdp.vram[0x3802] = 1
    vdp.vram[32] = 0xFF

    vdp.render_scanline(0)

    expect(vdp.framebuffer[0]).to eq(0x22)
    expect(vdp.framebuffer[8]).to eq(0x11)
  end
end

RSpec.describe AstralVerse::ScryingStone do
  it 'advances a halted ROM frame without locking the caller' do
    stone = described_class.new
    stone.absorb_codex_essence([0x76])

    expect { stone.gaze_frame }.not_to raise_error
    expect(stone.emulator.cpu.halted).to be true
  end
end
