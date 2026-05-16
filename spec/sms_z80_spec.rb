require 'spec_helper'

RSpec.describe SmsEmulator::Z80 do
  class Z80SpecMemory
    attr_reader :io_writes

    def initialize
      @bytes = Array.new(0x10000, 0)
      @io = Hash.new(0xFF)
      @io_writes = []
    end

    def load(addr, bytes)
      bytes.each_with_index { |byte, index| @bytes[(addr + index) & 0xFFFF] = byte & 0xFF }
    end

    def read_byte(addr)
      @bytes[addr & 0xFFFF]
    end

    def write_byte(addr, value)
      @bytes[addr & 0xFFFF] = value & 0xFF
    end

    def read_io(port)
      @io[port & 0xFFFF]
    end

    def write_io(port, value)
      @io_writes << [port & 0xFFFF, value & 0xFF]
      @io[port & 0xFFFF] = value & 0xFF
    end

    def set_io(port, value)
      @io[port & 0xFFFF] = value & 0xFF
    end
  end

  let(:memory) { Z80SpecMemory.new }
  let(:cpu) { described_class.new(memory) }

  def run(bytes, steps: bytes.length)
    memory.load(cpu.pc, bytes)
    steps.times { cpu.step }
  end

  it 'executes 8-bit loads, ALU ops, stores and jumps' do
    run([
      0x3E, 0x12,       # LD A,$12
      0x06, 0x05,       # LD B,$05
      0x80,             # ADD A,B
      0x32, 0x00, 0xC0, # LD ($C000),A
      0xC3, 0x10, 0x00  # JP $0010
    ], steps: 5)

    expect(cpu.a).to eq(0x17)
    expect(memory.read_byte(0xC000)).to eq(0x17)
    expect(cpu.pc).to eq(0x0010)
    expect(cpu.flag_z?).to be false
  end

  it 'handles stack calls and returns' do
    memory.load(0x0000, [0xCD, 0x06, 0x00, 0x76, 0x00, 0x00, 0x3E, 0x44, 0xC9])

    cpu.step
    expect(cpu.pc).to eq(0x0006)
    expect(cpu.sp).to eq(0xDFEE)

    cpu.step
    cpu.step
    expect(cpu.a).to eq(0x44)
    expect(cpu.pc).to eq(0x0003)
    expect(cpu.sp).to eq(0xDFF0)
  end

  it 'executes CB rotate, bit, reset and set opcodes' do
    run([
      0x06, 0x81, # LD B,$81
      0xCB, 0x00, # RLC B
      0xCB, 0x78, # BIT 7,B
      0xCB, 0x80, # RES 0,B
      0xCB, 0xC8  # SET 1,B
    ], steps: 5)

    expect(cpu.b).to eq(0x02)
    expect(cpu.flag_z?).to be true
  end

  it 'executes IX indexed memory operations' do
    run([
      0xDD, 0x21, 0x00, 0xC0, # LD IX,$C000
      0xDD, 0x36, 0x02, 0x55, # LD (IX+2),$55
      0xDD, 0x7E, 0x02,       # LD A,(IX+2)
      0xDD, 0xCB, 0x02, 0xC6  # SET 0,(IX+2)
    ], steps: 4)

    expect(cpu.ix).to eq(0xC000)
    expect(cpu.a).to eq(0x55)
    expect(memory.read_byte(0xC002)).to eq(0x55)
  end

  it 'executes ED block transfer and IO opcodes' do
    memory.write_byte(0xC000, 0xAA)
    run([
      0x21, 0x00, 0xC0, # LD HL,$C000
      0x11, 0x10, 0xC0, # LD DE,$C010
      0x01, 0x01, 0x00, # LD BC,$0001
      0xED, 0xA0,       # LDI
      0x3E, 0x77,       # LD A,$77
      0xD3, 0xBE        # OUT ($BE),A
    ], steps: 6)

    expect(memory.read_byte(0xC010)).to eq(0xAA)
    expect(cpu.bc).to eq(0)
    expect(memory.io_writes).to include([0x77BE, 0x77])
  end

  it 'repeats LDIR until BC reaches zero' do
    memory.write_byte(0xC000, 0x11)
    memory.write_byte(0xC001, 0x22)
    run([
      0x21, 0x00, 0xC0, # LD HL,$C000
      0x11, 0x10, 0xC0, # LD DE,$C010
      0x01, 0x02, 0x00, # LD BC,$0002
      0xED, 0xB0        # LDIR
    ], steps: 5)

    expect(memory.read_byte(0xC010)).to eq(0x11)
    expect(memory.read_byte(0xC011)).to eq(0x22)
    expect(cpu.bc).to eq(0)
    expect(cpu.pc).to eq(0x000B)
  end

  it 'consumes cycles while halted so frame loops can keep advancing' do
    run([0x76], steps: 1)

    expect(cpu.halted).to be true
    expect(cpu.step).to eq(4)
  end
end
