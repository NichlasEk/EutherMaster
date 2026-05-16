#!/usr/bin/env ruby

require_relative '../lib/astral_verse'

rom_path = ARGV[0] || AstralVerse::LastRelicCache.last_relic
frames = (ARGV[1] || 180).to_i
hotspots = ARGV.include?('--hotspots')

abort "Usage: #{$PROGRAM_NAME} ROM_PATH [frames]" unless rom_path && File.exist?(rom_path)

stone = AstralVerse::ScryingStone.new
stone.absorb_codex(rom_path)
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

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
frames.times { stone.gaze_frame }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
perf = stone.emulator.perf_summary

puts "ROM: #{File.basename(rom_path)}"
puts "Frames: #{frames}"
puts "Wall FPS: %.2f" % (frames / elapsed)
puts "Emu FPS: %.2f" % perf[:fps]
puts "Avg frame: %.2f ms" % perf[:avg_frame_ms]
puts "Avg CPU: %.2f ms" % perf[:avg_cpu_ms]
puts "Avg VDP: %.2f ms" % perf[:avg_vdp_ms]
puts "Avg CPU steps/frame: %.0f" % perf[:avg_cpu_steps]
puts "PC: %04X  SP: %04X  Cycles: %d" % [stone.emulator.cpu.pc, stone.emulator.cpu.sp, stone.emulator.cpu.total_cycles]
puts "VDP regs: #{stone.emulator.vdp.registers.map { |value| '%02X' % value }.join(' ')}"
puts "Pixels: #{stone.vision_sprite.scrying_pool.uniq.first(16).map { |value| '%02X' % value }.join(',')}"

if hotspots
  puts "PC hotspots:"
  pc_hits.sort_by { |_pc, count| -count }.first(20).each do |pc, count|
    puts "  %04X  %d" % [pc, count]
  end
end
