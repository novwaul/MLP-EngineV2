// Verilator C++ testbench for the placed netlist-level CORE_TB (NumOfTest = 10).
//
// Drop-in counterpart to the RTL sim_main.cpp for the post-PnR flow. The exit /
// progress / accuracy logic is identical; the only difference is the
// register-file access path. After Yosys flatten the SRF.GPR array no longer
// exists as a Verilator IData[32] member, so core_tb.sv stitches each
// 32-bit GPR back together into a continuously-assigned wire (gpr25..gpr31)
// at the testbench top. This file reads those wires.

#include "VCORE_TB.h"
#include "VCORE_TB___024root.h"
#include <verilated.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>

#ifndef SIM_NUM_OF_TEST
#define SIM_NUM_OF_TEST 10
#endif

// Time precision is set to 1ps via --timescale-override (see Makefile),
// so 5000 ps = 5 ns = half clock period.
static constexpr int NUM_OF_TEST = SIM_NUM_OF_TEST;
static constexpr int HALF_PERIOD = 5000;
static constexpr uint32_t EXIT_MAGIC = 99999;

#define GPR25 (top->rootp->CORE_TB__DOT__gpr25)
#define GPR26 (top->rootp->CORE_TB__DOT__gpr26)
#define GPR27 (top->rootp->CORE_TB__DOT__gpr27)
#define GPR28 (top->rootp->CORE_TB__DOT__gpr28)
#define GPR29 (top->rootp->CORE_TB__DOT__gpr29)
#define GPR30 (top->rootp->CORE_TB__DOT__gpr30)
#define GPR31 (top->rootp->CORE_TB__DOT__gpr31)

static inline void half_tick(VCORE_TB *top, VerilatedContext *ctx) {
    ctx->timeInc(HALF_PERIOD);
    top->clk_i = !top->clk_i;
    top->mclk_i = !top->mclk_i;
    top->eval();
}

int main(int argc, char **argv) {
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);

    auto top = std::make_unique<VCORE_TB>(ctx.get());

    // Initial state: rst_ni=1, clocks=0 (matches the RTL sim_main.cpp).
    top->rst_ni = 1;
    top->clk_i = 0;
    top->mclk_i = 0;
    top->eval();

    // Reset sequence: 1 -> 0 -> 1, one period each.
    half_tick(top.get(), ctx.get());
    half_tick(top.get(), ctx.get());
    top->rst_ni = 0;
    half_tick(top.get(), ctx.get());
    half_tick(top.get(), ctx.get());
    top->rst_ni = 1;

    uint32_t last_gpr25 = static_cast<uint32_t>(GPR25);
    uint32_t last_gpr26 = static_cast<uint32_t>(GPR26);
    std::printf("Inference image #%u - #%u\n", last_gpr26 + 1, last_gpr26 + 4);

    auto t0 = std::chrono::steady_clock::now();
    bool exit_seen = false;

    while (!ctx->gotFinish() && !exit_seen) {
        half_tick(top.get(), ctx.get());
        half_tick(top.get(), ctx.get());

        uint32_t v26 = static_cast<uint32_t>(GPR26);
        if (v26 != last_gpr26) {
            last_gpr26 = v26;
            if (v26 != 0) {
                uint32_t v27 = static_cast<uint32_t>(GPR27);
                std::printf("Current correction count = %u\n", v27);
            }
            if (v26 < static_cast<uint32_t>(NUM_OF_TEST)) {
                std::printf("Inference image #%u - #%u\n", v26 + 1, v26 + 4);
            }
        }

        uint32_t v25 = static_cast<uint32_t>(GPR25);
        if (v25 != last_gpr25) {
            last_gpr25 = v25;
            if (v25 == EXIT_MAGIC) {
                exit_seen = true;
            }
        }
    }

    auto elapsed =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
            .count();
    std::printf("exit signal seen after %.1f s wall time\n", elapsed);

    uint32_t correct   = static_cast<uint32_t>(GPR27);
    uint32_t mcycle    = static_cast<uint32_t>(GPR28);
    uint32_t mcycleh   = static_cast<uint32_t>(GPR29);
    uint32_t minstret  = static_cast<uint32_t>(GPR30);
    uint32_t minstreth = static_cast<uint32_t>(GPR31);
    double accuracy = static_cast<double>(correct) /
                      static_cast<double>(NUM_OF_TEST) * 100.0;

    static const char *const sep =
        "-------------------------------------------------------";
    std::printf("%s\n", sep);
    std::printf("Accuracy = %.2f\n", accuracy);
    std::printf("%s\n", sep);
    std::printf("mcycleh   = %08X, mcycle   = %08X\n", mcycleh, mcycle);
    std::printf("minstreth = %08X, minstret = %08X\n", minstreth, minstret);
    std::printf("%s\n", sep);

    top->final();
    return 0;
}
