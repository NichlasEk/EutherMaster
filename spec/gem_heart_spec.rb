require 'spec_helper'

RSpec.describe AstralVerse::GemHeart do
  let(:vault) { AstralVerse::CrystalVault.new }
  let(:heart) { AstralVerse::GemHeart.new(vault) }

  describe '#attune' do
    it 'cleanses all essences to zero' do
      heart.amber = 0x42
      heart.attune
      expect(heart.amber).to eq(0)
      expect(heart.beryl).to eq(0)
      expect(heart.force).to eq(0)
    end

    it 'rests the prophecy scroll at the beginning' do
      expect(heart.prophecy_scroll).to eq(0)
    end

    it 'fills the mana well near the shard pool summit' do
      expect(heart.mana_well).to eq(0xDFF0)
    end

    it 'awakens with ears closed to omens' do
      expect(heart.ear_open_1).to be false
      expect(heart.ear_open_2).to be false
    end
  end

  describe '#weave_incantation — STILLNESS (0x00)' do
    it 'consumes 4 pulses of cosmic energy' do
      pulses = heart.weave_incantation
      expect(pulses).to eq(4)
      expect(heart.total_pulse).to eq(4)
    end
  end

  describe '#weave_incantation — BIND AMBER (0x3E)' do
    it 'infuses amber with the drawn essence' do
      vault.etch_essence(0xC000, 0x3E)
      vault.etch_essence(0xC001, 0xAB)
      heart.prophecy_scroll = 0xC000
      heart.weave_incantation
      expect(heart.amber).to eq(0xAB)
      expect(heart.prophecy_scroll).to eq(0xC002)
    end
  end

  describe '#weave_incantation — PURGE AMBER (0xAF)' do
    it 'shatters amber to void and seals karma of emptiness' do
      heart.amber = 0x55
      vault.etch_essence(0xC000, 0xAF)
      heart.prophecy_scroll = 0xC000
      heart.weave_incantation
      expect(heart.amber).to eq(0)
      expect(heart.karma_void?).to be true
      expect(heart.karma_carry?).to be false
    end
  end

  describe '#weave_incantation — ENTER TRANCE (0x76)' do
    it 'sends the GemHeart into deep slumber' do
      vault.etch_essence(0xC000, 0x76)
      heart.prophecy_scroll = 0xC000
      heart.weave_incantation
      expect(heart.in_trance).to be true
      expect(heart.weave_incantation).to eq(0)
    end
  end

  describe '#weave_incantation — LEAP (0xC3)' do
    it 'shifts the prophecy scroll to a new leyline' do
      vault.etch_essence(0xC000, 0xC3)
      vault.etch_essence(0xC001, 0x34)
      vault.etch_essence(0xC002, 0x12)
      heart.prophecy_scroll = 0xC000
      heart.weave_incantation
      expect(heart.prophecy_scroll).to eq(0x1234)
    end
  end

  describe '#soul vessel (AF)' do
    it 'holds amber in the high aura and force in the low' do
      heart.amber = 0x12
      heart.force = 0x34
      expect(heart.soul).to eq(0x1234)

      heart.soul = 0xBEEF
      expect(heart.amber).to eq(0xBE)
      expect(heart.force).to eq(0xEF)
    end
  end

  describe '#core vessel (BC)' do
    it 'holds beryl and citrine as one' do
      heart.beryl = 0xAA
      heart.citrine = 0xBB
      expect(heart.core).to eq(0xAABB)
    end
  end

  describe '#depth vessel (DE)' do
    it 'holds diamond and emerald as one' do
      heart.diamond = 0x11
      heart.emerald = 0x22
      expect(heart.depth).to eq(0x1122)
    end
  end

  describe '#spirit vessel (HL)' do
    it 'holds jade and lapis as one' do
      heart.jade = 0x33
      heart.lapis = 0x44
      expect(heart.spirit).to eq(0x3344)
    end
  end

  describe '#mana well (stack)' do
    it 'pushes and pops souls in LIFO order' do
      heart.prophecy_scroll = 0x1234
      heart.push_soul(heart.prophecy_scroll)
      expect(heart.pop_soul).to eq(0x1234)
    end
  end
end
