#!/usr/bin/env ruby

if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable) && !RubyVM::YJIT.enabled?
  RubyVM::YJIT.enable
end

require_relative '../lib/astral_verse'
require_relative '../lib/astral_verse/audio/psg_player' if ARGV.include?('--audio-render')

state_index = ARGV.index('--state')
state_path = state_index ? ARGV[state_index + 1] : nil
ARGV.slice!(state_index, 2) if state_index

rom_path = ARGV[0] || AstralVerse::LastRelicCache.last_relic
frames = (ARGV[1] || 180).to_i
hotspots = ARGV.include?('--hotspots')
opcodes = ARGV.include?('--opcodes')
audio_render = ARGV.include?('--audio-render')

if state_path
  abort "State not found: #{state_path}" unless File.exist?(state_path)
elsif !rom_path || !File.exist?(rom_path)
  abort "Usage: #{$PROGRAM_NAME} [ROM_PATH] [frames] [--state PATH] [--audio-render]"
end

stone = AstralVerse::ScryingStone.new
if state_path
  stone.load_snapshot(state_path)
  stone.emulator.reset_perf
  rom_path = stone.crystal_vault.relic_path || state_path
else
  stone.absorb_codex(rom_path)
end
pc_hits = Hash.new(0)

if hotspots
  cpu = stone.emulator.cpu
  class << cpu
    attr_accessor :pc_hits
    alias perf_original_step step unless method_defined?(:perf_original_step)

    def step
      @pc_hits[@pc] += 1 if @pc_hits
      perf_original_step
    end
  end
  cpu.pc_hits = pc_hits
end

stone.emulator.cpu.enable_opcode_counts! if opcodes

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
audio_seconds = 0.0
audio_samples = 0
audio_credit = 0.0

frames.times do
  stone.gaze_frame
  if audio_render
    audio_credit += AstralVerse::PsgPlayer::SAMPLE_RATE * AstralVerse::PsgPlayer::FRAME_CYCLES / stone.emulator.psg.class::CLOCK
    sample_count = audio_credit.floor
    audio_credit -= sample_count
    audio_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stone.emulator.psg.render_frame_samples(sample_count, AstralVerse::PsgPlayer::FRAME_CYCLES, AstralVerse::PsgPlayer::SAMPLE_RATE)
    audio_seconds += Process.clock_gettime(Process::CLOCK_MONOTONIC) - audio_started
    audio_samples += sample_count
  end
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
perf = stone.emulator.perf_summary

puts "ROM: #{File.basename(rom_path)}"
puts "State: #{state_path}" if state_path
puts "Frames: #{frames}"
puts "Wall FPS: %.2f" % (frames / elapsed)
puts "Emu FPS: %.2f" % perf[:fps]
puts "Avg frame: %.2f ms" % perf[:avg_frame_ms]
puts "Avg CPU: %.2f ms" % perf[:avg_cpu_ms]
puts "Avg VDP: %.2f ms" % perf[:avg_vdp_ms]
puts "Avg CPU steps/frame: %.0f" % perf[:avg_cpu_steps]
if audio_render
  puts "Avg audio render: %.2f ms" % ((audio_seconds / frames) * 1000.0)
  puts "Audio render realtime: %.1fx" % ((audio_samples.to_f / AstralVerse::PsgPlayer::SAMPLE_RATE) / audio_seconds)
end
puts "PC: %04X  SP: %04X  Cycles: %d" % [stone.emulator.cpu.pc, stone.emulator.cpu.sp, stone.emulator.cpu.total_cycles]
puts "VDP regs: #{stone.emulator.vdp.registers.map { |value| '%02X' % value }.join(' ')}"
puts "Pixels: #{stone.vision_sprite.scrying_pool.uniq.first(16).map { |value| '%02X' % value }.join(',')}"

if hotspots
  puts "PC hotspots:"
  pc_hits.sort_by { |_pc, count| -count }.first(20).each do |pc, count|
    puts "  %04X  %d" % [pc, count]
  end
end

if opcodes
  puts "Opcode hotspots:"
  stone.emulator.cpu.opcode_counts.each_with_index
    .select { |count, _opcode| count.positive? }
    .sort_by { |count, _opcode| -count }
    .first(30)
    .each do |count, opcode|
      puts "  %02X  %d" % [opcode, count]
    end
  puts "CB opcode hotspots:"
  stone.emulator.cpu.cb_opcode_counts.each_with_index
    .select { |count, _opcode| count.positive? }
    .sort_by { |count, _opcode| -count }
    .first(20)
    .each do |count, opcode|
      puts "  CB %02X  %d" % [opcode, count]
    end
  puts "ED opcode hotspots:"
  stone.emulator.cpu.ed_opcode_counts.each_with_index
    .select { |count, _opcode| count.positive? }
    .sort_by { |count, _opcode| -count }
    .first(20)
    .each do |count, opcode|
      puts "  ED %02X  %d" % [opcode, count]
    end
end
