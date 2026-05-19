require 'spec_helper'

RSpec.describe AstralVerse::RomDetector do
  def bytes(size)
    Array.new(size, 0)
  end

  it 'detects Mega Drive ROMs from the SEGA header' do
    rom = bytes(0x200)
    rom[0x100, 4] = 'SEGA'.bytes
    rom[0x1F0, 3] = 'JUE'.bytes

    info = described_class.detect(rom, path: 'sonic.bin')

    expect(info.system).to eq(:mega_drive)
    expect(info.label).to eq('MD')
    expect(info.header_offset).to eq(0x100)
    expect(info.md_regions).to eq(%i[jp us eu])
  end

  it 'detects copier-headered Mega Drive ROMs' do
    rom = bytes(0x400)
    rom[0x300, 4] = 'SEGA'.bytes

    info = described_class.detect(rom, path: 'game.bin')

    expect(info.system).to eq(:mega_drive)
    expect(info.copier_header).to be true
  end

  it 'detects SMS and Game Gear ROMs from the TMR SEGA header' do
    sms = bytes(0x8000)
    sms[0x7FF0, 8] = 'TMR SEGA'.bytes
    sms[0x7FFF] = 0x40

    gg = bytes(0x8000)
    gg[0x7FF0, 8] = 'TMR SEGA'.bytes
    gg[0x7FFF] = 0x60

    expect(described_class.detect(sms, path: 'alex.bin').system).to eq(:sms)
    expect(described_class.detect(gg, path: 'sonic.bin').system).to eq(:game_gear)
  end

  it 'uses specific extensions as fallback for headerless ROMs' do
    expect(described_class.detect(bytes(0x1000), path: 'homebrew.sms').system).to eq(:sms)
    expect(described_class.detect(bytes(0x1000), path: 'homebrew.gg').system).to eq(:game_gear)
    expect(described_class.detect(bytes(0x1000), path: 'homebrew.md').system).to eq(:mega_drive)
    expect(described_class.detect(bytes(0x1000), path: 'unknown.bin')).to be_nil
  end

  it 'parses old-style Mega Drive region fields from all three bytes' do
    rom = bytes(0x200)
    rom[0x100, 4] = 'SEGA'.bytes
    rom[0x1F0, 3] = ' E '.bytes

    expect(described_class.detect(rom, path: 'pal.md').md_regions).to eq([:eu])
  end

  it 'parses new-style Mega Drive region bitfields' do
    rom = bytes(0x200)
    rom[0x100, 4] = 'SEGA'.bytes
    rom[0x1F0, 3] = 'C  '.bytes

    expect(described_class.detect(rom, path: 'world.md').md_regions).to eq(%i[us eu])
  end
end
