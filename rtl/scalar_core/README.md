# scalar_core

Baseline design: a multi-cycle RV32IM core with an instruction cache. Inference
runs entirely in software.

<p align="center"><img src="../../docs/arch/scalar_core.svg" alt="scalar_core architecture" width="900"></p>

## Blocks

| Block | Description |
|---|---|
| `CPU_TOP` (`cpu_top.sv`) | Connects the instruction cache and the core. Exposes the `imem_*` (cache refill) and `dmem_*` (load/store) ports. |
| `INSTR_CACHE` (`rtl/cache/instr_cache.sv`) | Direct-mapped, 128 lines × 32-bit. Idle/Read/Write/Reset FSM. The last hit is held in the `latched_instr` register. |
| `CACHE_SRAM` (`rtl/cache/submodule/cache_sram.sv`) | 56-bit {valid, tag, data} entries stored in two `sky130_sram_1kbyte_1rw1r_32x256_8` macros (`u_sram_lo`, `u_sram_hi`). |
| `SCALAR_CORE` (`core/scalar_core.sv`) | RV32IM + Zicsr. The decoder FSM runs Fetch → Execute → (Dmem \| Jump) → Fetch. |
| `DECODER` (`core/decoder.sv`) | Instruction decode and the multi-cycle FSM. Counts retired instructions (`minstret`). |
| `REGFILE` (`core/regfile.sv`) | 32 × 32-bit registers. |
| `ALU` (`core/alu.sv`) | Integer ALU, including `MUL` / `MULH*`. |
| `CSR` (`core/csr.sv`) | `mcycle`, `minstret`. |

## Notes

- `dmem_addr_o` is driven directly by the ALU result (no output register).
- During StExecute and StDmem the instruction comes from the cache's
  `latched_instr` register. The SRAM output reaches the core directly only in
  the Fetch hit cycle, when `dmem_req_o = 0`.
- The external memory is the testbench's `MEMORY_TOP` (`rtl/memory/memory_top.sv`,
  not synthesized). It serves one request whenever a free-running 4-cycle
  counter wraps.
- The ALU, REGFILE, and CSR are reused unchanged by `mlp_engine/v2`.
