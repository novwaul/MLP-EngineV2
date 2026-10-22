# LibreLane PnR settings

All three designs (`scalar_core`, `mlp_engine/v1`, `mlp_engine/v2`) use
LibreLane 3.0.2 on sky130A with one shared set of PnR settings. The three
`librelane/<design>/config/config.json` files differ only in the RTL file
list, the macro set, and the clock port name.

Run with `./run.sh` inside `librelane/<design>/`. Each run writes to
`runs/RUN_<date>_<time>/`.

## Floorplan

| Setting | Value |
|---|---|
| `DIE_AREA` / `CORE_AREA` | `0 0 2200 2200` / `20.24 21.76 2179.48 2176.0` |
| `PL_TARGET_DENSITY_PCT` | 45 |
| `FP_MACRO_*_HALO` | 40 |
| `CLOCK_PERIOD` | 180 ns |

**Macros sit on the die edges.**

| Macro | Location (x, y) | Orientation |
|---|---|---|
| ICACHE `u_sram_lo` / `u_sram_hi` | (100, 100), (680, 100), bottom edge | FS |
| SPAD 0–3 (v1, v2) | x = 100 / 610 / 1120 / 1630; y = 1651 (v1) / 1700 (v2), top edge | N |

- **Why the edges:** sky130 OpenRAM macros block met1–met4, and met5 is
  horizontal. A macro island in the middle of the die forced long detours,
  which caused unfixable clock-net cap and hold violations.
- `pin_order.cfg` spacers are adjusted so that pins keep their positions.

## SRAM Liberty patch

- **Change:** `rtl/macros/sky130_sram_macros/lib/*_TT_1p8V_25C.lib` raise the
  `max_transition` of `addr0`, `wmask0`, and `addr1` from 0.04 ns to 0.5 ns.
  Nothing else is changed.
- **Why:** an OpenRAM generator bug (VLSIDA/OpenRAM issue #298, PR #306) wrote
  the largest characterized slew as the pin limit. No sky130 cell can drive
  0.04 ns (RSZ-0090: 0.098 ns at zero load).
- The rationale and the SHA-256 of the original file are in the lib headers.
- **Caveat:** only a TT lib exists, so ss/ff STA uses TT SRAM timing.
