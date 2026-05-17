#!/usr/bin/env ruby

require 'optparse'
require 'time'
require_relative '../lib/sms_emulator/cpu/z80'

class FlatMemory
  attr_reader :direct_cpu_memory

  def initialize
    @direct_cpu_memory = Array.new(0x10000, 0)
  end

  def load(bytes, addr = 0)
    bytes.each_with_index { |value, index| @direct_cpu_memory[(addr + index) & 0xFFFF] = value & 0xFF }
  end

  def read_byte(addr)
    @direct_cpu_memory[addr & 0xFFFF]
  end

  def write_byte(addr, value)
    @direct_cpu_memory[addr & 0xFFFF] = value & 0xFF
  end

  def read_io(_port) = 0xFF
  def write_io(_port, _value) = nil
end

options = {
  cycles: 20_000_000,
  profile: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [--cycles N] [--profile]"
  opts.on('--cycles N', Integer, 'Target cycles per run') { |value| options[:cycles] = value }
  opts.on('--profile', 'Print opcode histogram from fast run') { options[:profile] = true }
end.parse!

# Tight synthetic loop with SMS/Z80-common instructions:
# LD r,n, LD r,r, INC/DEC, XOR/OR/CP, conditional JR and JP.
program = [
  0x3E, 0x55,       # LD A,$55
  0x06, 0x40,       # LD B,$40
  0x0E, 0x01,       # LD C,$01
  0x16, 0x02,       # LD D,$02
  0x1E, 0x03,       # LD E,$03
  0x26, 0xC0,       # LD H,$C0
  0x2E, 0x00,       # LD L,$00
  0x78,             # LD A,B
  0x3C,             # INC A
  0x47,             # LD B,A
  0x0C,             # INC C
  0x15,             # DEC D
  0x1C,             # INC E
  0xAF,             # XOR A
  0xB7,             # OR A
  0xFE, 0x00,       # CP $00
  0x28, 0x02,       # JR Z,+2
  0x3E, 0x99,       # LD A,$99 (skipped)
  0x04,             # INC B
  0x05,             # DEC B
  0xC3, 0x0E, 0x00  # JP $000E
]

def build_cpu(program)
  memory = FlatMemory.new
  memory.load(program)
  cpu = SmsEmulator::Z80.new(memory)
  cpu
end

def bench(label)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  cycles = yield
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  hz = cycles / elapsed
  puts "%-12s %10d cycles  %8.3f s  %10.0f cycles/s" % [label, cycles, elapsed, hz]
  hz
end

target = options[:cycles]

old_cpu = build_cpu(program)
old_hz = bench('step') do
  cycles = 0
  cycles += old_cpu.step while cycles < target
  cycles
end

fast_cpu = build_cpu(program)
fast_cpu.enable_opcode_counts! if options[:profile]
fast_hz = bench('run_cycles') { fast_cpu.run_cycles(target) }

puts "speedup      %.2fx" % (fast_hz / old_hz)
puts "final old   PC=%04X A=%02X F=%02X B=%02X C=%02X D=%02X E=%02X H=%02X L=%02X" %
  [old_cpu.pc, old_cpu.a, old_cpu.f, old_cpu.b, old_cpu.c, old_cpu.d, old_cpu.e, old_cpu.h, old_cpu.l]
puts "final fast  PC=%04X A=%02X F=%02X B=%02X C=%02X D=%02X E=%02X H=%02X L=%02X" %
  [fast_cpu.pc, fast_cpu.a, fast_cpu.f, fast_cpu.b, fast_cpu.c, fast_cpu.d, fast_cpu.e, fast_cpu.h, fast_cpu.l]

if options[:profile]
  puts "opcode frequency:"
  fast_cpu.opcode_counts.each_with_index
    .select { |count, _opcode| count.positive? }
    .sort_by { |count, _opcode| -count }
    .first(20)
    .each { |count, opcode| puts "  %02X  %10d" % [opcode, count] }
end
