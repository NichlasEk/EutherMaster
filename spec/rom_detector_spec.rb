require 'spec_helper'
require 'tmpdir'

RSpec.describe AstralVerse::RomDetector do
  def bytes(size)
    Array.new(size, 0)
  end

  def seven_zip_available?
    system('7z', 'i', out: File::NULL, err: File::NULL)
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

  it 'detects interleaved SMD copier dumps even when they have the wrong extension' do
    raw = bytes(0x4000)
    raw[0x100, 4] = 'SEGA'.bytes
    raw[0x1F0, 3] = 'JUE'.bytes
    smd = bytes(512)
    raw.each_slice(0x4000) do |block|
      even = []
      odd = []
      (0...(block.length / 2)).each do |index|
        even << block[index * 2]
        odd << block[(index * 2) + 1]
      end
      smd.concat(odd)
      smd.concat(even)
    end

    info = described_class.detect(smd, path: 'contra.md')

    expect(info.system).to eq(:mega_drive)
    expect(info.format).to eq(:mega_drive_smd)
    expect(info.smd_interleaved).to be true
    expect(info.header_offset).to eq(0x100)
    expect(info.md_regions).to eq(%i[jp us eu])
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

  it 'detects and loads ROMs from zip archives' do
    skip '7z not installed' unless seven_zip_available?

    Dir.mktmpdir do |dir|
      rom = bytes(0x200)
      rom[0x100, 4] = 'SEGA'.bytes
      rom_path = File.join(dir, 'sonic.md')
      archive_path = File.join(dir, 'sonic.zip')
      File.binwrite(rom_path, rom.pack('C*'))
      system('7z', 'a', '-tzip', archive_path, rom_path, out: File::NULL, err: File::NULL)

      loaded = described_class.load_rom_file(archive_path)

      expect(loaded[:info].system).to eq(:mega_drive)
      expect(loaded[:info].name).to eq('sonic.md')
      expect(loaded[:bytes][0x100, 4]).to eq('SEGA'.bytes)
    end
  end

  it 'detects and loads ROMs from 7z archives' do
    skip '7z not installed' unless seven_zip_available?

    Dir.mktmpdir do |dir|
      rom = bytes(0x8000)
      rom[0x7FF0, 8] = 'TMR SEGA'.bytes
      rom[0x7FFF] = 0x40
      rom_path = File.join(dir, 'alex.sms')
      archive_path = File.join(dir, 'alex.7z')
      File.binwrite(rom_path, rom.pack('C*'))
      system('7z', 'a', archive_path, rom_path, out: File::NULL, err: File::NULL)

      loaded = described_class.load_rom_file(archive_path)

      expect(loaded[:info].system).to eq(:sms)
      expect(loaded[:info].name).to eq('alex.sms')
      expect(loaded[:bytes][0x7FF0, 8]).to eq('TMR SEGA'.bytes)
    end
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
