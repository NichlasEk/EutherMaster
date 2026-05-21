require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Mega Drive audio' do
  it 'routes YM2612 port writes through the 68k bus' do
    ym2612 = MegaDrive::YM2612.new
    bus = MegaDrive::M68KBus.new(ym2612: ym2612)

    bus.write_word(0xA04000, 0xA034)

    expect(ym2612.registers[0][0xA0]).to eq(0x34)
    expect(ym2612.read_register & 0x80).to eq(0x80)

    ym2612.tick(MegaDrive::YM2612::WRITE_BUSY_CYCLES)
    expect(ym2612.read_register & 0x80).to eq(0)
  end

  it 'routes PSG writes through the VDP data window' do
    psg = MegaDrive::PSG.new
    bus = MegaDrive::M68KBus.new(psg: psg)

    bus.write_word(0xC00010, 0x009F)

    expect(psg.writes).to eq(1)
    expect(psg.write_log.last[:value]).to eq(0x9F)
  end

  it 'renders a keyed-on YM2612 carrier' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0x4C)
    ym2612.write_data(0x00)
    ym2612.write_address_1(0x5C)
    ym2612.write_data(0x1F)
    ym2612.write_address_1(0xA0)
    ym2612.write_data(0x6A)
    ym2612.write_address_1(0xA4)
    ym2612.write_data((4 << 3) | 0x02)
    ym2612.write_address_1(0xB4)
    ym2612.write_data(0xC0)
    ym2612.begin_frame
    ym2612.write_address_1(0x28)
    ym2612.write_data(0xF0)

    samples = ym2612.render_frame_samples(128, 1_000)

    expect(samples.flatten.any? { |sample| sample.abs > 0.001 }).to be(true)
  end

  it 'converts YM2612 fnum/block to Mega Drive pitch scale' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0xA0)
    ym2612.write_data(0x6A)
    ym2612.write_address_1(0xA4)
    ym2612.write_data((4 << 3) | 0x02)

    expect(ym2612.send(:channel_frequency, 0)).to be_within(0.5).of(261.95)
  end

  it 'replays YM2612 DAC sample writes at their frame cycles' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_register(0, 0x2B, 0x80)
    ym2612.begin_frame
    ym2612.write_register(0, 0x2A, 0x00, cycle: 0)
    ym2612.write_register(0, 0x2A, 0xFF, cycle: 80)

    samples = ym2612.render_frame_mono_samples(32, 160)

    expect(samples[6]).to be < -0.03
    expect(samples[24]).to be > 0.03
  end

  it 'releases YM2612 operators after key-off instead of leaving notes stuck' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0x4C)
    ym2612.write_data(0x00)
    ym2612.write_address_1(0x5C)
    ym2612.write_data(0x1F)
    ym2612.write_address_1(0x8C)
    ym2612.write_data(0x0F)
    ym2612.write_address_1(0xA0)
    ym2612.write_data(0x6A)
    ym2612.write_address_1(0xA4)
    ym2612.write_data((4 << 3) | 0x02)
    ym2612.begin_frame
    ym2612.write_address_1(0x28)
    ym2612.write_data(0x80)
    keyed = ym2612.render_frame_samples(128, 1_000).flatten.map(&:abs).max

    ym2612.begin_frame
    ym2612.write_address_1(0x28)
    ym2612.write_data(0x00)
    released = ym2612.render_frame_samples(2_048, 16_000).flatten.last(512).map(&:abs).max

    expect(keyed).to be > 0.001
    expect(released).to be < keyed
  end

  it 'advances YM2612 timers and clears status flags through timer control' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0x24)
    ym2612.write_data(0xFF)
    ym2612.write_address_1(0x25)
    ym2612.write_data(0x03)
    ym2612.write_address_1(0x27)
    ym2612.write_data(0x05)

    ym2612.tick(MegaDrive::YM2612::TIMER_TICK_CYCLES)
    expect(ym2612.read_register & 0x01).to eq(0x01)

    ym2612.write_address_1(0x27)
    ym2612.write_data(0x10)
    expect(ym2612.read_register & 0x01).to eq(0)
  end

  it 'paces YM2612 timers at master clock divided by 144' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0x24)
    ym2612.write_data(0xFF)
    ym2612.write_address_1(0x25)
    ym2612.write_data(0x03)
    ym2612.write_address_1(0x27)
    ym2612.write_data(0x05)

    ym2612.tick(143)
    expect(ym2612.read_register & 0x01).to eq(0)

    ym2612.tick(1)
    expect(ym2612.read_register & 0x01).to eq(0x01)
  end

  it 'does not raise YM timer flags unless timer flag bits are enabled' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0x24)
    ym2612.write_data(0xFF)
    ym2612.write_address_1(0x25)
    ym2612.write_data(0x03)
    ym2612.write_address_1(0x27)
    ym2612.write_data(0x01)

    ym2612.tick(MegaDrive::YM2612::TIMER_TICK_CYCLES)

    expect(ym2612.read_register & 0x01).to eq(0)
  end

  it 'does not let audio rendering roll back live YM busy and timer state' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.begin_frame
    ym2612.write_address_1(0xA0)
    ym2612.write_data(0x34)
    ym2612.tick(MegaDrive::YM2612::WRITE_BUSY_CYCLES)

    ym2612.render_frame_samples(64, 1_000)

    expect(ym2612.read_register & 0x80).to eq(0)
  end

  it 'downmixes both YM2612 stereo channels into the mono audio path' do
    configure = lambda do |ym2612|
      ym2612.write_address_1(0x4C)
      ym2612.write_data(0x00)
      ym2612.write_address_1(0x5C)
      ym2612.write_data(0x1F)
      ym2612.write_address_1(0xA0)
      ym2612.write_data(0x6A)
      ym2612.write_address_1(0xA4)
      ym2612.write_data((4 << 3) | 0x02)
      ym2612.write_address_1(0xB4)
      ym2612.write_data(0x80)
      ym2612.begin_frame
      ym2612.write_address_1(0x28)
      ym2612.write_data(0xF0)
    end
    stereo_ym = MegaDrive::YM2612.new
    mono_ym = MegaDrive::YM2612.new
    configure.call(stereo_ym)
    configure.call(mono_ym)

    stereo_downmix = stereo_ym.render_frame_samples(128, 1_000).map { |left, right| (left + right) * 0.5 }
    mono = mono_ym.render_frame_mono_samples(128, 1_000)

    expect(mono).to eq(stereo_downmix)
    expect(mono.map(&:abs).max).to be > 0.001
  end

  it 'renders captured Mega Drive audio jobs for the async audio worker' do
    configure = lambda do |audio|
      ym2612 = audio.instance_variable_get(:@ym2612)
      ym2612.write_address_1(0x4C)
      ym2612.write_data(0x00)
      ym2612.write_address_1(0x5C)
      ym2612.write_data(0x1F)
      ym2612.write_address_1(0xA0)
      ym2612.write_data(0x6A)
      ym2612.write_address_1(0xA4)
      ym2612.write_data((4 << 3) | 0x02)
      ym2612.write_address_1(0xB4)
      ym2612.write_data(0xC0)
      audio.begin_frame
      ym2612.write_address_1(0x28)
      ym2612.write_data(0xF0)
    end
    live = MegaDrive::Audio.new(MegaDrive::PSG.new, MegaDrive::YM2612.new)
    async_source = MegaDrive::Audio.new(MegaDrive::PSG.new, MegaDrive::YM2612.new)
    configure.call(live)
    configure.call(async_source)

    expected = live.render_frame_samples(128, AstralVerse::PsgPlayer::FRAME_CYCLES)
    job = async_source.capture_frame_job(128, AstralVerse::PsgPlayer::FRAME_CYCLES)
    actual = async_source.async_renderer.render_frame_job(job)

    expect(actual).to eq(expected)
  end

  it 'returns fresh YM2612 status only from the status port' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0xA0)
    ym2612.write_data(0x34)

    expect(ym2612.read_register(0x4001) & 0x80).to eq(0)
    expect(ym2612.read_register(0x4000) & 0x80).to eq(0x80)
    ym2612.tick(MegaDrive::YM2612::WRITE_BUSY_CYCLES)
    expect(ym2612.read_register(0x4001) & 0x80).to eq(0x80)
    expect(ym2612.read_register(0x4000) & 0x80).to eq(0)
  end

  it 'does not extend YM2612 busy when writes arrive while already busy' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0xA0)
    ym2612.write_data(0x34)
    ym2612.tick(MegaDrive::YM2612::WRITE_BUSY_CYCLES - 1)
    ym2612.write_address_1(0xA4)
    ym2612.write_data(0x20)

    expect(ym2612.read_register(0x4000) & 0x80).to eq(0x80)
    ym2612.tick(1)
    expect(ym2612.read_register(0x4000) & 0x80).to eq(0)
  end

  it 'uses channel 3 special operator frequencies when YM2612 mode enables them' do
    ym2612 = MegaDrive::YM2612.new
    ym2612.write_address_1(0x27)
    ym2612.write_data(0x40)
    ym2612.write_address_1(0xA2)
    ym2612.write_data(0x40)
    ym2612.write_address_1(0xA6)
    ym2612.write_data(4 << 3)
    ym2612.write_address_1(0xA9)
    ym2612.write_data(0xC0)
    ym2612.write_address_1(0xAD)
    ym2612.write_data(4 << 3)
    ym2612.write_address_1(0xB2)
    ym2612.write_data(0x07)
    ym2612.begin_frame
    ym2612.write_address_1(0x28)
    ym2612.write_data(0xF2)

    ym2612.render_frame_samples(64, 1_000)
    phases = ym2612.instance_variable_get(:@phase)

    expect(phases[8]).to be > phases[11]
  end

  it 'exposes combined MD audio through the existing PSG player hook' do
    emulator = MegaDrive::Emulator.new

    expect(emulator.psg).to be_a(MegaDrive::Audio)
    expect(emulator.psg).to respond_to(:render_frame_samples)
  end

  it 'uses exact PSG clock cycles for Mega Drive audio pacing' do
    emulator = MegaDrive::Emulator.new

    expect(emulator.audio_frame_cycles).to be_within(0.0001).of(MegaDrive::PSG::CLOCK / 60.0)
    expect(emulator.psg.frame_cycles).to be_within(0.0001).of(MegaDrive::PSG::CLOCK / 60.0)

    emulator.configure_region(timing: :pal, region: :eu)

    expect(emulator.audio_frame_cycles).to be_within(0.0001).of(MegaDrive::PSG::CLOCK / 50.0)
    expect(emulator.psg.frame_cycles).to be_within(0.0001).of(MegaDrive::PSG::CLOCK / 50.0)
  end

  it 'softens Mega Drive PSG edges with a cheap one-pole filter' do
    audio = MegaDrive::Audio.new(MegaDrive::PSG.new, MegaDrive::YM2612.new)
    samples = [0.0, 1.0, 1.0, 1.0]

    audio.filter_psg_samples!(samples)

    expect(samples[1]).to be_between(0.0, 1.0).exclusive
    expect(samples[2]).to be > samples[1]
    expect(samples[3]).to be > samples[2]
  end

  it 'grants the Z80 bus immediately for 68k-side boot code' do
    bus = MegaDrive::M68KBus.new

    expect(bus.read_byte(0xA11100) & 0x01).to eq(1)

    bus.write_word(0xA11100, 0x0100)

    expect(bus.read_byte(0xA11100) & 0x01).to eq(0)
  end

  it 'maps 68k-side byte writes into mirrored Z80 RAM' do
    emulator = MegaDrive::Emulator.new

    emulator.bus.write_byte(0xA00000, 0x3E)
    emulator.bus.write_byte(0xA02001, 0xA0)
    emulator.bus.write_byte(0xA00002, 0x32)
    emulator.bus.write_byte(0xA02003, 0x00)

    expect(emulator.z80_bus.read_byte(0x0000)).to eq(0x3E)
    expect(emulator.z80_bus.read_byte(0x0001)).to eq(0xA0)
    expect(emulator.z80_bus.read_byte(0x0002)).to eq(0x32)
    expect(emulator.z80_bus.read_byte(0x0003)).to eq(0x00)
  end

  it 'maps 68k-side word writes into both Z80 RAM bytes' do
    emulator = MegaDrive::Emulator.new

    emulator.bus.write_word(0xA00000, 0x3EA0)
    emulator.bus.write_word(0xA00002, 0x3200)

    expect(emulator.z80_bus.read_byte(0x0000)).to eq(0x3E)
    expect(emulator.z80_bus.read_byte(0x0001)).to eq(0xA0)
    expect(emulator.z80_bus.read_byte(0x0002)).to eq(0x32)
    expect(emulator.z80_bus.read_byte(0x0003)).to eq(0x00)
  end

  it 'maps 68k-side long writes into consecutive Z80 RAM bytes' do
    emulator = MegaDrive::Emulator.new

    emulator.bus.write_long(0xA00010, 0x12345678)

    expect((0...4).map { |offset| emulator.z80_bus.read_byte(0x0010 + offset) }).to eq([0x12, 0x34, 0x56, 0x78])
  end

  it 'leaves Mega Drive Z80 I/O ports unwired' do
    emulator = MegaDrive::Emulator.new

    emulator.z80_bus.write_io(0x7F11, 0x9F)

    expect(emulator.z80_bus.read_io(0x7F11)).to eq(0xFF)
    expect(emulator.instance_variable_get(:@sms_psg).writes).to eq(0)
  end

  it 'pulses the Mega Drive Z80 IM1 interrupt once per frame' do
    emulator = MegaDrive::Emulator.new
    rom = Array.new(0x200, 0)
    rom[0, 8] = [0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00]
    emulator.load_rom_data(rom)
    program = [
      0xF3,             # DI
      0x31, 0xFD, 0x1F, # LD SP,$1FFD
      0xED, 0x56,       # IM 1
      0x3E, 0x00,       # LD A,0
      0x32, 0x00, 0x10, # LD ($1000),A
      0xFB,             # EI
      0x18, 0xFE        # JR $
    ]
    isr = [
      0x3A, 0x00, 0x10, # LD A,($1000)
      0x3C,             # INC A
      0x32, 0x00, 0x10, # LD ($1000),A
      0xFB,             # EI
      0xC9              # RET
    ]
    program.each_with_index { |byte, index| emulator.bus.write_byte(0xA00000 + index, byte) }
    isr.each_with_index { |byte, index| emulator.bus.write_byte(0xA00038 + index, byte) }
    emulator.bus.write_byte(0xA11200, 0x01)

    4.times do
      emulator.bus.run_z80_cycles(200)
      emulator.z80_cpu.interrupt(0xFF)
    end

    expect(emulator.z80_bus.read_byte(0x1000)).to be > 0
  end

  it 'runs Z80 audio code against memory-mapped YM2612 ports' do
    emulator = MegaDrive::Emulator.new
    program = [
      0x3E, 0xA0,       # LD A,$A0
      0x32, 0x00, 0x40, # LD ($4000),A
      0x3E, 0x34,       # LD A,$34
      0x32, 0x01, 0x40, # LD ($4001),A
      0x76              # HALT
    ]
    program.each_with_index { |byte, index| emulator.bus.write_byte(0xA00000 + index, byte) }

    emulator.bus.write_byte(0xA11200, 0x01)
    emulator.bus.run_z80_cycles(80)

    expect(emulator.ym2612.registers[0][0xA0]).to eq(0x34)
  end

  it 'timestamps Z80 audio writes across elapsed Z80 cycles inside a run batch' do
    emulator = MegaDrive::Emulator.new
    program = [
      0x3E, 0x9F,       # LD A,$9F
      0x32, 0x11, 0x7F, # LD ($7F11),A
      0x00,             # NOP
      0x00,             # NOP
      0x3E, 0x90,       # LD A,$90
      0x32, 0x11, 0x7F, # LD ($7F11),A
      0x76              # HALT
    ]
    program.each_with_index { |byte, index| emulator.bus.write_byte(0xA00000 + index, byte) }
    emulator.bus.write_byte(0xA11200, 0x01)
    emulator.bus.frame_cycle = 1_000
    emulator.bus.ym_frame_cycle = 2_000

    emulator.bus.run_z80_cycles(80)

    cycles = emulator.instance_variable_get(:@sms_psg).write_log.last(2).map { |write| write[:cycle] }
    expect(cycles.first).to be > 1_000
    expect(cycles.last).to be > cycles.first
  end

  it 'halts Z80 execution while the 68k owns the Z80 bus' do
    emulator = MegaDrive::Emulator.new
    emulator.bus.write_byte(0xA00000, 0x00) # NOP
    emulator.bus.write_byte(0xA00001, 0x00) # NOP
    emulator.bus.write_byte(0xA11200, 0x01)
    emulator.bus.write_byte(0xA11100, 0x01)

    emulator.bus.run_z80_cycles(32)

    expect(emulator.z80_cpu.pc).to eq(0)
  end

  it 'latches the frame IRQ until the Z80 bus is available' do
    emulator = MegaDrive::Emulator.new
    emulator.z80_cpu.sp = 0x1FFE
    emulator.z80_cpu.iff1 = true
    emulator.z80_cpu.im = 1
    emulator.instance_variable_set(:@z80_irq_asserted, true)
    emulator.bus.write_byte(0xA11200, 0x01)
    emulator.bus.write_byte(0xA11100, 0x01)

    expect(emulator.send(:drain_z80_pending, 32, allow_partial: true)).to eq(0)
    expect(emulator.instance_variable_get(:@z80_irq_asserted)).to be true

    emulator.bus.write_byte(0xA11100, 0x00)
    pending = emulator.send(:drain_z80_pending, 32, allow_partial: true)

    expect(emulator.instance_variable_get(:@z80_irq_asserted)).to be false
    expect(emulator.z80_cpu.pc).to be > 0x0038
    expect(pending).to be < 32
  end

  it 'carries Z80 instruction overrun as timing debt' do
    emulator = MegaDrive::Emulator.new
    emulator.bus.write_byte(0xA00000, 0x00) # NOP, 4 cycles
    emulator.bus.write_byte(0xA11200, 0x01)

    pending = emulator.send(:drain_z80_pending, 2, allow_partial: true)

    expect(pending).to eq(-2)
  end

  it 'does not replay queued Z80 audio time after the 68k releases the bus' do
    emulator = MegaDrive::Emulator.new
    rom = Array.new(0x200, 0)
    rom[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
    rom[0x100] = 0x60 # BRA.s
    rom[0x101] = 0xFE
    emulator.load_rom_data(rom)
    emulator.bus.write_byte(0xA00000, 0x00) # NOP
    emulator.bus.write_byte(0xA00001, 0x00) # NOP
    emulator.bus.write_byte(0xA11200, 0x01)
    emulator.bus.write_byte(0xA11100, 0x01)
    emulator.instance_variable_set(:@z80_pending, 64)

    emulator.run_frame

    expect(emulator.instance_variable_get(:@z80_pending)).to eq(0)
    expect(emulator.z80_cpu.pc).to eq(0)
  end

  it 'resets the YM2612 when the Z80 reset line is asserted' do
    emulator = MegaDrive::Emulator.new
    emulator.ym2612.write_address_1(0xA0)
    emulator.ym2612.write_data(0x34)

    emulator.bus.write_byte(0xA11200, 0x00)

    expect(emulator.ym2612.registers[0][0xA0]).to eq(0)
  end

  it 'routes 68k-side VDP ports to the Mega Drive VDP' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)

    bus.write_word(0xC00004, 0x8F02)
    bus.write_word(0xC00004, 0xC000)
    bus.write_word(0xC00004, 0x0000)
    bus.write_word(0xC00000, 0x0EEE)
    vdp.render_frame

    expect(vdp.registers[15]).to eq(2)
    expect(vdp.cram[0]).to eq(0x0EEE)
    expect(vdp.palette_rgba[0].bytes[0, 3]).to eq([255, 255, 255])
  end

  it 'decodes full Mega Drive VDP data-port command targets' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)

    bus.write_word(0xC00004, 0xC000) # CRAM write address 0
    bus.write_word(0xC00004, 0x0000)
    bus.write_word(0xC00000, 0x1EEE)
    expect(vdp.cram[0]).to eq(0x0EEE)

    bus.write_word(0xC00004, 0x4000) # VSRAM write address 0
    bus.write_word(0xC00004, 0x0010)
    bus.write_word(0xC00000, 0x0BEE)
    expect(vdp.vsram[0]).to eq(0x03EE)

    bus.write_word(0xC00004, 0x0000) # CRAM read address 0
    bus.write_word(0xC00004, 0x0020)
    expect(bus.read_word(0xC00000)).to eq(0x0EEE)
  end

  it 'preserves hidden Mega Drive CRAM low bits for read-modify-write palette code' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)

    bus.write_word(0xC00004, 0xC000) # CRAM write address 0
    bus.write_word(0xC00004, 0x0000)
    bus.write_word(0xC00000, 0x0F51)
    vdp.render_frame

    bus.write_word(0xC00004, 0x0000) # CRAM read address 0
    bus.write_word(0xC00004, 0x0020)

    expect(vdp.cram[0]).to eq(0x0F51)
    expect(bus.read_word(0xC00000)).to eq(0x0F51)
    expect(vdp.palette_rgba[0].bytes[0, 3]).to eq([0, 87, 255])
  end

  it 'uses Mega Drive hardware plane dimensions for prohibited size register combinations' do
    vdp = MegaDrive::VDP.new

    {
      0x00 => [32, 32],
      0x02 => [64, 1],
      0x13 => [128, 32],
      0x22 => [64, 1],
      0x23 => [128, 64],
      0x31 => [64, 64],
      0x33 => [128, 128]
    }.each do |register_value, expected|
      vdp.write_control(0x9000 | register_value)
      expect(vdp.send(:plane_dimensions)).to eq(expected)
    end
  end

  it 'does not fall through to Scroll A behind transparent Window pixels' do
    vdp = MegaDrive::VDP.new

    vdp.write_control(0x8144) # display enable
    vdp.write_control(0x8200 | 0x30) # Scroll A at C000
    vdp.write_control(0x8300 | 0x02) # Window at 1000
    vdp.write_control(0x8400) # Scroll B at 0000
    vdp.write_control(0x8700) # backdrop color 0
    vdp.write_control(0x9100) # Window covers from left edge
    vdp.write_control(0x9280) # Window covers all visible rows

    # Tile 1 is opaque color 1, tile 2 is transparent, tile 3 is opaque color 3.
    vdp.write_control(0x4020)
    vdp.write_control(0x0000)
    8.times { vdp.write_data(0x1111) }
    vdp.write_control(0x4040)
    vdp.write_control(0x0000)
    8.times { vdp.write_data(0x0000) }
    vdp.write_control(0x4060)
    vdp.write_control(0x0000)
    8.times { vdp.write_data(0x3333) }

    vdp.write_control(0x4000) # Scroll B nametable tile 1
    vdp.write_control(0x0000)
    vdp.write_data(0x0001)
    vdp.write_control(0x4000 | 0xC000) # Scroll A nametable tile 3
    vdp.write_control(0x0000)
    vdp.write_data(0x0003)
    vdp.write_control(0x4000 | 0x1000) # Window nametable transparent tile 2
    vdp.write_control(0x0000)
    vdp.write_data(0x0002)

    vdp.render_frame

    expect(vdp.framebuffer[0] & 0x0F).to eq(1)
  end

  it 'binds the UI-visible framebuffer to the Mega Drive VDP' do
    emulator = MegaDrive::Emulator.new

    expect(emulator.vdp.framebuffer).to equal(emulator.framebuffer)
  end

  it 'skips clean Mega Drive VDP redraws' do
    vdp = MegaDrive::VDP.new

    vdp.render_frame
    version = vdp.render_version
    vdp.render_frame

    expect(vdp.render_version).to eq(version)
  end

  it 'renders scroll-plane tiles before CRAM has been populated' do
    vdp = MegaDrive::VDP.new
    vdp.write_control(0x8144)
    vdp.write_control(0x8200 | 0x30)
    vdp.write_control(0x8F02)
    vdp.write_control(0x4000)
    vdp.write_control(0x0000)
    4.times { vdp.write_data(0x1111) }
    vdp.write_control(0x4000 | 0xC000)
    vdp.write_control(0x0000)
    vdp.write_data(0x0000)
    vdp.render_frame

    expect(vdp.cram.all?(&:zero?)).to be(true)
    expect(vdp.framebuffer.any? { |pixel| pixel != 0 }).to be(true)
  end

  it 'performs memory-to-CRAM DMA through the VDP control port' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    bus.write_word(0x200, 0x000E)
    bus.write_word(0x202, 0x00E0)

    bus.write_word(0xC00004, 0x8114) # DMA enable
    bus.write_word(0xC00004, 0x9312) # length low
    bus.write_word(0xC00004, 0x9400) # length high
    bus.write_word(0xC00004, 0x9500) # source bits 9-1
    bus.write_word(0xC00004, 0x9601) # source bits 16-9
    bus.write_word(0xC00004, 0x9700) # memory-to-VRAM/CRAM
    bus.write_word(0xC00004, 0xC000) # CRAM write address 0
    bus.write_word(0xC00004, 0x0080) # DMA start

    expect(vdp.cram[0]).to eq(0x000E)
    expect(vdp.cram[1]).to eq(0x00E0)
    expect(vdp.registers[19]).to eq(0)
    expect(vdp.registers[20]).to eq(0)
    expect(vdp.registers[21]).to eq(0x12)
    expect(vdp.registers[22]).to eq(0x01)
  end

  it 'performs VRAM fill DMA through the VDP data port' do
    bus = MegaDrive::M68KBus.new(vdp: MegaDrive::VDP.new)

    bus.write_word(0xC00004, 0x8114) # DMA enable
    bus.write_word(0xC00004, 0x9302) # length low
    bus.write_word(0xC00004, 0x9400) # length high
    bus.write_word(0xC00004, 0x9780) # VRAM fill
    bus.write_word(0xC00004, 0x4000) # VRAM write address 0
    bus.write_word(0xC00004, 0x0080) # DMA start
    bus.write_word(0xC00000, 0xAA00)

    expect(bus.vdp.vram[1]).to eq(0xAA)
    expect(bus.vdp.vram[3]).to eq(0xAA)
  end

  it 'performs VRAM copy DMA' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    vdp.vram[0] = 0x5A
    vdp.vram[1] = 0xA5
    vdp.vram[2] = 0xC3
    vdp.vram[3] = 0x3C

    bus.write_word(0xC00004, 0x8114) # DMA enable
    bus.write_word(0xC00004, 0x9302) # length low
    bus.write_word(0xC00004, 0x9400) # length high
    bus.write_word(0xC00004, 0x9500) # source bits 9-1
    bus.write_word(0xC00004, 0x9600)
    bus.write_word(0xC00004, 0x97C0) # VRAM copy
    bus.write_word(0xC00004, 0x4004) # VRAM write address 4
    bus.write_word(0xC00004, 0x0080) # DMA start

    expect(vdp.vram[4]).to eq(0x5A)
    expect(vdp.vram[5]).to eq(0xA5)
    expect(vdp.vram[6]).to eq(0xC3)
    expect(vdp.vram[7]).to eq(0x3C)
  end

  it 'uses raw VRAM byte addresses for VRAM copy DMA sources' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    vdp.vram[0x0100] = 0x11
    vdp.vram[0x0101] = 0x22
    vdp.vram[0x0200] = 0x33
    vdp.vram[0x0201] = 0x44

    bus.write_word(0xC00004, 0x8114) # DMA enable
    bus.write_word(0xC00004, 0x9301) # length low
    bus.write_word(0xC00004, 0x9400) # length high
    bus.write_word(0xC00004, 0x9500) # raw VRAM copy source low
    bus.write_word(0xC00004, 0x9601) # raw VRAM copy source high => $0100, not $0200
    bus.write_word(0xC00004, 0x97C0) # VRAM copy
    bus.write_word(0xC00004, 0x4004) # VRAM write address 4
    bus.write_word(0xC00004, 0x0080) # DMA start

    expect(vdp.vram[4]).to eq(0x11)
    expect(vdp.vram[5]).to eq(0x22)
    expect(vdp.registers[21]).to eq(0x02)
    expect(vdp.registers[22]).to eq(0x01)
  end

  it 'maps zero MD CRAM entries to black instead of the SMS fallback palette' do
    vdp = MegaDrive::VDP.new

    expect(vdp.palette_rgba[0].bytes[0, 3]).to eq([0, 0, 0])
    expect(vdp.palette_rgba[17].bytes[0, 3]).to eq([0, 0, 0])
  end

  it 'keeps the VBlank status bit until VBlank ends' do
    vdp = MegaDrive::VDP.new

    vdp.request_vblank!
    expect(vdp.read_control & 0x0080).to eq(0x0080)

    vdp.acknowledge_interrupt(6)
    expect(vdp.read_control & 0x0080).to eq(0x0080)

    vdp.end_vblank!
    expect(vdp.read_control & 0x0080).to eq(0)
  end

  it 'reports HBlank while a Mega Drive VBlank interrupt is pending' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    bus.frame_cycle = MegaDrive::VDP::VBLANK_START_CYCLE

    vdp.request_vblank!

    expect(vdp.read_control & 0x0004).to eq(0x0004)
    expect(vdp.read_control & 0x0008).to eq(0x0008)
  end

  it 'exposes the Mega Drive VDP H/V counter at $C00008' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    bus.frame_cycle = MegaDrive::VDP::LINE_CYCLES * 0xE0

    expect(bus.read_byte(0xC00008)).to eq(0xE0)
    expect(bus.read_word(0xC00008) >> 8).to eq(0xE0)
  end

  it 'renders basic sprites from the sprite attribute table' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    bus.write_word(0xC00004, 0x8144)
    bus.write_word(0xC00004, 0x8500) # sprite table at $0000
    bus.write_word(0xC00004, 0x4000)
    bus.write_word(0xC00004, 0x0000)
    bus.write_word(0xC00000, 0x0080) # Y
    bus.write_word(0xC00000, 0x0000) # 1x1, end link
    bus.write_word(0xC00000, 0x0001) # tile 1
    bus.write_word(0xC00000, 0x0080) # X

    bus.write_word(0xC00004, 0x4020) # tile 1 pattern
    bus.write_word(0xC00004, 0x0000)
    4.times { bus.write_word(0xC00000, 0x1111) }
    vdp.render_frame

    expect(vdp.framebuffer[0]).not_to eq(0)
    expect(vdp.framebuffer[7]).not_to eq(0)
  end

  it 'routes the first controller through the Genesis I/O ports' do
    controller = MegaDrive::Controller.new
    bus = MegaDrive::M68KBus.new(controller: controller)
    controller.port_a = 0xFF &
      ~MegaDrive::Controller::START &
      ~MegaDrive::Controller::BUTTON_A &
      ~MegaDrive::Controller::BUTTON_B &
      ~MegaDrive::Controller::BUTTON_C

    bus.write_byte(0xA10009, 0x40)
    bus.write_byte(0xA10003, 0x40)
    expect(bus.read_byte(0xA10002) & 0x10).to eq(0)
    expect(bus.read_byte(0xA10002) & 0x20).to eq(0)
    expect(bus.read_byte(0xA10003) & 0x10).to eq(0)

    bus.write_byte(0xA10003, 0x00)
    expect(bus.read_byte(0xA10002) & 0x10).to eq(0)
    expect(bus.read_byte(0xA10002) & 0x20).to eq(0)
    expect(bus.read_byte(0xA10003) & 0x20).to eq(0)
    expect(bus.read_word(0xA10002) & 0x20).to eq(0)
  end

  it 'cold-boots Genesis controller control registers as zero' do
    bus = MegaDrive::M68KBus.new(controller: MegaDrive::Controller.new)

    expect(bus.read_word(0xA10008)).to eq(0)
  end

  it 'routes the second controller through the Genesis I/O ports' do
    controller_b = MegaDrive::Controller.new
    bus = MegaDrive::M68KBus.new(controller: MegaDrive::Controller.new, controller_b: controller_b)

    bus.write_byte(0xA1000B, 0x40)
    bus.write_byte(0xA10005, 0x00)
    expect(bus.read_byte(0xA10005)).to eq(0xB3)

    bus.write_byte(0xA10005, 0x40)
    expect(bus.read_byte(0xA10005)).to eq(0xFF)
  end

  it 'does not write back M68K TAS memory targets on Mega Drive' do
    bus = MegaDrive::M68KBus.new
    cpu = MegaDrive::M68K.new(bus)
    bus.load(0, [0x4A, 0xF9, 0xFF, 0xFF, 0x00, 0x6C]) # TAS.B $FFFF006C
    bus.write_byte(0xFFFF006C, 0x01)

    cpu.step

    expect(bus.read_byte(0xFFFF006C)).to eq(0x01)
    expect(cpu.pc).to eq(6)
  end

  it 'duplicates byte writes to Mega Drive VDP ports like the 16-bit bus' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)

    bus.write_byte(0xC00004, 0x8F)
    expect(vdp.registers[15]).to eq(0x8F)

    bus.write_word(0xC00004, 0x4000)
    bus.write_byte(0xC00000, 0xA5)
    expect(vdp.vram[0]).to eq(0xA5)
    expect(vdp.vram[1]).to eq(0xA5)
  end

  it 'exposes odd-byte VDP status reads used by Paprium boot code' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)
    bus.frame_cycle = MegaDrive::VDP::LINE_CYCLES * MegaDrive::VDP::VISIBLE_LINES

    expect(bus.read_byte(0xC00005) & 0x08).to eq(0x08)
  end

  it 'mirrors normal cartridge ROM reads across the MD cart window' do
    bus = MegaDrive::M68KBus.new
    bus.load_rom([0x12, 0x34, 0x56, 0x78])

    expect(bus.read_word(0)).to eq(0x1234)
    expect(bus.read_word(0x80000)).to eq(0x1234)
    expect(bus.read_word(0x9FFFFE)).to eq(0x5678)
  end

  it 'maps battery backed SRAM from the Mega Drive header and saves beside the ROM' do
    Dir.mktmpdir do |dir|
      rom_path = File.join(dir, 'savegame.md')
      rom = Array.new(0x200, 0)
      rom[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
      rom[0x100, 4] = 'SEGA'.bytes
      rom[0x1B0, 12] = ['R'.ord, 'A'.ord, 0xF8, 0x20, 0x00, 0x20, 0x00, 0x01, 0x00, 0x20, 0x00, 0x0F]
      File.binwrite(rom_path, rom.pack('C*'))

      emulator = MegaDrive::Emulator.new
      emulator.load_rom(rom_path, info: AstralVerse::RomDetector.detect(rom, path: rom_path))

      expect(File.exist?(File.join(dir, 'savegame.srm'))).to be(false)
      emulator.bus.write_byte(0xA130F1, 0x01)
      emulator.bus.write_byte(0x200001, 0x42)
      emulator.bus.flush_sram

      expect(File.binread(File.join(dir, 'savegame.srm')).bytes.first).to eq(0x42)

      emulator = MegaDrive::Emulator.new
      emulator.load_rom(rom_path, info: AstralVerse::RomDetector.detect(rom, path: rom_path))
      emulator.bus.write_byte(0xA130F1, 0x01)

      expect(emulator.bus.read_byte(0x200001)).to eq(0x42)
      expect(emulator.bus.read_byte(0x200002)).to eq(0xFF)
    end
  end

  it 'backs Mega Drive EEPROM headers with persistent cart memory' do
    Dir.mktmpdir do |dir|
      rom_path = File.join(dir, 'eeprom.md')
      rom = Array.new(0x200, 0)
      rom[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
      rom[0x100, 4] = 'SEGA'.bytes
      rom[0x1B0, 4] = ['R'.ord, 'A'.ord, 0xE8, 0x40]
      File.binwrite(rom_path, rom.pack('C*'))

      emulator = MegaDrive::Emulator.new
      emulator.load_rom(rom_path, info: AstralVerse::RomDetector.detect(rom, path: rom_path))
      emulator.bus.write_byte(0x200001, 0x7A)
      emulator.bus.flush_sram

      expect(File.binread(File.join(dir, 'eeprom.srm')).bytes.first).to eq(0x7A)

      emulator = MegaDrive::Emulator.new
      emulator.load_rom(rom_path, info: AstralVerse::RomDetector.detect(rom, path: rom_path))

      expect(emulator.bus.read_byte(0x200001)).to eq(0x7A)
    end
  end

  it 'loads default SRAM for headerless games and maps it when the SRAM latch is enabled' do
    Dir.mktmpdir do |dir|
      rom_path = File.join(dir, 'headerless-save.md')
      rom = Array.new(0x400, 0)
      rom[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
      rom[0x100, 4] = 'SEGA'.bytes
      rom[0x1A4, 4] = [0x00, 0x1F, 0xFF, 0xFF]
      File.binwrite(rom_path, rom.pack('C*'))

      emulator = MegaDrive::Emulator.new
      emulator.load_rom(rom_path, info: AstralVerse::RomDetector.detect(rom, path: rom_path))
      expect(emulator.bus.sram_path).to eq(File.join(dir, 'headerless-save.srm'))

      emulator.bus.write_byte(0x200001, 0x99)
      emulator.bus.flush_sram

      save_path = File.join(dir, 'headerless-save.srm')
      expect(File.binread(save_path).bytes.first).to eq(0x99)

      emulator = MegaDrive::Emulator.new
      emulator.load_rom(rom_path, info: AstralVerse::RomDetector.detect(rom, path: rom_path))

      expect(emulator.bus.read_byte(0x200001)).to eq(0x99)
    end
  end

  it 'does not create an SRAM file for headerless games until SRAM is written' do
    Dir.mktmpdir do |dir|
      rom_path = File.join(dir, 'headerless-clean.md')
      rom = Array.new(0x200, 0)
      rom[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
      rom[0x100, 4] = 'SEGA'.bytes
      File.binwrite(rom_path, rom.pack('C*'))

      emulator = MegaDrive::Emulator.new
      emulator.load_rom(rom_path, info: AstralVerse::RomDetector.detect(rom, path: rom_path))
      emulator.bus.flush_sram

      expect(File.exist?(File.join(dir, 'headerless-clean.srm'))).to be(false)
    end
  end

  it 'handles SRAM latch accesses through 16-bit and 32-bit bus operations' do
    bus = MegaDrive::M68KBus.new
    bus.load_rom(Array.new(0x200, 0))

    expect(bus.read_word(0xA130F0)).to eq(0x0000)
    bus.write_word(0xA130F0, 0x0001)

    expect(bus.read_byte(0xA130F1)).to eq(0x01)
    expect(bus.read_word(0xA130F0)).to eq(0x0101)
    expect(bus.read_long(0xA130EE)).to eq(0x0101_0101)

    bus.write_long(0xA130EE, 0x0000_0000)
    expect(bus.read_word(0xA130F0)).to eq(0x0000)
  end

  it 'mirrors the 68k work RAM across the E00000-FFFFFF range' do
    bus = MegaDrive::M68KBus.new

    bus.write_word(0xE00000, 0x1234)
    expect(bus.read_word(0xFF0000)).to eq(0x1234)

    bus.write_word(0xFFFFFE, 0xABCD)
    expect(bus.read_word(0xE0FFFE)).to eq(0xABCD)
  end

  it 'reports configured Mega Drive timing and region through the version register' do
    emulator = MegaDrive::Emulator.new

    expect(emulator.bus.read_byte(0xA10001)).to eq(0xA0)

    emulator.configure_region(timing: :pal, region: :eu)
    expect(emulator.bus.read_byte(0xA10001)).to eq(0xE0)

    emulator.configure_region(timing: :ntsc, region: :jp)
    expect(emulator.bus.read_byte(0xA10001)).to eq(0x80)
  end

  it 'auto-detects old-style Europe-only Mega Drive headers as PAL Europe' do
    emulator = MegaDrive::Emulator.new
    rom = Array.new(0x200, 0)
    rom[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
    rom[0x100, 4] = 'SEGA'.bytes
    rom[0x1F0, 3] = ' E '.bytes

    emulator.load_rom_data(rom, info: AstralVerse::RomDetector.detect(rom, path: 'sonic3.md'))

    expect(emulator.frame_rate).to eq(50.0)
    expect(emulator.frame_cycles).to be_within(0.0001).of(MegaDrive::Emulator::Z80_CLOCK / 50.0)
    expect(emulator.bus.read_byte(0xA10001)).to eq(0xE0)
  end

  it 'auto-detects all-region old-style Mega Drive headers as NTSC overseas' do
    emulator = MegaDrive::Emulator.new
    rom = Array.new(0x200, 0)
    rom[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
    rom[0x100, 4] = 'SEGA'.bytes
    rom[0x1F0, 3] = 'JUE'.bytes

    emulator.load_rom_data(rom, info: AstralVerse::RomDetector.detect(rom, path: 'world.md'))

    expect(emulator.frame_rate).to eq(60.0)
    expect(emulator.bus.read_byte(0xA10001)).to eq(0xA0)
  end

  it 'auto-detects new-style Europe-only Mega Drive headers as PAL Europe' do
    emulator = MegaDrive::Emulator.new
    rom = Array.new(0x200, 0)
    rom[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
    rom[0x100, 4] = 'SEGA'.bytes
    rom[0x1F0, 3] = '8  '.bytes

    emulator.load_rom_data(rom, info: AstralVerse::RomDetector.detect(rom, path: 'euro.md'))

    expect(emulator.frame_rate).to eq(50.0)
    expect(emulator.bus.read_byte(0xA10001)).to eq(0xE0)
  end

  it 'lets manual Mega Drive timing and region override header auto-detection' do
    emulator = MegaDrive::Emulator.new
    rom = Array.new(0x200, 0)
    rom[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
    rom[0x100, 4] = 'SEGA'.bytes
    rom[0x1F0, 3] = 'E  '.bytes

    emulator.load_rom_data(rom, info: AstralVerse::RomDetector.detect(rom, path: 'pal.md'))
    emulator.configure_region(timing: :ntsc, region: :jp)

    expect(emulator.frame_rate).to eq(60.0)
    expect(emulator.bus.read_byte(0xA10001)).to eq(0x80)
  end

  it 'deinterleaves SMD copier dumps before loading the Mega Drive bus' do
    raw = Array.new(0x4000, 0)
    raw[0, 8] = [0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
    raw[0x100, 4] = 'SEGA'.bytes
    smd = Array.new(512, 0)
    raw.each_slice(0x4000) do |block|
      odd = []
      even = []
      (0...(block.length / 2)).each do |index|
        even << block[index * 2]
        odd << block[(index * 2) + 1]
      end
      smd.concat(odd)
      smd.concat(even)
    end
    info = AstralVerse::RomDetector.detect(smd, path: 'contra.md')
    emulator = MegaDrive::Emulator.new

    emulator.load_rom_data(smd, info: info)

    expect(emulator.bus.read_word(0x100)).to eq(0x5345)
  end

  it 'uses the Genesis VRAM odd-address word lane mapping' do
    vdp = MegaDrive::VDP.new
    bus = MegaDrive::M68KBus.new(vdp: vdp)

    bus.write_word(0xC00004, 0x4001)
    bus.write_word(0xC00004, 0x0000)
    bus.write_word(0xC00000, 0x1234)

    expect(vdp.vram[1]).to eq(0x12)
    expect(vdp.vram[0]).to eq(0x34)
    bus.write_word(0xC00004, 0x0001)
    bus.write_word(0xC00004, 0x0000)
    expect(vdp.read_data).to eq(0x1234)
  end

end
