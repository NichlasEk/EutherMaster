require 'spec_helper'

RSpec.describe SmsEmulator::PSG do
  it 'latches tone period writes across low and high data bytes' do
    psg = described_class.new

    psg.write(0x80 | 0x06)
    psg.write(0x20)

    expect(psg.tone_periods[0]).to eq(0x206)
    expect(psg.tone_frequency(0)).to be > 0
  end

  it 'latches channel volumes using SN76489 attenuation levels' do
    psg = described_class.new

    psg.write(0x90 | 0x00)
    expect(psg.channel_volume(0)).to eq(1.0)

    psg.write(0x90 | 0x0F)
    expect(psg.channel_volume(0)).to eq(0.0)
  end

  it 'updates noise control and exposes white noise mode' do
    psg = described_class.new

    psg.write(0xE0 | 0x07)

    expect(psg.noise_control).to eq(0x07)
    expect(psg).to be_white_noise
  end

  it 'treats tone period zero as one like SN76489 hardware' do
    psg = described_class.new

    psg.write(0x80)
    psg.write(0x00)

    expect(psg.tone_periods[0]).to eq(0)
    expect(psg.tone_frequency(0)).to be_within(0.001).of(described_class::CLOCK / 32.0)
  end

  it 'renders bounded mixed samples' do
    psg = described_class.new
    psg.write(0x80 | 0x08)
    psg.write(0x10)
    psg.write(0x90 | 0x00)

    samples = psg.render_samples(32)

    expect(samples.length).to eq(32)
    expect(samples.all? { |sample| sample.between?(-1.0, 1.0) }).to be true
  end

  it 'renders frame samples by replaying writes at their frame cycle' do
    psg = described_class.new
    psg.write(0x80 | 0x08)
    psg.write(0x00)
    psg.begin_frame
    psg.write(0x90 | 0x0F, cycle: 0)
    psg.write(0x90 | 0x00, cycle: 100)

    samples = psg.render_frame_samples(64, 200)

    expect(samples[0, 32].map(&:abs).sum).to be < 0.001
    expect(samples[32, 32].map(&:abs).sum).to be > 0.001
  end

  it 'does not let audio replay overwrite late live volume writes' do
    psg = described_class.new
    psg.write(0x80 | 0x08)
    psg.write(0x00)
    psg.write(0x90 | 0x00)
    psg.begin_frame
    psg.write(0x90 | 0x0F, cycle: 199)

    psg.render_frame_samples(64, 200)

    expect(psg.volumes[0]).to eq(15)
  end
end

RSpec.describe SmsEmulator::Memory do
  it 'routes PSG writes through both SMS sound ports' do
    psg = SmsEmulator::PSG.new
    memory = described_class.new(nil, nil, psg)

    memory.write_io(0x7E, 0x90)
    memory.write_io(0x7F, 0x95)

    expect(psg.writes).to eq(2)
    expect(psg.volumes[0]).to eq(5)
  end
end
