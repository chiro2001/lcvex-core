// lcvex_mmio_fabric.h
// C++ MMIO fabric 与锁步协调器共享的、版本化 checkpoint 状态。

#ifndef LCVEX_MMIO_FABRIC_H
#define LCVEX_MMIO_FABRIC_H

#include <cstddef>
#include <cstdint>

#pragma pack(push, 1)
struct LcvexMmioFabricState {
    char magic[8];             // "LCVXMMIO"
    uint32_t version;          // 1
    uint32_t size;
    uint32_t pl031_tick_offset;
    uint32_t pl031_mr;
    uint32_t pl031_lr;
    uint32_t pl031_im;
    uint32_t pl031_is;
    uint8_t pl031_alarm_armed;
    uint8_t reserved[7];
    uint64_t now_ns;
};
#pragma pack(pop)

static_assert(sizeof(LcvexMmioFabricState) == 52,
              "LcvexMmioFabricState layout changed");

extern "C" bool lcvex_mmio_fabric_save(LcvexMmioFabricState *state);
extern "C" bool lcvex_mmio_fabric_restore(
    const LcvexMmioFabricState *state);

#endif  // LCVEX_MMIO_FABRIC_H
