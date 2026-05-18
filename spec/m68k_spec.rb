require 'spec_helper'

RSpec.describe MegaDrive::M68K do
  let(:bus) { MegaDrive::M68KBus.new }
  let(:cpu) { described_class.new(bus) }

  class InterruptBus < MegaDrive::M68KBus
    attr_accessor :level
    attr_reader :acknowledged

    def interrupt_level = @level || 0

    def acknowledge_interrupt(level)
      @acknowledged = level
      @level = 0
    end
  end

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

  it 'uses the extension word address as the base for word branch displacements' do
    reset_to(0x100)
    load_program(0x100, [
      0x6100, 0x0004, # BSR.W -> $106
      0x60FE,         # skipped trap
      0x7042,         # MOVEQ #$42,D0
      0x4E75          # RTS
    ])

    cpu.step
    expect(cpu.pc).to eq(0x106)
    cpu.step
    expect(cpu.d[0]).to eq(0x42)
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

  it 'coalesces absolute-long TST busy-wait branches' do
    reset_to(0x100)
    load_program(0x100, [
      0x4A39, 0x00FF, 0x0006, # TST.B $FF0006
      0x66F8                  # BNE back to TST
    ])
    bus.write_byte(0xFF0006, 1)

    cpu.step
    cpu.step

    expect(cpu.pc).to eq(0x100)
    expect(cpu.cycles).to eq(MegaDrive::M68K::BUSY_WAIT_BRANCH_CYCLES)
  end

  it 'keeps sign-extended absolute-short LEA values in address registers' do
    reset_to(0x100)
    load_program(0x100, [
      0x41F8, 0x89E8, # LEA $89E8.w,A0
      0x43E8, 0x0016  # LEA 16(A0),A1
    ])

    2.times { cpu.step }

    expect(cpu.a[0]).to eq(0xFFFF_89E8)
    expect(cpu.a[1]).to eq(0xFFFF_89FE)
  end

  it 'does not consume absolute destination extensions twice for quick memory ops' do
    reset_to(0x100)
    load_program(0x100, [
      0x52B8, 0xFE0C, # ADDQ.L #1,$FE0C
      0x4E71
    ])
    bus.write_long(0xFFFF_FE0C, 0x41)

    cpu.step

    expect(bus.read_long(0xFFFF_FE0C)).to eq(0x42)
    expect(cpu.pc).to eq(0x104)
  end

  it 'updates postincrement effective addresses for quick memory ops' do
    reset_to(0x100)
    load_program(0x100, [
      0x41F8, 0x0200, # LEA $0200,A0
      0x5458          # ADDQ.W #2,(A0)+
    ])
    bus.write_word(0x200, 0x0004)
    bus.write_word(0x202, 0x0010)

    2.times { cpu.step }

    expect(bus.read_word(0x200)).to eq(0x0006)
    expect(bus.read_word(0x202)).to eq(0x0010)
    expect(cpu.a[0]).to eq(0x202)
  end

  it 'tests memory values without changing X' do
    reset_to(0x100)
    load_program(0x100, [
      0x4AB9, 0x0000, 0x0040 # TST.L $00000040
    ])
    bus.write_long(0x40, 0x8000_0000)
    cpu.sr = 0x2010

    cpu.step

    expect(cpu.flag_n?).to be true
    expect(cpu.flag_z?).to be false
    expect(cpu.flag_x?).to be true
  end

  it 'handles PC-relative effective addresses' do
    reset_to(0x100)
    load_program(0x100, [
      0x41FA, 0x0006, # LEA 6(PC),A0 -> $108
      0x303A, 0x0004  # MOVE.W 4(PC),D0 -> word at $10A
    ])
    bus.write_word(0x10A, 0xCAFE)

    cpu.step
    cpu.step

    expect(cpu.a[0]).to eq(0x108)
    expect(cpu.d[0] & 0xFFFF).to eq(0xCAFE)
  end

  it 'moves multiple registers from postincrement memory' do
    reset_to(0x100)
    load_program(0x100, [
      0x4C98, 0x00C0 # MOVEM.W (A0)+,D6-D7
    ])
    cpu.instance_variable_get(:@a)[0] = 0x200
    bus.write_word(0x200, 0x1111)
    bus.write_word(0x202, 0xFFFE)

    cpu.step

    expect(cpu.d[6]).to eq(0x1111)
    expect(cpu.d[7]).to eq(0xFFFF_FFFE)
    expect(cpu.a[0]).to eq(0x204)
  end

  it 'sign-extends data registers without colliding with MOVEM' do
    reset_to(0x100)
    load_program(0x100, [
      0x70FF, # MOVEQ #-1,D0
      0x4880, # EXT.W D0
      0x48C0  # EXT.L D0
    ])

    3.times { cpu.step }

    expect(cpu.d[0]).to eq(0xFFFF_FFFF)
    expect(cpu.flag_n?).to be true
  end

  it 'executes immediate logical and compare operations' do
    reset_to(0x100)
    load_program(0x100, [
      0x700F,       # MOVEQ #$0F,D0
      0x0200, 0x03, # ANDI.B #$03,D0
      0x0C00, 0x03  # CMPI.B #$03,D0
    ])

    3.times { cpu.step }

    expect(cpu.d[0]).to eq(0x03)
    expect(cpu.flag_z?).to be true
  end

  it 'preserves extend through compare operations' do
    reset_to(0x100)
    load_program(0x100, [
      0x46FC, 0x2010, # MOVE #$2010,SR
      0x7003,         # MOVEQ #3,D0
      0x0C00, 0x04,   # CMPI.B #$04,D0
      0xB03C, 0x03    # CMP.B #$03,D0
    ])

    4.times { cpu.step }

    expect(cpu.flag_x?).to be true
    expect(cpu.flag_z?).to be true
  end

  it 'moves values between USP and address registers' do
    reset_to(0x100)
    load_program(0x100, [
      0x4E68, # MOVE A0,USP
      0x4E61  # MOVE USP,A1
    ])
    cpu.instance_variable_get(:@a)[0] = 0x1234_5678

    2.times { cpu.step }

    expect(cpu.usp).to eq(0x1234_5678)
    expect(cpu.a[1]).to eq(0x1234_5678)
  end

  it 'pushes effective addresses with PEA' do
    reset_to(0x100)
    load_program(0x100, [
      0x4878, 0x1234,       # PEA ($1234).W
      0x4879, 0x0000, 0x3456 # PEA ($3456).L
    ])

    cpu.step
    expect(cpu.ssp).to eq(0x00FE_FFFC)
    expect(bus.read_long(cpu.ssp)).to eq(0x0000_1234)

    cpu.step
    expect(cpu.ssp).to eq(0x00FE_FFF8)
    expect(bus.read_long(cpu.ssp)).to eq(0x0000_3456)
  end

  it 'creates and removes stack frames with LINK and UNLK' do
    reset_to(0x100)
    load_program(0x100, [
      0x4E56, 0xFFF0, # LINK A6,#-16
      0x4E5E          # UNLK A6
    ])
    cpu.instance_variable_get(:@a)[6] = 0x1234_5678

    cpu.step
    expect(cpu.a[6]).to eq(0x00FE_FFFC)
    expect(cpu.ssp).to eq(0x00FE_FFEC)
    expect(bus.read_long(0x00FE_FFFC)).to eq(0x1234_5678)

    cpu.step
    expect(cpu.a[6]).to eq(0x1234_5678)
    expect(cpu.ssp).to eq(0x00FF_0000)
  end

  it 'sets byte destinations with Scc conditions' do
    reset_to(0x100)
    load_program(0x100, [
      0x50F8, 0x2000, # ST ($2000).W
      0x57F8, 0x2001, # SEQ ($2001).W
      0x56C0          # SNE D0
    ])

    cpu.step
    expect(bus.read_byte(0x2000)).to eq(0xFF)

    cpu.sr = 0x2004
    cpu.step
    expect(bus.read_byte(0x2001)).to eq(0xFF)

    cpu.sr = 0x2004
    cpu.step
    expect(cpu.d[0] & 0xFF).to eq(0x00)
  end

  it 'executes register arithmetic and comparisons' do
    reset_to(0x100)
    load_program(0x100, [
      0x7A05, # MOVEQ #5,D5
      0x7E03, # MOVEQ #3,D7
      0xDA47, # ADD.W D7,D5
      0xBA47  # CMP.W D7,D5
    ])

    4.times { cpu.step }

    expect(cpu.d[5] & 0xFFFF).to eq(8)
    expect(cpu.flag_z?).to be false
    expect(cpu.flag_c?).to be false
  end

  it 'executes signed and unsigned division' do
    reset_to(0x100)
    load_program(0x100, [
      0x85FC, 0x0068, # DIVS.W #$0068,D2
      0x80FC, 0x000A  # DIVU.W #$000A,D0
    ])
    cpu.instance_variable_get(:@d)[2] = 0xFFFF_FF30
    cpu.instance_variable_get(:@d)[0] = 123

    2.times { cpu.step }

    expect(cpu.d[2]).to eq(0x0000_FFFE)
    expect(cpu.d[0]).to eq(0x0003_000C)
  end

  it 'executes signed and unsigned multiplication' do
    reset_to(0x100)
    load_program(0x100, [
      0x303C, 0x0006, # MOVE.W #6,D0
      0x323C, 0xFFFE, # MOVE.W #-2,D1
      0xC0C1,         # MULU.W D1,D0
      0xC3C0          # MULS.W D0,D1
    ])

    4.times { cpu.step }

    expect(cpu.d[0]).to eq(0x0005_FFF4)
    expect(cpu.d[1]).to eq(0x0000_0018)
  end

  it 'exchanges data and address registers' do
    reset_to(0x100)
    load_program(0x100, [
      0x203C, 0x1111, 0x2222, # MOVE.L #$11112222,D0
      0x223C, 0x3333, 0x4444, # MOVE.L #$33334444,D1
      0x243C, 0x5555, 0x6666, # MOVE.L #$55556666,D2
      0xC141,                 # EXG D0,D1
      0xC58F                  # EXG D2,A7
    ])

    5.times { cpu.step }

    expect(cpu.d[0]).to eq(0x3333_4444)
    expect(cpu.d[1]).to eq(0x1111_2222)
    expect(cpu.d[2]).to eq(0x00FF_0000)
    expect(cpu.ssp).to eq(0x5555_6666)
  end

  it 'executes DBcc loops' do
    reset_to(0x100)
    load_program(0x100, [
      0x7201,       # MOVEQ #1,D1
      0x51C9, 0xFFFE # DBF D1,*-2
    ])

    cpu.step
    cpu.step
    expect(cpu.pc).to eq(0x102)
    expect(cpu.d[1] & 0xFFFF).to eq(0)

    cpu.step
    expect(cpu.pc).to eq(0x106)
    expect(cpu.d[1] & 0xFFFF).to eq(0xFFFF)
  end

  it 'executes dynamic bit tests and mutations' do
    reset_to(0x100)
    load_program(0x100, [
      0x7003, # MOVEQ #3,D0
      0x0111, # BTST D0,(A1)
      0x0151  # BCHG D0,(A1)
    ])
    cpu.instance_variable_get(:@a)[1] = 0x200
    bus.write_byte(0x200, 0x08)

    3.times { cpu.step }

    expect(cpu.flag_z?).to be false
    expect(bus.read_byte(0x200)).to eq(0)
  end

  it 'does not consume absolute destination extensions twice for bit memory writes' do
    reset_to(0x100)
    load_program(0x100, [
      0x08F8, 0x0003, 0x2000, # BSET #3,($2000).W
      0x4E71                  # NOP
    ])

    cpu.step

    expect(cpu.pc).to eq(0x106)
    expect(bus.read_byte(0x2000)).to eq(0x08)
    expect(bus.read_word(cpu.pc)).to eq(0x4E71)
  end

  it 'does not consume absolute destination extensions twice for arithmetic memory writes' do
    reset_to(0x100)
    load_program(0x100, [
      0x203C, 0x0000, 0x0002, # MOVE.L #2,D0
      0xD1B8, 0x2000,         # ADD.L D0,($2000).W
      0x4E71                  # NOP
    ])
    bus.write_long(0x2000, 3)

    2.times { cpu.step }

    expect(cpu.pc).to eq(0x10A)
    expect(bus.read_long(0x2000)).to eq(5)
    expect(bus.read_word(cpu.pc)).to eq(0x4E71)
  end

  it 'moves immediate values into SR' do
    reset_to(0x100)
    load_program(0x100, [
      0x46FC, 0x2700
    ])

    cpu.step

    expect(cpu.sr).to eq(0x2700)
  end

  it 'moves SR into a destination operand' do
    reset_to(0x100)
    load_program(0x100, [
      0x46FC, 0x270F,
      0x40C6
    ])

    2.times { cpu.step }

    expect(cpu.d[6] & 0xFFFF).to eq(0x270F)
  end

  it 'clears operands and preserves extend' do
    reset_to(0x100)
    load_program(0x100, [
      0x70FF, # MOVEQ #-1,D0
      0x4280  # CLR.L D0
    ])
    cpu.step
    cpu.sr = cpu.sr | 0x10
    cpu.step

    expect(cpu.d[0]).to eq(0)
    expect(cpu.flag_z?).to be true
    expect(cpu.flag_x?).to be true
  end

  it 'negates operands with NEG' do
    reset_to(0x100)
    load_program(0x100, [
      0x7E02, # MOVEQ #2,D7
      0x4447  # NEG.W D7
    ])

    2.times { cpu.step }

    expect(cpu.d[7] & 0xFFFF).to eq(0xFFFE)
    expect(cpu.flag_n?).to be true
    expect(cpu.flag_c?).to be true
  end

  it 'inverts operands with NOT' do
    reset_to(0x100)
    load_program(0x100, [
      0x700F, # MOVEQ #$0F,D0
      0x4600  # NOT.B D0
    ])

    2.times { cpu.step }

    expect(cpu.d[0] & 0xFF).to eq(0xF0)
    expect(cpu.flag_n?).to be true
  end

  it 'executes logical and arithmetic register shifts' do
    reset_to(0x100)
    load_program(0x100, [
      0x703F, # MOVEQ #$3F,D0
      0xEC08  # LSR.B #6,D0
    ])

    2.times { cpu.step }

    expect(cpu.d[0] & 0xFF).to eq(0)
    expect(cpu.flag_c?).to be true
    expect(cpu.flag_z?).to be true
  end

  it 'executes register rotates without treating them as shifts' do
    reset_to(0x100)
    load_program(0x100, [
      0x103C, 0x0081, # MOVE.B #$81,D0
      0xE318,         # ROL.B #1,D0
      0xE210          # ROXR.B #1,D0
    ])
    cpu.sr = cpu.sr | MegaDrive::M68K::FLAG_X

    2.times { cpu.step }
    expect(cpu.d[0] & 0xFF).to eq(0x03)
    expect(cpu.flag_c?).to be true
    expect(cpu.flag_x?).to be true

    cpu.step
    expect(cpu.d[0] & 0xFF).to eq(0x81)
    expect(cpu.flag_c?).to be true
  end

  it 'executes memory rotates and shifts' do
    reset_to(0x100)
    load_program(0x100, [
      0xE7F8, 0x2000, # ROL.W ($2000).W
      0xE2F8, 0x2002  # LSR.W ($2002).W
    ])
    bus.write_word(0x2000, 0x8001)
    bus.write_word(0x2002, 0x0003)

    cpu.step
    expect(bus.read_word(0x2000)).to eq(0x0003)
    expect(cpu.flag_c?).to be true

    cpu.step
    expect(bus.read_word(0x2002)).to eq(0x0001)
    expect(cpu.flag_c?).to be true
  end

  it 'executes MOVEP without treating it as a bit operation' do
    reset_to(0x100)
    load_program(0x100, [
      0x01C8, 0x0010, # MOVEP.L D0,$10(A0)
      0x0348, 0x0010  # MOVEP.L $10(A0),D1
    ])
    cpu.instance_variable_get(:@a)[0] = 0x2000
    cpu.instance_variable_get(:@d)[0] = 0x1234_5678

    cpu.step
    expect(bus.read_byte(0x2010)).to eq(0x12)
    expect(bus.read_byte(0x2012)).to eq(0x34)
    expect(bus.read_byte(0x2014)).to eq(0x56)
    expect(bus.read_byte(0x2016)).to eq(0x78)

    cpu.step
    expect(cpu.d[1]).to eq(0x1234_5678)
  end

  it 'writes LEA results to A7 as the active stack pointer' do
    reset_to(0x100)
    load_program(0x100, [
      0x4FEF, 0x0010 # LEA 16(A7),A7
    ])
    bus.write_long(cpu.ssp + 0x10, 0x1234_5678)

    cpu.step

    expect(cpu.ssp).to eq(0x00FF_0010)
    expect(bus.read_long(cpu.ssp)).to eq(0x1234_5678)
  end

  it 'handles address-register indexed effective addresses' do
    reset_to(0x100)
    load_program(0x100, [
      0x3030, 0x0004 # MOVE.W 4(A0,D0.W),D0
    ])
    cpu.instance_variable_get(:@a)[0] = 0x200
    cpu.instance_variable_get(:@d)[0] = 2
    bus.write_word(0x206, 0xBEEF)

    cpu.step

    expect(cpu.d[0] & 0xFFFF).to eq(0xBEEF)
  end

  it 'executes register logical operations' do
    reset_to(0x100)
    load_program(0x100, [
      0x740F, # MOVEQ #$0F,D2
      0x7803, # MOVEQ #$03,D4
      0x8882, # OR.L D2,D4
      0x8F82, # OR.L D7,D2
      0xC482  # AND.L D2,D2
    ])
    cpu.instance_variable_get(:@d)[7] = 0xF0

    5.times { cpu.step }

    expect(cpu.d[4]).to eq(0x0F)
    expect(cpu.d[2]).to eq(0xFF)
    expect(cpu.flag_z?).to be false
  end

  it 'executes EOR from data register to destination' do
    reset_to(0x100)
    load_program(0x100, [
      0x700F, # MOVEQ #$0F,D0
      0x7203, # MOVEQ #$03,D1
      0xB100  # EOR.B D0,D0
    ])

    3.times { cpu.step }

    expect(cpu.d[0] & 0xFF).to eq(0)
    expect(cpu.flag_z?).to be true
  end

  it 'swaps data register words' do
    reset_to(0x100)
    load_program(0x100, [
      0x243C, 0x1234, 0x5678, # MOVE.L #$12345678,D2
      0x4842                  # SWAP D2
    ])

    2.times { cpu.step }

    expect(cpu.d[2]).to eq(0x5678_1234)
  end

  it 'services autovector interrupts and returns with RTE' do
    bus = InterruptBus.new
    cpu = described_class.new(bus)
    bus.write_long(0x000000, 0x00FF0000)
    bus.write_long(0x000004, 0x200)
    bus.write_long((24 + 6) * 4, 0x300)
    bus.write_word(0x200, 0x4E71)
    bus.write_word(0x300, 0x4E73)
    cpu.reset
    cpu.sr = 0x2300
    bus.level = 6

    cpu.step
    expect(cpu.pc).to eq(0x300)
    expect(bus.acknowledged).to eq(6)

    cpu.step
    expect(cpu.pc).to eq(0x200)
    expect(cpu.sr).to eq(0x2300)
  end

  it 'services TRAP vectors' do
    reset_to(0x100)
    bus.write_long((32 + 1) * 4, 0x200)
    load_program(0x100, [0x4E41]) # TRAP #1

    cpu.step

    expect(cpu.pc).to eq(0x200)
    expect(cpu.ssp).to eq(0x00FE_FFFA)
    expect(bus.read_word(cpu.ssp)).to eq(0x2700)
    expect(bus.read_long(cpu.ssp + 2)).to eq(0x102)
  end
end
