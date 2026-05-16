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

  it 'mirrors mapper registers into RAM so games can save and restore banks' do
    memory = described_class.new
    memory.load_rom(Array.new(0xC000, 0))

    expect(memory.read_byte(0xFFFC)).to eq(0)
    expect(memory.read_byte(0xFFFD)).to eq(0)
    expect(memory.read_byte(0xFFFE)).to eq(1)
    expect(memory.read_byte(0xFFFF)).to eq(2)

    memory.write_byte(0xFFFF, 0x82)

    expect(memory.read_byte(0xFFFF)).to eq(0x82)
  end

  it 'routes VDP ports through the memory bus' do
    vdp = SmsEmulator::VDP.new
    memory = described_class.new(vdp)

    memory.write_io(0xBF, 0xE0)
    memory.write_io(0xBF, 0x81)

    expect(vdp.registers[1]).to eq(0xE0)
  end

  it 'routes mirrored SMS VDP ports by bit pattern' do
    vdp = SmsEmulator::VDP.new
    memory = described_class.new(vdp)

    memory.write_io(0x81, 0x00)
    memory.write_io(0x81, 0x40)
    memory.write_io(0x80, 0x7B)
    memory.write_io(0x81, 0x00)
    memory.write_io(0x81, 0x00)

    expect(memory.read_io(0x80)).to eq(0x7B)
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

    vdp.vram[sprite_base] = 10
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

  it 'only terminates mode 4 sprite scanning on the D0 marker' do
    vdp = described_class.new
    vdp.registers[1] = 0x40
    vdp.registers[5] = 0x7E
    vdp.cram[17] = 0x15
    sprite_base = 0x3F00

    vdp.vram[sprite_base] = 0xD5
    vdp.vram[sprite_base + 1] = 10
    vdp.vram[sprite_base + 0x82] = 20
    vdp.vram[sprite_base + 0x83] = 1
    vdp.vram[32] = 0x80

    vdp.render_scanline(10)

    expect(vdp.framebuffer[10 * described_class::SMS_WIDTH + 20]).to eq(0x15)
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

  it 'uses the VDP read buffer and prefetches on VRAM read commands' do
    vdp = described_class.new
    vdp.vram[0x1234] = 0xAB
    vdp.vram[0x1235] = 0xCD

    vdp.write_control(0x34)
    vdp.write_control(0x12)

    expect(vdp.read_data).to eq(0xAB)
    expect(vdp.read_data).to eq(0xCD)
  end

  it 'keeps the composed VDP address after register writes' do
    vdp = described_class.new

    vdp.write_control(0xE0)
    vdp.write_control(0x81)
    vdp.write_data(0x44)

    expect(vdp.registers[1]).to eq(0xE0)
    expect(vdp.vram[0x01E0]).to eq(0x44)
  end

  it 'keeps address high bits when a new control sequence writes only the low byte first' do
    vdp = described_class.new

    vdp.write_control(0x34)
    vdp.write_control(0x12)
    vdp.read_data
    vdp.write_control(0x56)
    vdp.write_data(0x99)

    expect(vdp.vram[0x1256]).to eq(0x99)
  end

  it 'replaces address high bits on the second control byte' do
    vdp = described_class.new

    vdp.write_control(0x34)
    vdp.write_control(0x3F)
    vdp.write_control(0x56)
    vdp.write_control(0x40)
    vdp.write_data(0x99)

    expect(vdp.vram[0x0056]).to eq(0x99)
    expect(vdp.vram[0x3F56]).to eq(0)
  end

end

RSpec.describe AstralVerse::ScryingStone do
  it 'advances a halted ROM frame without locking the caller' do
    stone = described_class.new
    stone.absorb_codex_essence([0x76])

    expect { stone.gaze_frame }.not_to raise_error
    expect(stone.emulator.cpu.halted).to be true
  end

  it 'saves and loads emulator snapshots' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'state.bin')
      stone = described_class.new
      stone.absorb_codex_essence([0x00, 0x76])
      stone.gaze_frame
      saved_pc = stone.emulator.cpu.pc

      stone.save_snapshot(path)
      stone.emulator.cpu.pc = 0x1234
      stone.emulator.cpu.instance_variable_set(:@memory, nil)
      stone.load_snapshot(path)

      expect(stone.emulator.cpu.pc).to eq(saved_pc)
      expect(stone.emulator.cpu.memory).to equal(stone.emulator.memory)
      expect(stone.emulator.memory.vdp).to equal(stone.emulator.vdp)
      expect(stone.vision_sprite.scrying_pool).to eq(stone.emulator.vdp.framebuffer)
    end
  end
end
