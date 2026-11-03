//-----------------------------------------------------------------------------
// dgc_tb.vh - shared testbench macros for the distortion-correction project.
//
// Every testbench that includes this file must declare:
//     integer dgc_errors = 0;
//
// Testbench results are reported through four markers that run_test.ps1 parses:
//     TEST_INFO  <free text>   -> informational, printed on PASS
//     TEST_FAIL  <reason>      -> failure detail
//     TEST_PASS                -> printed exactly once when dgc_errors == 0
//
// Vendor Pango models reference a global instance named GRS_INST. A testbench
// that instantiates a Pango DRAM/FIFO model must place
//     DGC_GRS_INST;
// in its own scope (the reference is resolved by searching upward).
//-----------------------------------------------------------------------------
`ifndef DGC_TB_VH
`define DGC_TB_VH

// Pango global reset shim required by GTP_DRM*/GTP_FIFO* behavioural models.
`define DGC_GRS_INST  GTP_GRS GRS_INST (.GRS_N(1'b1));

// Clock half periods (ns) for the six frozen clock domains.
`define DGC_T_VIN   3.3670    // 148.5 MHz  (input pixel domain, nominal)
`define DGC_T_DDR   4.0000    // 125 MHz    (DDR user domain)
`define DGC_T_PROC  2.2222    // 225 MHz    (processing domain)
`define DGC_T_VOUT  3.3670    // 148.5 MHz  (output pixel domain, nominal)
`define DGC_T_CFG  50.0000    // 10  MHz    (HDMI I2C configuration)
`define DGC_T_SYS  18.5185    // 27  MHz    (board oscillator)

`define DGC_FAIL(msg)                                                        \
    begin                                                                    \
        dgc_errors = dgc_errors + 1;                                         \
        $display("TEST_FAIL: %s (time=%0t, file=%s:%0d)",                    \
                 msg, $time, `__FILE__, `__LINE__);                          \
    end

`define DGC_CHECK(cond, msg)                                                 \
    if (!(cond)) `DGC_FAIL(msg)

// Bit-exact comparison; unknown bits count as a failure.
`define DGC_CHECK_EQ(act, exp, msg)                                          \
    if ((act) !== (exp)) begin                                               \
        dgc_errors = dgc_errors + 1;                                         \
        $display("TEST_FAIL: %s (time=%0t) exp=%0h act=%0h",                 \
                 msg, $time, (exp), (act));                                  \
    end

// Signed-safe version for error magnitudes.
`define DGC_CHECK_LE(act, lim, msg)                                         \
    if ((act) > (lim)) begin                                                 \
        dgc_errors = dgc_errors + 1;                                         \
        $display("TEST_FAIL: %s (time=%0t) act=%0d limit=%0d",               \
                 msg, $time, (act), (lim));                                  \
    end

`define DGC_INFO(fmt, args) $display("TEST_INFO: " fmt, args)

`define DGC_FINISH                                                           \
    begin                                                                    \
        if (dgc_errors == 0)                                                 \
            $display("TEST_PASS");                                           \
        else                                                                 \
            $display("TEST_FAIL_COUNT %0d", dgc_errors);                     \
        $finish;                                                             \
    end

`endif // DGC_TB_VH
