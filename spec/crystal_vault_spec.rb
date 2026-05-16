require 'spec_helper'

RSpec.describe AstralVerse::CrystalVault do
  let(:vault) { AstralVerse::CrystalVault.new }

  describe '#channel_essence' do
    it 'reads from crystal shards at mirrored leylines' do
      vault.etch_essence(0xC000, 0x42)
      expect(vault.channel_essence(0xC000)).to eq(0x42)
      expect(vault.channel_essence(0xE000)).to eq(0x42)
    end

    it 'reads from ancient codex' do
      vault.inscribe_codex([0xAB, 0xCD])
      expect(vault.channel_essence(0x0000)).to eq(0xAB)
      expect(vault.channel_essence(0x0001)).to eq(0xCD)
    end
  end

  describe '#etch_essence' do
    it 'writes only to crystal shards' do
      vault.etch_essence(0xC000, 0x42)
      expect(vault.crystal_shards[0]).to eq(0x42)
    end

    it 'does not deface the ancient codex' do
      vault.inscribe_codex([0xAB])
      vault.etch_essence(0x0000, 0xFF)
      expect(vault.channel_essence(0x0000)).to eq(0xAB)
    end
  end

  describe '#channel_word' do
    it 'reads two essences as one rune' do
      vault.etch_essence(0xC000, 0x34)
      vault.etch_essence(0xC001, 0x12)
      expect(vault.channel_word(0xC000)).to eq(0x1234)
    end
  end
end
