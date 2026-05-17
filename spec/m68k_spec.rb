require 'spec_helper'

RSpec.describe MegaDrive::M68K do
  let(:bus) { MegaDrive::M68KBus.new }
  let(:cpu) { described_class.new(bus) }

  def reset_to(address)
    bus.write_long(0x000000, 0x00FF0000)
    bus.write_long(0x000004, address)
    cpu.reset
  end

  def load_program(address, words)
    bytes = words.flat_map { |word| [(word >> 8) & 0xFF, word & 0xFF] }
    bus.load(address, bytes)
  end

  it 'loads reset vectors into supervisor stack and PC' do
    reset_to(0x000200)

    expect(cpu.ssp).to eq(0x00FF0000)
    expect(cpu.pc).to eq(0x000200)
    expect(cpu.supervisor?).to be true
    expect(cpu.sr & 0x2700).to eq(0x2700)
  end

  it 'executes MOVEQ and preserves X while setting NZ flags' do
    reset_to(0x100)
    load_program(0x100, [0x70FF, 0x7200])

    cpu.step
    expect(cpu.d[0]).to eq(0xFFFF_FFFF)
    expect(cpu.flag_n?).to be true
    expect(cpu.flag_z?).to be false

    cpu.step
    expect(cpu.d[1]).to eq(0)
    expect(cpu.flag_z?).to be true
  end

  it 'executes immediate MOVE to data and address registers' do
    reset_to(0x100)
    load_program(0x100, [
      0x203C, 0x1234, 0x5678, # MOVE.L #$12345678,D0
      0x327C, 0xFFFE,         # MOVEA.W #$FFFE,A1
      0x13C0, 0x0000, 0x2000  # MOVE.B D0,$00002000
    ])

    3.times { cpu.step }

    expect(cpu.d[0]).to eq(0x1234_5678)
    expect(cpu.a[1]).to eq(0xFFFF_FFFE)
    expect(bus.read_byte(0x2000)).to eq(0x78)
  end

  it 'branches, calls and returns using the supervisor stack' do
    reset_to(0x100)
    load_program(0x100, [
      0x6104,       # BSR +4 -> $106
      0x7001,       # skipped until RTS returns
      0x4E71,       # NOP
      0x7002,       # MOVEQ #2,D0
      0x4E75,       # RTS
      0x6002,       # BRA +2
      0x7203,       # skipped
      0x7204        # MOVEQ #4,D1
    ])

    cpu.step
    expect(cpu.pc).to eq(0x106)
    expect(cpu.ssp).to eq(0x00FEFFFC)

    cpu.step
    cpu.step
    expect(cpu.pc).to eq(0x102)
    expect(cpu.ssp).to eq(0x00FF0000)
    cpu.step
    expect(cpu.d[0]).to eq(0x0000_0001)
  end

  it 'jumps and calls through absolute long addresses' do
    reset_to(0x100)
    load_program(0x100, [0x4EB9, 0x0000, 0x0200, 0x7001])
    load_program(0x200, [0x7044, 0x4EF9, 0x0000, 0x0106])

    cpu.step
    expect(cpu.pc).to eq(0x200)
    cpu.step
    cpu.step

    expect(cpu.d[0]).to eq(0x44)
    expect(cpu.pc).to eq(0x106)
  end

  it 'handles LEA and quick add/sub without touching address-register flags' do
    reset_to(0x100)
    load_program(0x100, [
      0x41F9, 0x0000, 0x4000, # LEA $4000,A0
      0x5488,                 # ADDQ.L #2,A0
      0x5380                  # SUBQ.L #1,D0
    ])

    3.times { cpu.step }

    expect(cpu.a[0]).to eq(0x4002)
    expect(cpu.d[0]).to eq(0xFFFF_FFFF)
    expect(cpu.flag_n?).to be true
    expect(cpu.flag_c?).to be true
  end
end
