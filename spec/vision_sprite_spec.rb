require 'spec_helper'

RSpec.describe AstralVerse::VisionSprite do
  let(:sprite) { AstralVerse::VisionSprite.new }

  describe '#attune' do
    it 'cleanses all astral ink to zero' do
      sprite.astral_ink[0] = 0xFF
      sprite.attune
      expect(sprite.astral_ink[0]).to eq(0)
    end

    it 'silences the omen line' do
      sprite.omen_line = true
      sprite.attune
      expect(sprite.omen_line).to be false
    end

    it 'resets the scrying pool to darkness' do
      sprite.scrying_pool[0] = 0xFF
      sprite.attune
      expect(sprite.scrying_pool[0]).to eq(0)
    end
  end

  describe '#channel_ink' do
    it 'reads essence from the astral ink at the latched leyline' do
      sprite.etch_command(0x00)
      sprite.etch_command(0x00)
      sprite.etch_ink(0x42)
      sprite.instance_variable_set(:@leyline_latch, 0)
      sprite.instance_variable_set(:@etch_pending, false)
      expect(sprite.channel_ink).to eq(0x42)
    end
  end

  describe '#etch_ink' do
    it 'writes essence into astral ink' do
      sprite.instance_variable_set(:@leyline_latch, 0)
      sprite.instance_variable_set(:@code_sigil, 0)
      sprite.etch_ink(0x42)
      expect(sprite.astral_ink[0]).to eq(0x42)
    end

    it 'writes into chroma soul when code sigil is 3' do
      sprite.instance_variable_set(:@leyline_latch, 0x05)
      sprite.instance_variable_set(:@code_sigil, 3)
      sprite.etch_ink(0xAB)
      expect(sprite.chroma_soul[0x05]).to eq(0xAB)
    end
  end

  describe '#etch_command' do
    it 'sets the leyline latch on first etch' do
      sprite.etch_command(0x42)
      expect(sprite.instance_variable_get(:@leyline_latch)).to eq(0x42)
      expect(sprite.instance_variable_get(:@etch_pending)).to be true
    end

    it 'completes leyline binding on second etch' do
      sprite.etch_command(0x42)  # low
      sprite.etch_command(0x00)  # high + code
      expect(sprite.instance_variable_get(:@leyline_latch)).to eq(0x0042)
    end
  end

  describe '#channel_karma' do
    it 'returns and clears the karma register' do
      sprite.instance_variable_set(:@karma, 0x80)
      expect(sprite.channel_karma).to eq(0x80)
      expect(sprite.instance_variable_get(:@karma)).to eq(0x00)
    end
  end
end
