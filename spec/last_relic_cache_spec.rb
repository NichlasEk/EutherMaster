require 'tmpdir'
require_relative '../lib/astral_verse/last_relic_cache'

RSpec.describe AstralVerse::LastRelicCache do
  around do |example|
    Dir.mktmpdir do |dir|
      old_dir = Dir.pwd
      Dir.chdir(dir)
      example.run
    ensure
      Dir.chdir(old_dir)
    end
  end

  it 'saves paths and UI settings to one TOML file' do
    rom_dir = Dir.pwd
    rom_path = File.join(rom_dir, 'game.sms')
    File.write(rom_path, 'rom')

    described_class.save_relic(rom_path)
    described_class.save_rom_dir(rom_dir)
    described_class.save_volume(0.42)
    described_class.save_debug_mask(true)
    described_class.save_timing_mode(:pal)
    described_class.save_region_mode(:eu)

    config = File.read('.astralverse.toml')
    expect(config).to include('[paths]')
    expect(config).to include("last_relic = \"#{rom_path}\"")
    expect(config).to include("rom_dir = \"#{rom_dir}\"")
    expect(config).to include('[ui]')
    expect(config).to include('volume = 0.42')
    expect(config).to include('debug_mask = true')
    expect(config).to include('autostart = true')
    expect(config).to include('timing_mode = "pal"')
    expect(config).to include('region_mode = "eu"')

    expect(described_class.last_relic).to eq(rom_path)
    expect(described_class.rom_dir).to eq(rom_dir)
    expect(described_class.volume).to eq(0.42)
    expect(described_class.debug_mask?).to be(true)
    expect(described_class.autostart?).to be(true)
    expect(described_class.timing_mode).to eq('pal')
    expect(described_class.region_mode).to eq('eu')
  end

  it 'falls back to the old cache files when TOML has not been written yet' do
    rom_path = File.join(Dir.pwd, 'legacy.sms')
    File.write(rom_path, 'rom')
    File.write('.astralverse_cache', rom_path)
    File.write('.astralverse_rom_dir', Dir.pwd)

    expect(described_class.last_relic).to eq(rom_path)
    expect(described_class.rom_dir).to eq(Dir.pwd)
  end
end
