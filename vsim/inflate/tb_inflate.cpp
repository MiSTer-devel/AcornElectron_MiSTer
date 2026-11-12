// Standalone test for rtl/inflate.sv: feed a .gz file, compare the output.
//   ./obj_dir/Vinflate <file.gz> <expected> [seed]
// Input bytes arrive 1-4 clocks after in_req; out_ready drops randomly.
#include "Vinflate.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

static std::vector<unsigned char> load(const char *f) {
	std::vector<unsigned char> v; FILE *fp = fopen(f, "rb");
	if (!fp) { perror(f); exit(2); }
	int c; while ((c = fgetc(fp)) != EOF) v.push_back(c);
	fclose(fp); return v;
}

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: %s in.gz expected [seed]\n", argv[0]); return 2; }
	auto in = load(argv[1]), exp = load(argv[2]);
	srand(argc > 3 ? atoi(argv[3]) : 1);
	Vinflate *t = new Vinflate;
	size_t ip = 0, op = 0; int pending = -1; long cyc = 0; bool bad = false;
	auto clk = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++; };
	t->reset = 1; clk(); clk(); t->reset = 0;
	t->start = 1; clk(); t->start = 0;
	while (cyc < 400000000L) {
		// input: answer a request after 1-4 clocks
		t->in_valid = 0;
		if (pending == 0) { t->in_valid = 1; t->in_data = ip < in.size() ? in[ip] : 0; ip++; pending = -1; }
		else if (pending > 0) pending--;
		t->out_ready = (rand() % 4) != 0;
		bool take = t->out_valid && t->out_ready;
		unsigned char ob = t->out_data;
		clk();
		if (t->in_req) pending = rand() % 4;
		if (take) {
			if (op >= exp.size() || ob != exp[op]) {
				if (!bad) fprintf(stderr, "MISMATCH at %zu: got %02x want %02x\n", op, ob, op < exp.size() ? exp[op] : 0);
				bad = true;
			}
			op++;
		}
		if (t->error) { printf("FAIL %s: error %d after %zu bytes (in %zu/%zu)\n", argv[1], t->error_code, op, ip, in.size()); return 1; }
		if (t->done) break;
	}
	if (!t->done && !(t->busy == 0)) { printf("FAIL %s: timeout\n", argv[1]); return 1; }
	if (bad || op != exp.size()) { printf("FAIL %s: %zu of %zu bytes, mismatch=%d\n", argv[1], op, exp.size(), bad); return 1; }
	printf("PASS %s: %zu -> %zu bytes, %ld clocks (%.1f clk/byte)\n", argv[1], in.size(), op, cyc, (double)cyc / (op ? op : 1));
	return 0;
}
