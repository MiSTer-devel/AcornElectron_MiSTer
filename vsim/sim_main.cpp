// Acorn Electron Verilator simulation driver (GUI + headless).
// Structure follows TK2000_MiSTer/verilator/sim_main.cpp.

#include <verilated.h>
#include "Vemu.h"
#include "Vemu___024root.h"
#include "Vemu_emu.h"

#include "imgui.h"
#include "implot.h"
#include <stdio.h>
#include <SDL.h>
#include <SDL_opengl.h>

#include "sim_console.h"
#include "sim_bus.h"
#include "sim_video.h"
#include "sim_audio.h"
#include "sim_input.h"
#include "sim_clock.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <algorithm>
#include <chrono>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#if VM_TRACE_VCD
#include <verilated_vcd_c.h>
#endif

// ---------------------------------------------------------------- globals

bool headless = false;              // used by sim_video.cpp
DebugConsole console;
SimBus bus(console);
SimInput input(13, console);

// ULA picture: 640 active pixels at 16 MHz, 256 lines per field (text modes
// 250). vid_mode 00 is 312-line progressive, 01 interlaced (312/313-line
// fields with the same picture): one sim "frame" is one 50 Hz field.
#define VGA_WIDTH  640
#define VGA_HEIGHT 256
SimVideo video(VGA_WIDTH, VGA_HEIGHT, 0);
float vga_scale = 1.5;

Vemu *top = nullptr;
vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

const int clk_sys_freq = 16000000;
SimClock clk_sys(1);
SimAudio audio(clk_sys_freq, false);

#if VM_TRACE_VCD
VerilatedVcdC *tfp = nullptr;
#endif

// ------------------------------------------------------------- automation

struct KeyEvent { int frame; unsigned char code; bool ext; bool pressed; };
struct JoyEvent { int frame; int stick; unsigned mask; };
struct AnalogEvent { int frame; int stick; int x, y; };

static std::vector<KeyEvent> key_events;
static size_t key_event_pos = 0;
static int key_gap_cycles = 0;
static bool ps2_toggle = false;
static int opt_key_hold = 3, opt_key_gap = 3;

static std::vector<JoyEvent> joy_events;
static std::vector<AnalogEvent> analog_events;
static int opt_stop_at_frame = -1;
static std::vector<int> opt_screenshot_frames;
static int opt_screenshot_every = 0;
static std::string opt_screenshot_dir = ".", opt_screenshot_prefix = "frame";
static bool opt_hash = false;
static std::vector<int> opt_reset_frames;
static std::string opt_rom, opt_tape, opt_cart[2];
static int opt_tape_frame = 0;
static std::vector<int> opt_tape_rewind;
static std::vector<std::pair<int, std::string>> opt_ram_dumps;
static std::vector<std::pair<int, std::string>> opt_peeks;   // frame, "addr[,addr...]"
static int reset_hold = 0;
static int pulse_cycles = 0;
static int osd_pulse_cycles = 0;
static int rom_pending = 0;   // --rom / --cart1 / --cart2 queued, downloads not all started yet
static std::vector<int> opt_osd_break, opt_osd_ctrl_break, opt_osd_shift_break;
static bool last_relay = false;
static unsigned joy_mask[2] = { 0, 0 };

static const int initial_reset = 64;   // clk_sys cycles

// ------------------------------------------------------------- the clock

// --cpu-trace <frame>[:<n>]: from that field on, keep the last n opcode
// fetches (PC, opcode) and print them when a BRK (opcode 00) is fetched.
static int opt_trace_from = -1, opt_trace_n = 4000, trace_brks = 0;
struct TraceEnt { int frame; uint16_t pc; uint16_t op; };   // op 0x1xx: a write of xx to &FE05
static std::vector<TraceEnt> trace_ring;
static size_t trace_pos = 0;
static int cur_frame() { return video.count_frame; }
static void cpu_trace_sample() {
	unsigned d = top->dbg_cpu;
	if (!((d >> 8) & 1)) return;                         // Enable
	int fr = cur_frame();
	if (fr < opt_trace_from) return;
	bool romsel = !((d >> 10) & 1) && (top->dbg_cpu_addr & 0xFF0F) == 0xFE05;   // a ROM select / IRQ clear write
	if (!romsel && !((d >> 9) & 1)) return;              // else only opcode fetches (Sync)
	if (romsel && (getenv("TRACE_ALLSEL") || (((d >> 11) & 0x0F) != 0x08 && ((d >> 11) & 0x0F) != 0x0C)))   // selects other than 8 / 12
		printf("ROMSEL frame %d pc-ish %04X value %02X\n", fr, trace_ring.empty() ? 0 : trace_ring[(trace_pos + trace_ring.size() - 1) % trace_ring.size()].pc, (d >> 11) & 0xFF);
	TraceEnt ent = { fr, (uint16_t)top->dbg_cpu_addr, (uint16_t)(romsel ? 0x100 | ((d >> 11) & 0xFF) : (d & 0xFF)) };
	if (trace_ring.size() < (size_t)opt_trace_n) trace_ring.push_back(ent);
	else trace_ring[trace_pos] = ent;
	trace_pos = (trace_pos + 1) % opt_trace_n;
	static int dump_at = getenv("TRACE_DUMP_AT") ? atoi(getenv("TRACE_DUMP_AT")) : -1;
	if ((!romsel && (d & 0xFF) == 0 && trace_brks < 3) || (dump_at >= 0 && fr >= dump_at)) {
		if (dump_at >= 0 && fr >= dump_at) dump_at = -1;
		trace_brks++;
		printf("CPUTRACE BRK at %04X frame %d; last %zu fetches:\n", top->dbg_cpu_addr, fr, trace_ring.size());
		for (size_t i = 0; i < trace_ring.size(); i++) {
			const TraceEnt &e = trace_ring[(trace_pos + i) % trace_ring.size()];
			if (e.op & 0x100) printf("CPUTRACE %d %04X W%02X\n", e.frame, e.pc, e.op & 0xFF);
			else printf("CPUTRACE %d %04X %02X\n", e.frame, e.pc, e.op);
		}
		trace_ring.clear(); trace_pos = 0;
	}
}

// Clocks: one 96 MHz sub-step counter drives clk_48 (every sub-step),
// clk_24 (every 2nd) and clk_sys = 16 MHz (every 3rd), so their edges line
// up as from one PLL. A tick() is half a clk_sys period (3 sub-steps).
static uint64_t substep = 0;

// Image slots answering hps_io's block protocol (512-byte blocks) at clk_sys:
// 0 = the MMC card for MMFS (--sd, sys/sd_card.sv in sim.v), 1/2 = the
// Plus 3's floppy drives (--floppy0 / --floppy1, rtl/plus3.sv). Writes stay
// in memory; the image files are never changed.
struct SimImg { std::vector<uint8_t> data; bool present = false, mounted = false; };
static SimImg sd_imgs[3];
static bool sd_write = false;
static int sd_state = 0, sd_pos = 0, sd_drv = 0;
static uint32_t sd_blk = 0;
static bool opt_sd_log = false;
static bool load_image(int slot, const std::string &fn) {
	FILE *f = fopen(fn.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open image %s\n", fn.c_str()); return false; }
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	sd_imgs[slot].data.resize(n);
	bool ok = fread(sd_imgs[slot].data.data(), 1, n, f) == (size_t)n;
	fclose(f);
	sd_imgs[slot].present = ok;
	return ok;
}
static uint32_t sd_lba_of(int d) { return d == 0 ? top->sd_lba0 : d == 1 ? top->sd_lba1 : top->sd_lba2; }
static uint8_t sd_din_of(int d) { return d == 0 ? top->sd_buff_din0 : d == 1 ? top->sd_buff_din1 : top->sd_buff_din2; }
static void sd_card_step() {
	if (opt_sd_log) {   // the MMC card's SPI lines: toggle counts and decoded bytes
		static unsigned last = 0, tog[5]; unsigned d = top->dbg_sd;
		for (int b = 0; b < 5; b++) if (((d ^ last) >> b) & 1) tog[b]++;
		static int nb = 0, nbytes = 0; static unsigned bo = 0, bi = 0;
		if ((d & 4) && !(last & 4) && nbytes < 400) {
			bo = (bo << 1) | ((d >> 1) & 1); bi = (bi << 1) | (d & 1);
			if (++nb == 8) { printf("SPI %02X/%02X%s", bo & 0xFF, bi & 0xFF, (++nbytes % 12) ? " " : "\n"); nb = 0; bo = bi = 0; }
		}
		last = d;
	}
	top->img_mounted = 0;
	top->sd_buff_wr = 0;
	if (main_time < 100) return;
	for (int i = 0; i < 3; i++)                       // mount one slot per clock
		if (sd_imgs[i].present && !sd_imgs[i].mounted) {
			top->img_mounted = 1 << i; top->img_size = sd_imgs[i].data.size(); top->img_readonly = 0;
			sd_imgs[i].mounted = true;
			return;
		}
	switch (sd_state) {
	case 0:
		for (int i = 0; i < 3; i++)
			if (((top->sd_rd | top->sd_wr) >> i) & 1) {
				sd_drv = i; sd_write = (top->sd_wr >> i) & 1; sd_blk = sd_lba_of(i);
				sd_pos = 0; sd_state = 1; top->sd_ack = 1 << i;
				if (opt_sd_log) printf("SD%d %s block %u (frame %d)\n", i, sd_write ? "write" : "read", sd_blk, video.count_frame);
				break;
			}
		break;
	case 1: {
		std::vector<uint8_t> &img = sd_imgs[sd_drv].data;
		size_t off = (size_t)sd_blk * 512 + sd_pos;
		top->sd_buff_addr = sd_pos;
		if (!sd_write) {
			top->sd_buff_dout = off < img.size() ? img[off] : 0;
			top->sd_buff_wr = 1;
		} else if (sd_pos > 0) {   // din follows addr one clock later (registered block RAM)
			size_t o = (size_t)sd_blk * 512 + sd_pos - 1;
			if (o < img.size()) img[o] = sd_din_of(sd_drv);
		}
		if (++sd_pos == (sd_write ? 513 : 512)) sd_state = 2;
		break;
	}
	case 2:
		top->sd_ack = 0;
		sd_state = 0;
		break;
	}
}

// --video-stats: per field (vsync to vsync) the active lines, the active
// pixels of the widest line, the total lines and pixels per line
static bool opt_video_stats = false;
// --vcheck: what Main reads from sys video_calc (par 1: nres in [7:0], int
// in [9:8]; 2/3 hcnt, 4/5 vcnt), sampled round-robin, printed each field
static bool opt_vcheck = false;
static uint16_t vc_val[32];
static int vc_par = 1;
static void video_stats(bool hb, bool vb, bool hs, bool vs) {
	static bool ohs = 1, ovs = 1;
	static int px = 0, de_px = 0, max_de = 0, min_de = 1 << 30, lines = 0, de_lines = 0, line_px = 0;
	bool de = !hb && !vb;
	px++; if (de) de_px++;
	if (!hs && ohs) {                    // hsync falling: end of a line
		if (de_px) { de_lines++; if (de_px > max_de) max_de = de_px; if (de_px < min_de) min_de = de_px; }
		lines++; line_px = px; px = 0; de_px = 0;
	}
	if (!vs && ovs) {                    // vsync falling: end of a field
		printf("VSTATS frame %d: %d active lines, %d-%d active px/line, %d lines, %d px/line\n",
		       video.count_frame, de_lines, min_de == (1 << 30) ? 0 : min_de, max_de, lines, line_px);
		lines = de_lines = max_de = 0; min_de = 1 << 30;
	}
	// edges within a line (pixel index from hsync falling), for a few lines
	static bool ohb = 1, ovb = 1; static int dump = 0;
	if (getenv("VSTATS_EDGES") && video.count_frame == atoi(getenv("VSTATS_EDGES"))) {
		if (hs != ohs && dump < 40) { printf("EDGE px %d HS %d (vb %d)\n", px, hs, vb); dump++; }
		if (hb != ohb && dump < 40) { printf("EDGE px %d HB %d\n", px, hb); dump++; }
		if (vb != ovb) { printf("EDGE px %d VB %d line %d\n", px, vb, lines); dump++; }
		if (vs != ovs) { printf("EDGE px %d VS %d line %d\n", px, vs, lines); dump++; }
	}
	ohb = hb; ovb = vb;
	ohs = hs; ovs = vs;
}

static void tick() {
	for (int i = 0; i < 3; i++, substep++) {
		bool c16 = (substep % 6) < 3, c24 = (substep % 4) < 2, c48 = (substep % 2) == 0;
		bool r16 = c16 && !top->clk_sys, r48 = c48 && !top->clk_48;
		if (r16 && opt_trace_from >= 0) cpu_trace_sample();
		if (r16) { input.BeforeEval(); bus.BeforeEval(); sd_card_step(); }
		top->clk_sys = c16; top->clk_24 = c24; top->clk_48 = c48;
		top->eval();
#if VM_TRACE_VCD
		if (tfp) tfp->dump(substep);
#endif
		if (r16) {
			if (opt_vcheck) {
				vc_val[vc_par] = top->vc_dout;   // dout follows par_num one clk_sys later
				static const int pars[] = {1, 2, 4, 17, 18};
				static int pi = 0;
				static int wait = 0;
				if (++wait == 4) { wait = 0; pi = (pi + 1) % 5; vc_par = pars[pi]; top->vc_par = vc_par; }
			}
			bus.AfterEval();
			audio.Clock(top->AUDIO_L, top->AUDIO_R);
			main_time++;
		}
		if (r48 && top->CE_PIXEL) {
			uint32_t colour = 0xFF000000 | top->VGA_B << 16 | top->VGA_G << 8 | top->VGA_R;
			video.Clock(top->VGA_HB, top->VGA_VB, top->VGA_HS, top->VGA_VS, colour);
			if (opt_video_stats) video_stats(top->VGA_HB, top->VGA_VB, top->VGA_HS, top->VGA_VS);
		}
	}
}

// One clk_sys half-period plus key injection and reset handling.
static inline void step() {
	if (key_gap_cycles > 0) key_gap_cycles--;
	else if (key_event_pos < key_events.size() && key_events[key_event_pos].frame <= video.count_frame) {
		const KeyEvent &e = key_events[key_event_pos++];
		ps2_toggle = !ps2_toggle;
		top->ps2_key = e.code | (e.ext ? 1 << 8 : 0) | (e.pressed ? 1 << 9 : 0) | (ps2_toggle ? 1 << 10 : 0);
		key_gap_cycles = 2000;
	}
	if (pulse_cycles > 0 && --pulse_cycles == 0) top->tape_rewind = 0;

	// Reset: power-on, --reset-at-frame, and held until a queued ROM image
	// starts loading (the download itself resets the machine, as on MiSTer).
	// only a queued ROM (index 0) holds reset; a tape download must not
	{   // a queued ROM / cartridge download holds reset until the last one has started
		static int last_index = -1;
		if (rom_pending && top->ioctl_download && top->ioctl_index != last_index &&
		    (top->ioctl_index == 0 || top->ioctl_index == 3 || top->ioctl_index == 4)) { last_index = top->ioctl_index; rom_pending--; }
		if (!top->ioctl_download) last_index = -1;
	}
	bool rom_queued = rom_pending > 0;
	if (reset_hold > 0) reset_hold--;
	top->reset_in = (main_time < (vluint64_t)initial_reset) || reset_hold > 0 || rom_queued;
	if (osd_pulse_cycles > 0 && --osd_pulse_cycles == 0) { top->btn_break = 0; top->btn_ctrl_break = 0; top->btn_shift_break = 0; }

	tick();
}

// ----------------------------------------------------------------- output

static unsigned long long fb_hash() {
	unsigned long long h = 1469598103934665603ULL;
	if (!output_ptr) return 0;
	for (int i = 0; i < video.output_width * video.output_height; i++) {
		h ^= output_ptr[i] & 0xFFFFFF;
		h *= 1099511628211ULL;
	}
	return h;
}

static void save_screenshot(int frame) {
	if (!output_ptr) return;
	char filename[1024];
	snprintf(filename, sizeof(filename), "%s/%s_%04d.png", opt_screenshot_dir.c_str(), opt_screenshot_prefix.c_str(), frame);
	int w = video.output_width, h = video.output_height;
	std::vector<uint8_t> rgb(w * h * 3);
	for (int i = 0; i < w * h; i++) {
		uint32_t p = output_ptr[i];
		rgb[i * 3 + 0] = p & 0xFF;
		rgb[i * 3 + 1] = (p >> 8) & 0xFF;
		rgb[i * 3 + 2] = (p >> 16) & 0xFF;
	}
	if (stbi_write_png(filename, w, h, 3, rgb.data(), w * 3))
		printf("SCREENSHOT frame %d %s FBHASH %016llx\n", frame, filename, fb_hash());
	else
		printf("ERROR: could not write %s\n", filename);
}

// Main 32 KB RAM lives in the ULA (RAM_32k_DualPort).
static uint8_t ram_peek(unsigned addr);

// ----------------------------------------------------------- keyboard text

// ASCII -> PS/2 set 2 code for rtl/ps2kybrd/keyboard.vhd, which maps keys by
// position onto the Electron matrix. Shifted symbols follow the Electron
// keyboard: SHIFT 1-9 = ! " # $ % & ' ( ), SHIFT 0 = @, the ' key is ':'
// (SHIFT '*'), ';' SHIFT '+', '-' SHIFT '=', ',' '<', '.' '>', '/' '?'.
static bool ascii_to_ps2(char c, unsigned char &code, bool &shift) {
	static const char *letters = "abcdefghijklmnopqrstuvwxyz";
	static const unsigned char lcode[26] = { 0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,
	                                         0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A };
	static const unsigned char dcode[10] = { 0x45,0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46 };
	static const char *shifted_digits = "@!\"#$%&'()";
	shift = false;
	char l = tolower(c);
	if (l >= 'a' && l <= 'z') { code = lcode[strchr(letters, l) - letters]; return true; }  // CAPS LOCK is on at boot
	if (c >= '0' && c <= '9') { code = dcode[c - '0']; return true; }
	if (const char *p = strchr(shifted_digits, c)) { code = dcode[p - shifted_digits]; shift = true; return true; }
	switch (c) {
	case ' ': code = 0x29; return true;
	case ':': code = 0x52; return true;
	case '*': code = 0x52; shift = true; return true;
	case ';': code = 0x4C; return true;
	case '+': code = 0x4C; shift = true; return true;
	case '-': code = 0x4E; return true;
	case '=': code = 0x4E; shift = true; return true;
	case ',': code = 0x41; return true;
	case '<': code = 0x41; shift = true; return true;
	case '.': code = 0x49; return true;
	case '>': code = 0x49; shift = true; return true;
	case '/': code = 0x4A; return true;
	case '?': code = 0x4A; shift = true; return true;
	}
	return false;
}

static void add_key_text(int frame, const std::string &text) {
	int f = frame;
	auto push = [&](unsigned char code, bool ext, bool shift, bool ctrl) {
		if (shift) key_events.push_back({ f, 0x12, false, true });
		if (ctrl) key_events.push_back({ f, 0x14, false, true });
		key_events.push_back({ f, code, ext, true });
		key_events.push_back({ f + opt_key_hold, code, ext, false });
		if (ctrl) key_events.push_back({ f + opt_key_hold, 0x14, false, false });
		if (shift) key_events.push_back({ f + opt_key_hold, 0x12, false, false });
		f += opt_key_hold + opt_key_gap;
	};
	for (size_t j = 0; j < text.size(); j++) {
		char c = text[j];
		if (c == '\\' && j + 1 < text.size()) {
			char n = text[++j];
			if (n == 'n' || n == 'r') { push(0x5A, false, false, false); continue; }  // RETURN
			if (n == 'b') { push(0x66, false, false, false); continue; }             // DELETE
			if (n == 'e') { push(0x76, false, false, false); continue; }             // ESCAPE
			if (n == 'k') { push(0x78, false, false, false); continue; }             // F11 = BREAK
			if (n == 'K') { push(0x78, false, false, true); continue; }              // CTRL-BREAK
			if (n == 'S') { push(0x78, false, true, false); continue; }              // SHIFT-BREAK
			if (n == 'f' && j + 1 < text.size() && isdigit(text[j + 1])) {           // \f<d>: FUNC+d (PC F1-F9, F10 = f0)
				static const unsigned char fcode[10] = { 0x09,0x05,0x06,0x04,0x0C,0x03,0x0B,0x83,0x0A,0x01 };
				push(fcode[text[++j] - '0'], false, false, false);
				continue;
			}
			if (n == 'c') { push(0x58, false, false, false); continue; }             // CAPS LOCK (FUNC)
			if (n == 'U') { push(0x75, true, false, false); continue; }
			if (n == 'D') { push(0x72, true, false, false); continue; }
			if (n == 'L') { push(0x6B, true, false, false); continue; }
			if (n == 'R') { push(0x74, true, false, false); continue; }
			if (n == '^' && j + 1 < text.size()) {
				unsigned char code; bool shift;
				if (ascii_to_ps2(text[++j], code, shift)) push(code, false, false, true);
				continue;
			}
			c = n;
		}
		unsigned char code; bool shift;
		if (ascii_to_ps2(c, code, shift)) push(code, false, shift, false);
		else fprintf(stderr, "WARNING: no Electron key for '%c'\n", c);
	}
	std::stable_sort(key_events.begin(), key_events.end(),
	                 [](const KeyEvent &a, const KeyEvent &b) { return a.frame < b.frame; });
}

// ------------------------------------------------------------ per frame

static bool on_frame(int frame) {
	if (!opt_tape.empty() && opt_tape_frame >= 0 && frame >= opt_tape_frame) {
		printf("FRAME %d: load tape %s\n", frame, opt_tape.c_str());
		bus.QueueDownload(opt_tape, 2, true);
		opt_tape_frame = -1;
	}
	for (int f : opt_tape_rewind) if (f == frame) { printf("FRAME %d: tape stop & rewind\n", frame); top->tape_rewind = 1; pulse_cycles = 64; }
	for (int r : opt_reset_frames) if (r == frame) { printf("FRAME %d: reset\n", frame); reset_hold = 2000; }
	for (int f : opt_osd_break) if (f == frame) { printf("FRAME %d: OSD BREAK\n", frame); top->btn_break = 1; osd_pulse_cycles = 64; }
	for (int f : opt_osd_ctrl_break) if (f == frame) { printf("FRAME %d: OSD Ctrl-BREAK\n", frame); top->btn_ctrl_break = 1; osd_pulse_cycles = 64; }
	for (int f : opt_osd_shift_break) if (f == frame) { printf("FRAME %d: OSD SHIFT-BREAK\n", frame); top->btn_shift_break = 1; osd_pulse_cycles = 64; }
	for (auto &j : joy_events) if (j.frame == frame) joy_mask[j.stick] = j.mask;
	top->joystick_0 = joy_mask[0];
	top->joystick_1 = joy_mask[1];
	for (auto &a : analog_events) if (a.frame == frame) {
		uint16_t v = ((a.y & 0xFF) << 8) | (a.x & 0xFF);
		if (a.stick == 0) top->joystick_l_analog_0 = v; else top->joystick_l_analog_1 = v;
	}
	if (top->dbg_cas_relay != last_relay) {
		printf("FRAME %d: MOTOR %s (tape position %u of %u)\n", frame, top->dbg_cas_relay ? "on" : "off",
		       top->dbg_tape_addr, top->dbg_tape_end);
		last_relay = top->dbg_cas_relay;
	}
	for (auto &d : opt_ram_dumps) if (d.first == frame) {
		FILE *f = fopen(d.second.c_str(), "wb");
		if (f) {
			for (unsigned i = 0; i < 32768; i++) fputc(ram_peek(i), f);
			fclose(f);
			printf("FRAME %d: RAM dumped to %s\n", frame, d.second.c_str());
		}
	}
	for (auto &p : opt_peeks) if (p.first == frame) {
		std::stringstream ss(p.second); std::string t;
		while (std::getline(ss, t, ',')) {
			unsigned a = strtoul(t.c_str(), NULL, 16);
			printf("PEEK frame %d %04X = %02X\n", frame, a, ram_peek(a));
		}
	}
	if (opt_vcheck) printf("VCHECK frame %d: nres %d int %d hcnt %d vcnt %d de_h %d de_v %d\n", frame,
		vc_val[1] & 0xFF, (vc_val[1] >> 8) & 3, vc_val[2], vc_val[4], vc_val[17], vc_val[18]);
	if (opt_hash) printf("FBHASH frame %d %016llx\n", frame, fb_hash());
	bool shot = std::find(opt_screenshot_frames.begin(), opt_screenshot_frames.end(), frame) != opt_screenshot_frames.end();
	if (opt_screenshot_every > 0 && frame > 0 && frame % opt_screenshot_every == 0) shot = true;
	if (shot) save_screenshot(frame);
	if (opt_stop_at_frame >= 0 && frame >= opt_stop_at_frame) {
		printf("STOP at frame %d (%.2f s emulated)\n", frame, main_time / (double)clk_sys_freq);
		return false;
	}
	return true;
}

// ------------------------------------------------------------------ args

static void usage() {
	printf("Acorn Electron Verilator sim\n\nUsage: ./obj_dir/Vemu [options]\n\n");
	printf("  --headless                    No window (also HEADLESS=1)\n");
	printf("  --stop-at-frame <n>           Exit after field n (50 fields = 1 s)\n");
	printf("  --screenshot <n[,n...]>       PNG (640x256) at these fields\n");
	printf("  --screenshot-every <n>        PNG every n fields\n");
	printf("  --screenshot-dir <dir>        Directory for PNGs (default .)\n");
	printf("  --screenshot-prefix <name>    PNG prefix (default frame -> frame_0100.png)\n");
	printf("  --hash                        Print FBHASH every field\n");
	printf("  --send-keys <frame>:<text>    Type text. \\n RETURN, \\b DELETE, \\e ESCAPE, \\k BREAK,\n");
	printf("                                \\K CTRL-BREAK, \\S SHIFT-BREAK, \\c CAPS LOCK, \\U\\D\\L\\R cursor,\n");
	printf("                                \\f<d> FUNC+d (PC F-key),\n");
	printf("                                \\^X CTRL+X. Letters type as capitals (CAPS LOCK on)\n");
	printf("  --key-hold <n> / --key-gap <n> Fields a key is held / between keys (default 3/3)\n");
	printf("  --joy <frame>:<hexmask>       Joystick 1 buttons from frame (bit 0 R,1 L,2 D,3 U,4 Fire)\n");
	printf("  --joy2 <frame>:<hexmask>      Joystick 2\n");
	printf("  --analog <frame>:<x>,<y>      Stick 1 analog, signed -127..127\n");
	printf("  --analog2 <frame>:<x>,<y>     Stick 2 analog\n");
	printf("  --swap-joysticks              OSD Swap Joysticks: Yes\n");
	printf("  --interlaced                  OSD Interlace: On (vid_mode 01; default 00 is progressive)\n");
	printf("  --cpu-speed <0|1|2>           OSD CPU speed: Normal, 2 MHz, 4 MHz\n");
	printf("  --osd-break <n>               OSD BREAK button at field n. Repeatable\n");
	printf("  --osd-ctrl-break <n>          OSD Ctrl-BREAK button at field n. Repeatable\n");
	printf("  --osd-shift-break <n>         OSD SHIFT-BREAK button at field n. Repeatable\n");
	printf("  --autoboot                    OSD Autoboot: On (SHIFT held at power-on; default Off in the sim)\n");
	printf("  --rom <file>                  Load a 112 KB ROM image (ELK.mif layout) at power-on\n");
	printf("  --cart1 / --cart2 <file>      OSD Cartridge 1 (ROMs 2/3) / 2 (ROMs 0/1) at power-on\n");
	printf("  --sd <image> [--sd-log]       SD card image for MMFS (MMB / boot.vhd); writes stay in memory\n");
	printf("  --plus3, --floppy0/1 <adf>    OSD Plus 3 On; ADFS floppy images in drives 0/1\n");
	printf("  --tape <file>                 Load a tape (OSD F2) at --tape-frame (default 0)\n");
	printf("  --tape-frame <n>\n");
	printf("  --tape-rewind <n>             OSD Stop & Rewind at field n. Repeatable\n");
	printf("  --tape-monitor                OSD Tape audio: On\n");
	printf("  --tape-turbo <n>              OSD Tape speed: n x (UEF only; default Normal)\n");
	printf("  --reset-at-frame <n>          Pulse reset at field n. Repeatable\n");
	printf("  --dump-ram <frame>:<file>     Save the 32 KB main RAM. Repeatable\n");
	printf("  --peek <frame>:<hex[,hex]>    Print main RAM bytes at a field. Repeatable\n");
#if VM_TRACE_VCD
	printf("  --trace <file.vcd>            Write a VCD\n");
#endif
}

static bool split_frame(const std::string &v, int &frame, std::string &rest) {
	size_t c = v.find(':');
	if (c == std::string::npos) return false;
	frame = atoi(v.substr(0, c).c_str());
	rest = v.substr(c + 1);
	return true;
}

static int parse_args(int argc, char **argv) {
	const char *eh = getenv("HEADLESS");
	if (eh && eh[0] && eh[0] != '0') headless = true;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&](void) -> std::string {
			if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", a.c_str()); exit(2); }
			return argv[++i];
		};
		int fr; std::string rest;
		if (a == "-h" || a == "--help") { usage(); exit(0); }
		else if (a == "--headless" || a == "--no-gui") headless = true;
		else if (a == "--stop-at-frame") opt_stop_at_frame = atoi(next().c_str());
		else if (a == "--screenshot") {
			std::stringstream ss(next()); std::string t;
			while (std::getline(ss, t, ',')) if (!t.empty()) opt_screenshot_frames.push_back(atoi(t.c_str()));
		}
		else if (a == "--screenshot-every") opt_screenshot_every = atoi(next().c_str());
		else if (a == "--screenshot-dir") opt_screenshot_dir = next();
		else if (a == "--screenshot-prefix") opt_screenshot_prefix = next();
		else if (a == "--hash") opt_hash = true;
		else if (a == "--key-hold") opt_key_hold = atoi(next().c_str());
		else if (a == "--key-gap") opt_key_gap = atoi(next().c_str());
		else if (a == "--send-keys") {
			if (!split_frame(next(), fr, rest)) { fprintf(stderr, "--send-keys wants frame:text\n"); return 2; }
			add_key_text(fr, rest);
		}
		else if (a == "--joy" || a == "--joy2") {
			if (!split_frame(next(), fr, rest)) { fprintf(stderr, "%s wants frame:hexmask\n", a.c_str()); return 2; }
			joy_events.push_back({ fr, a == "--joy2" ? 1 : 0, (unsigned)strtoul(rest.c_str(), NULL, 16) });
		}
		else if (a == "--analog" || a == "--analog2") {
			int x, y;
			if (!split_frame(next(), fr, rest) || sscanf(rest.c_str(), "%d,%d", &x, &y) != 2) {
				fprintf(stderr, "%s wants frame:x,y\n", a.c_str()); return 2;
			}
			analog_events.push_back({ fr, a == "--analog2" ? 1 : 0, x, y });
		}
		else if (a == "--swap-joysticks") top->swap_joysticks = 1;
		else if (a == "--interlaced") top->vid_interlaced = 1;
		else if (a == "--cpu-speed") top->osd_cpu_speed = atoi(next().c_str()) & 3;
		else if (a == "--osd-break") opt_osd_break.push_back(atoi(next().c_str()));
		else if (a == "--osd-ctrl-break") opt_osd_ctrl_break.push_back(atoi(next().c_str()));
		else if (a == "--osd-shift-break") opt_osd_shift_break.push_back(atoi(next().c_str()));
		else if (a == "--autoboot") top->autoboot = 1;
		else if (a == "--rom") opt_rom = next();
		else if (a == "--video-stats") opt_video_stats = true;
		else if (a == "--vcheck") opt_vcheck = true;
		else if (a == "--sd-log") opt_sd_log = true;
		else if (a == "--sd") { if (!load_image(0, next())) return 2; }
		else if (a == "--floppy0") { if (!load_image(1, next())) return 2; }
		else if (a == "--floppy1") { if (!load_image(2, next())) return 2; }
		else if (a == "--plus3") top->osd_plus3 = 1;
		else if (a == "--cart1") opt_cart[0] = next();
		else if (a == "--cart2") opt_cart[1] = next();
		else if (a == "--tape") opt_tape = next();
		else if (a == "--tape-frame") opt_tape_frame = atoi(next().c_str());
		else if (a == "--tape-rewind") opt_tape_rewind.push_back(atoi(next().c_str()));
		else if (a == "--tape-monitor") top->tape_monitor = 1;
		else if (a == "--no-tape-overlay") top->tape_overlay_off = 1;
		else if (a == "--tape-turbo") { top->tape_fast = 1; top->tape_turbo_n = atoi(next().c_str()) & 31; }
		else if (a == "--reset-at-frame") opt_reset_frames.push_back(atoi(next().c_str()));
		else if (a == "--dump-ram") {
			if (!split_frame(next(), fr, rest)) { fprintf(stderr, "--dump-ram wants frame:file\n"); return 2; }
			opt_ram_dumps.push_back({ fr, rest });
		}
		else if (a == "--cpu-trace") {
			std::string v = next(); opt_trace_from = atoi(v.c_str());
			size_t c = v.find(':'); if (c != std::string::npos) opt_trace_n = atoi(v.c_str() + c + 1);
		}
		else if (a == "--peek") {
			if (!split_frame(next(), fr, rest)) { fprintf(stderr, "--peek wants frame:hexaddr[,hexaddr]\n"); return 2; }
			opt_peeks.push_back({ fr, rest });
		}
#if VM_TRACE_VCD
		else if (a == "--trace") {
			Verilated::traceEverOn(true);
			tfp = new VerilatedVcdC;
			top->trace(tfp, 99);
			tfp->open(next().c_str());
		}
#endif
		else { fprintf(stderr, "unknown option %s (try --help)\n", a.c_str()); return 2; }
	}
	return 0;
}

static uint8_t ram_peek(unsigned addr) {
	return top->rootp->emu->Electron__DOT__ula__DOT__ram_32k__DOT__mem[addr & 0x7FFF];
}

// ------------------------------------------------------------------- main

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	top = new Vemu();
	if (int r = parse_args(argc, argv)) return r;

	bus.ioctl_addr = &top->ioctl_addr;
	bus.ioctl_index = &top->ioctl_index;
	bus.ioctl_wait = &top->ioctl_wait;
	bus.ioctl_download = &top->ioctl_download;
	bus.ioctl_wr = &top->ioctl_wr;
	bus.ioctl_dout = &top->ioctl_dout;
	input.ps2_key = &top->ps2_key;

	if (!opt_rom.empty()) { bus.QueueDownload(opt_rom, 0, true); rom_pending++; }
	for (int c = 0; c < 2; c++)
		if (!opt_cart[c].empty()) { bus.QueueDownload(opt_cart[c], 3 + c, true); rom_pending++; }

	if (video.Initialise("Verilator Sim: Acorn Electron") == 1) return 1;
	if (!headless) {
		audio.Initialise();
		input.Initialise();
	}

	int last_frame = -1;
	auto check_frame = [&]() -> bool {
		if (video.count_frame != last_frame) {
			last_frame = video.count_frame;
			return on_frame(last_frame);
		}
		return true;
	};

	if (headless) {
		auto t0 = std::chrono::steady_clock::now();
		check_frame();
		while (true) {
			for (int s = 0; s < 4096; s++) step();
			if (!check_frame()) break;
		}
		double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
		printf("Ran %d fields in %.1fs (%.1f fields/s, %.2fx real time) video x %d..%d y %d..%d\n",
		       last_frame, secs, last_frame / secs, last_frame / secs / 50.0,
		       video.stats_xMin, video.stats_xMax, video.stats_yMin, video.stats_yMax);
#if VM_TRACE_VCD
		if (tfp) tfp->close();
#endif
		top->final();
		return 0;
	}

	bool run_enable = true;
	int batch = 400000;
	bool done = false;
	while (!done) {
		SDL_Event event;
		while (SDL_PollEvent(&event)) {
			ImGui_ImplSDL2_ProcessEvent(&event);
			if (event.type == SDL_QUIT) done = true;
		}
		video.StartFrame();
		input.Read();
		ImGui::NewFrame();

		ImGui::Begin("Simulation control");
		ImGui::SetWindowPos("Simulation control", ImVec2(0, 0), ImGuiCond_Once);
		ImGui::SetWindowSize("Simulation control", ImVec2(420, 160), ImGuiCond_Once);
		ImGui::Checkbox("RUN", &run_enable);
		ImGui::SliderInt("Batch", &batch, 1000, 2000000);
		if (ImGui::Button("Reset")) reset_hold = 2000; ImGui::SameLine();
		if (ImGui::Button("Screenshot")) save_screenshot(video.count_frame); ImGui::SameLine();
		if (ImGui::Button("Rewind tape")) { top->tape_rewind = 1; pulse_cycles = 64; }
		ImGui::Text("field %d  %.2f s  motor %s", video.count_frame, main_time / (double)clk_sys_freq,
		            top->dbg_cas_relay ? "on" : "off");
		ImGui::End();

		bool show_log = true;
		console.Draw("Debug log", &show_log, ImVec2(420, 500));
		ImGui::SetWindowPos("Debug log", ImVec2(0, 170), ImGuiCond_Once);

		ImGui::Begin("Video");
		ImGui::SetWindowPos("Video", ImVec2(430, 0), ImGuiCond_Once);
		ImGui::SetWindowSize("Video", ImVec2(VGA_WIDTH * vga_scale + 24, VGA_HEIGHT * vga_scale * 2 + 70), ImGuiCond_Once);
		ImGui::SliderFloat("Zoom", &vga_scale, 1, 4);
		// a field is 640x256 of a 4:3 picture: double the height
		ImGui::Image(video.texture_id, ImVec2(video.output_width * vga_scale, video.output_height * vga_scale * 2));
		ImGui::End();

		video.UpdateTexture();

		if (run_enable)
			for (int s = 0; s < batch; s++) { step(); if (!check_frame()) { done = true; break; } }
		else
			check_frame();
	}

	audio.CleanUp();
	video.CleanUp();
	input.CleanUp();
	return 0;
}
