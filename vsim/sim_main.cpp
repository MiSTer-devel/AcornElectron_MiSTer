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
// 250). The ULA's 15 kHz modes are interlaced (vid_mode 00): one sim "frame"
// is one 50 Hz field.
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
static std::string opt_rom, opt_tape;
static int opt_tape_frame = 0;
static std::vector<int> opt_tape_rewind;
static std::vector<std::pair<int, std::string>> opt_ram_dumps;
static std::vector<std::pair<int, std::string>> opt_peeks;   // frame, "addr[,addr...]"
static int reset_hold = 0;
static int pulse_cycles = 0;
static bool last_relay = false;
static unsigned joy_mask[2] = { 0, 0 };

static const int initial_reset = 64;   // clk_sys cycles

// ------------------------------------------------------------- the clock

static void tick() {
	clk_sys.Tick();
	top->clk_sys = clk_sys.clk;
	if (clk_sys.clk != clk_sys.old) {
		if (clk_sys.clk) { input.BeforeEval(); bus.BeforeEval(); }
		top->eval();
#if VM_TRACE_VCD
		if (tfp) tfp->dump(main_time * 2 + (clk_sys.clk ? 0 : 1));
#endif
		if (clk_sys.clk) bus.AfterEval();
	}
	if (clk_sys.IsRising()) {
		audio.Clock(top->AUDIO_L, top->AUDIO_R);
		if (top->CE_PIXEL) {
			uint32_t colour = 0xFF000000 | top->VGA_B << 16 | top->VGA_G << 8 | top->VGA_R;
			video.Clock(top->VGA_HB, top->VGA_VB, top->VGA_HS, top->VGA_VS, colour);
		}
		main_time++;
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

	// Reset: power-on, --reset-at-frame, and held while a ROM image loads
	// (AcornElectron.sv only writes the ROM while reset is high).
	bool rom_loading = bus.HasQueue() || (top->ioctl_download && top->ioctl_index == 0);
	if (reset_hold > 0) reset_hold--;
	top->reset = (main_time < (vluint64_t)initial_reset) || reset_hold > 0 || rom_loading;

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
			if (n == 'k') { push(0x09, false, false, false); continue; }             // F10 = BREAK
			if (n == 'K') { push(0x09, false, false, true); continue; }              // CTRL-BREAK
			if (n == 'S') { push(0x09, false, true, false); continue; }              // SHIFT-BREAK
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
	for (auto &j : joy_events) if (j.frame == frame) joy_mask[j.stick] = j.mask;
	top->joystick_0 = joy_mask[0];
	top->joystick_1 = joy_mask[1];
	for (auto &a : analog_events) if (a.frame == frame) {
		uint16_t v = ((a.y & 0xFF) << 8) | (a.x & 0xFF);
		if (a.stick == 0) top->joystick_l_analog_0 = v; else top->joystick_l_analog_1 = v;
	}
	if (top->dbg_cas_relay != last_relay) {
		printf("FRAME %d: MOTOR %s (tape addr %u of %u)\n", frame, top->dbg_cas_relay ? "on" : "off",
		       top->dbg_tape_addr, top->dbg_tape_end + 1);
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
	printf("                                \\^X CTRL+X. Letters type as capitals (CAPS LOCK on)\n");
	printf("  --key-hold <n> / --key-gap <n> Fields a key is held / between keys (default 3/3)\n");
	printf("  --joy <frame>:<hexmask>       Joystick 1 buttons from frame (bit 0 R,1 L,2 D,3 U,4 Fire)\n");
	printf("  --joy2 <frame>:<hexmask>      Joystick 2\n");
	printf("  --analog <frame>:<x>,<y>      Stick 1 analog, signed -127..127\n");
	printf("  --analog2 <frame>:<x>,<y>     Stick 2 analog\n");
	printf("  --swap-joysticks              OSD Swap Joysticks: Yes\n");
	printf("  --progressive                 vid_mode 01 (15 kHz non-interlaced)\n");
	printf("  --rom <file>                  Load a 112 KB ROM image (ELK.mif layout) at power-on\n");
	printf("  --tape <file>                 Load a tape (OSD F2) at --tape-frame (default 0)\n");
	printf("  --tape-frame <n>\n");
	printf("  --tape-rewind <n>             OSD Stop & Rewind at field n. Repeatable\n");
	printf("  --tape-monitor                OSD Monitor Tape Sound: Yes\n");
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
		else if (a == "--progressive") top->vid_progressive = 1;
		else if (a == "--rom") opt_rom = next();
		else if (a == "--tape") opt_tape = next();
		else if (a == "--tape-frame") opt_tape_frame = atoi(next().c_str());
		else if (a == "--tape-rewind") opt_tape_rewind.push_back(atoi(next().c_str()));
		else if (a == "--tape-monitor") top->tape_monitor = 1;
		else if (a == "--reset-at-frame") opt_reset_frames.push_back(atoi(next().c_str()));
		else if (a == "--dump-ram") {
			if (!split_frame(next(), fr, rest)) { fprintf(stderr, "--dump-ram wants frame:file\n"); return 2; }
			opt_ram_dumps.push_back({ fr, rest });
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

	if (!opt_rom.empty()) bus.QueueDownload(opt_rom, 0, true);

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
