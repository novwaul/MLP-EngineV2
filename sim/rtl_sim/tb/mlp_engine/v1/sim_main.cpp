// Verilator C++ testbench for CORE_TB (NumOfTest = SIM_NUM_OF_TEST, default 10).
//
// Drives clk_i / mclk_i / rst_ni, samples DUT.SCORE.SRF.GPR[*] every cycle,
// prints inference progress and final stats.
//
// Hierarchical signal access uses Verilator's flattened naming convention;
// gpr_public.vlt makes only the SRF.GPR array public (see Makefile).

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
static constexpr int FULL_PERIOD = 10000;
static constexpr uint32_t EXIT_MAGIC = 99999;

// CORE_TB.DUT.SCORE.SRF.GPR -> Verilator flattens to this single member.
// If a future Verilator/RTL change shifts the flat name, only this line
// needs updating.
#define GPR_ARR (top->rootp->CORE_TB__DOT__DUT__DOT__SCORE__DOT__SRF__DOT__GPR)

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

    // Initial state: rst_ni=1, clocks=0.
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

    uint32_t last_gpr25 = static_cast<uint32_t>(GPR_ARR[25]);
    uint32_t last_gpr26 = static_cast<uint32_t>(GPR_ARR[26]);
    uint32_t last_correct = static_cast<uint32_t>(GPR_ARR[27]);
    std::printf("Starting inference (%d images)\n", NUM_OF_TEST);

    auto t0 = std::chrono::steady_clock::now();
    bool exit_seen = false;

    while (!ctx->gotFinish() && !exit_seen) {
        // Falling edge half
        half_tick(top.get(), ctx.get());
        // Rising edge half
        half_tick(top.get(), ctx.get());

        // After the rising edge eval(), all FFs in the SRF have updated.
        uint32_t v26 = static_cast<uint32_t>(GPR_ARR[26]);
        if (v26 != last_gpr26) {
            uint32_t v27 = static_cast<uint32_t>(GPR_ARR[27]);
            // x26 advances after label checking; x27 holds cumulative correct answers.
            // Derive the completed range from the counters for scalar and batched runs.
            uint32_t completed = v26 < static_cast<uint32_t>(NUM_OF_TEST)
                                     ? v26 : static_cast<uint32_t>(NUM_OF_TEST);
            if (completed > last_gpr26) {
                uint32_t count = completed - last_gpr26;
                uint32_t correct = v27 - last_correct;
                if (count == 1) {
                    std::printf("Image #%u: %s (correct = %u/%u)\n",
                                completed, correct == 1 ? "correct" : "incorrect",
                                v27, completed);
                } else {
                    std::printf("Images #%u - #%u: %u/%u correct (total = %u/%u)\n",
                                last_gpr26 + 1, completed, correct, count, v27, completed);
                }
                std::fflush(stdout);
            }
            last_gpr26 = v26;
            last_correct = v27;
        }

        uint32_t v25 = static_cast<uint32_t>(GPR_ARR[25]);
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

    uint32_t correct   = static_cast<uint32_t>(GPR_ARR[27]);
    uint32_t mcycle    = static_cast<uint32_t>(GPR_ARR[28]);
    uint32_t mcycleh   = static_cast<uint32_t>(GPR_ARR[29]);
    uint32_t minstret  = static_cast<uint32_t>(GPR_ARR[30]);
    uint32_t minstreth = static_cast<uint32_t>(GPR_ARR[31]);
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
