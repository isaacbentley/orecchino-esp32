// The host's `gauge` reply, shared by the boards with a BQ27220 gauge and a
// BQ25896 charger (the T5 E-Paper S3 Pro and the T-Embed CC1101): one JSON
// line with the gauge's whole state, its learning milestones and the
// charger's. Formatting only, so tests/gauge_test.cpp pins the exact line.
#pragma once
#include <stdio.h>
#include "bq27220.h"
#include "bq25896.h"

// `profile`: what this boot's provision() found (bq27220::result_name).
// `chg` null when the board has no charger or it did not answer.
inline void power_report_json(char* out, size_t n, const char* profile, unsigned cell_mah,
                              const bq27220::State& s, const bq25896::State* chg) {
  char c[128] = "null";
  if (chg)
    snprintf(c, sizeof(c), "{\"state\":\"%s\",\"ichg_ma\":%d,\"vreg_mv\":%d,\"iinlim_ma\":%d,\"part\":%d}",
             chg->charging, chg->ichg_ma, chg->vreg_mv, chg->iinlim_ma, chg->part);
  char ma[12] = "null";
  if (s.ma_ok) snprintf(ma, sizeof(ma), "%d", s.ma);
  snprintf(out, n,
           "{\"type\":\"gauge\",\"profile\":\"%s\",\"cell_mah\":%u,\"soc\":%d,\"mv\":%d,\"ma\":%s,"
           "\"remaining_mah\":%d,\"full_mah\":%d,\"design_mah\":%d,\"cycles\":%d,\"soh\":%d,"
           "\"learning\":{\"full\":%s,\"vdq\":%s,\"edv2\":%s},"
           "\"battery_status\":%d,\"operation_status\":%d,\"charger\":%s}\n",
           profile, cell_mah, s.soc_pct, s.mv, ma, s.remaining_mah, s.full_mah, s.design_mah, s.cycles,
           s.soh_pct, s.full ? "true" : "false", s.vdq ? "true" : "false", s.edv2 ? "true" : "false",
           s.battery_status, s.operation_status, c);
}
