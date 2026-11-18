// Per-board BQ27220 profiles: the cell's capacity and its CEDV discharge
// model, as LilyGO ships them for each board (lib/BQ27220/
// bq27220_data_memory.c in the T5S3-4.7-e-paper-PRO and T-Embed-CC1101
// repositories). bq27220::provision() writes one of these when the chip
// holds anything else. Addresses are TI data-memory locations; the order is
// the vendor's write order.
#pragma once
#include "bq27220.h"

namespace bq27220 {

// Gauging Configuration bits both vendors set: CCT (cycle count threshold
// is a share of FullChargeCapacity), SC (learning suits an independent
// charger), FIXED_EDV0, FCC_LIM (FullChargeCapacity never exceeds the
// design), FC_FOR_VDQ, IGNORE_SD (count only real discharge). CSYNC stays
// off: reaching charge termination does not snap the count to full.
constexpr uint16_t kGaugingConfig = 0x0D31;

// The boards' BQ25896 fast-charge currents (bq25896.h rounds each down to
// its 64 mA step): about 0.65C of each cell, instead of the charger's
// 2048 mA power-on value. Here beside the cells so a test holds them to it.
constexpr int kT5ChargeMa = 1000;      // -> 960 mA for the 1500 mAh cell
constexpr int kTEmbedChargeMa = 845;   // -> 832 mA for the 1300 mAh cell

// LilyGO T5 E-Paper S3 Pro: 3.7 V 1500 mAh cell.
constexpr uint16_t kT5CellMah = 1500;
constexpr Param kT5EpdProfile[] = {
  { 0x929B, 2, kGaugingConfig },
  { 0x9206, 2, 0x0C8C },   // Operation Config A
  { 0x9208, 1, 0x4C },     // Operation Config B
  { 0x929D, 2, kT5CellMah },   // Full Charge Capacity, mAh (learning starts here)
  { 0x929F, 2, kT5CellMah },   // Design Capacity, mAh
  { 0x92A3, 2, 3743 },     // EMF, mV
  { 0x92A9, 2, 149 },      // C0
  { 0x92AB, 2, 867 },      // R0
  { 0x92AD, 2, 4030 },     // T0
  { 0x92AF, 2, 316 },      // R1
  { 0x92B1, 1, 9 },        // TC
  { 0x92B2, 1, 0 },        // C1
  { 0x92BD, 2, 4173 },     // Start DOD 0%: open-circuit mV at each 10% of discharge
  { 0x92BF, 2, 4043 },     //   10%
  { 0x92C1, 2, 3925 },     //   20%
  { 0x92C3, 2, 3821 },     //   30%
  { 0x92C5, 2, 3725 },     //   40%
  { 0x92C7, 2, 3665 },     //   50%
  { 0x92C9, 2, 3619 },     //   60%
  { 0x92CB, 2, 3585 },     //   70%
  { 0x92CD, 2, 3515 },     //   80%
  { 0x92CF, 2, 3439 },     //   90%
  { 0x92D1, 2, 2713 },     //   100%
  { 0x92B4, 2, 3031 },     // EDV0, mV: empty
  { 0x92B7, 2, 3385 },     // EDV1
  { 0x92BA, 2, 3501 },     // EDV2: low-battery point
  { 0x91DE, 1, 1 },        // current deadband, mA
  { 0x9217, 2, 1 },        // sleep current, mA
};

// LilyGO T-Embed CC1101: 1300 mAh cell. Adds the charge-termination
// thresholds LilyGO pairs with its charger settings.
constexpr uint16_t kTEmbedCellMah = 1300;
constexpr Param kTEmbedProfile[] = {
  { 0x929B, 2, kGaugingConfig },
  { 0x9206, 2, 0x0C8C },   // Operation Config A
  { 0x9208, 1, 0x4C },     // Operation Config B
  { 0x929D, 2, kTEmbedCellMah },   // Full Charge Capacity, mAh
  { 0x929F, 2, kTEmbedCellMah },   // Design Capacity, mAh
  { 0x91FB, 2, 512 },      // Charging Current, mA
  { 0x91FD, 2, 4208 },     // Charging Voltage, mV
  { 0x9201, 2, 128 },      // Taper Current, mA
  { 0x92A5, 2, 100 },      // Charge Termination Voltage (taper window below 4208), mV
  { 0x922A, 2, 75 },       // Charge Detect Threshold, mA
  { 0x922C, 2, 40 },       // Quit Current, mA
  { 0x92A3, 2, 3743 },     // EMF, mV
  { 0x92A9, 2, 149 },      // C0
  { 0x92AB, 2, 867 },      // R0
  { 0x92AD, 2, 4030 },     // T0
  { 0x92AF, 2, 316 },      // R1
  { 0x92B1, 1, 9 },        // TC
  { 0x92B2, 1, 0 },        // C1
  { 0x92BD, 2, 4183 },     // Start DOD 0%
  { 0x92BF, 2, 4043 },
  { 0x92C1, 2, 3925 },
  { 0x92C3, 2, 3821 },
  { 0x92C5, 2, 3725 },
  { 0x92C7, 2, 3665 },
  { 0x92C9, 2, 3619 },
  { 0x92CB, 2, 3585 },
  { 0x92CD, 2, 3515 },
  { 0x92CF, 2, 3439 },
  { 0x92D1, 2, 3299 },     //   100%
  { 0x92B4, 2, 3300 },     // EDV0, mV
  { 0x92B7, 2, 3321 },     // EDV1
  { 0x92BA, 2, 3355 },     // EDV2
  { 0x91DE, 1, 1 },        // current deadband, mA
  { 0x9217, 2, 1 },        // sleep current, mA
};

}  // namespace bq27220
