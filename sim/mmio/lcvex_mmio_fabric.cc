// lcvex_mmio_fabric.cc
// Verilator DPI 后端：P6 C++ MMIO fabric 的首个设备为 ARM PL031 RTC。
//
// 不能把同一锁步 QEMU 当作运行时 MMIO 从端：DUT load 必须先取得数值，再让
// QEMU 执行该指令。因此本文件是可独立链接的确定性设备实现；QEMU 仅用于
// 开发期语义取证和锁步比较。后续 fw_cfg/virtio 等设备在此增加，不写进 RTL。

#include <cstdint>
#include <cstdio>
#include <cstring>

#include "svdpi.h"
#include "lcvex_mmio_fabric.h"

namespace {

constexpr uint64_t kPl031Base = 0x0000000009010000ULL;
constexpr uint64_t kPl031Top = kPl031Base + 0x1000ULL;
// 对应 QEMU runner 的 -rtc base=2000-01-01T00:00:00,clock=vm。
constexpr uint32_t kRtcBaseSeconds = 946684800U;
constexpr uint64_t kNsecPerSec = 1000000000ULL;
constexpr uint32_t kFabricStateVersion = 1;
constexpr char kFabricStateMagic[8] = {'L', 'C', 'V', 'X', 'M', 'M', 'I', 'O'};

constexpr uint32_t kRtcDr = 0x00;
constexpr uint32_t kRtcMr = 0x04;
constexpr uint32_t kRtcLr = 0x08;
constexpr uint32_t kRtcCr = 0x0c;
constexpr uint32_t kRtcImsc = 0x10;
constexpr uint32_t kRtcRis = 0x14;
constexpr uint32_t kRtcMis = 0x18;
constexpr uint32_t kRtcIcr = 0x1c;

struct FaultRecord {
    bool valid = false;
    uint64_t addr = 0;
    bool we = false;
    uint8_t strb = 0;
    uint64_t wdata = 0;
};

class MmioFabric {
 public:
    void reset() {
        tick_offset_ = kRtcBaseSeconds;
        mr_ = 0;
        lr_ = 0;
        im_ = 0;
        is_ = 0;
        alarm_armed_ = false;
        now_ns_ = 0;
        last_fault_ = {};
    }

    void tick(uint64_t now_ns) {
        now_ns_ = now_ns;
        update_alarm();
    }

    void access(uint64_t addr, bool we, uint8_t strb, uint64_t wdata,
                uint64_t now_ns, uint64_t *rdata, bool *fault, bool *irq) {
        now_ns_ = now_ns;
        update_alarm();
        *rdata = 0;
        *fault = false;

        if (addr >= kPl031Base && addr < kPl031Top) {
            const uint32_t offset = static_cast<uint32_t>(addr - kPl031Base);
            if (we) {
                if ((strb & 0x0fU) != 0) {
                    write32(offset, static_cast<uint32_t>(wdata), strb & 0x0fU);
                }
                if ((strb & 0xf0U) != 0) {
                    write32(offset + 4, static_cast<uint32_t>(wdata >> 32),
                            static_cast<uint8_t>(strb >> 4));
                }
            } else {
                *rdata = read32(offset);
                // M1-B 的 64-bit read 以连续两个 32-bit AMBA 访问复刻 QEMU。
                if ((strb & 0xf0U) != 0) {
                    *rdata |= static_cast<uint64_t>(read32(offset + 4)) << 32;
                }
            }
            update_alarm();
            *irq = irq_level();
            return;
        }

        record_fault(addr, we, strb, wdata);
        *fault = true;
        *irq = irq_level();
    }

    bool save(LcvexMmioFabricState *state) const {
        if (state == nullptr) {
            return false;
        }
        *state = {};
        for (unsigned i = 0; i < sizeof(state->magic); ++i) {
            state->magic[i] = kFabricStateMagic[i];
        }
        state->version = kFabricStateVersion;
        state->size = sizeof(*state);
        state->pl031_tick_offset = tick_offset_;
        state->pl031_mr = mr_;
        state->pl031_lr = lr_;
        state->pl031_im = im_;
        state->pl031_is = is_;
        state->pl031_alarm_armed = alarm_armed_ ? 1 : 0;
        state->now_ns = now_ns_;
        return true;
    }

    bool restore(const LcvexMmioFabricState &state) {
        if (std::memcmp(state.magic, kFabricStateMagic, sizeof(state.magic)) != 0 ||
            state.version != kFabricStateVersion || state.size != sizeof(state)) {
            return false;
        }
        tick_offset_ = state.pl031_tick_offset;
        mr_ = state.pl031_mr;
        lr_ = state.pl031_lr;
        im_ = state.pl031_im & 1U;
        is_ = state.pl031_is & 1U;
        alarm_armed_ = state.pl031_alarm_armed != 0;
        now_ns_ = state.now_ns;
        return true;
    }

 private:
    uint32_t count() const {
        return tick_offset_ + static_cast<uint32_t>(now_ns_ / kNsecPerSec);
    }

    bool irq_level() const { return (is_ & im_ & 1U) != 0; }

    void update_alarm() {
        // QEMU PL031 在 match 恰好到达时置位；icount 下每条退休推进 1 ns，
        // 因此不跳过秒边界。复位没有定时器；MR/LR 写入才重新安排一个 alarm。
        if (alarm_armed_ && count() == mr_) {
            is_ = 1;
            alarm_armed_ = false;  // timer_del 后不会因 ICR 清除而重复触发
        }
    }

    static uint32_t byte_mask(uint8_t strb) {
        uint32_t mask = 0;
        for (unsigned i = 0; i < 4; ++i) {
            if ((strb & (1U << i)) != 0) {
                mask |= 0xffU << (8 * i);
            }
        }
        return mask;
    }

    static uint32_t merge(uint32_t old_value, uint32_t new_value, uint8_t strb) {
        const uint32_t mask = byte_mask(strb);
        return (old_value & ~mask) | (new_value & mask);
    }

    uint32_t read32(uint32_t offset) const {
        static constexpr uint8_t kId[8] = {
            0x31, 0x10, 0x14, 0x00, 0x0d, 0xf0, 0x05, 0xb1};
        switch (offset) {
            case kRtcDr:   return count();
            case kRtcMr:   return mr_;
            case kRtcLr:   return lr_;
            case kRtcCr:   return 1;       // PL031 恒 enable
            case kRtcImsc: return im_;
            case kRtcRis:  return is_;
            case kRtcMis:  return is_ & im_;
            case kRtcIcr:  return 0;       // QEMU: write-only，读 RAZ
            default:
                if (offset >= 0xfe0 && offset <= 0xffc &&
                    (offset & 3U) == 0) {
                    return kId[(offset - 0xfe0) >> 2];
                }
                // QEMU 对已映射 PL031 内的未知寄存器只记 guest-error，RAZ。
                return 0;
        }
    }

    void write32(uint32_t offset, uint32_t value, uint8_t strb) {
        switch (offset) {
            case kRtcLr:
                lr_ = merge(lr_, value, strb);
                tick_offset_ += lr_ - count();
                alarm_armed_ = true;
                break;
            case kRtcMr:
                mr_ = merge(mr_, value, strb);
                alarm_armed_ = true;
                break;
            case kRtcImsc:
                im_ = merge(im_, value, strb) & 1U;
                break;
            case kRtcIcr:
                is_ &= ~merge(0, value, strb);
                break;
            case kRtcCr:
            case kRtcDr:
            case kRtcRis:
            case kRtcMis:
                break;  // 恒 enable / read-only：与 QEMU 一致忽略写入
            default:
                break;  // ID 或未实现寄存器写入：QEMU guest-error 后忽略
        }
    }

    void record_fault(uint64_t addr, bool we, uint8_t strb, uint64_t wdata) {
        if (last_fault_.valid && last_fault_.addr == addr &&
            last_fault_.we == we && last_fault_.strb == strb &&
            last_fault_.wdata == wdata) {
            return;
        }
        last_fault_ = {true, addr, we, strb, wdata};
        std::fprintf(stderr,
                     "mmio-fabric: 未建模访问 pa=0x%016llx %s strb=0x%02x "
                     "wdata=0x%016llx\n",
                     static_cast<unsigned long long>(addr), we ? "write" : "read",
                     static_cast<unsigned>(strb),
                     static_cast<unsigned long long>(wdata));
    }

    uint32_t tick_offset_ = kRtcBaseSeconds;
    uint32_t mr_ = 0;
    uint32_t lr_ = 0;
    uint32_t im_ = 0;
    uint32_t is_ = 0;
    bool alarm_armed_ = false;
    uint64_t now_ns_ = 0;
    FaultRecord last_fault_;
};

MmioFabric g_fabric;

}  // namespace

extern "C" void lcvex_mmio_fabric_reset() {
    g_fabric.reset();
}

extern "C" void lcvex_mmio_fabric_tick(uint64_t now_ns) {
    g_fabric.tick(now_ns);
}

extern "C" void lcvex_mmio_fabric_access(uint64_t addr, svBit we,
                                            uint8_t strb, uint64_t wdata,
                                            uint64_t now_ns, uint64_t *rdata,
                                            svBit *fault, svBit *irq_level) {
    bool access_fault = false;
    bool irq = false;
    g_fabric.access(addr, we != 0, strb, wdata, now_ns, rdata, &access_fault,
                    &irq);
    *fault = access_fault ? 1 : 0;
    *irq_level = irq ? 1 : 0;
}

extern "C" bool lcvex_mmio_fabric_save(LcvexMmioFabricState *state) {
    return g_fabric.save(state);
}

extern "C" bool lcvex_mmio_fabric_restore(
    const LcvexMmioFabricState *state) {
    return state != nullptr && g_fabric.restore(*state);
}
