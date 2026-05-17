require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Mega Drive ROM loading' do
  def write_md_rom(path)
    rom = Array.new(0x200, 0)
    rom[0x000, 4] = [0x00, 0x00, 0x10, 0x00]
    rom[0x004, 4] = [0x00, 0x00, 0x01, 0x20]
    rom[0x100, 4] = 'SEGA'.bytes
    rom[0x120, 2] = [0x70, 0x01] # MOVEQ #1,D0
    File.binwrite(path, rom.pack('C*'))
  end

  it 'routes Mega Drive ROMs to the MegaDrive emulator' do
    path = File.join(Dir.mktmpdir, 'tiny.md')
    write_md_rom(path)

    stone = AstralVerse::ScryingStone.new
    stone.absorb_codex(path)

    expect(stone.rom_info.system).to eq(:mega_drive)
    expect(stone.emulator).to be_a(MegaDrive::Emulator)
    expect(stone.emulator.cpu.pc).to eq(0x120)
  end
end
