require 'spec_helper'

RSpec.describe AstralVerse::MysticTouch do
  let(:touch) { AstralVerse::MysticTouch.new }

  describe '#attune' do
    it 'rests both palms to high (no gesture)' do
      touch.invoke(AstralVerse::MysticTouch::GESTURE_NORTH)
      touch.attune
      expect(touch.left_palm).to eq(0xFF)
      expect(touch.right_palm).to eq(0xFF)
    end
  end

  describe '#invoke and #release' do
    it 'presses a gesture on the left palm' do
      touch.invoke(AstralVerse::MysticTouch::GESTURE_NORTH)
      expect(touch.left_palm).to eq(0xFF & ~AstralVerse::MysticTouch::GESTURE_NORTH)
    end

    it 'releases a gesture on the left palm' do
      touch.invoke(AstralVerse::MysticTouch::GESTURE_PRIMUS)
      touch.release(AstralVerse::MysticTouch::GESTURE_PRIMUS)
      expect(touch.left_palm).to eq(0xFF)
    end
  end
end
