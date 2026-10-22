#!/usr/bin/env python3
"""Generate architecture SVGs for scalar_core, v1 and v2.

Usage: python3 docs/arch/gen_arch.py docs/arch
"""
import os, sys

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

STYLE = """
<style>
  .bg    { fill: #ffffff; }
  .top   { fill: #f6f8fb; stroke: #6b7785; stroke-width: 2; stroke-dasharray: 8 5; }
  .logic { fill: #dceaff; stroke: #3b6fb6; stroke-width: 1.6; }
  .inner { fill: #ffffff; stroke: #3b6fb6; stroke-width: 1.2; }
  .reg   { fill: #fff3b8; stroke: #b39500; stroke-width: 1.4; }
  .sram  { fill: #ffe0bf; stroke: #d27a1e; stroke-width: 1.6; }
  .sramc { fill: #fff6ec; stroke: #d27a1e; stroke-width: 1.6; }
  .acc   { fill: #def5e1; stroke: #2f8f45; stroke-width: 1.6; }
  .acci  { fill: #ffffff; stroke: #2f8f45; stroke-width: 1.2; }
  .pe    { fill: #b9e7c2; stroke: #2f8f45; stroke-width: 1.2; }
  .ext   { fill: #eceff2; stroke: #7a838c; stroke-width: 1.6; }
  .wire  { stroke: #33414f; stroke-width: 1.8; fill: none; }
  .bus   { stroke: #33414f; stroke-width: 4; fill: none; }
  .bc    { stroke: #2f8f45; stroke-width: 1.6; fill: none; }
  text   { font-family: Helvetica, Arial, sans-serif; fill: #1d2730; }
  .h     { font-size: 20px; font-weight: bold; }
  .t     { font-size: 15px; font-weight: bold; }
  .s     { font-size: 12.5px; }
  .xs    { font-size: 11px; fill: #45525e; }
  .lbl   { font-size: 11.5px; fill: #33414f; font-style: italic; }
</style>
<defs>
  <marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
    <path d="M0,0 L10,5 L0,10 z" fill="#33414f"/>
  </marker>
  <marker id="g" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
    <path d="M0,0 L10,5 L0,10 z" fill="#2f8f45"/>
  </marker>
</defs>
"""


class Svg:
    def __init__(self, w, h):
        self.w, self.h, self.e = w, h, []

    def rect(self, x, y, w, h, cls, r=8):
        self.e.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" class="{cls}"/>')

    def text(self, x, y, s, cls='s', anchor='start'):
        s = s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        self.e.append(f'<text x="{x}" y="{y}" class="{cls}" text-anchor="{anchor}">{s}</text>')

    def box(self, x, y, w, h, cls, title, lines=(), tcls='t', r=8):
        """Box with a centred title and centred sub-lines."""
        self.rect(x, y, w, h, cls, r)
        n = 1 + len(lines)
        total = 18 + 15 * (n - 1)
        cy = y + h / 2 - total / 2 + 14
        self.text(x + w / 2, cy, title, tcls, 'middle')
        for i, l in enumerate(lines):
            self.text(x + w / 2, cy + 18 + 15 * i, l, 's', 'middle')

    def group(self, x, y, w, h, cls, title, sub=None):
        """Container box with a top-left title."""
        self.rect(x, y, w, h, cls, 10)
        self.text(x + 14, y + 24, title, 't')
        if sub:
            self.text(x + 14, y + 42, sub, 'xs')

    def line(self, pts, cls='wire', start=False, end=True, marker='a'):
        d = 'M' + ' L'.join(f'{x},{y}' for x, y in pts)
        ms = f' marker-start="url(#{marker})"' if start else ''
        me = f' marker-end="url(#{marker})"' if end else ''
        self.e.append(f'<path d="{d}" class="{cls}"{ms}{me}/>')

    def dot(self, x, y, fill='#2f8f45', r=3):
        self.e.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}"/>')

    def legend(self, x, y, items):
        for cls, name in items:
            self.rect(x, y - 12, 18, 14, cls, 3)
            self.text(x + 24, y, name, 'xs')
            x += 30 + 7.2 * len(name)

    def save(self, path):
        body = '\n'.join(self.e)
        with open(path, 'w') as f:
            f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
                    f'viewBox="0 0 {self.w} {self.h}">\n{STYLE}\n'
                    f'<rect width="100%" height="100%" class="bg"/>\n{body}\n</svg>\n')


LEGEND = [('logic', 'logic'), ('reg', 'register'), ('sram', 'SRAM macro'),
          ('acc', 'accelerator'), ('ext', 'outside the chip')]


def icache(s, x, y, w=320, h=230, refill_reg=False):
    s.group(x, y, w, h, 'logic', 'INSTR_CACHE', 'direct-mapped, 128 lines × 32-bit')
    bw = (w - 44) / 2
    s.box(x + 14, y + 56, bw, 50, 'inner', 'Cache FSM', ['Idle/Read/Write/Reset'], 's')
    s.box(x + 30 + bw, y + 56, bw, 50, 'reg', 'latched_instr', ['last hit'], 's')
    s.text(x + 14, y + 128, 'CACHE_SRAM: 56-bit {valid, tag, data}', 'xs')
    s.box(x + 14, y + 136, bw, 78, 'sram', 'u_sram_lo', ['sky130_sram_1kbyte', '1rw1r_32x256_8'], 's')
    s.box(x + 30 + bw, y + 136, bw, 78, 'sram', 'u_sram_hi', ['sky130_sram_1kbyte', '1rw1r_32x256_8'], 's')


def cache_core_wires(s, x0, x1, y):
    s.line([(x0, y), (x1, y)])
    s.text((x0 + x1) / 2, y - 6, 'instr, hit', 'lbl', 'middle')
    s.line([(x1, y + 34), (x0, y + 34)])
    s.text((x0 + x1) / 2, y + 28, 'addr, read', 'lbl', 'middle')


# ----------------------------------------------------------------------------- scalar_core
s = Svg(1000, 640)
s.text(20, 34, 'scalar_core  —  CPU_TOP', 'h')
s.rect(20, 52, 960, 340, 'top', 12)
s.text(34, 74, 'CPU_TOP', 'xs')
icache(s, 50, 90)
s.group(520, 90, 430, 270, 'logic', 'SCALAR_CORE', 'RV32IM + Zicsr, multi-cycle')
s.box(540, 145, 390, 58, 'inner', 'DECODER', ['FSM:  Fetch → Execute → Dmem | Jump → Fetch'])
s.box(540, 218, 120, 54, 'reg', 'PC / IADDR', [], 's')
s.box(675, 218, 120, 54, 'inner', 'REGFILE', ['32 × 32'], 's')
s.box(810, 218, 120, 54, 'inner', 'ALU', ['incl. MUL / MULH*'], 's')
s.box(540, 286, 120, 54, 'inner', 'CSR', ['mcycle, minstret'], 's')
s.text(680, 310, 'dmem_addr_o = ALU result', 'xs')
s.text(680, 326, '(no output register)', 'xs')
cache_core_wires(s, 370, 520, 165)
s.box(150, 490, 700, 72, 'ext', 'External memory  (MEMORY_TOP, testbench)', ['one request served every 4 cycles'])
s.line([(210, 320), (210, 490)], start=True)
s.text(220, 445, 'imem_*  (cache refill)', 'lbl')
s.line([(870, 360), (870, 420), (760, 420), (760, 490)], start=True)
s.text(770, 445, 'dmem_*  (load / store)', 'lbl')
s.legend(20, 612, [l for l in LEGEND if l[0] != 'acc'])
s.save(f'{OUT}/scalar_core.svg')

# ----------------------------------------------------------------------------- v1
s = Svg(1100, 820)
s.text(20, 34, 'mlp_engine/v1  —  CPU_TOP', 'h')
s.rect(20, 52, 1060, 600, 'top', 12)
s.text(34, 74, 'CPU_TOP', 'xs')
icache(s, 50, 90)
s.group(440, 90, 620, 360, 'logic', 'SCALAR_CORE', 'baseline core + array control')
s.box(458, 145, 272, 70, 'inner', 'DECODER (multi-cycle FSM)', ['LB / LH / LHU / SB / LBU / MULH / MULHU', 'decoded as array commands'], 's')
s.box(458, 228, 128, 50, 'inner', 'REGFILE', ['32 × 32'], 's')
s.box(602, 228, 128, 50, 'inner', 'ALU', [], 's')
s.box(458, 290, 128, 46, 'inner', 'CSR', [], 's')
s.box(602, 290, 128, 46, 'reg', 'PC / IADDR', [], 's')
s.text(458, 362, 'load write-back data → array data_i', 'xs')
s.text(458, 378, '(one element per instruction)', 'xs')
# broadcast array
ax, ay = 748, 140
s.group(ax, ay, 296, 296, 'acc', 'SYSTOLIC_ARRAY', '4×4, 9-bit data, 18-bit psums, broadcast')
pe, gap = 30, 14
gx, gy = ax + 92, ay + 92
gw = 4 * pe + 3 * gap
for j in range(4):
    cx = gx + j * (pe + gap)
    bx = cx + pe + 5                      # vertical broadcast line in the gap
    s.rect(bx - 15, ay + 50, 30, 20, 'reg', 4)
    s.text(bx, ay + 64, f'w{j}', 'xs', 'middle')
    s.line([(bx, ay + 70), (bx, gy + 3 * (pe + gap) + pe - 6)], 'bc', end=False)
    for i in range(4):
        y = gy + i * (pe + gap) + 8
        s.line([(bx, y), (cx + pe, y)], 'bc', end=False); s.dot(bx, y, r=2.5)
for i in range(4):
    cy = gy + i * (pe + gap)
    by = cy + pe + 5                      # horizontal broadcast line in the gap
    s.rect(ax + 16, by - 10, 36, 20, 'reg', 4)
    s.text(ax + 34, by + 4, f'i{i}', 'xs', 'middle')
    s.line([(ax + 52, by), (gx + 3 * (pe + gap) + pe - 6, by)], 'bc', end=False)
    for j in range(4):
        x = gx + j * (pe + gap) + 8
        s.line([(x, by), (x, cy + pe)], 'bc', end=False); s.dot(x, by, r=2.5)
for i in range(4):
    for j in range(4):
        x = gx + j * (pe + gap); y = gy + i * (pe + gap)
        s.rect(x, y, pe, pe, 'pe', 4)
        s.text(x + pe / 2, y + pe / 2 + 4, 'PE', 'xs', 'middle')
s.text(ax + 148, ay + 288, 'each w / i register drives a whole column / row', 'xs', 'middle')
s.line([(730, 250), (748, 250)])
# shared dmem bus
s.line([(470, 470), (1040, 470)], 'bus', end=False)
s.text(660, 462, 'core dmem bus  (dmem_addr_o, dmem_wdata_o)', 'lbl')
s.line([(600, 450), (600, 470)], end=False)
s.group(420, 500, 420, 130, 'sramc', 'SCRATCH_PAD', '0x4000–0x4FFF, 4 KB, selected by instruction type (SH / LBU / LB / LH)')
for k in range(4):
    s.box(436 + k * 100, 555, 90, 62, 'sram', f'SRAM {k}', ['8 × 1024'], 's')
s.line([(630, 470), (630, 500)], start=True)
s.text(852, 498, 'rdata mux:', 'xs')
s.text(852, 514, 'spad_ready ? spad : dmem', 'xs')
s.text(852, 534, 'dmem_req_o masked', 'xs')
s.text(852, 550, 'during SPAD access', 'xs')
s.box(150, 700, 880, 72, 'ext', 'External memory  (MEMORY_TOP, testbench)', ['one request served every 4 cycles'])
s.line([(210, 320), (210, 700)], start=True)
s.text(220, 680, 'imem_*  (cache refill)', 'lbl')
s.line([(1010, 470), (1010, 700)], start=True)
s.text(1000, 680, 'dmem_*', 'lbl', 'end')
cache_core_wires(s, 370, 440, 165)
s.legend(20, 800, LEGEND)
s.save(f'{OUT}/v1.svg')

# ----------------------------------------------------------------------------- v2
s = Svg(1200, 960)
s.text(20, 34, 'mlp_engine/v2  —  MLP_V2_TOP', 'h')
s.rect(20, 52, 1160, 742, 'top', 12)
s.text(34, 74, 'MLP_V2_TOP', 'xs')
icache(s, 50, 90)
s.box(50, 330, 320, 40, 'reg', 'imem_response', ['refill data held for the cache'], 's')
s.group(436, 90, 328, 270, 'logic', 'SCALAR_CORE (v2)', 'baseline core + extensions')
s.box(452, 145, 296, 40, 'reg', 'Instruction register', [], 's')
s.box(452, 196, 296, 62, 'inner', 'DECODER', ['Fetch / Execute / Dmem / Jump', '+ Custom (command) + Stop (EBREAK, fault)'], 's')
for k, n in enumerate(['REGFILE', 'ALU', 'CSR']):
    s.box(452 + k * 101, 270, 94, 44, 'inner', n, [], 's')
s.text(452, 334, 'REGFILE / ALU / CSR reused from scalar_core', 'xs')
s.text(452, 349, 'byte strobes, misaligned / bus-error fault', 'xs')
# accelerator
s.group(810, 90, 350, 490, 'acc', 'MLP_V2_ACCELERATOR', 'custom-0: CFG / LOAD / RUN / STORE / WAIT / STATUS')
s.box(826, 145, 155, 56, 'acci', 'Config regs', ['addr / stride / shape'], 's')
s.box(990, 145, 155, 56, 'acci', 'Status', ['busy / error / overflow'], 's')
s.box(826, 212, 319, 50, 'acci', 'DMA  (byte-granular)', ['addr = base + row·stride + idx'], 's')
s.box(826, 273, 319, 54, 'reg', 'Double buffers  (bank 0 / bank 1)', ['abuf[2][4][16] · wbuf[2][4][16] · bbuf[2][4]'], 's')
pe, gap = 24, 13
gx, gy = 872, 384
for i in range(4):
    for j in range(4):
        x = gx + j * (pe + gap); y = gy + i * (pe + gap)
        s.rect(x, y, pe, pe, 'pe', 4)
        if j < 3:
            s.line([(x + pe, y + pe / 2), (x + pe + gap - 1, y + pe / 2)], 'bc', marker='g')
        if i < 3:
            s.line([(x + pe / 2, y + pe), (x + pe / 2, y + pe + gap - 1)], 'bc', marker='g')
for i in range(4):
    y = gy + i * (pe + gap) + pe / 2
    s.line([(838, y), (gx - 1, y)], 'bc', marker='g')
s.text(826, gy - 8, 'a →', 'xs')
for j in range(4):
    x = gx + j * (pe + gap) + pe / 2
    s.line([(x, gy - 18), (x, gy - 1)], 'bc', marker='g')
s.text(gx + 4 * (pe + gap) - 4, gy - 8, 'w ↓', 'xs')
s.line([(985, 327), (985, 352)])
s.text(993, 346, 'a / w edges', 'lbl')
s.box(1035, 400, 110, 72, 'reg', 'result_buf', ['ReLU, round', '→ uint8'], 's')
s.line([(gx + 4 * (pe + gap) - gap, 436), (1035, 436)])
s.text(826, 548, 'MLP_V2_ARRAY: 4×4 output-stationary systolic array', 'xs')
s.text(826, 564, 'int8 × int8 → 20-bit, nearest-neighbour links only', 'xs')
s.line([(764, 160), (810, 160)])
s.text(787, 152, 'cmd', 'lbl', 'middle')
s.line([(810, 192), (764, 192)])
s.text(787, 210, 'result', 'lbl', 'middle')
# arbiter
s.group(300, 630, 480, 132, 'logic', 'DATA BUS ARBITER', 'round-robin between core and accelerator, one transaction at a time')
s.box(316, 686, 210, 62, 'inner', 'Bus FSM', ['IDLE → SPAD | EXTERNAL', '→ RESPONSE → GAP'], 's')
s.box(540, 686, 226, 62, 'reg', 'Request / response regs', ['addr_q, data_q, strb_q, write_q', 'response_q'], 's')
s.line([(600, 360), (600, 630)])
s.text(610, 500, 'core mem_*', 'lbl')
s.line([(940, 580), (940, 605), (720, 605), (720, 630)])
s.text(950, 600, 'accelerator mem_*  (DMA)', 'lbl')
# scratchpad
s.group(820, 630, 340, 140, 'sramc', 'MLP_V2_SCRATCH_PAD', '0x4000–0x4FFF, 4 KB')
for k in range(4):
    s.box(834 + k * 80, 685, 72, 66, 'sram', f'bank {k}', ['32×256'], 's')
s.line([(780, 696), (820, 696)], start=True)
s.box(150, 850, 900, 72, 'ext', 'External memory  (MEMORY_TOP, testbench)', ['one request served every 4 cycles'])
s.line([(210, 370), (210, 850)], start=True)
s.text(220, 830, 'imem_*  (cache refill)', 'lbl')
s.line([(540, 762), (540, 850)], start=True)
s.text(550, 830, 'dmem_*  (driven by registers)', 'lbl')
cache_core_wires(s, 370, 436, 165)
s.legend(20, 945, LEGEND)
s.save(f'{OUT}/v2.svg')
print('ok')
