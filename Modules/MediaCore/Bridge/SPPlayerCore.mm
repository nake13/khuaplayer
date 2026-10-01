#import "SPPlayerCore.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#import "SPMetalRenderer.h"
#import "SPFrameBudgetGenerator.h"
#include "SPVideoFrameQueueSizing.hpp"
#include "SPFrameSelectionPolicy.hpp"
#include "SPInterpolationRoutingPolicy.hpp"
#include "SPMotionFrameCompatibility.hpp"
#include "SPPlayerSessionPolicy.hpp"
#include "SPPacketDataSnapshot.hpp"
#import "SPVideoDecoding.h"
#import "SPVideoDecoder.h"
#import "SPFFmpegDecoder.h"
#import "SPPlanarPixelFormat.h"

static BOOL spPlanarOutputEnabled(void) {
#if SP_APP_STORE
    return YES;
#else
    static const BOOL enabled = getenv("SP_NO_PLANAR") == nullptr;
    return enabled;
#endif
}
#import "SPAudioDecoder.h"
#import "SPAudioOutput.h"
#import "SPSubtitleRenderer.h"
#import "SPTimelineThumbnailer.h"
#import "Demuxer.hpp"
#include "SPSourceGrowthPolicy.hpp"
#include "SPContentCoverage.hpp"
#include "SPResilience.hpp"
#include "SPTrialDecode.hpp"
#include "SPResilientEndPolicy.hpp"
#include "SPPacketFixDispatch.hpp"
#include "SPVideoRecoveryLane.hpp"
#include "SPGopReadback.hpp"
#include "SPDisplayRotation.hpp"
#include <memory>

@interface SPDamageSnapshot ()
- (instancetype)initWithGeneration:(uint64_t)generation durationUs:(int64_t)durationUs
                    availableEndUs:(int64_t)availableEndUs main:(NSData *)main perTrack:(NSData *)perTrack
                           pending:(NSData *)pending;
@end
#import "BoundedQueue.hpp"
#import "SeekTargets.hpp"
#import "SPDoviRPU.hpp"
#import <VideoToolbox/VTErrors.h>

#include <mach/mach.h>
#include <pthread.h>
#include <thread>
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <map>
#include <set>
#include <unordered_set>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/pixdesc.h>
#include <dav1d/dav1d.h>
}

using namespace sp;

namespace {
// libc++ shipped with the macOS 26 SDK does not expose the C++20
// std::atomic<std::shared_ptr<T>> specialization for this deployment target,
// but its C++11 shared_ptr atomic free functions provide the same lifetime
// guarantee. Keep the tiny compatibility wrapper local to this translation
// unit so load/exchange always return a strong reference.
template <typename T>
class SPAtomicSharedPtr {
public:
    std::shared_ptr<T> load() const noexcept {
        return std::atomic_load_explicit(&value_, std::memory_order_acquire);
    }

    void store(std::shared_ptr<T> desired) noexcept {
        std::atomic_store_explicit(&value_, std::move(desired), std::memory_order_release);
    }

    std::shared_ptr<T> exchange(std::shared_ptr<T> desired) noexcept {
        return std::atomic_exchange_explicit(&value_, std::move(desired),
                                             std::memory_order_acq_rel);
    }

private:
    mutable std::shared_ptr<T> value_;
};

// A single frame type keeps the steady-state, paused, seek, and first-frame
// presentation paths on the same selection logic for both motion and Off modes.
// The Off path keeps synthetic/epoch at false/0. Its nine-byte metadata overhead
// is negligible at a queue depth of at most 20, while a separate dispatch method
// preserves the Off hot-path behavior.
struct DecodedFrame {
    CVPixelBufferRef buffer = NULL;
    int64_t ptsUs = 0;
    int64_t gen = 0;
    bool synthetic = false;
    uint64_t interpolationEpoch = 0;
};

static inline SPFrameCandidateMetadata spFrameMetadata(
    const DecodedFrame &frame) noexcept {
    return {frame.ptsUs, frame.gen, frame.synthetic,
            frame.interpolationEpoch};
}

struct TaggedPacket {
    AVPacket *pkt = nullptr;
    int64_t gen = 0;

    bool control = false;

    bool discard = false;

    int8_t allZero = -1;
};

#include "SPRuntimeGates.hpp"

static inline bool spClkDbg() {
    static const bool on = getenv("SP_CLKDBG") != nullptr;
    return on;
}

static inline bool spLandingTrimOff() {
#if SP_APP_STORE
    return false;
#else
    static const bool off = getenv("SP_NO_LANDTRIM") != nullptr;
    return off;
#endif
}
// Optional A/V diagnostics compare the ring's audible content position with the
// media clock. This reveals content/accounting mismatches that a self-consistent
// clock alone cannot detect; both diagnostic switches must be enabled.
static inline bool spSyncProbe() {
    static const bool on = spDebug() && getenv("SP_SYNCPROBE") != nullptr;
    return on;
}

static inline NSTimeInterval spUptimeSec() {
    return spNowUs() / 1e6;
}

static constexpr double kSPAudioClockHz = 48000.0;

static constexpr size_t kSPRebufferExitPacketsBase = 12;
static constexpr size_t kSPRebufferExitPacketsBoosted = 32;

// The audio-packet queue uses the same capacity during construction and prepare,
// for both local and remote media. Bursty TrueHD input produced starvation counts
// of 31, 21, and 0 at capacities 64, 256, and 768 respectively. A single value
// also keeps prelude buffering deterministic across sessions.
static constexpr size_t kSPAudioPacketQueueCapacity = 768;

// Bound landing-audio trimming. Interleaving and DTS-based MP4 seeks can return
// audio before the landing keyframe PTS, sometimes by the full reorder delay.
// Trim at most five seconds; larger discontinuities retain untrimmed behavior.
static constexpr int64_t kSPLandingTrimMaxUs = 5000000;

static bool spAv1SeqHeaderParse(const uint8_t *obu, size_t len, int *outW, int *outH) {
    if (!obu || len < 3) return false;
    Dav1dSequenceHeader seq;
    if (dav1d_parse_sequence_header(&seq, obu, len) < 0) return false;
    if (seq.profile > 2 || seq.max_width <= 0 || seq.max_height <= 0) return false;
    if (outW) *outW = seq.max_width;
    if (outH) *outH = seq.max_height;
    return true;
}

static const int kAv1SeqTrialBudget = 16;
static int spAv1TrialDecodeKeyTU(const uint8_t *data, size_t size) {
    if (!data || size == 0) return -1;
    Dav1dSettings s;
    dav1d_default_settings(&s);
    s.n_threads = 1;
    s.max_frame_delay = 1;
    s.apply_grain = 0;
    s.frame_size_limit = 8192u * 8192u;
    s.logger.callback = nullptr;
    Dav1dContext *c = nullptr;
    if (dav1d_open(&c, &s) < 0 || !c) return -1;
    Dav1dData d = {};
    uint8_t *buf = dav1d_data_create(&d, size);
    if (!buf) { dav1d_close(&c); return -1; }
    memcpy(buf, data, size);
    int verdict = 1;
    const int r = dav1d_send_data(c, &d);
    if (r < 0 && r != DAV1D_ERR(EAGAIN)) verdict = 0;
    for (int i = 0; verdict == 1 && i < 16; ++i) {
        Dav1dPicture pic = {};
        const int g = dav1d_get_picture(c, &pic);
        if (g == 0) { dav1d_picture_unref(&pic); continue; }
        if (g != DAV1D_ERR(EAGAIN)) verdict = 0;
        break;
    }
    dav1d_data_unref(&d);
    dav1d_close(&c);
    return verdict;
}

static std::atomic<unsigned> gSPCoreLogSeq{0};
#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_spLogId, ##__VA_ARGS__)

#define SP_RESLOG(...) do { if (spDebug()) [self resilientLog:[NSString stringWithFormat:__VA_ARGS__]]; } while (0)

static inline bool spPixelBufferIsInterlaced(CVPixelBufferRef buffer) {
    if (!buffer) return false;
    CVAttachmentMode mode = kCVAttachmentMode_ShouldNotPropagate;
    CFTypeRef value = CVBufferCopyAttachment(buffer, kCVImageBufferFieldCountKey, &mode);
    int fieldCount = 1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &fieldCount);
    }
    if (value) CFRelease(value);
    if (fieldCount > 1) return true;
    value = CVBufferCopyAttachment(buffer, kCVImageBufferFieldDetailKey, &mode);
    if (!value) return false;
    CFRelease(value);
    return true;
}

// Process-wide frame-queue memory wall. The 384 MB budget is approximately 2.5
// times the per-window ceiling, so a small number of windows retain their normal
// capacity. Newly created queues shrink to the remaining budget under heavier
// multi-window load, but always receive at least 0.125 seconds of cadence frames.
// The soft wall changes buffering depth, not playback correctness. Existing
// queues are not resized retroactively, and closing a window returns its claim.
static std::atomic<int64_t> gSPFrameQueueClaimedBytes{0};
static constexpr int64_t kSPFrameQueueWallBytes = 384ll * 1024 * 1024;

static int64_t spFrameQueueWallBytes(void) {
#if SP_INTERNAL_BUILD && !SP_APP_STORE
    static const int64_t v = [] {
        if (spDebug()) {
            if (const char *e = getenv("SP_FQWALL_MB")) {
                long mb = atol(e);
                if (mb >= 16 && mb <= 4096) return (int64_t)mb * 1024 * 1024;
                NSLog(@"[FQWall] SP_FQWALL_MB=%s 超出取值范围 [16,4096]，忽略（沿用默认 384MB）", e);
            }
        }
        return kSPFrameQueueWallBytes;
    }();
    return v;
#else
    return kSPFrameQueueWallBytes;
#endif
}

static std::mutex gSPFrameQueueClaimMtx;

static size_t spFrameQueueClaim(size_t desiredFrames, size_t frameBytes,
                                size_t floorFrames, int64_t *claimSlot,
                                unsigned logId) {
    std::lock_guard<std::mutex> lock(gSPFrameQueueClaimMtx);
    if (*claimSlot > 0) gSPFrameQueueClaimedBytes.fetch_sub(*claimSlot);
    *claimSlot = 0;
    const int64_t fb = (int64_t)MAX(frameBytes, (size_t)1);
    const int64_t remain = spFrameQueueWallBytes() - gSPFrameQueueClaimedBytes.load();
    const size_t affordable = remain > 0 ? (size_t)(remain / fb) : 0;
    size_t granted = desiredFrames;
    if (affordable < desiredFrames) {
        granted = MAX(MIN(floorFrames, desiredFrames), affordable);
        granted = MAX(granted, (size_t)2);
        if (spDebug()) {
            NSLog(@"[c%u][Core] 帧队列触及进程内存墙：%zu→%zu 帧"
                  @"（进程已占 %lldMB / 墙 %lldMB）",
                  logId, desiredFrames, granted,
                  gSPFrameQueueClaimedBytes.load() / (1024 * 1024),
                  spFrameQueueWallBytes() / (1024 * 1024));
        }
    }
    *claimSlot = (int64_t)granted * fb;
    gSPFrameQueueClaimedBytes.fetch_add(*claimSlot);
    return granted;
}

static void spFrameQueueRelease(int64_t *claimSlot) {
    std::lock_guard<std::mutex> lock(gSPFrameQueueClaimMtx);
    if (*claimSlot > 0) gSPFrameQueueClaimedBytes.fetch_sub(*claimSlot);
    *claimSlot = 0;
}

std::mutex sVtWarmMtx;
std::set<uint64_t> sVtWarmKeys;

std::atomic<bool> gVtWarmIssued{false};

std::atomic<bool> gRealOpenIssued{false};

static int spCodecParDepth(const AVCodecParameters *par) {
    int depth = 0;
    const AVPixFmtDescriptor *pd = av_pix_fmt_desc_get((AVPixelFormat)par->format);
    if (pd && pd->nb_components > 0) depth = pd->comp[0].depth;
    if (depth <= 0 && par->bits_per_raw_sample > 0) depth = par->bits_per_raw_sample;
    return depth > 0 ? depth : 8;
}
static uint64_t spVtWarmKey(const AVCodecParameters *par) {
    int chroma = 0;
    const int depth = spCodecParDepth(par);
    const AVPixFmtDescriptor *pd = av_pix_fmt_desc_get((AVPixelFormat)par->format);
    if (pd) chroma = (pd->log2_chroma_w << 2) | (pd->log2_chroma_h & 3);

    uint64_t prof = par->profile >= 0 ? (uint64_t)(uint32_t)par->profile + 1 : 0;
    return ((uint64_t)par->codec_id << 32) |
           ((prof & 0xFFFFF) << 12) |
           ((uint64_t)(depth & 0x3F) << 4) | (uint64_t)(chroma & 0xF);
}
}

// Built entirely on the serial prepare queue, then published to UI-visible
// ivars only by the generation-checked main-queue finish block.  Keeping this
// immutable transfer object separate prevents stop()/menu getters from racing
// ARC stores performed by a cancelled prepare.
@interface SPPreparedTrackSnapshot : NSObject
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *audioTracks;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *subtitleTracks;
@property(nonatomic, readonly) int initialAudioTrackIndex;
@property(nonatomic, readonly) NSInteger initialSubtitleTrackIndex;
- (instancetype)initWithAudioTracks:(NSArray<NSDictionary *> *)audioTracks
                      subtitleTracks:(NSArray<NSDictionary *> *)subtitleTracks
              initialAudioTrackIndex:(int)initialAudioTrackIndex
           initialSubtitleTrackIndex:(NSInteger)initialSubtitleTrackIndex;
@end

@implementation SPPreparedTrackSnapshot
- (instancetype)initWithAudioTracks:(NSArray<NSDictionary *> *)audioTracks
                      subtitleTracks:(NSArray<NSDictionary *> *)subtitleTracks
              initialAudioTrackIndex:(int)initialAudioTrackIndex
           initialSubtitleTrackIndex:(NSInteger)initialSubtitleTrackIndex {
    self = [super init];
    if (self) {
        _audioTracks = [audioTracks copy];
        _subtitleTracks = [subtitleTracks copy];
        _initialAudioTrackIndex = initialAudioTrackIndex;
        _initialSubtitleTrackIndex = initialSubtitleTrackIndex;
    }
    return self;
}
@end

@interface SPPlayerCore ()
- (void)notifyFrameInterpolationDidChange;
- (void)resetPresentedFrameRate;
#if !SP_APP_STORE
- (void)installAutomationHooksForOpenedPath:(NSString *)path;
#endif
@end

struct SPSeekRequestMailbox {
    struct Request {
        int64_t targetUs = -1;
        int64_t gen = 0;
        BOOL forward = NO;
        int64_t originUs = -1;

        int64_t requestWallUs = 0;

        int64_t alignToleranceUs = 0;
    };

    void publish(const Request &request) {
        std::lock_guard<std::mutex> lk(mtx_);
        req_ = request;
        valid_.store(true);
    }

    bool peek() const { return valid_.load(); }

    bool take(Request *out) {
        if (!valid_.load()) return false;
        std::lock_guard<std::mutex> lk(mtx_);
        if (!valid_.load()) return false;
        *out = req_;
        valid_.store(false);
        return true;
    }

    void invalidate() {
        std::lock_guard<std::mutex> lk(mtx_);
        valid_.store(false);
    }

    void resetForNewSession() {
        std::lock_guard<std::mutex> lk(mtx_);
        req_.forward = NO;
        req_.originUs = -1;
    }

private:
    mutable std::mutex mtx_;
    Request req_;
    std::atomic<bool> valid_{false};
};

using sp::SPSeekTargetUs;
using sp::SPConsumableSeekTargetUs;
using sp::SPLandingTrimTargetUs;
using sp::SPLandingTrimDecision;
using sp::spEvaluateLandingAudioTrim;

static const int kSPPrepErrNoVideoStream  = -9100;
static const int kSPPrepErrZeroDimensions = -9102;
static const int kSPPrepErrDecoderCreate  = -9103;
static const int kSPPrepErrOpenCancelled  = -9104;
static const int kSPPrepErrRetryAltVideo  = -9105;

@implementation SPProbeCancellationToken {
    std::atomic<bool> _cancelled;
}

- (instancetype)init {
    if ((self = [super init])) _cancelled.store(false, std::memory_order_relaxed);
    return self;
}

- (void)cancel { _cancelled.store(true, std::memory_order_release); }
- (BOOL)isCancelled { return _cancelled.load(std::memory_order_acquire); }

@end

#if DEBUG && !SP_APP_STORE
// Private observation ABI v1; no product header or exported player API.
struct SPGopTraceRecord {
    uint32_t version = 1, byteSize = sizeof(SPGopTraceRecord);
    uint64_t id = 0, ordinal = 0;
    int64_t gen = 0, currentGen = 0, atUs = 0, startedUs = 0, frontier = -1;
    const char *event = "", *reason = "", *disposition = "";
    int64_t pos = -1, pts = INT64_MIN, dts = INT64_MIN, packetGen = -1;
    int32_t packetSize = 0, stream = -1, flags = 0, control = 0, discard = 0, sideData = 0;
    uint32_t deferred = 0, undo = 0;
    uint64_t bytes = 0;
    int64_t keyPos = -1, triggerPos = -1;
    uint64_t configRevision = 0;
    int64_t epochUs = 0;
};
struct SPGopTraceState {
    uint64_t id = 0;
    int64_t gen = 0, startedUs = 0, keyPos = -1, triggerPos = -1, epochUs = 0;
    uint64_t configRevision = 0;
    uint32_t deferred = 0, popped = 0;
    uint64_t bytes = 0;
    bool terminal = false;
    const char *reason = "unspecified";
};
static std::atomic<uint64_t> spGopTraceNextId{1}; // fault-only allocation; never reset on reopen
#define SP_G1_TRACE(code) do { code; } while (0)
#define SP_G1_REASON(value) [self laneSetGopTraceReason:(value)]
#else
#define SP_G1_TRACE(code) do {} while (0)
#define SP_G1_REASON(value) do {} while (0)
#endif
#define SP_G1_ABORT(value) do { SP_G1_REASON(value); [self laneAbortPendingReadbackReason:(value)]; } while (0)

// Untouched main-queue ownership while G1 pauses VT. Fixed storage makes
// rollback independent of allocation. A rejecting current packet has its own
// tail slot at Core; it is not an additional candidate/undo packet.
struct SPGopUndoFifo {
    TaggedPacket packets[32]{};
    size_t head = 0, count = 0;
    SPGopUndoFifo() = default;
    SPGopUndoFifo(const SPGopUndoFifo&) = delete;
    SPGopUndoFifo& operator=(const SPGopUndoFifo&) = delete;
    bool empty() const { return count == 0; }
    bool push(TaggedPacket& packet) {
        if (count == 32) return false;
        packets[(head + count) % 32] = packet; packet = {}; ++count;
        return true;
    }
    bool pop(TaggedPacket& packet) {
        if (!count) return false;
        packet = packets[head]; packets[head] = {}; head = (head + 1) % 32; --count;
        return true;
    }
    void clear() { TaggedPacket packet; while (pop(packet)) av_packet_free(&packet.pkt); head = 0; }
    ~SPGopUndoFifo() { clear(); }
};

// Decode-thread-owned G1 transaction. After the trigger's normal path, one
// final VT drain freezes the frontier until commit or rollback.
struct SPGopPendingReadback {
    SPFFmpegDecoder *__strong candidate = nil;
    id<SPVideoDecoding> __strong primary = nil;
    sp::ReadSourceView source;
    sptrial::PacketIdentity key, trigger;
    int64_t generation = 0, epochUs = 0, startedUs = 0, lastPos = -1;
    int64_t lastNormalTimestampUs = -1, frozenFrontier = -1;
    int64_t publishedEpochGen = 0, publishedEpochUs = 0;
    uint64_t revision = 0;
    size_t replayPackets = 0, mirroredPackets = 0, mirroredBytes = 0;
    int64_t readBytes = 0;
    bool frozen = false;

    static constexpr size_t kMaxStagedFrames = 16;
    static constexpr size_t kMaxStagedBytes = 256u * 1024 * 1024;
    SPDecodedVideoOutput frames[kMaxStagedFrames]{};
    size_t frameBytes[kMaxStagedFrames]{}, count = 0, bytes = 0;
    static bool sameIdentity(const sptrial::PacketIdentity& a, const sptrial::PacketIdentity& b) {
        return a.pos == b.pos && a.pts == b.pts && a.dts == b.dts && a.size == b.size && a.stream == b.stream;
    }
    void discardThrough(int64_t frontier) {
        size_t kept = 0;
        for (size_t i = 0; i < count; ++i) {
            if (frames[i].ptsUs <= frontier) {
                CVPixelBufferRelease(frames[i].pixelBuffer);
                bytes -= frameBytes[i];
            } else {
                frames[kept] = frames[i]; frameBytes[kept++] = frameBytes[i];
            }
        }
        count = kept;
    }
    bool stage(SPDecodedVideoOutput output, int64_t frontier) {
        discardThrough(frontier);
        if (!output.pixelBuffer) return true;
        if (output.ptsUs <= frontier) { CVPixelBufferRelease(output.pixelBuffer); return true; }
        const size_t size = CVPixelBufferGetDataSize(output.pixelBuffer);
        if (size == 0 || count == kMaxStagedFrames || size > kMaxStagedBytes - bytes) {
            CVPixelBufferRelease(output.pixelBuffer); return false;
        }
        frames[count] = output; frameBytes[count++] = size; bytes += size;
        return true;
    }
    ~SPGopPendingReadback() {
        for (size_t i = 0; i < count; ++i) if (frames[i].pixelBuffer) CVPixelBufferRelease(frames[i].pixelBuffer);
        [candidate shutdown];
    }
};

static bool spFlacNativeMd5Wanted(const AVCodecParameters *par, spresil::FlacStreamInfo *infoOut) {
    if (!par || par->codec_id != AV_CODEC_ID_FLAC || !par->extradata || par->extradata_size < 34) return false;
    spresil::FlacStreamInfo info;
    if (!spresil::flacParseStreamInfo(par->extradata, (size_t)par->extradata_size, info) || !info.md5Present()) return false;
    if (infoOut) *infoOut = info;
    return true;
}

@implementation SPPlayerCore {
    unsigned _spLogId;

    int64_t _framesQueueClaimBytes;
    int64_t _motionQueueClaimBytes;
    // Background thumbnail scanning yields while this window is not key. The UI
    // drives the state through setTimelinePreviewSuspended. Only idle scanning is
    // gated; on-demand hover previews remain available. A worker stays resident
    // without issuing I/O while suspended.
    std::atomic<bool> _thumbSuspendedByUI;

    int _dbgEofLogs;
    int64_t _dbgFirstPktPts;
    int _dbgDrainFrames;
    bool _dbgDoviRpuLogged;
    int _dbgBadFrames;
    int64_t _dbgFirstFrameUs;
    int64_t _dbgReanchorLogUs;
    NSTimeInterval _dbgClkDbgLast;
    int64_t _dbgTickCount;
    int64_t _dbgTickLastUs;
    double _dbgPosJumpLastPos;
    int64_t _dbgPosJumpLastGen;

    dispatch_source_t _uiSeekTimer;
    NSView *_view;
    BOOL _previewMode;
    CAMetalLayer *_layer;
    SPMetalRenderer *_renderer;
    id<SPVideoDecoding> _decoder;
    SPAudioDecoder *_audioDecoder;
    SPAudioOutput *_audioOutput;
    std::unique_ptr<BoundedQueue<TaggedPacket>> _audioPackets;
    std::thread _audioThread;
    int _audioStreamIndex;
    int _subtitleStreamIndex;
    BOOL _subtitleActive;
    SPSubtitleRenderer *_subtitleRenderer;
    BOOL _subtitleIsSRT;
    BOOL _subtitleIsMovText;
    BOOL _subtitleIsVTT;
    AVRational _subtitleTimeBase;
    int _subReadOrder;

    std::unordered_set<uint64_t> _subSeenEvents;

    size_t _subCueBytes;
    size_t _subCueCount;
    BOOL _subCapExceeded;
    std::atomic<bool> _subtitleRefreshPending;

    std::atomic<bool> _generatedSubtitleActive;

    SPPreparedTrackSnapshot *_preparedTrackSnapshot; // prepare queue → checked main publish
    NSString *_preparedDecoderName;
    NSString *_decoderNamePub;

    NSArray<NSDictionary *> *_audioTrackList;
    NSArray<NSDictionary *> *_subtitleTrackList;
    std::map<int, AVCodecParameters *> _audioParCopies;

    std::mutex _audioParFixMtx;
    int _audioParFixTrack;
    int64_t _audioParFixOpenGen;
    std::vector<uint8_t> _audioParFixBytes;
    std::atomic<bool> _audioParFixPending;
    std::map<int, AVRational> _audioTrackTimeBases;
    struct SPSubTrackMeta { int codecId; AVRational tb; };
    std::map<int, SPSubTrackMeta> _subTrackMeta;
    NSMutableDictionary<NSNumber *, NSData *> *_subTrackPrivate;

    std::atomic<int> _pendingAudioTrack;
    std::atomic<int> _audioRebuildTrack;
    std::atomic<int> _currentAudioTrackPub;

    std::mutex _subSwitchMtx;

    std::atomic<bool> _streamDiscardDirty;

    std::atomic<int64_t> _subLoadGen;
    NSInteger _currentSubtitleTrackPub;
    double _subtitleScale;
    NSString *_hdrDescription;
    NSString *_hdrStaticDetail;
    NSString *_hdrCodecName;
    NSDictionary *_mediaInfoSnapshot;
    BOOL _audioActive;

    std::atomic<int64_t> _audioEofDrainedGen;
    BOOL _audioClockHandedOff;

    BOOL _rebufferHold;
    int64_t _rebufferHoldStartUs;
    int64_t _lastDoSeekWallUs;

    std::atomic<bool> _audioOnlySession;

    NSTimer *_audioOnlyTimer;

    BOOL _pubSourceGrowing;
    BOOL _pubSourceWaiting;
    BOOL _pubSourceStalled;
    uint32_t _pubSourcePathRev;

    std::vector<std::pair<int64_t, int64_t>> _pendingSpansUs;

    std::vector<std::pair<int64_t, int64_t>> _noContentSpansUs;
    BOOL _mkvContentScanStarted;
    BOOL _pubContentSearching;
    BOOL _contentSearchCheckQueued;

    std::shared_ptr<IndexWaitState> _indexWaitPrepState;
    IndexWaitVerdict _indexWaitPrepVerdict;
    dispatch_source_t _indexWaitTimer;
    BOOL _indexWaiting;
    BOOL _indexWaitStalled;
    BOOL _pendingScanInFlight;
    int64_t _lastSourceWaitSeenUs;
    int64_t _pendingScanLastUs;
    dispatch_queue_t _pendingScanQueue;

    std::mutex _videoCoverageMtx;
    sp::ContentCoverage _videoCoverage;
    int64_t _videoCoverageGen;
    int64_t _coverageOpenStartUs;

    struct SPHoleJump { int64_t frame; int64_t fromUs; int64_t toUs; int64_t gen; bool head; };
    std::mutex _holeJumpMtx;
    std::vector<SPHoleJump> _holeJumps;
    std::atomic<int> _holeJumpCount;
    std::atomic<int64_t> _holeHeadGen;
    std::atomic<int64_t> _holeHeadToUs;
    int64_t _seekHoleNotifiedGen;
    std::atomic<int64_t> _lastDemuxedPos;
    size_t _rebufferExitPackets;
    int64_t _rebufferLastExitWallUs;
    NSTimeInterval _audioStarveSince;

    NSTimeInterval _exhaustedSince;
    int64_t _audioNextPtsUs;
    AVRational _audioTimeBase;
    int64_t _audioClockBaseUs;
    int64_t _audioBasePlayedFrames;

    int64_t _audioRateSwitchFrames;
    double _audioRateBeforeSwitch;
    BOOL _audioRateSwitchPending;
    CADisplayLink *_displayLink;
    CGSize _lastViewportPx;
    int64_t _edrPollAtUs;
    CGFloat _edrLastPushed;

    int64_t _paceDropped;
    int64_t _paceStarved;
    int64_t _pacePresented;
    int64_t _paceLogAtUs;
    int64_t _paceSlowTicks;
    int64_t _tickPrevEntryUs;
    int64_t _tickPrevCpuUs;
    double _tickPrevLinkTs;
    int64_t _tickLastGapUs;
    int64_t _tickLastCpuDeltaUs;
    int64_t _tickLastLinkDeltaUs;
    int64_t _paceTickMaxUs;
    int64_t _pacePrevPresentUs;
    int64_t _paceClockJumps;
    int64_t _paceClockJumpMaxUs;
    int64_t _pacePrevCommitWallUs;
    int64_t _paceCommitGapMaxUs;
    int64_t _pacePrevCommitPTSUs;
    BOOL _pacePrevCommitSynthetic;

    BOOL _presentRetryPending;
    int64_t _lastFrameGeneration;
    BOOL _lastFrameSynthetic;
    uint64_t _lastFrameInterpolationEpoch;

    BOOL _presentRetryCompletesPausedSeek;

    std::atomic<int> _frameInterpolationModeValue;

    std::atomic<int> _frameInterpolationCommittedModeValue;
    std::atomic<bool> _frameInterpolationActiveValue;
    std::atomic<bool> _interpolationResetRequested;
    std::atomic<uint64_t> _interpolationPolicyEpoch;
    std::atomic<uint64_t> _interpolationTransitionAckEpoch;
    std::mutex _interpolationTransitionMtx;
    std::condition_variable _interpolationTransitionCv;
    std::mutex _interpolationStatusMtx;
    NSString *_frameInterpolationStatusValue;

    SPFrameBudgetGenerator *_generator;
    int64_t _audioPacketDurationUs;
    BOOL _reinjectingReturnedFrames;
    std::atomic<uint64_t> _lateDropCounter;

    int64_t _fpsWindowStartUs;
    int64_t _fpsWindowCount;
    int64_t _fpsWindowGen;
    int64_t _fpsLastTickUs;
    std::atomic<double> _presentedFrameRateValue;
    BOOL _interpolationDynamicHDRUnsafe;
    BOOL _interpolationInterlaced;
    BOOL _interpolationCodedInterlacedSeen;
    // Actual decoded geometry is a media fact, not a transient policy status.
    // Keep it across Off/On so resetting status cannot reopen an oversized stream.
    std::atomic<bool> _interpolationDecodedResolutionLimited;
    std::atomic<double> _displayMaximumFPS;

    std::atomic<int> _interpolationPolicyStatusCode;
#if DEBUG && !SP_APP_STORE
    // Test-only route invariants. They are compiled out of the shipping
    // Release so proving seamless transitions adds no production hot-path
    // branch, counter, or object footprint.
#endif

    std::unique_ptr<Demuxer> _demuxer;
    std::unique_ptr<BoundedQueue<TaggedPacket>> _videoPackets;
    std::unique_ptr<BoundedQueue<DecodedFrame>> _frames;
    // Created on demand. The published slot extends the queue lifetime because
    // seek, stop, and setters may load and use it from any thread. An atomic raw
    // pointer paired with unique_ptr would leave a use-after-free window between
    // load and slot reset. Off publishes nil and retains no motion queue.
    SPAtomicSharedPtr<BoundedQueue<DecodedFrame>> _motionFramesPublished;

    std::thread _demuxThread;
    std::thread _decodeThread;
    std::atomic<bool> _running;
    std::atomic<bool> _paused;
    std::atomic<bool> _seekPending;
    std::atomic<int64_t> _generation;
    std::atomic<bool> _flushPending;
    std::atomic<bool> _audioFlushPending;

    std::atomic<int64_t> _audioRingStartPtsUs;
    std::atomic<int64_t> _audioRingStartClockFrames;

    std::atomic<int64_t> _audioRingStartGen;
    std::atomic<int64_t> _audioRingEndPtsUs;

    int64_t _audioSegmentStartFrames;

    int64_t _coarseAnchorPendingGen;
    int64_t _coarseAnchorCandidateUs;

    SPSeekRequestMailbox _seekMailbox;
    int64_t _forwardSeekFloorUs;

    std::mutex _stateMtx;
    std::condition_variable _playCv;
    std::condition_variable _eofCv;
    std::mutex _decodeMtx;
    std::condition_variable _decodeCv;

    std::atomic<int64_t> _eofDrainedGen;
    std::atomic<double> _playbackRate; // 0.25–5.0; main-thread writes, audio/render reads.
    dispatch_queue_t _openQueue;
    double _volume;                 // Software gain 0~5 (UI percentage / 100)
    BOOL _muted;
    double _loopA, _loopB;
    CVPixelBufferRef _lastFrameBuffer;

    int64_t _frameStepAheadUs;

    std::atomic<bool> _motionCompareEnabled;
    CVPixelBufferRef _compareRealFrame;
    int64_t _compareRealFrameGen;
    bool _rendererCompareActive;
    std::atomic<bool> _seekFramePending;

    std::atomic<int64_t> _seekSettleGen;

    std::atomic<int64_t> _seekSettleRetryGen;
    std::atomic<bool> _needsOutputModeRedraw;
    std::atomic<bool> _seekBoostDecode;
    std::atomic<int64_t> _seekReqWallUs;
    std::atomic<int64_t> _pausedSeekWatchdogSeq;
    SPSeekTargetUs _catchUpTargetUs;

    SPConsumableSeekTargetUs _audioTrimTargetUs;

    SPLandingTrimTargetUs _audioLandingTrimUs;

    SPLandingTrimTargetUs _seekLandingKeyUs;

    int64_t _coarseLandingGen;

    int64_t _settledCoarseLandingUs;
    std::atomic<int> _decErrStreak;

    spresil::BitstreamLayout _videoLayout;
    spresil::DamageMap _damageMap;
    std::mutex _damageMtx;
    std::atomic<uint64_t> _damageGen;
    std::atomic<bool> _damageHasEvidence;
    SPDamageSnapshot *_damageSnapshotCache;
    int64_t _damageNotifyWallUs;
    BOOL _damageNotifyPending;
    std::atomic<bool> _damageNotifyHopQueued;
    uint32_t _growthPublishTick;
    std::atomic<bool> _resilientDryRun;
    std::atomic<int64_t> _availableEndUs;

    std::atomic<bool> _endTruncationEvidence;

    BOOL _flacTailProofWanted;
    uint8_t _flacStreamInfo[34];
    uint64_t _flacDeclaredTotal;
    std::atomic<int64_t> _flacMd5UnneededGen;
    BOOL _durationExtended;
    double _durationSnapshotSec;
    sp::ContentRun _contentRun;
    std::atomic<int> _openFailureHint;

    int _laneIntactFailSinceKey;
    BOOL _laneKeyDecodedOnVT;
    BOOL _laneArmed;
    BOOL _laneOnSW;
    BOOL _laneSWSawError;
    BOOL _laneGapPending;
    int _laneReturnFailures;
    int _laneReplayFailures;
    std::vector<AVPacket *> _laneGop;
    size_t _laneGopBytes;
    BOOL _laneGopOverflow;
    BOOL _laneGopFromKey;
    BOOL _laneReturnPendingVerify;
    BOOL _laneSWCandidateRejected;
    BOOL _videoTrackGivenUp;

    BOOL _audioFallbackTrackApplied;
    int _startCodePrefixFixes;
    std::set<int> _sessionExcludedVideo;
    std::set<int> _pendingExcludedVideo;
    NSString *_pendingExcludedVideoPath;
    double _pendingExcludedVideoStartSec;

    std::vector<int> _prepExcludedVideo;
    std::set<int> _prepRetryExcludedVideo;
    double _prepRetryStartSec;
    NSString *_prepPath;
    std::atomic<bool> _videoAltRetryRequested;
    std::atomic<bool> _videoAltPendingLogged;
    std::atomic<bool> _audioRecoveryRequested;
    std::atomic<int64_t> _audioSessionPcmFrames;
    std::unique_ptr<sptrial::Executor> _trialExecutor;
    int64_t _laneGopKeyPtsUs;
    int64_t _laneLastQueuedPtsUs;
    sptrial::PacketIdentity _laneReadbackKey;
    int64_t _laneReadbackEpochUs;
    int64_t _laneReadbackOriginTicks;
    uint64_t _laneConfigRevision, _laneReadbackConfigRevision;
    int _laneReadbackAttempts;
    BOOL _laneReadbackAttempted, _laneReadbackEpochValid;
    int _laneReadbackContainer; // 0=excluded, 1=MOV, 2=Matroska (prepare snapshot)
    std::unique_ptr<SPGopPendingReadback> _lanePendingReadback; // fault-only; decode thread owns all state
    SPGopUndoFifo _laneReadbackUndo;
#if DEBUG && !SP_APP_STORE
    SPGopTraceState _laneGopTrace; // decode owner; survives terminal until undo retires
#endif
    TaggedPacket _laneReadbackRollbackTail; // rejecting raw current packet follows all undo packets
    BOOL _laneReadbackHasRollbackTail;
    std::atomic<int> _dbgResilLogs;
    AVCodecParameters *_videoParCopy;

    AVCodecParameters *_thumbVideoPar;
    int _thumbVideoStreamId;

    uint64_t _rebuildFailFp;
    int64_t _rebuildFailAtUs;
    uint64_t _vtWarmKey;
    BOOL _vtWarmMarked;
    std::atomic<bool> _sessionEverPresented;

    std::atomic<int64_t> _lastSubmittedVideoGeneration;
    // UI visibility mirrors renderer submission suspension so optional index
    // I/O cannot treat a retained hidden-slot frame as a visible first frame.
    std::atomic<bool> _windowVisibleForRendering;

    uint64_t _openCommittedBase;
    uint64_t _openHardFailBase;
    std::atomic<int64_t> _approxMediaNowUs;
    std::atomic<bool> _audioResyncToNow;

    std::atomic<int64_t> _timelineEpochOffsetUs;
    std::atomic<int64_t> _timelineEpochGen;

    std::atomic<int64_t> _epochOffsetVideoUs;
    std::atomic<int64_t> _epochOffsetAudioUs;
    int64_t _epochDurationAppliedUs;

    std::vector<uint8_t> _av1SeqCandidate;
    int _av1SeqCandidateW, _av1SeqCandidateH;
    int _av1SeqReplaced;
    int _av1SeqTrials;
    spresil::Av1SeqVerdictMemo _av1SeqMemo;

    BOOL _videoIsMjpeg;
    BOOL _videoIsVp9;
    BOOL _videoIsVp8;
    BOOL _videoIsProres;
    int _proresGeomFixes;
    int _proresGeomDropped;
    int _vpSyncFixes;
    int _jpegCountFixes;
    int _jpegLengthFixes;
    int _vp9MarkerFixes;
    BOOL _containerIsMpegTs;

    std::atomic<int64_t> _seekBurstBaseGen;
    BOOL _prevSeekUnsettled;

    std::atomic<bool> _seekFlashDone;
    SPSeekTargetUs _seekDisplayTargetUs;

    std::atomic<int64_t> _seekDemuxDoneGen;

    std::atomic<int64_t> _scrubHintUs;
    std::atomic<bool> _scrubHintPending;

    std::atomic<int64_t> _indexPrefetchHoverHoldUs;
    // Timeline previews are owned by the main thread. Idle admission reads the
    // atomic _presentStarveWallUs mirror; the worker must not dereference packet
    // queues that can be rebuilt during media replacement. Presentation starvation
    // is the idle signal because bursty audio muxing can keep the video queue level
    // low even while playback has sufficient supply.
    SPTimelineThumbnailer *_thumbnailer;

    std::atomic<int64_t> _presentStarveWallUs;

    SPPlayerState _state;
    // Low-frequency state publication for caption workers. Do not read the
    // main-thread-only _state from a reader, or add policy work to frame ticks.
    std::atomic<SPPlayerState> _backgroundPlaybackState;
    double _duration;
    int64_t _timelineOriginUs;
    double _position;
    int _videoStreamIndex;
    AVRational _videoTimeBase;
    double _videoFps;
    int _videoWidth, _videoHeight;
    int _videoRotation;   // Clockwise display rotation from the container.
    BOOL _hasAudio;
    int64_t _lastPresentedPtsUs;
    int64_t _frameIntervalUs;
    int64_t _mediaClockPtsUs;
    int64_t _mediaClockWallUs;
    int64_t _appLaunchUs;
    std::atomic<int64_t> _openGeneration;

    std::atomic<int64_t> _rendererConfiguredOpenGeneration;
    NSString *_currentFilePath;
    std::atomic<bool> _firstFramePending;

    std::atomic<bool> _speculativeFirstFrameRevoked;
    int _preparedColorPrimaries, _preparedColorTrc, _preparedColorSpace, _preparedColorRange;
    float _preparedPeakNits;
    double _videoSar;
    BOOL _preparedDoviIPT;
    int _doviNalLengthSize;
    NSTimeInterval _lastPosNotify;
    double _pendingStartSeconds;
    double _requestedStartSeconds;

    BOOL _pendingForceSW;
    NSString *_pendingForceSWPath;

    bool _sessionForceSW;
    BOOL _swTerminalFallbackTried;
    BOOL _videoIsAttachedPic;
    std::vector<AVPacket *> _preludeVideoPkts;

    std::vector<AVPacket *> _preludeAudioOverflow;

    bool _reorderContainerSuspect;
    int _reorderSuspectStreak;
    std::atomic<bool> _reorderCheckDone;
    NSData *_reorderProbePkt;
    NSData *_reorderProbeExtra;
    enum AVCodecID _reorderProbeCodec;
    NSString *_reorderProbePath;
    BOOL _pendingRestampSeq;
    bool _sessionRestampSeq;
    int64_t _restampNextPtsUs;
    bool _preludeSeekDone;
    double _preludeStartSeconds;

    std::mutex _renderMtx;
    std::mutex _lifecycleMtx;
    std::mutex _audioOutMtx;
    double _activeStartSeconds;
}

#pragma mark - Lifecycle

static int spProbeInterrupt(void *opaque);

struct SPDisplaySizeProbeContext {
    int64_t deadlineUs;
    __unsafe_unretained SPProbeCancellationToken *token;
};

static int spDisplaySizeProbeInterrupt(void *opaque) {
    auto *context = static_cast<SPDisplaySizeProbeContext *>(opaque);
    return spNowUs() > context->deadlineUs || context->token.isCancelled;
}

+ (BOOL)fullFeatureTier {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (spDebug()) {
            const NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
            NSLog(@"[Tier] 功能档位=%@（macOS %ld.%ld%@）", spFullTier() ? @"完整版" : @"兼容版",
                  (long)os.majorVersion, (long)os.minorVersion,
                  spAutomation() && getenv("SP_TIER") ? @"，SP_TIER 覆盖" : @"");
        }
    });
    return spFullTier();
}

+ (CGSize)probeDisplaySizeForURL:(NSURL *)url {
    return [self probeDisplaySizeForURL:url cancellationToken:nil];
}

+ (CGSize)probeDisplaySizeForURL:(NSURL *)url
              cancellationToken:(SPProbeCancellationToken *)token {

    if (token.isCancelled) return CGSizeZero;
    SPDisplaySizeProbeContext probeContext = {spNowUs() + 3000000, token};
    AVFormatContext *ctx = avformat_alloc_context();
    if (!ctx) return CGSizeZero;
    ctx->interrupt_callback = {spDisplaySizeProbeInterrupt, &probeContext};

    ctx->probesize = 4 << 20;
    ctx->max_analyze_duration = AV_TIME_BASE / 2;
    if (avformat_open_input(&ctx, url.fileSystemRepresentation, nullptr, nullptr) < 0) {
        return CGSizeZero;
    }
    if (avformat_find_stream_info(ctx, nullptr) < 0) {
        avformat_close_input(&ctx);
        return CGSizeZero;
    }
    CGSize result = CGSizeZero;
    if (token.isCancelled) {
        avformat_close_input(&ctx);
        return result;
    }
    for (unsigned i = 0; i < ctx->nb_streams; i++) {
        AVStream *st = ctx->streams[i];
        AVCodecParameters *par = st->codecpar;
        if (par->codec_type != AVMEDIA_TYPE_VIDEO) continue;
        if (st->disposition & AV_DISPOSITION_ATTACHED_PIC) continue;
        if (par->width <= 0 || par->height <= 0) continue;
        double sar = 1.0;
        AVRational s = st->sample_aspect_ratio.num > 0 ? st->sample_aspect_ratio
                                                       : par->sample_aspect_ratio;
        if (s.num > 0 && s.den > 0) sar = (double)s.num / s.den;
        result = CGSizeMake(par->width * sar, par->height);
        if (sp::spRotationSwapsAxes(sp::spStreamClockwiseRotation(st))) {
            result = CGSizeMake(result.height, result.width);
        }
        break;
    }
    avformat_close_input(&ctx);
    return result;
}

static int spProbeStreamHasBFrames(enum AVCodecID cid, NSData *extra, NSData *pktData) {
    const AVCodec *codec = avcodec_find_decoder(cid);
    if (!codec) return -1;
    AVCodecContext *cctx = avcodec_alloc_context3(codec);
    if (!cctx) return -1;
    int result = -1;
    if (extra.length > 0) {
        cctx->extradata = (uint8_t *)av_mallocz(extra.length + AV_INPUT_BUFFER_PADDING_SIZE);
        if (cctx->extradata) {
            memcpy(cctx->extradata, extra.bytes, extra.length);
            cctx->extradata_size = (int)extra.length;
        }
    }
    cctx->thread_count = 1;
    if (avcodec_open2(cctx, codec, nullptr) == 0) {
        AVPacket *pkt = av_packet_alloc();
        if (pkt && av_new_packet(pkt, (int)pktData.length) == 0) {
            memcpy(pkt->data, pktData.bytes, pktData.length);
            if (avcodec_send_packet(cctx, pkt) == 0) {
                AVFrame *fr = av_frame_alloc();
                if (fr) {
                    avcodec_receive_frame(cctx, fr);
                    av_frame_free(&fr);
                }
            }
            result = cctx->has_b_frames;
        }
        if (pkt) av_packet_free(&pkt);
    }
    avcodec_free_context(&cctx);
    return result;
}

static int spProbeInterrupt(void *opaque) {
    return spNowUs() > *(int64_t *)opaque;
}
static BOOL spProbeStreamEmitsBFrames(NSString *path) {
    int64_t deadline = spNowUs() + 8000000;
    BOOL found = NO;

    AVFormatContext *fmt = avformat_alloc_context();
    if (!fmt) return NO;
    fmt->interrupt_callback = {spProbeInterrupt, &deadline};
    if (avformat_open_input(&fmt, path.fileSystemRepresentation, nullptr, nullptr) < 0) {
        return NO;
    }
    int vIdx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (vIdx >= 0) {
        const AVCodec *codec = avcodec_find_decoder(fmt->streams[vIdx]->codecpar->codec_id);
        AVCodecContext *cctx = codec ? avcodec_alloc_context3(codec) : nullptr;
        if (cctx &&
            avcodec_parameters_to_context(cctx, fmt->streams[vIdx]->codecpar) >= 0) {
            cctx->thread_count = 1;
            if (avcodec_open2(cctx, codec, nullptr) == 0) {
                AVPacket *pkt = av_packet_alloc();
                AVFrame *fr = av_frame_alloc();
                int fed = 0;
                while (!found && fed < 96 && pkt && fr &&
                       spNowUs() < deadline && av_read_frame(fmt, pkt) >= 0) {
                    if (pkt->stream_index == vIdx) {
                        fed++;
                        if (avcodec_send_packet(cctx, pkt) == 0) {
                            while (avcodec_receive_frame(cctx, fr) == 0) {
                                if (fr->pict_type == AV_PICTURE_TYPE_B) { found = YES; break; }
                            }
                        }
                    }
                    av_packet_unref(pkt);
                }
                if (pkt) av_packet_free(&pkt);
                if (fr) av_frame_free(&fr);
            }
        }
        if (cctx) avcodec_free_context(&cctx);
    }
    avformat_close_input(&fmt);
    return found;
}

- (void)scheduleBrokenReorderProbe {
    NSData *pktData = _reorderProbePkt;
    NSData *extra = _reorderProbeExtra;
    enum AVCodecID cid = _reorderProbeCodec;
    NSString *path = _reorderProbePath;
    if (!pktData || !path) return;
    const int64_t gen = _openGeneration.load();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int hb = spProbeStreamHasBFrames(cid, extra, pktData);
        if (hb <= 0) {
            if (spDebug()) {
                SPLOG(@"[Core] 重排探针：码流无 B 帧（hb=%d），pts==dts 合法", hb);
            }
            return;
        }

        if (!spProbeStreamEmitsBFrames(path)) {
            if (spDebug()) {
                SPLOG(@"[Core] 重排探针：声明重排容量=%d 但头部无实际 B 帧 → 免罪", hb);
            }
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_openGeneration.load() != gen) return;
            double pos = self->_position;
            SPLOG(@"[Core] 坏重排封装（B 帧深度=%d + 容器无 ctts）→ 软解重开 @%.1fs", hb, pos);
            self->_pendingForceSW = YES;
            self->_pendingRestampSeq = YES;
            self->_pendingForceSWPath = path;
            [self openMediaAtURL:[NSURL fileURLWithPath:path] startAt:pos error:nil];
        });
    });
}

- (instancetype)initWithView:(NSView *)view {
    return [self initWithView:view previewMode:NO];
}

- (instancetype)initWithView:(NSView *)view previewMode:(BOOL)previewMode {
    self = [super init];
    if (self) {
        _previewMode = previewMode;
        _rendererConfiguredOpenGeneration.store(-1);
        _seekSettleGen.store(0);
        _seekSettleRetryGen.store(-1);
        _spLogId = gSPCoreLogSeq.fetch_add(1, std::memory_order_relaxed) + 1;
        _dbgFirstPktPts = -1;
        _dbgPosJumpLastPos = -1;
        _dbgPosJumpLastGen = -1;
        _view = view;
        _layer = (CAMetalLayer *)view.layer;
        _renderer = [[SPMetalRenderer alloc] initWithLayer:_layer logId:_spLogId];
        _decoder = nil;
        _demuxer = std::make_unique<Demuxer>();

        {
            SPSeekRequestMailbox *mailbox = &_seekMailbox;
            std::atomic<bool> *running = &_running;
            _demuxer->setGrowthYield([mailbox, running] { return mailbox->peek() || !running->load(); });
        }

        if (spDebug()) {
            const unsigned logId = _spLogId;
            _demuxer->setDebugLogSink([logId](const char *line) {
                NSString *s = line ? [NSString stringWithUTF8String:line] : nil;
                if (s) NSLog(@"[c%u]%@", logId, s);
            });
        }
        _videoPackets = std::make_unique<BoundedQueue<TaggedPacket>>(48);
        _audioPackets = std::make_unique<BoundedQueue<TaggedPacket>>(
            kSPAudioPacketQueueCapacity);
        _frames = std::make_unique<BoundedQueue<DecodedFrame>>(6);
        _motionFramesPublished.store(nullptr);
        _audioStreamIndex = -1;
        _subtitleStreamIndex = -1;
        _pendingAudioTrack.store(-2);
        _audioRebuildTrack.store(-2);
        _currentAudioTrackPub.store(-1);
        _currentSubtitleTrackPub = -1;
        _subtitleScale = 1.0;
        _subtitleActive = NO;
        _subtitleIsSRT = NO;
        _subtitleRefreshPending.store(false);
        _scrubHintUs.store(-1);
        _scrubHintPending.store(false);
        _indexPrefetchHoverHoldUs.store(0);
        _presentStarveWallUs.store(0);
        _lastSubmittedVideoGeneration.store(-1);
        _windowVisibleForRendering.store(true);
        _audioActive = NO;
        _audioEofDrainedGen = -1;
        _audioClockHandedOff = NO;
        _audioClockBaseUs = 0;
        _audioBasePlayedFrames = 0;
        _audioRateSwitchFrames = -1;
        _audioRateBeforeSwitch = 1.0;
        _audioRateSwitchPending = NO;

        _state = SPPlayerStateIdle;
        _backgroundPlaybackState.store(SPPlayerStateIdle);
        _duration = 0;
        _timelineOriginUs = 0;
        _position = 0;
        _videoStreamIndex = -1;
        _videoFps = 0;
        _lastPresentedPtsUs = 0;
        _frameIntervalUs = 40000;
        _mediaClockPtsUs = 0;
        _mediaClockWallUs = 0;
        _appLaunchUs = spNowUs();
        _firstFramePending = false;
        _speculativeFirstFrameRevoked.store(false);
        _lastPosNotify = 0;
        _lastViewportPx = CGSizeZero;
        _hasAudio = NO;
        _flushPending = false;
        _audioFlushPending = false;
        _audioRingStartPtsUs.store(-1);
        _audioRingStartClockFrames.store(0);
        _audioRingStartGen.store(-1);
        _audioRingEndPtsUs.store(-1);
        _audioSegmentStartFrames = 0;
        _coarseAnchorPendingGen = -1;
        _coarseAnchorCandidateUs = 0;
        _reorderContainerSuspect = false;
        _reorderSuspectStreak = 0;
        _reorderCheckDone.store(true);
        _sessionRestampSeq = false;
        _restampNextPtsUs = -1;
        _eofDrainedGen = -1;
        _playbackRate.store(1.0);
        _openQueue = dispatch_queue_create("dev.khuaplayer.open", DISPATCH_QUEUE_SERIAL);
        _volume = 1.0;
        _muted = NO;
        _loopA = -1;
        _loopB = -1;
        _lastFrameBuffer = NULL;
        _lastFrameGeneration = -1;
        _lastFrameSynthetic = NO;
        _frameStepAheadUs = 0;
#if SP_APP_STORE
        _motionCompareEnabled.store(false);
#else
        _motionCompareEnabled.store(false);
        if (_motionCompareEnabled.load()) [_renderer setCompareSplitEnabled:YES];
#endif
        _compareRealFrame = NULL;
        _compareRealFrameGen = -1;
        _rendererCompareActive = false;
        _lastFrameInterpolationEpoch = 0;
        _presentRetryPending = NO;
        _presentRetryCompletesPausedSeek = NO;
        _seekFramePending = false;
        _seekBoostDecode = false;
        _seekReqWallUs = 0;
        _pausedSeekWatchdogSeq = 0;
        _catchUpTargetUs.clear();
        _seekBurstBaseGen = 0;
        _videoSar = 1.0;
        _seekFlashDone = true;
        _preludeSeekDone = false;
        _seekDisplayTargetUs.clear();
        _seekDemuxDoneGen = 0;

        _forwardSeekFloorUs = -1;
        _coarseLandingGen = -1;
        _settledCoarseLandingUs = -1;
        _frameInterpolationModeValue.store(SPFrameInterpolationModeOff);
        _frameInterpolationCommittedModeValue.store(SPFrameInterpolationModeOff);
        _frameInterpolationActiveValue.store(false);
        _interpolationResetRequested.store(false);
        _interpolationPolicyEpoch.store(1);
        _interpolationTransitionAckEpoch.store(1);
        _frameInterpolationStatusValue = NSLocalizedString(@"memc.status.off", nil);
        _interpolationDynamicHDRUnsafe = NO;
        _interpolationInterlaced = NO;
        _interpolationCodedInterlacedSeen = NO;
        _interpolationDecodedResolutionLimited.store(false);
        _displayMaximumFPS.store(60.0);
        _interpolationPolicyStatusCode.store(-1);
        {

            sp::SPFrameGeneratorLiveState live;
            live.generation = &_generation;
            live.seekPending = &_seekPending;
            live.requestedMode = &_frameInterpolationModeValue;
            live.policyEpoch = &_interpolationPolicyEpoch;
            live.firstFramePending = &_firstFramePending;
            live.running = &_running;
            live.paused = &_paused;
            live.displayMaximumFPS = &_displayMaximumFPS;
            live.playbackRate = &_playbackRate;
            live.activeValue = &_frameInterpolationActiveValue;
            live.lateDrops = &_lateDropCounter;
            __weak SPPlayerCore *weakSelf = self;
            _generator = [[SPFrameBudgetGenerator alloc]
                initWithDevice:_renderer.device
                         logId:_spLogId
                     liveState:live
                       enqueue:^PushResult(CVPixelBufferRef buffer, int64_t ptsUs, int64_t generation,
                                           BOOL synthetic, uint64_t epoch, uint64_t interruptGeneration) {
                           SPPlayerCore *s = weakSelf;
                           if (!s) return PushResult::Closed;
                           return [s enqueueMotionVideoBuffer:buffer ptsUs:ptsUs generation:generation
                                                    synthetic:synthetic interpolationEpoch:epoch
                                          interruptGeneration:interruptGeneration];
                       }
                        status:^(NSString *status, BOOL active, int code) {
                            SPPlayerCore *s = weakSelf;
                            if (s) [s setInterpolationWorkerStatus:status active:active code:code];
                        }
                    queueDepth:^size_t {
                        SPPlayerCore *s = weakSelf;
                        if (!s) return (size_t)0;
                        auto q = s->_motionFramesPublished.load();
                        return q ? q->size() : (size_t)0;
                    }];
        }
#if DEBUG && !SP_APP_STORE
#endif
#if !SP_APP_STORE
        [self startFreezeWatchdogIfRequested];
#endif

        av_log_set_level(spDebug() ? AV_LOG_WARNING : AV_LOG_ERROR);
        _subtitleRenderer = [[SPSubtitleRenderer alloc] initWithDevice:_renderer.device
                                                                  logId:_spLogId];

        __weak SPPlayerCore *weakSelf = self;
        _subtitleRenderer.publishCallback = ^{
            SPPlayerCore *sself = weakSelf;
            if (!sself) return;
            if (!sself->_subtitleRefreshPending.exchange(true)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    sself->_subtitleRefreshPending.store(false);
                    [sself refreshSubtitleDisplay];
                });
            }
        };

#if SP_APP_STORE
        if (!previewMode) {
#else
        if (!getenv("SP_NO_GPUWARMUP") && !previewMode) {
#endif
            // Yield warm-up when a real open has already started
            // (openGeneration > 0). The first real frame performs the same GPU
            // initialization, and prepareAudio creates its AudioUnit as needed.
            // GPU/driver and CoreAudio HAL cold initialization are process-wide,
            // so each warm-up is issued at most once to avoid redundant startup
            // contention across multiple cores.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                static std::atomic<bool> gGpuWarmIssued{false};
                if (gGpuWarmIssued.exchange(true)) return;
                if (self->_openGeneration > 0) return;
                int64_t t0 = spNowUs();
                [_renderer warmUpGPU];
                if (spDebug()) SPLOG(@"[Core] GPU预热: %lldms", (spNowUs() - t0) / 1000);
            });

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                static std::atomic<bool> gAudioWarmIssued{false};
                if (gAudioWarmIssued.exchange(true)) return;
                if (self->_openGeneration > 0) return;
                int64_t t0 = spNowUs();
                [self ensureAudioOutput];
                if (spDebug()) SPLOG(@"[Core] AudioUnit预建: %lldms", (spNowUs() - t0) / 1000);
            });
            // The first VT decoder session costs about 87 ms for driver/XPC
            // loading; later sessions cost about 1.3 ms. Delay warm-up by 300 ms
            // so a launch-time media open can claim the VT driver first instead
            // of contending with a speculative session.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                if (gVtWarmIssued.exchange(true)) return; // process-wide once gate
                if (self->_openGeneration > 0 || gRealOpenIssued.load()) return;
                int64_t t0 = spNowUs();
                [SPVideoDecoder warmUpDecoderForCodecID:AV_CODEC_ID_H264];
                if (self->_openGeneration > 0 || gRealOpenIssued.load()) return;
                [SPVideoDecoder warmUpDecoderForCodecID:AV_CODEC_ID_HEVC];
                if (spDebug()) SPLOG(@"[Core] VT预热: %lldms", (spNowUs() - t0) / 1000);
            });
        }
    }
    return self;
}

#if !SP_APP_STORE

- (void)startFreezeWatchdogIfRequested {
    if (!getenv("SP_FREEZE_LOG")) return;
    const unsigned logId = _spLogId;
    __weak SPPlayerCore *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        __block uint64_t lastBeat = 0;
        while (true) {
            usleep(3000000);

            if (weakSelf == nil) return;
            lastBeat = 0;
            dispatch_async(dispatch_get_main_queue(), ^{ lastBeat = spNowUs(); });
            usleep(2000000);
            if (lastBeat == 0) {
                NSLog(@"[c%u][Freeze] 主线程疑似卡死（3s 心跳无响应）！", logId);
            }
        }
    });
}
#endif

- (void)dealloc {
    [self stop];
    _trialExecutor.reset();
    [_generator shutdown];
    spFrameQueueRelease(&_framesQueueClaimBytes);
    spFrameQueueRelease(&_motionQueueClaimBytes);
    for (auto &kv : _audioParCopies) avcodec_parameters_free(&kv.second);
    _audioParCopies.clear();
}

- (void)ensureDisplayLink {
    if (_displayLink) return;
    _displayLink = [_view displayLinkWithTarget:self selector:@selector(displayLinkTick:)];
    if (!_displayLink) {
        SPLOG(@"[Core] 无法创建 DisplayLink（macOS 14+ 需要）");
        return;
    }
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _displayLink.paused = YES;
}

#pragma mark - Opening media

- (BOOL)openFileAtPath:(NSString *)path error:(NSError **)error {
    // Opening runs in the background. The main thread stops the current session,
    // publishes Opening, and returns without blocking the window or UI.
    const int64_t openT0 = spNowUs();

    gRealOpenIssued.store(true, std::memory_order_release);
    // MEMC always returns to Off for a new media item. Workload characteristics
    // vary between items, and carrying the mode forward would overlap engine
    // setup and ring fill with the busiest replacement or resume-seek window.
    if (_frameInterpolationModeValue.load() != (int)SPFrameInterpolationModeOff) {
        [self setFrameInterpolationMode:SPFrameInterpolationModeOff];
    }
    // EDR is a stateless per-item toggle like MEMC: carrying it across items
    // would open the next SDR file straight into the EDR layer without the
    // user asking. The SP_XDR hook re-arms it after each open when needed.
    if ([_renderer sdrBoostEnabled]) [_renderer setSDRBoostEnabled:NO];
    // Aspect ratio, crop, rotation, and mirroring are scoped to one media item.
    // Reset them in the core so every open path, including sequential playback
    // and test hooks, observes the same invariant. UI menu state resets in open().
    [_renderer resetPictureTransform];
    [self stop];
    _interpolationDecodedResolutionLimited.store(false);
    if (spDebug()) {
        SPLOG(@"[Open] 主线程 stop 段 %.0fms", (spNowUs() - openT0) / 1000.0);
    }
    _audioOnlySession.store(false);

    _dbgEofLogs = 0;
    _dbgFirstPktPts = -1;
    _dbgDrainFrames = 0;
    _dbgDoviRpuLogged = false;
    _dbgBadFrames = 0;
    _dbgFirstFrameUs = 0;

    _pendingStartSeconds = _requestedStartSeconds;
    _requestedStartSeconds = 0;
    [self ensureDisplayLink];
    [self setState:SPPlayerStateOpening];

    int64_t gen;
    {

        std::lock_guard<std::mutex> lock(_lifecycleMtx);
        gen = ++_openGeneration;
        _speculativeFirstFrameRevoked.store(false, std::memory_order_release);
    }
    NSString *pathCopy = [path copy];
    _currentFilePath = pathCopy;

    _position = _pendingStartSeconds;
    _duration = 0;
    _timelineOriginUs = 0;

    _sessionForceSW = _pendingForceSW && _pendingForceSWPath &&
                      [_pendingForceSWPath isEqualToString:pathCopy];

    _sessionRestampSeq = _sessionForceSW && _pendingRestampSeq;
    _pendingForceSW = NO;
    _pendingRestampSeq = NO;
    _pendingForceSWPath = nil;
    if (!_sessionForceSW) _swTerminalFallbackTried = NO;

    _sessionExcludedVideo.clear();
    if (_pendingExcludedVideoPath && [_pendingExcludedVideoPath isEqualToString:pathCopy]) _sessionExcludedVideo = _pendingExcludedVideo;
    _pendingExcludedVideo.clear();
    _pendingExcludedVideoPath = nil;
    _videoAltRetryRequested.store(false);
    _videoAltPendingLogged.store(false);
    _audioRecoveryRequested.store(false);
    _audioSessionPcmFrames.store(0);

    const std::vector<int> excludedSnapshot(_sessionExcludedVideo.begin(), _sessionExcludedVideo.end());
    dispatch_async(_openQueue, ^{
        if (gen != self->_openGeneration) return;
        self->_prepExcludedVideo = excludedSnapshot;
        int64_t tOpen0 = spNowUs();

        int prepErr = [self prepareMediaInBackground:pathCopy generation:gen];
        int64_t prepUs = spNowUs() - tOpen0;
        if (spDebug()) {
            SPLOG(@"[Core] 后台准备: %lldms (demux+解码器)", prepUs / 1000);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_openGeneration) {

                return;
            }
            [self finishMediaOpenWithPrepError:prepErr path:pathCopy];
        });
    });
    return YES;
}

- (int)prepareMediaInBackground:(NSString *)path generation:(int64_t)openGen {
    _prepPath = path;

    if (_decoder) { [_decoder shutdown]; _decoder = nil; }
    _audioDecoder = nil;

    _audioOnlySession.store(false);

    _videoPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
    _audioPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
    _frames->drain([](DecodedFrame f) { if (f.buffer) CVPixelBufferRelease(f.buffer); });
    if (auto motionFrames = _motionFramesPublished.exchange(nullptr)) {
        motionFrames->drain([](DecodedFrame f) {
            if (f.buffer) CVPixelBufferRelease(f.buffer);
        });
        spFrameQueueRelease(&_motionQueueClaimBytes);
    }
    _frameInterpolationCommittedModeValue.store(SPFrameInterpolationModeOff);
    _demuxer->close();
    _openFailureHint.store(0);
    _demuxer->setExcludedVideoStreams(_prepExcludedVideo);
    if (!_prepExcludedVideo.empty()) SPLOG(@"[Resilient] 备用视频轨重开：排除 %zu 条已实证不可解的视频流", _prepExcludedVideo.size());
    int ret = _demuxer->open(path.UTF8String, false);
    _containerIsMpegTs = ret == 0 && _demuxer->containerName().find("mpegts") != std::string::npos;
    _laneReadbackContainer = 0;
    if (ret == 0) {
        const auto& container = _demuxer->containerName();
        if (container.find("mov") != std::string::npos) _laneReadbackContainer = 1;
        else if (container.find("matroska") != std::string::npos) _laneReadbackContainer = 2;
    }
    if (ret < 0) {

        _openFailureHint.store((int)_demuxer->openFailureHint());
        _indexWaitPrepState.reset();
        if ((spresil::OpenFailureHint)_openFailureHint.load() == spresil::OpenFailureHint::IndexAtTailNotDownloaded) {

            auto st = std::make_shared<IndexWaitState>();
            _indexWaitPrepVerdict = spProbeIndexWait(path.UTF8String, *st);
            if (_indexWaitPrepVerdict != IndexWaitVerdict::NotWritten) _indexWaitPrepState = st;
        }
        SPLOG(@"[Core] 打开失败：demux open err=%d (%s) hint=%d path=%@",
              ret, av_err2str(ret), _openFailureHint.load(), path.lastPathComponent);
        [self discardFailedPrepare];
        return ret;
    }
    if (_demuxer->openedAfterZeroHeadRetry()) {
        SPLOG(@"[Resilient] 零头 %lld 字节：扩探测预算重试后打开成功（轨道/参数仍按常规验证）",
              (long long)_demuxer->openDiagnosis().leadingZeroBytes);
    }

    _videoStreamIndex = _demuxer->videoStream();

    bool needAnalyze = (_videoStreamIndex < 0);
    if (!needAnalyze) {
        const StreamInfo &vs0 = _demuxer->streams()[_videoStreamIndex];
        AVCodecParameters *par0 = _demuxer->ctx()->streams[_videoStreamIndex]->codecpar;

        std::string container = _demuxer->containerName();
        bool mkvLike = container.find("matroska") != std::string::npos ||
                       container.find("webm") != std::string::npos;

        bool mp4Like = container.find("mp4") != std::string::npos ||
                       container.find("mov") != std::string::npos;
        bool analyzeFree = mp4Like && par0->codec_id == AV_CODEC_ID_H264;
        needAnalyze = (vs0.width == 0 || vs0.height == 0 || par0->extradata_size == 0 ||
                       (!analyzeFree && par0->format == AV_PIX_FMT_NONE) ||
                       vs0.fps <= 0 ||
                       (mkvLike && par0->color_trc == AVCOL_TRC_UNSPECIFIED));
    }

    auto prepareSuperseded = [self, openGen] {
        return self->_openGeneration.load(std::memory_order_acquire) != openGen;
    };
    if (prepareSuperseded()) { [self discardFailedPrepare]; return kSPPrepErrOpenCancelled; }
    if (needAnalyze) {
        int ar = _demuxer->analyzeStreams();
        if (ar < 0) { [self discardFailedPrepare]; return ar; }
        _videoStreamIndex = _demuxer->videoStream();
        if (_videoStreamIndex < 0) {
            // A file with audio tracks but no video uses the audio-only session.
            // A container with no usable streams still returns -100.
            if (_demuxer->audioStream() < 0) {
                [self discardFailedPrepare];
                return kSPPrepErrNoVideoStream;
            }
            return [self prepareAudioOnlySessionWithGeneration:openGen];
        }
    }

    const StreamInfo &vs = _demuxer->streams()[_videoStreamIndex];
    AVFormatContext *ctx = _demuxer->ctx();
    AVCodecParameters *par = ctx->streams[_videoStreamIndex]->codecpar;
    if (vs.width == 0 || vs.height == 0) {

        const int altVideo = _demuxer->alternateVideoStream(_videoStreamIndex);
        if (altVideo >= 0 && !prepareSuperseded()) {
            SPLOG(@"[Resilient] 视频轨 流#%d 分析后无尺寸而文件另有视频轨 流#%d → 排除本轨重开", _videoStreamIndex, altVideo);
            _prepRetryExcludedVideo = std::set<int>(_prepExcludedVideo.begin(), _prepExcludedVideo.end());
            _prepRetryExcludedVideo.insert(_videoStreamIndex);
            _prepRetryStartSec = _preludeStartSeconds;
            [self discardFailedPrepare];
            return kSPPrepErrRetryAltVideo;
        }
        if (_demuxer->audioStream() >= 0 && !prepareSuperseded()) {
            const std::string vcodec = vs.codecName;
            SPLOG(@"[Resilient] 视频轨 流#%d（%s）分析后无尺寸 → 视频轨标不可用，以纯音频会话继续", _videoStreamIndex, vcodec.c_str());
            const int aret = [self prepareAudioOnlySessionWithGeneration:openGen];
            if (aret == 0) {
                _videoTrackGivenUp = YES;
                [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::None
                              confidence:spresil::Confidence::DecodeVerified
                                  fromUs:0 untilUs:(int64_t)(MAX(_duration, 0.5) * 1e6)];
                SP_RESLOG(@"视频轨（%s）无有效尺寸，音轨可解：只播放音频", vcodec.c_str());
            }
            return aret;
        }
        [self discardFailedPrepare];
        return kSPPrepErrZeroDimensions;
    }

    {
        std::string cn = _demuxer->containerName();
        _reorderContainerSuspect =
            !_sessionRestampSeq &&
            (cn.find("mp4") != std::string::npos || cn.find("mov") != std::string::npos) &&
            (par->codec_id == AV_CODEC_ID_H264 || par->codec_id == AV_CODEC_ID_HEVC);
        _reorderSuspectStreak = 0;
        _reorderCheckDone.store(!_reorderContainerSuspect);
        _reorderProbeCodec = par->codec_id;
        _reorderProbeExtra = (par->extradata && par->extradata_size > 0)
            ? [NSData dataWithBytes:par->extradata length:(NSUInteger)par->extradata_size]
            : nil;
        _reorderProbePkt = nil;
        _reorderProbePath = [path copy];
        _restampNextPtsUs = -1;
        if (_sessionRestampSeq) {
            SPLOG(@"[Core] 坏重排修复会话：FFmpeg 解码（显示序）+ 按帧率顺序重打 pts");
        }
    }

    _videoTimeBase = vs.timeBase;

    if (_videoParCopy) avcodec_parameters_free(&_videoParCopy);
    if (_thumbVideoPar) avcodec_parameters_free(&_thumbVideoPar);
    _videoParCopy = avcodec_parameters_alloc();
    if (_videoParCopy) avcodec_parameters_copy(_videoParCopy, par);
    _thumbVideoPar = avcodec_parameters_alloc();
    if (_thumbVideoPar) avcodec_parameters_copy(_thumbVideoPar, par);
    _thumbVideoStreamId = ctx->streams[_videoStreamIndex]->id;

    _videoLayout = spresil::classifyLayout(
        par->codec_id == AV_CODEC_ID_H264, par->codec_id == AV_CODEC_ID_HEVC,
        par->codec_id == AV_CODEC_ID_AV1,
        par->codec_id == AV_CODEC_ID_MPEG1VIDEO || par->codec_id == AV_CODEC_ID_MPEG2VIDEO ||
            par->codec_id == AV_CODEC_ID_MPEG4,
        par->extradata, par->extradata_size, par->codec_id == AV_CODEC_ID_MPEG4);
    _videoIsMjpeg = par->codec_id == AV_CODEC_ID_MJPEG;
    _videoIsVp9 = par->codec_id == AV_CODEC_ID_VP9;
    _videoIsVp8 = par->codec_id == AV_CODEC_ID_VP8;
    _videoIsProres = par->codec_id == AV_CODEC_ID_PRORES;

    _videoFps = vs.fps > 0 ? MAX(1.0, MIN(vs.fps, 240.0)) : 30.0;
    if (spDebug() && vs.fps > 240.0) SPLOG(@"[Core] 容器 fps=%.1f 超界 → 节奏按 240", vs.fps);
    _videoWidth = vs.width;
    _videoHeight = vs.height;
    // Decoded frames keep their stored orientation; the renderer turns them.
    _videoRotation = vs.rotation;
    [_renderer setSourceRotation:_videoRotation];
    if (spDebug() && _videoRotation) SPLOG(@"[Core] 容器显示矩阵：顺时针旋转 %d°", _videoRotation);

    _videoIsAttachedPic =
        (ctx->streams[_videoStreamIndex]->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0;
    _hasAudio = _demuxer->audioStream() >= 0;
    _duration = (_demuxer->durationUs() > 0 ? _demuxer->durationUs() : vs.durationUs) / 1e6;
    _timelineOriginUs = _demuxer->timelineOriginUs();
    _laneReadbackOriginTicks = av_rescale_q(_timelineOriginUs, AV_TIME_BASE_Q, _videoTimeBase);
    _frameIntervalUs = (int64_t)(1e6 / _videoFps);
    _preparedColorPrimaries = vs.colorPrimaries;
    _preparedColorTrc = vs.colorTrc;
    _preparedColorSpace = vs.colorSpace;
    _preparedColorRange = vs.colorRange;
    _preparedPeakNits = (vs.maxCll > 0) ? vs.maxCll : 1000.0f;
    _videoSar = (vs.sampleAspect.num > 0 && vs.sampleAspect.den > 0)
                    ? av_q2d(vs.sampleAspect) : 1.0;

    _preparedDoviIPT = (vs.isDovi && vs.doviProfile == 5);

    _doviNalLengthSize = 4;
    if (_preparedDoviIPT && _videoParCopy && _videoParCopy->extradata &&
        _videoParCopy->extradata_size >= 23 && _videoParCopy->extradata[0] == 1) {
        _doviNalLengthSize = (_videoParCopy->extradata[21] & 3) + 1;
    }
    // Per-frame Dolby Vision or HDR10+ dynamic metadata no longer describes a
    // synthesized image. Static HDR10 (PQ) and HLG color remain safe to interpolate.
    // Only DoVi P5/IPTPQc2 dynamic metadata currently enters the rendering path;
    // HDR10+ and supported P8.x media render their HDR10/HLG/SDR base layer without
    // consuming RPU or ST 2094-40 data. Unknown profiles and compatibility modes
    // remain on the pass-through path unless their base-layer semantics are known.
    const BOOL doviHasVerifiedBaseLayer =
        vs.isDovi &&
        ((vs.doviProfile == 8 &&
          (vs.doviBlCompatId == 1 || vs.doviBlCompatId == 2 ||
           vs.doviBlCompatId == 4)) ||
         // P7 commonly uses compatibility id 6 and defines an HDR10 base layer.
         // This renderer displays only that base layer and consumes neither EL nor
         // RPU, so interpolating it has the same safety properties as HDR10.
         vs.doviProfile == 7);
    _interpolationDynamicHDRUnsafe = vs.isDovi && !doviHasVerifiedBaseLayer;

    _interpolationInterlaced = par->field_order != AV_FIELD_UNKNOWN &&
                               par->field_order != AV_FIELD_PROGRESSIVE;
    _interpolationCodedInterlacedSeen = NO;

    if (vs.isDovi && vs.doviProfile == 8 &&
        (vs.doviBlCompatId == 1 || vs.doviBlCompatId == 4)) {
        BOOL filled = NO;
        if (_preparedColorTrc == AVCOL_TRC_UNSPECIFIED) {
            _preparedColorTrc = (vs.doviBlCompatId == 1) ? AVCOL_TRC_SMPTE2084
                                                         : AVCOL_TRC_ARIB_STD_B67;
            filled = YES;
        }
        if (_preparedColorPrimaries == AVCOL_PRI_UNSPECIFIED) {
            _preparedColorPrimaries = AVCOL_PRI_BT2020;
            filled = YES;
        }
        if (_preparedColorSpace == AVCOL_SPC_UNSPECIFIED) {
            _preparedColorSpace = AVCOL_SPC_BT2020_NCL;
            filled = YES;
        }
        if (filled && spDebug()) {
            SPLOG(@"[Core] DoVi P8 VUI 缺失字段 → 按 bl_compat=%d 补全 (trc=%d pri=%d spc=%d)",
                  vs.doviBlCompatId, _preparedColorTrc, _preparedColorPrimaries, _preparedColorSpace);
        }
    }
    if (spDebug() && vs.isDovi) {
        const char *compat = vs.doviBlCompatId == 1 ? "HDR10(2020 PQ)"
                           : vs.doviBlCompatId == 2 ? "SDR(709)"
                           : vs.doviBlCompatId == 4 ? "HLG" : "无(P5 IPT)";
        SPLOG(@"[Core] Dolby Vision Profile %d.%d 兼容层=%s → %@", vs.doviProfile,
              vs.doviBlCompatId, compat,
              _preparedDoviIPT ? @"IPTPQc2 转换链" : @"基础层直播");
    }

    if (_preparedColorSpace == AVCOL_SPC_UNSPECIFIED &&
        _preparedColorPrimaries == AVCOL_PRI_UNSPECIFIED && vs.height > 0 && vs.height <= 576) {
        _preparedColorSpace = AVCOL_SPC_SMPTE170M;
        _preparedColorPrimaries = (vs.height <= 480) ? AVCOL_PRI_SMPTE170M : AVCOL_PRI_BT470BG;
    }

    {
        const AVPixFmtDescriptor *pfd = av_pix_fmt_desc_get((AVPixelFormat)par->format);
        const bool rgbPix = pfd && (pfd->flags & AV_PIX_FMT_FLAG_RGB);
        if (_preparedColorSpace == AVCOL_SPC_RGB || (rgbPix && _preparedColorSpace == AVCOL_SPC_UNSPECIFIED)) {
            _preparedColorSpace = (vs.height > 0 && vs.height <= 576) ? AVCOL_SPC_SMPTE170M
                                                                        : AVCOL_SPC_BT709;
        }
    }
    if (spDebug() && fabs(_videoSar - 1.0) > 0.001) {
        SPLOG(@"[Core] 变形内容 SAR=%.4f 显示比例=%.3f", _videoSar,
              (double)vs.width * _videoSar / MAX(vs.height, 1));
    }

    _audioStreamIndex = _demuxer->audioStream();
    _audioPacketDurationUs = 0;

    _subtitleStreamIndex = _previewMode ? -1 : _demuxer->subtitleStream();
    _preparedTrackSnapshot = [self buildTrackSnapshotsWithContext:ctx];

    [self foldResumeSeekIntoPrepare];

    [self freePreludePackets];
    _av1SeqCandidate.clear();
    _av1SeqCandidateW = _av1SeqCandidateH = 0;
    int preludeAudioPushed = 0;
    NSData *firstPacketSnapshot = nil;
    for (int i = 0; i < 128 && _preludeVideoPkts.empty(); i++) {
        AVPacket *pkt = av_packet_alloc();
        if (!pkt) break;
        int r = _demuxer->readPacket(pkt);
        if (r <= 0) { av_packet_free(&pkt); break; }

        const bool isolated = _demuxer->videoTrackIsolated();
        if (pkt->stream_index == _videoStreamIndex) {

            if (_reorderContainerSuspect && !_reorderProbePkt && pkt->size > 0) {
                firstPacketSnapshot = sp::packetDataSnapshot(pkt);
                _reorderProbePkt = firstPacketSnapshot;
            }
            _preludeVideoPkts.push_back(pkt);
        } else if (pkt->stream_index == _audioStreamIndex) {
            if (_audioPacketDurationUs <= 0 && pkt->duration > 0 && _audioStreamIndex < (int)_demuxer->streams().size()) {
                const AVRational tb = _demuxer->streams()[_audioStreamIndex].timeBase;
                if (tb.num > 0 && tb.den > 0) _audioPacketDurationUs = av_rescale_q(pkt->duration, tb, AVRational{1, 1000000});
            }
            if (preludeAudioPushed < 32) {

                preludeAudioPushed++;
                TaggedPacket tp = { pkt, 0 };
                if (!_audioPackets->push(std::move(tp))) av_packet_free(&tp.pkt);
            } else {

                _preludeAudioOverflow.push_back(pkt);
            }
        } else {
            av_packet_free(&pkt);
        }
        if (isolated) break;
    }

    if ((par->codec_id == AV_CODEC_ID_H264 || par->codec_id == AV_CODEC_ID_HEVC) && !_preludeVideoPkts.empty() &&
        _videoParCopy && _thumbVideoPar) {
        const AVPacket *kp = _preludeVideoPkts.front();
        const bool isH264 = par->codec_id == AV_CODEC_ID_H264;
        const bool suspect = isH264
            ? spresil::h264ConfigSuspect(par->extradata, par->extradata_size, kp->data, (size_t)kp->size)
            : spresil::hevcConfigSuspect(par->extradata, par->extradata_size, kp->data, (size_t)kp->size);
        if (suspect) {
            bool ok = false;
            spresil::BitstreamLayout layout;
            std::vector<uint8_t> extra;
            int vpsCount = 0, spsCount = 0, ppsCount = 0;
            if (isH264) {
                const spresil::H264ConfigBootstrap bs = spresil::bootstrapH264Config(kp->data, (size_t)kp->size, par->extradata, par->extradata_size);
                ok = bs.ok; layout = bs.layout; extra = bs.extradata; spsCount = bs.spsCount; ppsCount = bs.ppsCount;
            } else {
                const spresil::HevcConfigBootstrap bs = spresil::bootstrapHevcConfig(kp->data, (size_t)kp->size, par->extradata, par->extradata_size);
                ok = bs.ok; layout = bs.layout; extra = bs.extradata; vpsCount = bs.vpsCount; spsCount = bs.spsCount; ppsCount = bs.ppsCount;
            }
            if (ok && !_resilientDryRun.load(std::memory_order_relaxed)) {
                bool installed = true;
                for (AVCodecParameters *cp : {_videoParCopy, _thumbVideoPar}) {
                    uint8_t *nx = (uint8_t *)av_mallocz(extra.size() + AV_INPUT_BUFFER_PADDING_SIZE);
                    if (!nx) { installed = false; break; }
                    memcpy(nx, extra.data(), extra.size());
                    av_freep(&cp->extradata);
                    cp->extradata = nx;
                    cp->extradata_size = (int)extra.size();
                }
                if (installed) {
                    par = _videoParCopy;
                    _videoLayout = layout;
                    SP_RESLOG(
                        @"%@ 配置记录与样本矛盾：由首个关键帧包的带内参数重建（%@%d SPS / %d PPS，%@）",
                        isH264 ? @"H.264" : @"HEVC",
                        isH264 ? @"" : [NSString stringWithFormat:@"%d VPS / ", vpsCount], spsCount, ppsCount,
                        layout.kind == spresil::Bitstream::StartCode ? @"Annex-B"
                            : [NSString stringWithFormat:@"NAL 长度 %d 字节", layout.nalLengthSize]);
                }
            } else if (spDebug()) {
                SPLOG(@"[Resilient] %s 配置记录可疑但无法自举（无带内参数集或布局有歧义）%s", isH264 ? "H.264" : "HEVC",
                      ok ? "（干跑：不采纳）" : "");
            }
        }
    }

    if (par->codec_id == AV_CODEC_ID_AV1 && !_preludeVideoPkts.empty() && !_resilientDryRun.load(std::memory_order_relaxed)) {
        const AVPacket *kp = _preludeVideoPkts.front();
        spresil::Av1ObuSpan seqSpan;
        if (spresil::av1FindObu(kp->data, (size_t)kp->size, 1, seqSpan) && seqSpan.len <= 4096 &&
            !spAv1SeqHeaderParse(kp->data + seqSpan.start, seqSpan.len, nullptr, nullptr)) {
            const int64_t t0 = spNowUs();
            AVDictionary *o = nullptr;
            av_dict_set(&o, "scan_all_pmts", "0", 0);
            int scanned = 0, anyPkts = 0;

            sptrial::InterruptCtx ic;
            ic.abort = [&prepareSuperseded] { return prepareSuperseded(); };
            ic.deadlineUs = sptrial::monotonicNowUs() + 1500000;
            AVFormatContext *sc = sptrial::openInput(path.UTF8String, &ic, &o);
            if (sc) {
                AVPacket *sp = av_packet_alloc();
                while (sp && scanned < 96 && anyPkts < 4096 && _av1SeqCandidate.empty() && !ic.cancelled()) {
                    if (av_read_frame(sc, sp) < 0) break;
                    ++anyPkts;
                    if (sp->stream_index == _videoStreamIndex) {
                        ++scanned;
                        spresil::Av1ObuSpan s2;
                        int cw = 0, ch = 0;
                        if (spresil::av1FindObu(sp->data, (size_t)sp->size, 1, s2) && s2.len == seqSpan.len &&
                            spAv1SeqHeaderParse(sp->data + s2.start, s2.len, &cw, &ch)) {
                            _av1SeqCandidate.assign(sp->data + s2.start, sp->data + s2.start + s2.len);
                            _av1SeqCandidateW = cw;
                            _av1SeqCandidateH = ch;
                        }
                    }
                    av_packet_unref(sp);
                }
                av_packet_free(&sp);
                avformat_close_input(&sc);
            }
            av_dict_free(&o);
            if (!_av1SeqCandidate.empty()) {
                SP_RESLOG(@"AV1 首个 sequence header 载荷坏：前读 %d 包找到同长度的已验证副本（%.1fms），坏副本按包原位替换",
                                    scanned, (spNowUs() - t0) / 1000.0);
            } else if (spDebug()) {
                SPLOG(@"[Resilient] AV1 首个 sequence header 载荷坏，前读 %d 包未找到可用副本（%.1fms）", scanned, (spNowUs() - t0) / 1000.0);
            }
        }
    }

    dispatch_group_t grp = dispatch_group_create();
    dispatch_queue_t bg = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_semaphore_t rendererConfigGate = dispatch_semaphore_create(0);
    if (_renderer) {
        dispatch_group_enter(grp);
        [_renderer setColorimetryWithPrimaries:_preparedColorPrimaries
                                      transfer:_preparedColorTrc
                                    colorspace:_preparedColorSpace
                                         range:_preparedColorRange
                                      peakNits:_preparedPeakNits];
        [_renderer setSampleAspect:(float)_videoSar];
        [_renderer setDoviIPT:_preparedDoviIPT];
        [_renderer synchronizeOutputModeWithCompletion:^(BOOL ready) {
            // Completion is session-neutral at renderer level; bind publication
            // to this open explicitly.  Store-before-signal gives the racer an
            // acquire-visible proof that config and PSO are complete.
            if (ready && self->_openGeneration.load(std::memory_order_acquire) == openGen) {
                self->_rendererConfiguredOpenGeneration.store(
                    openGen, std::memory_order_release);
            }
            dispatch_semaphore_signal(rendererConfigGate);
            dispatch_group_leave(grp);
        }];
    } else {
        // Defensive no-Metal path: do not strand the group/racer.  The ready
        // generation stays invalid and startPipeline fails closed below.
        dispatch_semaphore_signal(rendererConfigGate);
    }

    const AVPixFmtDescriptor *pfdSW = av_pix_fmt_desc_get((AVPixelFormat)par->format);
    int h264Profile = par->codec_id == AV_CODEC_ID_H264 ? par->profile : -1;
    if (par->codec_id == AV_CODEC_ID_H264 && h264Profile < 0 && par->extradata &&
        par->extradata_size >= 4 && par->extradata[0] == 1) {
        h264Profile = par->extradata[1];
    }
    const bool rgbCoded = (pfdSW && (pfdSW->flags & AV_PIX_FMT_FLAG_RGB)) ||
                          par->color_space == AVCOL_SPC_RGB ||
                          h264Profile == AV_PROFILE_H264_HIGH_444_PREDICTIVE ||
                          h264Profile == AV_PROFILE_H264_CAVLC_444;
#if SP_APP_STORE
    const bool forceSW = _sessionForceSW || rgbCoded;
#else
    const bool forceSW = getenv("SP_FORCE_SW") != nullptr || _sessionForceSW || rgbCoded;
#endif
    int tbN = vs.timeBase.num, tbD = vs.timeBase.den;

    __block SPVideoDecoder *vt = nil;
    __block int vtRet = -1;

    NSData *firstPktHint = nil;
    if (!forceSW && par->codec_id == AV_CODEC_ID_HEVC && !_preludeVideoPkts.empty()) {
        if (!firstPacketSnapshot) {
            firstPacketSnapshot = sp::packetDataSnapshot(_preludeVideoPkts.front());
        }
        firstPktHint = firstPacketSnapshot;
    }
    if (prepareSuperseded()) { [self discardFailedPrepare]; return kSPPrepErrOpenCancelled; }
    if (!forceSW) {
        dispatch_group_async(grp, bg, ^{
            if (prepareSuperseded()) { vtRet = -1; return; }
            SPVideoDecoder *d = [[SPVideoDecoder alloc] init];
            d.spLogId = self->_spLogId;
            d.firstPacketHint = firstPktHint;
            int r = [d setupWithCodecParameters:par timeBaseNumerator:tbN timeBaseDenominator:tbD];
            d.firstPacketHint = nil;
            vtRet = r;
            if (r == 0) vt = d; else [d shutdown];
        });
    }

    _vtWarmKey = spVtWarmKey(par);
    bool vtWarm = false;
    bool vtDriverProven = false;
    {
        std::lock_guard<std::mutex> wl(sVtWarmMtx);
        vtWarm = sVtWarmKeys.count(_vtWarmKey) > 0;
    }

    vtDriverProven = SPVideoToolboxDriverLoaded();
    bool resuming = _preludeStartSeconds > 0.5;

    const bool hopelessRace =
        vtDriverProven && !forceSW &&
        (int64_t)par->width * (int64_t)par->height >= 3840LL * 2160 &&
        spCodecParDepth(par) >= 10;
#if SP_APP_STORE
    if (!forceSW && !_preludeVideoPkts.empty() &&
#else
    if (!forceSW && !getenv("SP_NO_FFRACE") && !_preludeVideoPkts.empty() &&
#endif
        !vtWarm && !resuming && !hopelessRace) {
        AVPacket *kfPkt = av_packet_clone(_preludeVideoPkts.front());

        AVCodecParameters *racePar = avcodec_parameters_alloc();
        if (racePar && avcodec_parameters_copy(racePar, par) < 0) {
            avcodec_parameters_free(&racePar);
        }

        int64_t raceT0 = spNowUs();

        dispatch_async(bg, ^{
            if (prepareSuperseded() || !racePar) {
                AVPacket *tmp = kfPkt;
                av_packet_free(&tmp);
                AVCodecParameters *tmpPar = racePar;
                if (tmpPar) avcodec_parameters_free(&tmpPar);
                return;
            }
            SPFFmpegDecoder *sw = [[SPFFmpegDecoder alloc] init];
            sw.spLogId = self->_spLogId;
            sw.singleFrameMode = YES;
            sw.rgbSourceMatrix = self->_preparedColorSpace;
            SPDecodedVideoOutput raceOutput = SPDecodedVideoOutputEmpty();
            if ([sw setupWithCodecParameters:racePar timeBaseNumerator:tbN timeBaseDenominator:tbD] == 0) {
                raceOutput = [sw decodePacketOutput:kfPkt];
                if (!raceOutput.pixelBuffer) {

                    raceOutput = [sw decodePacketOutput:NULL];
                }
            }
            AVPacket *tmp = kfPkt;
            av_packet_free(&tmp);
            AVCodecParameters *tmpPar = racePar;
            avcodec_parameters_free(&tmpPar);
            CVPixelBufferRef b = raceOutput.pixelBuffer;
            if (b) {
                // Hold the decoded candidate, not the renderer: output-mode
                // publication normally overlaps this decode.  The semaphore is
                // always signalled (including cancellation/no renderer), and
                // ensures the race never submits against the previous session.
                dispatch_semaphore_wait(rendererConfigGate, DISPATCH_TIME_FOREVER);

                if (self->_openGeneration.load(std::memory_order_acquire) == openGen &&
                    self->_rendererConfiguredOpenGeneration.load(
                        std::memory_order_acquire) == openGen &&
                    !self->_speculativeFirstFrameRevoked.load(std::memory_order_acquire) &&
                    self->_renderer.isReady) {
                    std::lock_guard<std::mutex> rlock(self->_renderMtx);

                    const BOOL revoked =
                        self->_speculativeFirstFrameRevoked.load(std::memory_order_acquire);
                    if (self->_openGeneration.load(std::memory_order_acquire) != openGen ||
                        self->_rendererConfiguredOpenGeneration.load(
                            std::memory_order_acquire) != openGen || revoked) {
                        if (spDebug() && revoked) {
                            SPLOG(@"[Core] 软解竞速首帧作废（seek 已撤销资格）: %.1fms",
                                  (spNowUs() - raceT0) / 1000.0);
                        }
                        CVPixelBufferRelease(b);
                        [sw shutdown];
                        return;
                    }

                    const BOOL took = [self->_renderer renderSpeculativeFirstFrame:b];
                    if (spDebug()) {
                        if (took) {
                            SPLOG(@"[Core] 软解竞速首帧上屏: %.1fms (竞速起点), %lldms (从app启动)",
                                  (spNowUs() - raceT0) / 1000.0, (spNowUs() - self->_appLaunchUs) / 1000);
                        } else {
                            SPLOG(@"[Core] 软解竞速首帧作废（正式帧已先受理）: %.1fms",
                                  (spNowUs() - raceT0) / 1000.0);
                        }
                    }
                } else if (spDebug() &&
                           self->_speculativeFirstFrameRevoked.load(std::memory_order_acquire) &&
                           self->_openGeneration.load(std::memory_order_acquire) == openGen) {
                    SPLOG(@"[Core] 软解竞速首帧作废（seek 已撤销资格）: %.1fms",
                          (spNowUs() - raceT0) / 1000.0);
                }
                CVPixelBufferRelease(b);
            }
            [sw shutdown];
        });
    }

    _audioFallbackTrackApplied = NO;
    dispatch_group_async(grp, bg, ^{
        if (prepareSuperseded()) return;
        [self prepareSubtitleWithContext:ctx];
        [self prepareAudioWithContext:ctx];
    });

    dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);

    if (_audioFallbackTrackApplied && !prepareSuperseded()) _preparedTrackSnapshot = [self buildTrackSnapshotsWithContext:ctx];
    if (prepareSuperseded()) {

        if (vt) [vt shutdown];
        [self discardFailedPrepare];
        return kSPPrepErrOpenCancelled;
    }

    int dret = vtRet;
    if (vt) {
        _decoder = vt;

    }
    if (!_decoder) {
        SPFFmpegDecoder *sw = [[SPFFmpegDecoder alloc] init];
        sw.spLogId = _spLogId;
        sw.previewMode = _previewMode;
        sw.planarOutputEnabled = spPlanarOutputEnabled();
        sw.rgbSourceMatrix = _preparedColorSpace;
        dret = [sw setupWithCodecParameters:par
                          timeBaseNumerator:vs.timeBase.num
                        timeBaseDenominator:vs.timeBase.den];
        if (dret == 0) {
            _decoder = sw;
        }
    }
    if (spDebug()) {
        SPLOG(@"[Core] 打开: codec=%s %dx%d fps=%.3f 容器=%s 色彩(pri=%d trc=%d)",
              vs.codecName.c_str(), vs.width, vs.height, vs.fps,
              _demuxer->containerName().c_str(), vs.colorPrimaries, vs.colorTrc);
        SPLOG(@"[Core] 解码器=%@ setup ret=%d hw=%d",
              _decoder ? _decoder.decoderName : @"无", dret,
              _decoder ? _decoder.isHardwareDecoding : 0);
    }

    if (dret != 0) {

        const int altVideo = _demuxer->alternateVideoStream(_videoStreamIndex);
        if (altVideo >= 0 && !prepareSuperseded()) {
            SPLOG(@"[Resilient] 视频解码器建不出来（ret=%d 流#%d codec=%s）而文件另有视频轨 流#%d → 排除本轨重开",
                  dret, _videoStreamIndex, vs.codecName.c_str(), altVideo);
            _prepRetryExcludedVideo = std::set<int>(_prepExcludedVideo.begin(), _prepExcludedVideo.end());
            _prepRetryExcludedVideo.insert(_videoStreamIndex);
            _prepRetryStartSec = _preludeStartSeconds;
            [self discardFailedPrepare];
            return kSPPrepErrRetryAltVideo;
        }

        if (_demuxer->audioStream() >= 0 && _audioActive && !_videoIsAttachedPic) {
            SPLOG(@"[Resilient] 视频解码器建不出来（ret=%d codec=%s）而音轨可解 → 视频轨标不可用，以纯音频会话继续",
                  dret, vs.codecName.c_str());
            [self releasePreparedDecodeState];
            _audioDecoder = nil;
            _audioActive = NO;
            _demuxer->seekToUs(0);
            const int aret = [self prepareAudioOnlySessionWithGeneration:openGen];
            if (aret == 0) {
                _videoTrackGivenUp = YES;
                [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::None
                              confidence:spresil::Confidence::DecodeVerified
                                  fromUs:0 untilUs:(int64_t)(MAX(_duration, 0.5) * 1e6)];
                SP_RESLOG(@"视频轨（%s）解码器建不出来，音轨完好：只播放音频", vs.codecName.c_str());
            }
            return aret;
        }
        [self discardFailedPrepare];
        return kSPPrepErrDecoderCreate;
    }

    _preparedDecoderName = _decoder.decoderName;
    if (spDebug()) {
        SPLOG(@"[Media] codec=%s bits=%d pri=%d trc=%d range=%d maxCll=%d dovi=%d prof=%d",
              vs.codecName.c_str(), vs.colorBits, vs.colorPrimaries, vs.colorTrc,
              vs.colorRange, vs.maxCll, (int)vs.isDovi, vs.doviProfile);
    }

    if (![self startPipelineFromPrepareWithGeneration:openGen audioOnly:NO]) {

        [self discardFailedPrepare];
        [_subtitleRenderer resetTrack];
        _renderer.subtitleTexture = nil;
        _subtitleActive = NO;
        _subtitleIsSRT = NO;
        _subtitleIsMovText = NO;
        _subtitleIsVTT = NO;
        _audioActive = NO;
        return kSPPrepErrOpenCancelled;
    }
    return 0;
}

// Prepare an audio-only session when no video track exists. Skip all video setup
// (decoder, prelude race, and color state) while keeping the audio and demux
// pipeline unchanged. This function is reachable only from the no-video branch
// and must not touch the video first-frame path.
- (int)prepareAudioOnlySessionWithGeneration:(int64_t)openGen {
    AVFormatContext *ctx = _demuxer->ctx();
    _videoStreamIndex = -1;
    _audioStreamIndex = _demuxer->audioStream();
    _hasAudio = (_audioStreamIndex >= 0);

    _subtitleStreamIndex = -1;
    _videoFps = 0;
    _videoWidth = 0;
    _videoHeight = 0;
    _videoRotation = 0;
    if (_videoParCopy) avcodec_parameters_free(&_videoParCopy);
    if (_thumbVideoPar) avcodec_parameters_free(&_thumbVideoPar);

    _audioFallbackTrackApplied = NO;
    [self prepareAudioWithContext:ctx];
    if (!_audioActive) { [self discardFailedPrepare]; return kSPPrepErrDecoderCreate; }
    _preparedTrackSnapshot = [self buildTrackSnapshotsWithContext:ctx];

    {
        const StreamInfo &as = _demuxer->streams()[_audioStreamIndex];
        _duration = (_demuxer->durationUs() > 0 ? _demuxer->durationUs()
                                                : as.durationUs) / 1e6;
        _timelineOriginUs = _demuxer->timelineOriginUs();
    }
    [self foldResumeSeekIntoPrepare];

    {
        int64_t originUs = MAX((int64_t)0,
                               _demuxer->streams()[_audioStreamIndex].startTimeUs);
        double startSec = _preludeStartSeconds;
        _audioNextPtsUs = (_preludeSeekDone && startSec > 0.5)
                              ? (int64_t)(startSec * 1e6) : originUs;
        _coverageOpenStartUs = _audioNextPtsUs;
    }
    if (spDebug()) SPLOG(@"[Core] 纯音频会话: codec=%s 容器=%s",
                         _demuxer->streams()[_audioStreamIndex].codecName.c_str(),
                         _demuxer->containerName().c_str());
    if (![self startPipelineFromPrepareWithGeneration:openGen audioOnly:YES]) {
        [self discardFailedPrepare];
        _audioActive = NO;
        return kSPPrepErrOpenCancelled;
    }
    return 0;
}

- (void)freePreludePackets {
    for (auto *p : _preludeVideoPkts) { AVPacket *tmp = p; av_packet_free(&tmp); }
    _preludeVideoPkts.clear();
    for (auto *p : _preludeAudioOverflow) { AVPacket *tmp = p; av_packet_free(&tmp); }
    _preludeAudioOverflow.clear();
}

- (void)releasePreparedDecodeState {
    [self freePreludePackets];
    if (_videoParCopy) avcodec_parameters_free(&_videoParCopy);
    if (_thumbVideoPar) avcodec_parameters_free(&_thumbVideoPar);
    [_decoder shutdown];
    _decoder = nil;
    if (_audioDecoder) [_audioDecoder shutdown];

    _audioPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
    _videoPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
}

- (void)discardFailedPrepare {
    [self releasePreparedDecodeState];
    _demuxer->close();
}

- (BOOL)startPipelineFromPrepareWithGeneration:(int64_t)openGen audioOnly:(BOOL)audioOnly {
    std::lock_guard<std::mutex> lock(_lifecycleMtx);
    if (openGen != _openGeneration) return NO;

    _audioOnlySession.store(audioOnly);
    // Video threads are allowed to prefill before finish/main enters Playing,
    // but never before this open generation's complete renderer configuration
    // is published.  This is the hard backstop for every formal first-frame
    // path; pure-audio sessions deliberately have no renderer configuration.
    if (!_audioOnlySession.load() &&
        _rendererConfiguredOpenGeneration.load(std::memory_order_acquire) != openGen) {
        SPLOG(@"[Core] renderer 配置发布失败/过期，拒绝启动视频管线 gen=%lld", openGen);
        return NO;
    }

    {
        size_t cap = spVideoFrameQueueCapacity(_videoWidth, _videoHeight, _videoFps, 1.0);
        const size_t fb = (size_t)MAX(_videoWidth, 1) * (size_t)MAX(_videoHeight, 1) * 3;
        cap = spFrameQueueClaim(cap, fb, spVideoFrameQueueFloor(_videoFps, 1.0),
                                &_framesQueueClaimBytes, _spLogId);
        if (_frames->capacity() != cap) {
            _frames = std::make_unique<BoundedQueue<DecodedFrame>>(cap);
            if (spDebug()) SPLOG(@"[Core] 帧队列容量=%zu (按 %dx%d 自适应)", cap, _videoWidth, _videoHeight);
        }
        if (auto motionFrames = _motionFramesPublished.exchange(nullptr)) {
            motionFrames->drain([](DecodedFrame f) {
                if (f.buffer) CVPixelBufferRelease(f.buffer);
            });
            spFrameQueueRelease(&_motionQueueClaimBytes);
        }
    }
    {

        const bool remoteVol = _demuxer->onRemoteVolume();
        const int64_t pktBudget = remoteVol ? 128ll * 1024 * 1024
                                            : 32ll * 1024 * 1024;
        const size_t pktCapMax = remoteVol ? 192 : 48;
        size_t pktCap = 48;
        if (_videoStreamIndex >= 0) {
            const StreamInfo &vsq = _demuxer->streams()[_videoStreamIndex];
            double fpsq = _videoFps > 0 ? _videoFps : 30.0;
            int64_t bytesPerPkt = (vsq.bitRate > 0) ? (int64_t)(vsq.bitRate / 8.0 / fpsq) : 0;
            if (bytesPerPkt <= 0) {

                const int64_t durUs = _demuxer->durationUs();
                if (durUs > 0 && _demuxer->fileSizeBytes() > 0) {
                    bytesPerPkt = (int64_t)((double)_demuxer->fileSizeBytes() /
                                            (durUs / 1e6) * 0.85 / fpsq);
                }
            }
            if (bytesPerPkt > 0) {
                pktCap = (size_t)(pktBudget / bytesPerPkt);

                pktCap = MAX((size_t)2, MIN(pktCap, pktCapMax));
            } else if (remoteVol) {
                pktCap = 96;
            }
        }
        if (_videoPackets->capacity() != pktCap) {
            _videoPackets = std::make_unique<BoundedQueue<TaggedPacket>>(pktCap);
            if (spDebug()) SPLOG(@"[Core] 包队列容量=%zu (按码率自适应%s)", pktCap,
                                 remoteVol ? "，远程卷加深" : "");
        }

        {
            size_t audioCap = kSPAudioPacketQueueCapacity;
            int64_t durUs = _audioPacketDurationUs;
            if (durUs <= 0 && _audioStreamIndex >= 0 && _audioStreamIndex < (int)_demuxer->streams().size()) {
                const std::string &cn = _demuxer->streams()[_audioStreamIndex].codecName;
                if (cn == "truehd" || cn == "mlp") durUs = 833;
            }
            if (durUs > 0) {
                const double pps = 1e6 / (double)durUs;
                audioCap = (size_t)MIN(16384.0, MAX((double)kSPAudioPacketQueueCapacity, ceil(pps * 8.0)));
            }
            if (_audioPackets->capacity() != audioCap) {
                _audioPackets->setCapacity(audioCap);
                if (spDebug()) SPLOG(@"[Core] 音频包队列容量=%zu (包时长 %lldus → 8s 跑道)", audioCap, (long long)durUs);
            }
        }
    }

    _firstFramePending = true;
    _lastPosNotify = 0;
    _pacePrevCommitWallUs = 0;
    _paceCommitGapMaxUs = 0;
    _pacePrevCommitPTSUs = AV_NOPTS_VALUE;
    _pacePrevCommitSynthetic = NO;
    _seekDisplayTargetUs.clear();
    _seekFramePending.store(false);
    _needsOutputModeRedraw.store(false);
    _catchUpTargetUs.clear();
    _audioTrimTargetUs.clear();

    _audioLandingTrimUs.clearForNewSession();
    _seekLandingKeyUs.clearForNewSession();
    _frameStepAheadUs = 0;

    _seekDemuxDoneGen.store(0);
    _seekSettleGen.store(0);
    _seekSettleRetryGen.store(-1);
    _seekPending.store(false);
    _audioFlushPending.store(false);
    _seekBoostDecode.store(false);
    _decErrStreak.store(0);
    _rebuildFailFp = 0;
    _rebuildFailAtUs = 0;

    [self resilientResetForNewSession];
    _vtWarmMarked = NO;
    _sessionEverPresented.store(false);
    [self resetPresentedFrameRate];
    _lastSubmittedVideoGeneration.store(-1);
    _openCommittedBase = _renderer.committedFrameCount;
    _openHardFailBase = _renderer.hardRenderFailureCount;
    _presentRetryPending = NO;
    _presentRetryCompletesPausedSeek = NO;
    _lastFrameGeneration = -1;
    _lastFrameSynthetic = NO;
    _lastFrameInterpolationEpoch = 0;
    _approxMediaNowUs.store(0);
    _audioResyncToNow.store(false);
    _timelineEpochOffsetUs.store(0);
    _timelineEpochGen.store(-1);
    _epochOffsetVideoUs.store(0);
    _epochOffsetAudioUs.store(0);
    _epochDurationAppliedUs = 0;
    _av1SeqReplaced = 0;
    _av1SeqTrials = 0;
    _av1SeqMemo.clear();
    _jpegLengthFixes = 0;
    _vp9MarkerFixes = 0;
    _startCodePrefixFixes = 0;
    _vpSyncFixes = 0;
    _jpegCountFixes = 0;
    _proresGeomFixes = 0;
    _proresGeomDropped = 0;
    _interpolationResetRequested.store(true);
    _interpolationPolicyEpoch.fetch_add(1);
    {

        sp::SPFrameGeneratorMediaInfo info;
        info.videoFps = _videoFps;
        info.frameIntervalUs = _frameIntervalUs;
        info.videoWidth = _videoWidth;
        info.videoHeight = _videoHeight;
        info.dynamicHDRUnsafe = _interpolationDynamicHDRUnsafe;
        info.interlaced = _interpolationInterlaced;
        [_generator resetForNewMediaWithInfo:info];
    }
    _interpolationPolicyStatusCode.store(-1);
#if DEBUG && !SP_APP_STORE
#endif
    _frameInterpolationActiveValue.store(false);
    _frameInterpolationCommittedModeValue.store(SPFrameInterpolationModeOff);
    {
        std::lock_guard<std::mutex> statusLock(_interpolationStatusMtx);
        _frameInterpolationStatusValue = _frameInterpolationModeValue.load() == SPFrameInterpolationModeDoubleRate
            ? NSLocalizedString(@"memc.status.waitingCompatibleFrames", nil) : NSLocalizedString(@"memc.status.off", nil);
    }
    _generation.store(0);
    _seekBurstBaseGen.store(0);

    _audioRingStartGen.store(-1);
    _audioRingStartPtsUs.store(-1);
    _coarseAnchorPendingGen = -1;
    _seekSettleGen.store(0);
    _seekFlashDone.store(true);
    _flushPending.store(false);
    _seekMailbox.invalidate();
    _seekMailbox.resetForNewSession();
    _forwardSeekFloorUs = -1;

    _eofDrainedGen.store(-1);
    _audioEofDrainedGen.store(-1);
    _audioClockHandedOff = NO;
    _audioStarveSince = 0;
    _exhaustedSince = 0;
    _rebufferHold = NO;
    _rebufferExitPackets = kSPRebufferExitPacketsBase;
    _lastDoSeekWallUs = 0;
    _prevSeekUnsettled = NO;
    _rebufferLastExitWallUs = 0;

    double startSec = _preludeStartSeconds;
    _activeStartSeconds = 0;

    {
        int64_t originUs = 0;
        if (_videoStreamIndex >= 0) {
            originUs = MAX((int64_t)0, _demuxer->streams()[_videoStreamIndex].startTimeUs);
        }
        _audioNextPtsUs = (startSec > 0.5 && _duration > 0 && startSec < _duration - 1.0)
                              ? (int64_t)(startSec * 1e6) : originUs;

        _coverageOpenStartUs = _audioNextPtsUs;
    }
    if (startSec > 0.5 && _duration > 0 && startSec < _duration - 1.0) {
        _activeStartSeconds = startSec;
        int64_t sUs = (int64_t)(startSec * 1e6);

        NSCAssert(_preludeSeekDone, @"续播点非零但 prepare 未完成 seek");
        int64_t durUs = (int64_t)(_duration * 1e6);
        int64_t dispTarget = sUs;
        if (dispTarget > durUs - 2 * _frameIntervalUs) {
            dispTarget = MAX((int64_t)0, durUs - 2 * _frameIntervalUs);
        }
        _seekDisplayTargetUs.set(dispTarget);
        _catchUpTargetUs.set(dispTarget);
        _audioTrimTargetUs.set(dispTarget);
        _seekReqWallUs.store(spNowUs());
        if (spDebug()) SPLOG(@"[Core] 续播起点 %.2fs（折叠进打开流程）", startSec);
    }

    for (AVPacket *p : _preludeVideoPkts) {
        TaggedPacket tp = { p, 0 };
        if (!_videoPackets->push(std::move(tp))) av_packet_free(&tp.pkt);
    }
    _preludeVideoPkts.clear();

    _paused = false;
    _running = true;

    if (_audioActive && _audioOutput) {
        [_audioOutput reset];
        _audioRateSwitchFrames = -1;
        _audioRateSwitchPending = NO;
        _audioThread = std::thread([self] { [self audioLoop]; });
    }

    _demuxer->releaseRetiredContexts();
    _demuxThread = std::thread([self, openGen] {
        [self demuxLoopForOpenGeneration:openGen];
    });
    if (!_audioOnlySession.load()) {
        _decodeThread = std::thread([self] { [self decodeLoop]; });
    }
    if (spDebug()) SPLOG(@"[Core] 管线已启动(后台): %lldms (从app启动)", (spNowUs() - _appLaunchUs) / 1000);
    return YES;
}

- (void)prepareSubtitleWithContext:(AVFormatContext *)ctx {
    _subtitleActive = NO;
    if (_subtitleStreamIndex >= 0) {
        AVCodecParameters *spar = ctx->streams[_subtitleStreamIndex]->codecpar;
        _subtitleIsSRT = (spar->codec_id == AV_CODEC_ID_SUBRIP);
        _subtitleIsMovText = (spar->codec_id == AV_CODEC_ID_MOV_TEXT);
        _subtitleIsVTT = (spar->codec_id == AV_CODEC_ID_WEBVTT);
        _subtitleTimeBase = ctx->streams[_subtitleStreamIndex]->time_base;
        _subReadOrder = 0;

        std::unordered_set<uint64_t>().swap(_subSeenEvents);
        _subCueBytes = 0;
        _subCueCount = 0;
        _subCapExceeded = NO;

        if ((spar->codec_id == AV_CODEC_ID_ASS || spar->codec_id == AV_CODEC_ID_SSA) &&
            spar->extradata && spar->extradata_size > 0) {
            [_subtitleRenderer setCodecPrivate:[NSData dataWithBytes:spar->extradata
                                                              length:spar->extradata_size]];
        }
        _subtitleActive = YES;
        if (spDebug()) {
            SPLOG(@"[Core] 字幕轨: %@", _subtitleIsSRT ? @"SRT"
                  : (_subtitleIsMovText ? @"mov_text"
                  : (_subtitleIsVTT ? @"WebVTT" : @"ASS(流式)")));
        }
    } else if (spDebug()) {
        SPLOG(@"[Core] 字幕轨: 无");
    }
}

- (SPAudioOutput *)ensureAudioOutput {
    SPAudioOutput *ao = nil;
    bool isCreator = false;
    {
        std::lock_guard<std::mutex> lock(_audioOutMtx);
        if (!_audioOutput) {
            _audioOutput = [[SPAudioOutput alloc] init];
            __weak SPPlayerCore *weakSelf = self;
            _audioOutput.outputLayoutChangeHandler = ^{ [weakSelf handleAudioOutputLayoutChange]; };
            isCreator = true;
        }
        ao = _audioOutput;
    }
    if (isCreator && ![ao setup]) {
        [ao markSetupFailed];
    }
    return ao;
}

- (void)prepareAudioWithContext:(AVFormatContext *)ctx {
    _audioActive = NO;

    _flacTailProofWanted = NO;
    _flacDeclaredTotal = 0;
    _flacMd5UnneededGen.store(-1, std::memory_order_relaxed);
    if (_audioStreamIndex >= 0) {

        SPAudioOutput *ao = [self ensureAudioOutput];
        std::vector<int> cands;
        cands.push_back(_audioStreamIndex);
        for (int pass = 0; pass < 2; ++pass) {
            for (unsigned i = 0; i < ctx->nb_streams; ++i) {
                AVStream *s = ctx->streams[i];
                if ((int)i == _audioStreamIndex || s->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
                if (!avcodec_find_decoder(s->codecpar->codec_id)) continue;
                const bool def = (s->disposition & AV_DISPOSITION_DEFAULT) != 0;
                if ((pass == 0) != def) continue;
                cands.push_back((int)i);
            }
        }
        const int selected = _audioStreamIndex;
        for (size_t k = 0; k < cands.size(); ++k) {
            const int idx = cands[k];
            AVCodecParameters *apar = ctx->streams[idx]->codecpar;
            SPAudioDecoder *ad = [[SPAudioDecoder alloc] init];
            ad.spLogId = _spLogId;
            ad.nativeMd5Enabled = spFlacNativeMd5Wanted(apar, nullptr);
            int sret = [ad setupWithCodecParameters:apar outputChannelMask:(ao ? [ao outputChannelMask] : 0)];
            if (sret != 0 && apar->codec_id == AV_CODEC_ID_FLAC && [self repairFlacStreamInfoInPlace:apar streamIndex:idx]) {

                sret = [ad setupWithCodecParameters:apar outputChannelMask:(ao ? [ao outputChannelMask] : 0)];
            }
            if (sret != 0) {
                if (k == 0 && cands.size() > 1) {
                    SPLOG(@"[Resilient] 所选音轨 流#%d 解码器 setup 失败 → 依次试文件里其余 %zu 条音轨", idx, cands.size() - 1);
                }
                continue;
            }
            if (idx != selected) {
                _audioPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
                _audioStreamIndex = idx;
                _audioPacketDurationUs = 0;
                _audioFallbackTrackApplied = YES;
                SPLOG(@"[Resilient] 音轨 流#%d 不可解，改用文件里完整的 流#%d（%s）", selected, idx,
                      avcodec_get_name(apar->codec_id));
                SP_RESLOG(@"所选音轨（流#%d）解码器建不出来，改用文件里另一条可解音轨（流#%d）", selected, idx);
            }
            _audioDecoder = ad;
            _audioTimeBase = ctx->streams[idx]->time_base;
            {

                spresil::FlacStreamInfo fi;
                if (ad.nativeMd5Enabled && spFlacNativeMd5Wanted(apar, &fi) && fi.totalSamples != 0 && _demuxer->containerName() == "flac") {
                    std::memcpy(_flacStreamInfo, apar->extradata, sizeof _flacStreamInfo);
                    _flacDeclaredTotal = fi.totalSamples;
                    _flacTailProofWanted = YES;
                }
            }
            if (ao) {

                [ao setVolume:(_muted ? 0.0f : (float)_volume)];
                _audioActive = YES;
            }
            break;
        }
        if (spDebug()) {
            SPLOG(@"[Core] 音频: %@（输出布局 %@）", _audioActive ? @"已启用" : @"降级为静音",
                  ao ? [ao outputLayoutDescription] : @"-");
        }
#if SP_INTERNAL_BUILD && !SP_APP_STORE
        // Internal automation can exercise both ordinary and boosted gain.
        const char *autovol = getenv("SP_AUTOVOLUME");
        if (autovol && _audioActive) {
            [self setVolume:(float)atof(autovol)];
            if (spDebug()) SPLOG(@"[Core] Automated volume=%.2f", _volume);
        }
#endif
    }
}

- (void)finishMediaOpenWithPrepError:(int)prepErr path:(NSString *)path {
    if (prepErr == kSPPrepErrRetryAltVideo) {

        _pendingExcludedVideo = _prepRetryExcludedVideo;
        _pendingExcludedVideoPath = [path copy];
        _pendingExcludedVideoStartSec = _prepRetryStartSec;
        SPLOG(@"[Resilient] 备用视频轨：重开 %@（起点 %.2fs，排除 %zu 条）", path.lastPathComponent, _pendingExcludedVideoStartSec,
              _pendingExcludedVideo.size());
        [self openMediaAtURL:[NSURL fileURLWithPath:path] startAt:_pendingExcludedVideoStartSec error:nil];
        return;
    }
    if (prepErr != 0) {
        NSString *desc;

        NSString *diagnosis = @"openFailed";
        if (prepErr == kSPPrepErrNoVideoStream)      { desc = NSLocalizedString(@"error.noPlayableTrack", nil); diagnosis = @"noPlayableTrack"; }
        else if (prepErr == kSPPrepErrDecoderCreate) { desc = NSLocalizedString(@"error.decoderCreateFailed", nil); diagnosis = @"decoderCreate"; }
        else {

            switch ((spresil::OpenFailureHint)_openFailureHint.load()) {
            case spresil::OpenFailureHint::IndexAtTailNotDownloaded:
                desc = NSLocalizedString(@"error.openFailed.indexAtTail", nil);

                diagnosis = _indexWaitPrepState ? @"indexAtTailDownloading" : @"indexAtTail";
                break;
            case spresil::OpenFailureHint::MissingMetadataIncomplete:
                desc = NSLocalizedString(@"error.openFailed.missingMetadata", nil); diagnosis = @"missingMetadata"; break;
            case spresil::OpenFailureHint::LeadingZeros:
                desc = NSLocalizedString(@"error.openFailed.zeroHead", nil); diagnosis = @"zeroHead"; break;
            case spresil::OpenFailureHint::None:
                desc = NSLocalizedString(@"error.openFailed", nil); break;
            }
        }

        SPLOG(@"[Core] 打开失败 err=%d（%@）path=%@", prepErr, desc, path.lastPathComponent);
        if ([_delegate respondsToSelector:@selector(playerCore:didFailWithError:)]) {
            NSError *err = [self makeErrorWithDomain:@"SPDemuxerError" code:prepErr description:desc
                                               phase:@"open" diagnosis:diagnosis terminal:YES];
            [_delegate playerCore:self didFailWithError:err];
        }
        [self setState:SPPlayerStateFailed];
        if (_indexWaitPrepState) [self startIndexWaitForPath:path state:_indexWaitPrepState];
        _indexWaitPrepState.reset();
        return;
    }

    // This method is entered only from the main-queue block after its
    // openGeneration check. Publish the immutable prepare result here; the
    // public arrays/current indices are never written by the open queue.
    SPPreparedTrackSnapshot *tracks = _preparedTrackSnapshot;
    _audioTrackList = tracks.audioTracks ?: @[];
    _subtitleTrackList = tracks.subtitleTracks ?: @[];
    _currentAudioTrackPub.store(tracks ? tracks.initialAudioTrackIndex : -1);
    _currentSubtitleTrackPub = tracks ? tracks.initialSubtitleTrackIndex : -1;
    _decoderNamePub = _preparedDecoderName;

    // Video renderer configuration was published in prepare's parallel group,
    // before startPipeline was allowed to launch decode.  Reapplying it here
    // would reopen an async output-mode window after frames are already queued.
#if DEBUG
    if (!_audioOnlySession.load()) {
        NSCAssert(_rendererConfiguredOpenGeneration.load(std::memory_order_acquire) ==
                      _openGeneration.load(std::memory_order_acquire),
                  @"video pipeline reached finish before renderer publication");
    }
#endif

    [self applyDisplayLinkRate];

    _mediaInfoSnapshot = [self buildMediaInfoSnapshot];

    double startSec = _activeStartSeconds;
    _activeStartSeconds = 0;
    [self beginPlaybackPrimedAtSec:startSec attempt:0];
#if !SP_APP_STORE
    [self installAutomationHooksForOpenedPath:path];
#endif
    [self scheduleTimelineThumbnails];
}

- (void)beginPlaybackPrimedAtSec:(double)startSec attempt:(int)attempt {

    const size_t primeTarget = MIN((size_t)24, _videoPackets->capacity() * 3 / 4);
    if (!_audioOnlySession.load() &&
        _demuxer->onRemoteVolume() && attempt < 14 && !_demuxer->eof() &&
        _videoPackets->size() < MAX(primeTarget, (size_t)1)) {
        const int64_t gen = _openGeneration.load();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (self->_openGeneration.load() != gen) return;
            [self beginPlaybackPrimedAtSec:startSec attempt:attempt + 1];
        });
        return;
    }
    int64_t startUs = (int64_t)(startSec * 1e6);

    if (_generation.load() == 0) {
        _mediaClockPtsUs = startUs;
        _mediaClockWallUs = spNowUs();
        _lastPresentedPtsUs = startUs;
        _position = startSec;
        if (_audioActive && _audioOutput) {
            _audioClockBaseUs = startUs;
            _audioBasePlayedFrames = _audioOutput.clockFrames;
        }
    }
    if (_audioActive && _audioOutput) [_audioOutput start];
    [self setState:SPPlayerStatePlaying];
    if (_audioOnlySession.load()) {

        [_audioOnlyTimer invalidate];
        _audioOnlyTimer = [NSTimer timerWithTimeInterval:0.25
                                                  target:self
                                                selector:@selector(audioOnlyTimerTick)
                                                userInfo:nil
                                                 repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:_audioOnlyTimer forMode:NSRunLoopCommonModes];
    } else if (_displayLink) {
        _displayLink.paused = NO;
    }
    if (spDebug()) {
        SPLOG(@"[Core] 打开完成，进入播放%s",
              attempt > 0 ? [NSString stringWithFormat:@"（预卷 %dms）",
                             attempt * 50].UTF8String : "");
    }
}

#if !SP_APP_STORE
- (void)installAutomationHooksForOpenedPath:(NSString *)path {

    if (spAutomation() && getenv("SP_XDR")) {
        [self setXdrEnabled:atoi(getenv("SP_XDR")) != 0];
    }

    if (spAutomation() && getenv("SP_TEST_CROP")) [self setCropAspect:atof(getenv("SP_TEST_CROP"))];
    if (spAutomation() && getenv("SP_TEST_ASPECT")) [self setForcedAspect:atof(getenv("SP_TEST_ASPECT"))];

    if (spAutomation() && getenv("SP_PICTEST")) {
        [self setAspectMode:4];
        [self setRotation:90];
        [self setMirror:1];
        [self setBrightness:0.1];
        [self setSaturation:1.2];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (spDebug()) SPLOG(@"[Test] 媒体信息: %@", [self mediaInfo]);
            [self captureScreenshotToPath:@"/tmp/sp_shot.png" completion:^(BOOL ok) {
                if (spDebug()) SPLOG(@"[Test] 截图: %@", ok ? @"成功" : @"失败");
            }];
        });
    }

    if (spAutomation() && getenv("SP_SUBTITLE_FILE")) {
        BOOL loaded = [self loadSubtitleFile:[NSString stringWithUTF8String:getenv("SP_SUBTITLE_FILE")]];
        if (spDebug() && loaded) SPLOG(@"[Core] 已加载外挂字幕: %s", getenv("SP_SUBTITLE_FILE"));
    }

    if (spAutomation() && getenv("SP_TRACKTEST")) {
        __weak SPPlayerCore *wself = self;
        auto after = ^(double sec, dispatch_block_t blk) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), blk);
        };
        after(1.5, ^{
            SPPlayerCore *s = wself; if (!s) return;
            NSLog(@"[c%u][TrackTest] 音轨=%@", s->_spLogId, s.audioTrackList);
            NSLog(@"[c%u][TrackTest] 字幕轨=%@ HDR=%@\n[TrackTest] HDR详情=%@",
                  s->_spLogId, s.subtitleTrackList, s.hdrDescription, s.hdrDetailDescription);
        });
        after(2.5, ^{
            SPPlayerCore *s = wself; if (!s) return;
            if (s.audioTrackList.count >= 2) {
                NSNumber *idx = s.audioTrackList[1][@"index"];
                [s selectAudioTrackAtIndex:idx.integerValue];
                NSLog(@"[c%u][TrackTest] 切音轨→%@", s->_spLogId, idx);
            }
        });
        after(4.5, ^{
            SPPlayerCore *s = wself; if (!s) return;
            NSArray *subs = s.subtitleTrackList;
            if (subs.count >= 1) {
                NSNumber *idx = subs.lastObject[@"index"];
                [s selectSubtitleTrackAtIndex:idx.integerValue];
                NSLog(@"[c%u][TrackTest] 切字幕→%@（当前=%ld）", s->_spLogId, idx, (long)s.currentSubtitleTrackIndex);
            }
        });
        after(6.0, ^{ SPPlayerCore *s = wself; if (!s) return;
            [s selectSubtitleTrackAtIndex:-1];
            NSLog(@"[c%u][TrackTest] 字幕关闭（当前=%ld）", s->_spLogId, (long)s.currentSubtitleTrackIndex); });
        after(7.0, ^{
            SPPlayerCore *s = wself; if (!s) return;
            if (s.subtitleTrackList.count >= 1) {
                [s selectSubtitleTrackAtIndex:[s.subtitleTrackList.firstObject[@"index"] integerValue]];
            }
            [s setSubtitleScale:1.6];
            NSLog(@"[c%u][TrackTest] 字幕恢复+放大（当前=%ld scale=%.2f）",
                  s->_spLogId, (long)s.currentSubtitleTrackIndex, s.subtitleScale);
        });
        after(8.5, ^{
            SPPlayerCore *s = wself; if (!s) return;
            // Exercise rapid track changes; latest-wins means only the final one applies.
            NSArray *al = s.audioTrackList;
            if (al.count >= 2) {
                for (int i = 0; i < 10; i++) {
                    [s selectAudioTrackAtIndex:[al[i % 2][@"index"] integerValue]];
                }
                NSLog(@"[c%u][TrackTest] 快速连切 10 次完成（当前=%ld）", s->_spLogId, (long)s.currentAudioTrackIndex);
            }

            [s selectAudioTrackAtIndex:99];
            [s selectSubtitleTrackAtIndex:99];
            [s setSubtitleScale:100];
        });
        after(11.0, ^{
            SPPlayerCore *s = wself; if (!s) return;
            NSLog(@"[c%u][TrackTest] 结束 音轨=%ld 字幕=%ld scale=%.2f pos=%.2f state=%ld",
                  s->_spLogId, (long)s.currentAudioTrackIndex, (long)s.currentSubtitleTrackIndex,
                  s.subtitleScale, s.position, (long)s.state);
        });
    }

    if (spAutomation() && getenv("SP_SEEKDRAG")) {
        double dur = self->_duration;
        for (int i = 1; i <= 60; i++) {
            double t = dur * (double)i / 60.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (500 + i * 5) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [self seekTo:t];
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (spDebug()) SPLOG(@"[Test] 拖动结束 最终 pos=%.2f", self->_position);
        });
    }

    if (spAutomation() && getenv("SP_SEEKEND")) {
        double dur = self->_duration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (spDebug()) SPLOG(@"[Test] 立即 seek 到结尾 %.2fs", dur);
            [self seekTo:dur];
        });
    }

    if (spAutomation() && getenv("SP_AUTOSEEK")) {
        double target = atof(getenv("SP_AUTOSEEK"));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SPLOG(@"[Test] seek 前 pos=%.2f → 跳转到 %.2f", self->_position, target);
            [self seekTo:target];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SPLOG(@"[Test] seek 后 pos=%.2f", self->_position);
        });
    }

    if (spAutomation() && getenv("SP_BENCHSEEK")) {
        NSString *spec = [NSString stringWithUTF8String:getenv("SP_BENCHSEEK")];
        for (NSString *item in [spec componentsSeparatedByString:@","]) {
            NSArray<NSString *> *kv = [item componentsSeparatedByString:@":"];
            if (kv.count != 2) continue;
            double at = kv[0].doubleValue, target = kv[1].doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                SPLOG(@"[Bench] seek 发起 t=%.1f → %.2f (pos=%.2f)", at, target, self->_position);
                [self seekTo:target];
            });
        }
    }

    auto spAutomationRepeat = ^(double startMs, double intervalMs, int count,
                                void (^body)(int i)) {
        if (count <= 0) return;
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        __block int fired = 0;
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(startMs * NSEC_PER_MSEC)),
                                  (uint64_t)(intervalMs * NSEC_PER_MSEC), 1 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            const int i = fired++;
            if (i >= count) { dispatch_source_cancel(timer); return; }
            body(i);
            if (fired >= count) dispatch_source_cancel(timer);
        });
        dispatch_resume(timer);
    };

    if (spAutomation() && getenv("SP_SCRUBSIM")) {
        NSString *spec = [NSString stringWithUTF8String:getenv("SP_SCRUBSIM")];
        NSArray<NSString *> *kv = [spec componentsSeparatedByString:@":"];
        if (kv.count >= 4) {
            double from = kv[0].doubleValue, step = kv[1].doubleValue;
            double intervalMs = MAX(20.0, kv[2].doubleValue);
            int count = MIN(200, kv[3].intValue);
            BOOL fwd = kv.count >= 5 && [kv[4] isEqualToString:@"fwd"];
            spAutomationRepeat(2000, intervalMs, count, ^(int i) {
                [self seekTo:from + step * i precise:NO forward:fwd];
            });
        }
    }

    if (spAutomation() && getenv("SP_HOVERSIM")) {
        NSString *spec = [NSString stringWithUTF8String:getenv("SP_HOVERSIM")];
        NSArray<NSString *> *kv = [spec componentsSeparatedByString:@":"];
        if (kv.count == 2) {
            double at = kv[0].doubleValue, target = kv[1].doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                SPLOG(@"[Test] HOVERSIM 提示 → %.2fs", target);
                [self prefetchScrubHintAt:target];
            });
        }
    }
    // SP_THUMBSIM="start:step:interval-ms:count[:cancelEveryN]" sends repeated
    // timeline-thumbnail requests through the real main-thread entry point. A
    // positive fifth field replaces every Nth request with cancellation to verify
    // worker claim, local retention, and cancellation semantics. It begins after
    // two seconds and may run alongside SP_SCRUBSIM to exercise hover/seek overlap.
    if (spAutomation() && getenv("SP_THUMBSIM")) {
        NSString *spec = [NSString stringWithUTF8String:getenv("SP_THUMBSIM")];
        NSArray<NSString *> *kv = [spec componentsSeparatedByString:@":"];
        if (kv.count >= 4) {
            double from = kv[0].doubleValue, step = kv[1].doubleValue;
            double intervalMs = MAX(20.0, kv[2].doubleValue);
            int count = MIN(400, kv[3].intValue);
            int cancelEveryN = kv.count >= 5 ? kv[4].intValue : 0;
            spAutomationRepeat(2000, intervalMs, count, ^(int i) {
                if (cancelEveryN > 0 && i % cancelEveryN == cancelEveryN - 1) {
                    [self cancelTimelinePreview];
                } else {
                    [self requestTimelinePreviewAt:from + step * i];
                }
            });
        }
    }

    if (spAutomation() && getenv("SP_AUTOSHOT")) {
        NSString *shotPath = [NSString stringWithUTF8String:getenv("SP_AUTOSHOT")];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self captureScreenshotToPath:shotPath completion:^(BOOL ok) {
                if (spDebug()) SPLOG(@"[Test] 截图 %@ → %@", ok ? @"成功" : @"失败", shotPath);
            }];
        });
    }

    if (spAutomation() && getenv("SP_RENDERSHOT")) {
        NSString *rsPath = [NSString stringWithUTF8String:getenv("SP_RENDERSHOT")];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self->_renderer requestRenderDumpToPath:rsPath];
        });
    }

    if (spAutomation() && getenv("SP_LOOPAB")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self setLoopPointA:2.0];
            [self setLoopPointB:5.0];
            if (spDebug()) SPLOG(@"[Test] 设置 AB 循环 2-5s");
        });
    }

    if (spAutomation() && getenv("SP_SEQSEEK")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            for (int i = 1; i <= 10; i++) {
                [self seekTo:(double)(i * 3)];
            }
            if (spDebug()) SPLOG(@"[Test] 连续 10 次 seek 已触发（目标 30s）");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (spDebug()) SPLOG(@"[Test] 2s 后 pos=%.2f", self->_position);
        });
    }

    if (spAutomation() && getenv("SP_UISEEK")) {

        if (_uiSeekTimer) {
            dispatch_source_cancel(_uiSeekTimer);
            _uiSeekTimer = nil;
        }
        static const int64_t kUISeekDwellUs = 40000;    // = SeekBurstCadence.dwell
        static const int64_t kUISeekTimeoutUs = 300000; // = .settleTimeout
        static const int64_t kUISeekPollUs = 10000;     // = .settlePoll
        __block int steps = 0;
        __block int64_t issuedUs = 0;
        __block BOOL inFlight = NO;
        __block double stickyTarget = -1;
        __block BOOL wasPlaying = NO;
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());

        dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  DISPATCH_TIME_FOREVER, 1 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(src, ^{
            if (self->_uiSeekTimer != src) {
                dispatch_source_cancel(src);
                return;
            }
            int64_t nowUs = spNowUs();
            BOOL eligible = YES;
            if (inFlight) {
                const int64_t el = nowUs - issuedUs;
                if (el < kUISeekDwellUs) eligible = NO;
                else if (!self.seekSettled && el < kUISeekTimeoutUs) eligible = NO;
            }
            if (eligible) {
                if (steps >= 8) {
                    SPLOG(@"[UISeek] 连发结束（不补精确，UI 同款）→ 恢复播放=%d", (int)wasPlaying);
                    if (wasPlaying) [self play];
                    dispatch_source_cancel(src);
                    self->_uiSeekTimer = nil;
                    return;
                }
                steps++;
                if (steps == 2 && self->_state == SPPlayerStatePlaying) {
                    wasPlaying = YES;
                    [self pause];
                }
                const double base = stickyTarget >= 0
                    ? MAX(stickyTarget, self->_position)
                    : self->_position;
                const double target = base + 5.0;
                SPLOG(@"[UISeek] 第%d步 → %.2fs (上一步settled=%d 耗时=%.0fms)",
                      steps, target, (int)self.seekSettled,
                      issuedUs > 0 ? (nowUs - issuedUs) / 1000.0 : 0);
                stickyTarget = target;
                inFlight = YES;
                issuedUs = nowUs;

                [self seekTo:target precise:NO forward:YES];
            }

            const int64_t elapsedUs = inFlight ? spNowUs() - issuedUs : 0;
            int64_t delayUs;
            if (elapsedUs < kUISeekDwellUs) delayUs = kUISeekDwellUs - elapsedUs;
            else if (!self.seekSettled && elapsedUs < kUISeekTimeoutUs)
                delayUs = MIN(kUISeekPollUs, kUISeekTimeoutUs - elapsedUs);
            else delayUs = kUISeekDwellUs;
            dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, delayUs * NSEC_PER_USEC),
                                      DISPATCH_TIME_FOREVER, 1 * NSEC_PER_MSEC);
        });
        _uiSeekTimer = src;
        dispatch_resume(src);
    }

    if (spAutomation() && getenv("SP_SEEK2")) {
        double a = 12, b = 18.5, gapMs = 150;
        sscanf(getenv("SP_SEEK2"), "%lf,%lf,%lf", &a, &b, &gapMs);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self seekTo:a precise:YES];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((2000 + gapMs) * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            [self seekTo:b precise:YES];
        });
    }

    if (spAutomation() && getenv("SP_BURSTSEEK")) {
        for (int i = 1; i <= 8; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (2000 + i * 60) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [self seekTo:self->_position + 2.0];
            });
        }
    }

    if (spAutomation() && getenv("SP_STEPSIM")) {
        NSString *spec = [NSString stringWithUTF8String:getenv("SP_STEPSIM")];
        NSArray<NSString *> *kv = [spec componentsSeparatedByString:@":"];
        if (kv.count >= 3) {
            const double at = MAX(0.0, kv[0].doubleValue);
            const int count = MIN(400, MAX(1, kv[1].intValue));
            const double intervalMs = MAX(10.0, kv[2].doubleValue);
            const NSInteger delta = (kv.count >= 4 && kv[3].intValue < 0) ? -1 : 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self->_state == SPPlayerStatePlaying) [self pause];
            });
            for (int i = 1; i <= count; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)((at * 1000 + i * intervalMs) * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    const int64_t t0 = spNowUs();
                    const double before = self->_position;
                    [self stepFrame:delta];
                    SPLOG(@"[StepSim] 第%d步 delta=%ld %.3f→%.3fs 耗时=%.2fms",
                          i, (long)delta, before, self->_position,
                          (spNowUs() - t0) / 1000.0);
                });
            }
        }
    }

    if (spAutomation() && getenv("SP_AUTORATE")) {
        NSString *spec = [NSString stringWithUTF8String:getenv("SP_AUTORATE")];
        if ([spec containsString:@":"]) {
            for (NSString *step in [spec componentsSeparatedByString:@","]) {
                NSArray<NSString *> *kv = [step componentsSeparatedByString:@":"];
                if (kv.count != 2) continue;
                double r = kv[0].doubleValue, at = kv[1].doubleValue;
                if (r <= 0 || at < 0) continue;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    SPLOG(@"[Test] AUTORATE → %.2fx", r);
                    [self setPlaybackRate:r];
                });
            }
        } else {
            double r = spec.doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self setPlaybackRate:r];
            });
        }
    }

    if (spAutomation() && getenv("SP_SEQOPEN")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self openFileAtPath:path error:nil];
        });
    }

    if (spAutomation() && getenv("SP_SEQOPEN2")) {
        NSString *next = [NSString stringWithUTF8String:getenv("SP_SEQOPEN2")];
        if (![next isEqualToString:path]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (spDebug()) SPLOG(@"[Test] 连开第二个文件: %@", next);
                [self openFileAtPath:next error:nil];
            });
        }
    }

    if (spAutomation() && getenv("SP_AUTOPAUSE")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (spDebug()) SPLOG(@"[Test] 暂停 pos=%.2f", self->_position);
            [self pause];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (spDebug()) SPLOG(@"[Test] 恢复 pos=%.2f", self->_position);
            [self play];
        });
    }

}
#endif

- (BOOL)openMediaAtURL:(NSURL *)url error:(NSError **)error {
    return [self openMediaAtURL:url startAt:0 error:error];
}

- (BOOL)openMediaAtURL:(NSURL *)url startAt:(double)seconds error:(NSError **)error {
    if (!url.isFileURL) {
        if (error) *error = [self makeErrorWithDomain:@"SPURLError" code:-1
                                          description:NSLocalizedString(@"error.localFilesOnly", nil)
                                                phase:@"open" diagnosis:@"url" terminal:YES];
        return NO;
    }

    _requestedStartSeconds = MAX(0.0, seconds);
    return [self openFileAtPath:url.path error:error];
}

#pragma mark - Controls

- (void)play {
    if (!_renderer.isReady) return;
    if (_state == SPPlayerStateOpening) return;

    if (_state == SPPlayerStateEnded) {

        [self seekTo:0.0 precise:YES];
        return;
    }
    if (_state == SPPlayerStateIdle || _state == SPPlayerStateFailed) return;

    const int64_t stepAheadUs = _frameStepAheadUs;
    _frameStepAheadUs = 0;

    const BOOL realignAudio = stepAheadUs * 2 > 5 * _frameIntervalUs &&
                              _audioActive && !_audioOnlySession.load();
    [self resumeProcessing];
    [self setState:SPPlayerStatePlaying];
    if (_displayLink) _displayLink.paused = NO;

    if (_audioOnlyTimer) _audioOnlyTimer.fireDate = [NSDate date];
    if (realignAudio) {
        if (spDebug()) SPLOG(@"[Step] 恢复播放：音频对齐 seek → %.3fs（步进领先 %.0fms）",
                             _lastPresentedPtsUs / 1e6, stepAheadUs / 1000.0);

        [self seekTo:(double)_lastPresentedPtsUs / 1e6 precise:YES];
    }
}

- (void)resumeProcessing {
    _paused = false;

    _mediaClockPtsUs = _audioOnlySession.load() ? (int64_t)(_position * 1e6)
                                                : _lastPresentedPtsUs;
    _mediaClockWallUs = spNowUs();
    if (_audioActive && _audioOutput) [_audioOutput start];
    {
        std::lock_guard<std::mutex> lock(_stateMtx);
        _playCv.notify_all();
        _eofCv.notify_all();
    }
}

- (void)pause {
    if (_state == SPPlayerStateIdle || _state == SPPlayerStateOpening ||
        _state == SPPlayerStateFailed || _state == SPPlayerStateEnded) {
        return;
    }
    _paused = true;
    _rebufferHold = NO;
    {
        std::lock_guard<std::mutex> lock(_stateMtx);
        _playCv.notify_all();
    }

    const BOOL seekInFlightNoFlash = _seekPending.load() && !_seekFramePending.load();
    if (seekInFlightNoFlash) {
        [self armPausedSeekPresentation];
    } else if (_displayLink) {
        _displayLink.paused = YES;
    }
    if (_audioOnlyTimer) _audioOnlyTimer.fireDate = NSDate.distantFuture;
    if (_audioOutput) [_audioOutput stop];
    [self setState:SPPlayerStatePaused];

    [self refreshSubtitleDisplay];
}

- (void)togglePlayPause {
    if (_state == SPPlayerStatePlaying) {
        [self pause];
    } else if (_state == SPPlayerStatePaused || _state == SPPlayerStateEnded) {
        [self play];
    }
}

- (void)seekTo:(double)seconds {
    [self seekTo:seconds precise:YES];
}

- (void)seekTo:(double)seconds precise:(BOOL)precise {
    [self seekTo:seconds precise:precise forward:NO];
}

- (void)seekTo:(double)seconds precise:(BOOL)precise forward:(BOOL)forward {
    if (_state == SPPlayerStateIdle || _state == SPPlayerStateOpening ||
        _state == SPPlayerStateFailed) {
        return;
    }
    double clamped = MAX(0.0, MIN(seconds, _duration));

    clamped = [self resilientSnapSeekSeconds:clamped forward:forward];
    int64_t us = (int64_t)(clamped * 1e6);

    _seekReqWallUs.store(spNowUs());
    BOOL wasPaused = (_state == SPPlayerStatePaused);
    BOOL wasEnded = (_state == SPPlayerStateEnded);

    _prevSeekUnsettled = _seekFramePending.load();
    _seekFlashDone.store(false);

    if (_audioOnlySession.load()) precise = YES;
    int64_t dispTarget = -1;
    if (precise) {
        int64_t durUs = (int64_t)(_duration * 1e6);
        dispTarget = us;
        if (durUs > 0 && dispTarget > durUs - 2 * _frameIntervalUs) {
            dispTarget = MAX((int64_t)0, durUs - 2 * _frameIntervalUs);
        }
    }

    if (!_seekFramePending.load()) {
        _seekBurstBaseGen.store(_generation.load() + 1);
    }

    const BOOL skipFlash = (precise && !_prevSeekUnsettled) || _audioOnlySession.load();
    _seekFramePending.store(!skipFlash);
    _seekFlashDone.store(skipFlash);

    const BOOL audioOnly = _audioOnlySession.load();
    _seekDisplayTargetUs.set(audioOnly ? -1 : dispTarget);

    [self doSeek:us
        trimTargetUs:dispTarget
           catchUpUs:(audioOnly ? -1 : dispTarget)

             forward:(precise ? NO : forward)
    alignToleranceUs:((precise && !audioOnly)
                          ? sp::spSeekGridToleranceUs(_frameIntervalUs) : 0)];

    if (audioOnly) _seekSettleGen.store(_generation.load());
    _lastPresentedPtsUs = us;
    _position = clamped;

    _mediaClockPtsUs = us;
    _mediaClockWallUs = spNowUs();
    [self notifyPosition];
    if (wasEnded) {

        [self resumeProcessing];
        [self setState:SPPlayerStatePlaying];
        if (_displayLink) _displayLink.paused = NO;

        if (_audioOnlyTimer) _audioOnlyTimer.fireDate = [NSDate date];
    } else if (wasPaused) {
        [self armPausedSeekPresentation];
    }
}

- (void)armPausedSeekPresentation {
    if (_displayLink) _displayLink.paused = NO;
    const int64_t wdSeq = _pausedSeekWatchdogSeq.fetch_add(1) + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self->_pausedSeekWatchdogSeq.load() != wdSeq) return;

        if (self->_state == SPPlayerStatePaused &&
            (self->_seekPending.load() || self->_presentRetryPending)) {
            if (spDebug()) SPLOG(@"[Core] 暂停态上屏看门狗：1s 未收尾，停 DisplayLink（目标帧/重试继续等）");
            self->_displayLink.paused = YES;
        }
    });
}

- (void)prefetchScrubHintAt:(double)seconds {
    if (_state == SPPlayerStateIdle || _state == SPPlayerStateOpening ||
        _state == SPPlayerStateFailed || seconds < 0) {
        return;
    }
    // Immediate hover I/O outranks the one-shot 9MiB Cues warmer — but hover
    // loads no index into the main context, so this is a deferral with a 2s
    // cooldown, not the permanent retirement a real seek performs (an early
    // sweep across the timeline must not condemn the first real seek to the
    // cold tail-of-file index read the warmer exists to eliminate). Order:
    // publish the cooldown BEFORE deferring — an admission pass that already
    // passed the hold check is then caught by the defer-seq recheck inside
    // the demuxer's publish lock, so no worker can slip past this hover.
    _indexPrefetchHoverHoldUs.store(spNowUs() + 2000000);
    _demuxer->deferIndexPrefetch();
    _scrubHintUs.store((int64_t)(seconds * 1e6));
    _scrubHintPending.store(true);
    {

        std::lock_guard<std::mutex> lock(_stateMtx);
    }
    _playCv.notify_all();
    _eofCv.notify_all();
}

static BOOL spThumbsEnabled(void) {
#if SP_APP_STORE
    return YES;
#else
    static BOOL on = !(getenv("SP_THUMBS") && atoi(getenv("SP_THUMBS")) == 0);
    return on;
#endif
}

- (BOOL)timelinePreviewEligible {
    return spThumbsEnabled() && !_previewMode && !_audioOnlySession.load() &&
           _currentFilePath != nil;
}

- (void)scheduleTimelineThumbnails {
    if (spDebug() && _preparedDoviIPT && spThumbsEnabled() && !_previewMode) {
        SPLOG(@"[Thumb] DoVi Profile 5（IPTPQc2）：缩略图走 Metal 转换核（RPU 逐图解析）");
    }

    if (![self timelinePreviewEligible] || _duration < 10.0) return;
    const int64_t gen = _openGeneration.load();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (self->_openGeneration.load() != gen) return;
        [[self ensureThumbnailerForGeneration:gen] startSweep];
    });
}

- (SPTimelineThumbnailer *)ensureThumbnailerForGeneration:(int64_t)gen {

    if (gen != _openGeneration.load() || ![self timelinePreviewEligible]) return nil;
    if (_thumbnailer) return _thumbnailer;
    __weak SPPlayerCore *weakSelf = self;

    SPThumbIdleProbe probe = ^BOOL {
        SPPlayerCore *s = weakSelf;
        if (!s || s->_openGeneration.load() != gen) return NO;
        if (s->_thumbSuspendedByUI.load()) return NO; // non-key window yields scanning
        if (s->_firstFramePending.load()) return NO;
        if (s->_seekPending.load() || s->_seekFramePending.load()) return NO;
        if (s->_catchUpTargetUs.valid()) return NO;
        if (s->_scrubHintPending.load()) return NO;
        // Supply is healthy after three seconds without presentation starvation.
        // This direct playback signal remains valid for bursty audio muxing, where
        // demux backpressure can keep the video queue near 8% despite adequate supply.
        return spNowUs() - s->_presentStarveWallUs.load() > 3000000;
    };

    SPThumbSeekBusyProbe seekBusy = ^BOOL {
        SPPlayerCore *s = weakSelf;
        if (!s || s->_openGeneration.load() != gen) return YES;
        return s->_firstFramePending.load() || s->_seekPending.load() ||
               s->_seekFramePending.load() || s->_catchUpTargetUs.valid();
    };
    void (^onUpdate)(void) = ^{
        SPPlayerCore *s = weakSelf;
        if (!s || s->_openGeneration.load() != gen) return;
        if ([s->_delegate respondsToSelector:
                @selector(playerCoreDidUpdateTimelinePreview:)]) {
            [s->_delegate playerCoreDidUpdateTimelinePreview:s];
        }
    };
    _thumbnailer = [[SPTimelineThumbnailer alloc]
            initWithPath:_currentFilePath
              durationUs:(int64_t)(_duration * 1e6)
        timelineOriginUs:_demuxer->timelineOriginUs()
            remoteVolume:_demuxer->onRemoteVolume()
          colorPrimaries:_preparedColorPrimaries
                colorTrc:_preparedColorTrc
              colorSpace:_preparedColorSpace
              colorRange:_preparedColorRange
             videoParams:_thumbVideoPar
        videoStreamIndex:_videoStreamIndex
           videoStreamId:_thumbVideoStreamId
                 doviIPT:_preparedDoviIPT
       doviNalLengthSize:_doviNalLengthSize
               idleProbe:probe
           seekBusyProbe:seekBusy
                onUpdate:onUpdate];
    _thumbnailer.spLogId = _spLogId;
    return _thumbnailer;
}

- (nullable id)timelinePreviewImageAt:(double)seconds
                              isExact:(nullable BOOL *)outExact {
    return [_thumbnailer previewImageAt:seconds isExact:outExact];
}

- (nullable SPThumbDustSnapshot *)timelineDustSnapshot {
    return [_thumbnailer dustSnapshot];
}

- (void)requestTimelinePreviewAt:(double)seconds {
    if (_state == SPPlayerStateIdle || _state == SPPlayerStateOpening ||
        _state == SPPlayerStateFailed || seconds < 0) {
        return;
    }
    // requestTimelinePreviewAt is also a public entry point (tests/legacy UI do
    // not necessarily send a scrub hint first), so keep the priority contract
    // complete here as well — the same hover deferral, never the permanent
    // seek retirement. Cooldown before defer (see prefetchScrubHintAt).
    _indexPrefetchHoverHoldUs.store(spNowUs() + 2000000);
    _demuxer->deferIndexPrefetch();

    [[self ensureThumbnailerForGeneration:_openGeneration.load()]
        requestPreviewAt:seconds];
}

- (void)cancelTimelinePreview {
    [_thumbnailer cancelPreviewRequest];
}

// A non-key window yields background scanning as described in the header. A
// resident worker resumes through its periodic probe within one probe interval.
- (void)setTimelinePreviewSuspended:(BOOL)suspended {
    bool was = _thumbSuspendedByUI.exchange(suspended);
    if (spDebug() && was != (bool)suspended) {
        SPLOG(@"[Thumb] %@", suspended ? @"后台扫描让路（窗口非 key）"
                                       : @"后台扫描恢复（窗口转 key）");
    }
}

- (void)stepFrame:(NSInteger)delta {
    if (delta == 0 || _videoFps <= 0 || _state == SPPlayerStateIdle) return;
    BOOL wasPlaying = (_state == SPPlayerStatePlaying);
    if (wasPlaying) [self pause];
    if (delta != 1 || ![self tryStepForwardFromFrameQueue]) {
        [self seekTo:_position + (double)delta / _videoFps];
    }
    if (wasPlaying) [self play];
}

- (void)setPlaybackRate:(double)rate {
    double clamped = MAX(0.25, MIN(rate, 5.0));
    double oldRate = _playbackRate.load();
    if (fabs(clamped - oldRate) < 0.001) return;

    if (_audioActive && _audioOutput) {

        BOOL liveClock = _audioOutput.isRunning && !_audioClockHandedOff;

        sp::SPRateSwitchAnchorInputs anchorIn;
        anchorIn.audioRunning = _audioOutput.isRunning;
        anchorIn.audioClockHandedOff = _audioClockHandedOff;
        anchorIn.audioOnlySession = _audioOnlySession.load();
        anchorIn.currentMediaNowUs = liveClock ? [self currentMediaNowUs] : 0;
        anchorIn.audioClockNowUs = [self audioClockNowUs];
        anchorIn.positionUs = (int64_t)(_position * 1e6);
        anchorIn.lastPresentedPtsUs = _lastPresentedPtsUs;
        _audioClockBaseUs = sp::spRateSwitchClockAnchorUs(anchorIn);
        _audioBasePlayedFrames = _audioOutput.clockFrames;

        if (!_audioRateSwitchPending) _audioRateBeforeSwitch = oldRate;
        _audioRateSwitchPending = YES;
        _audioRateSwitchFrames = -1;
        [_audioOutput requestRate:clamped];

        if (_audioPackets) {
            TaggedPacket ctl;
            ctl.gen = _generation.load();
            ctl.control = true;
            (void)_audioPackets->pushForTransition(std::move(ctl));
        }

        if (!liveClock && _audioClockHandedOff && !_paused.load()) {
            _mediaClockPtsUs = [self wallClockNowUs];
            _mediaClockWallUs = spNowUs();
        }
    } else {
        _mediaClockPtsUs = _lastPresentedPtsUs;
        _mediaClockWallUs = spNowUs();
    }
    _playbackRate.store(clamped);
    {

        std::lock_guard<std::mutex> lock(_interpolationTransitionMtx);
        _interpolationPolicyEpoch.fetch_add(1);
        _interpolationResetRequested.store(true);
    }
    {

        std::lock_guard<std::mutex> lock(_decodeMtx);
    }
    _decodeCv.notify_all();
    _interpolationTransitionCv.notify_all();

    [self notifyFrameInterpolationDidChange];
    if (spDebug()) SPLOG(@"[Core] 倍速=%.2fx", clamped);
}

- (int64_t)audioContentUsForFramesFrom:(int64_t)from to:(int64_t)to {
    const double rate = _playbackRate.load();

    if (_audioRateSwitchPending) {
        if (![_audioOutput rateSwitchPending]) {
            _audioRateSwitchPending = NO;
            _audioRateSwitchFrames = [_audioOutput rateSwitchPlayedFrame];
        } else {
            return (int64_t)((double)(to - from) / kSPAudioClockHz * 1e6 * _audioRateBeforeSwitch);
        }
    }
    const int64_t s = _audioRateSwitchFrames;
    if (s < 0 || from >= s) {
        return (int64_t)((double)(to - from) / kSPAudioClockHz * 1e6 * rate);
    }
    if (to <= s) {
        return (int64_t)((double)(to - from) / kSPAudioClockHz * 1e6 * _audioRateBeforeSwitch);
    }
    return (int64_t)((double)(s - from) / kSPAudioClockHz * 1e6 * _audioRateBeforeSwitch) +
           (int64_t)((double)(to - s) / kSPAudioClockHz * 1e6 * rate);
}

- (int64_t)audioClockNowUs {
    if (_holeJumpCount.load(std::memory_order_acquire) > 0) [self foldDueHoleJumps];
    return _audioClockBaseUs +
           [self audioContentUsForFramesFrom:_audioBasePlayedFrames to:_audioOutput.clockFrames];
}

- (int64_t)wallClockNowUs {
    int64_t elapsedUs = spNowUs() - _mediaClockWallUs;
    return _mediaClockPtsUs + (int64_t)((double)elapsedUs * _playbackRate.load());
}

- (BOOL)audioClockIsAuthoritative {
    return _audioActive && _audioOutput && _audioOutput.isRunning &&
           !_audioClockHandedOff;
}

- (int64_t)currentMediaNowUs {
    if ([self audioClockIsAuthoritative]) {
        return [self audioClockNowUs];
    }
    return [self wallClockNowUs];
}

- (double)playbackRate { return _playbackRate.load(); }

- (void)notifyFrameInterpolationDidChange {
    void (^notify)(void) = ^{
        id<SPPlayerCoreDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(playerCoreDidChangeFrameInterpolation:)]) {
            [delegate playerCoreDidChangeFrameInterpolation:self];
        }
    };
    if ([NSThread isMainThread]) notify();
    else dispatch_async(dispatch_get_main_queue(), notify);
}

- (SPFrameInterpolationMode)frameInterpolationMode {
    return (SPFrameInterpolationMode)_frameInterpolationModeValue.load();
}

- (void)setFrameInterpolationMode:(SPFrameInterpolationMode)mode {
#ifndef SP_ENHANCE
    // Builds without enhanced playback always converge on the normal off path.
    // This also closes indirect entry points while preserving full teardown.
    mode = SPFrameInterpolationModeOff;
#else

    if (!spFullTier()) mode = SPFrameInterpolationModeOff;
#endif
    if (mode != SPFrameInterpolationModeDoubleRate) mode = SPFrameInterpolationModeOff;
    // Apply the product ceiling to direct setters and automation as well as UI.
    // The worker code covers decoded dimensions growing beyond stream metadata.
    const BOOL requestedResolutionLimited = mode == SPFrameInterpolationModeDoubleRate &&
        (sp::spInterpolationExceeds4KLimit((uint32_t)MAX(_videoWidth, 0),
                                        (uint32_t)MAX(_videoHeight, 0)) ||
         _interpolationDecodedResolutionLimited.load());
    if (requestedResolutionLimited) mode = SPFrameInterpolationModeOff;
    const BOOL requestedUnavailable = mode == SPFrameInterpolationModeDoubleRate &&
                                      !SPFrameBudgetGenerator.isAvailable;
    if (requestedUnavailable) {
        mode = SPFrameInterpolationModeOff;
    }
    int previous;
    {
        std::lock_guard<std::mutex> lock(_interpolationTransitionMtx);
        previous = _frameInterpolationModeValue.load();
        if (previous != (int)mode) {
            _frameInterpolationModeValue.store((int)mode);
            _interpolationPolicyEpoch.fetch_add(1);

            _interpolationResetRequested.store(true);
        }
    }
    if (previous == (int)mode) {

        if (requestedUnavailable || requestedResolutionLimited) {
            {
                std::lock_guard<std::mutex> lock(_interpolationStatusMtx);
                _frameInterpolationStatusValue = requestedResolutionLimited
                    ? NSLocalizedString(@"memc.policy.resolutionLimit", nil)
                    : NSLocalizedString(@"memc.policy.unavailable", nil);
            }
            [self notifyFrameInterpolationDidChange];
        }
        return;
    }
    {
        std::lock_guard<std::mutex> lock(_interpolationStatusMtx);
        _frameInterpolationStatusValue = requestedResolutionLimited
            ? NSLocalizedString(@"memc.policy.resolutionLimit", nil)
            : (requestedUnavailable ? NSLocalizedString(@"memc.policy.unavailable", nil)
                : (mode == SPFrameInterpolationModeOff ? NSLocalizedString(@"memc.status.off", nil) : NSLocalizedString(@"memc.status.waitingCompatibleFrames", nil)));
    }
    _frameInterpolationActiveValue.store(false);

    [self resetPresentedFrameRate];

    _interpolationPolicyStatusCode.store(-1);
    if (_running.load()) {

        _frames->interruptPushes();
        if (auto motionFrames = _motionFramesPublished.load()) {
            motionFrames->interruptPushes();
        }
    }
    [self wakeDecodeThread];
    _interpolationTransitionCv.notify_all();
    [self notifyFrameInterpolationDidChange];
    if (mode == SPFrameInterpolationModeOff) {

        if (_compareRealFrame) { CVPixelBufferRelease(_compareRealFrame); _compareRealFrame = NULL; }
        _compareRealFrameGen = -1;
        if (_rendererCompareActive) { [_renderer setCompareBuffer:NULL]; _rendererCompareActive = false; }
    }
    if (spDebug()) SPLOG(@"[MEMC] 用户模式=%@", mode == SPFrameInterpolationModeDoubleRate ? @"2x" : @"off");
}

- (BOOL)frameInterpolationAvailable {

    if (!spFullTier()) return NO;

    const int resolved = [SPFrameBudgetGenerator availabilityIfResolved];
    if (resolved >= 0) return resolved != 0;
    [SPFrameBudgetGenerator resolveAvailabilityAsync];
    if (@available(macOS 15.4, *)) return YES;
    return NO;
}

- (void)notePresentedFrameForRate {
    if (_paused.load()) return;
    const int64_t now = spNowUs();
    const int64_t gen = _generation.load();

    const int64_t gapUs = MAX((int64_t)500000, 3 * _frameIntervalUs);
    if (_fpsWindowStartUs == 0 || gen != _fpsWindowGen || now - _fpsLastTickUs > gapUs) {
        _fpsWindowStartUs = now;
        _fpsWindowCount = 0;
        _fpsWindowGen = gen;
    }
    _fpsLastTickUs = now;
    _fpsWindowCount++;
    const int64_t elapsed = now - _fpsWindowStartUs;
    if (elapsed >= 1000000) {
        _presentedFrameRateValue.store((double)_fpsWindowCount * 1e6 / (double)elapsed);
        _fpsWindowStartUs = now;
        _fpsWindowCount = 0;
    }
}

- (void)resetPresentedFrameRate {
    _fpsWindowStartUs = 0;
    _fpsWindowCount = 0;
    _fpsWindowGen = -1;
    _fpsLastTickUs = 0;
    _presentedFrameRateValue.store(0.0);
}

- (double)presentedFrameRate {
    return _presentedFrameRateValue.load();
}

- (double)frameInterpolationCoverage {

    if (_frameInterpolationModeValue.load() == (int)SPFrameInterpolationModeOff) return 0.0;
    return _generator ? [_generator coverageRatio] : 0.0;
}

- (BOOL)frameInterpolationActive {
    return _frameInterpolationActiveValue.load();
}

- (sp::SPInterpolationPolicyCode)staticInterpolationBypassCode {
    if (_audioOnlySession.load()) {
        return sp::SPInterpolationPolicyCode::Active;
    }

    if (_interpolationDecodedResolutionLimited.load() ||
        sp::spInterpolationExceeds4KLimit((uint32_t)MAX(_videoWidth, 0),
                                        (uint32_t)MAX(_videoHeight, 0))) {
        return sp::SPInterpolationPolicyCode::ResolutionLimit;
    }
    if (_videoWidth <= 0) return sp::SPInterpolationPolicyCode::Active;
    if (_interpolationDynamicHDRUnsafe) {
        return sp::SPInterpolationPolicyCode::DynamicHDR;
    }
    if (_interpolationInterlaced) {
        return sp::SPInterpolationPolicyCode::Interlaced;
    }

    if (_playbackRate.load() > 1.0001) {
        return sp::SPInterpolationPolicyCode::FastPlayback;
    }
    // Use the same cadence gate as spEvaluateInterpolationRouting. FPS and panel
    // refresh are known at open time, so publish the unavailable state before
    // interaction. Fast playback is transient; unknown FPS remains a runtime gate.
    const double cadenceRate = _playbackRate.load();
    if (cadenceRate <= 1.0001 && _videoFps > 0.0 &&
        _videoFps * 2.0 * cadenceRate > _displayMaximumFPS.load() + 0.5) {
        return sp::SPInterpolationPolicyCode::DisplayCadence;
    }
    return sp::SPInterpolationPolicyCode::Active;
}

- (BOOL)frameInterpolationContentBypassed {
    if ([self staticInterpolationBypassCode] !=
        sp::SPInterpolationPolicyCode::Active) {
        return YES;
    }
    switch ((sp::SPInterpolationPolicyCode)_interpolationPolicyStatusCode.load()) {
        case sp::SPInterpolationPolicyCode::DynamicHDR:
        case sp::SPInterpolationPolicyCode::Interlaced:

        case sp::SPInterpolationPolicyCode::PixelFormat:
        case sp::SPInterpolationPolicyCode::MissingIOSurface:
        case sp::SPInterpolationPolicyCode::ChromaSiting:

        case sp::SPInterpolationPolicyCode::ResourceUnavailable:
        case sp::SPInterpolationPolicyCode::MemoryLimit:
        case sp::SPInterpolationPolicyCode::EngineFailed:
            return YES;
        default:
            return NO;
    }
}

- (NSString *)frameInterpolationUnavailableDescription {
    // Match the existing priority: current static facts precede worker status.
    // Use structured codes so localization and diagnostic wording never affect
    // which explanation the user receives.
    const sp::SPInterpolationPolicyCode staticCode = [self staticInterpolationBypassCode];
    const sp::SPInterpolationPolicyCode code = staticCode != sp::SPInterpolationPolicyCode::Active
        ? staticCode : (sp::SPInterpolationPolicyCode)_interpolationPolicyStatusCode.load();
    switch (code) {
        case sp::SPInterpolationPolicyCode::Unavailable:
            return NSLocalizedString(@"chrome.memc.tooltip.unavailable", nil);
        case sp::SPInterpolationPolicyCode::ResolutionLimit:
            return NSLocalizedString(@"chrome.memc.tooltip.resolutionLimit", nil);
        case sp::SPInterpolationPolicyCode::DynamicHDR:
        case sp::SPInterpolationPolicyCode::Interlaced:
        case sp::SPInterpolationPolicyCode::PixelFormat:
        case sp::SPInterpolationPolicyCode::MissingIOSurface:
        case sp::SPInterpolationPolicyCode::ChromaSiting:
            return NSLocalizedString(@"chrome.memc.tooltip.unsupportedVideo", nil);
        case sp::SPInterpolationPolicyCode::FastPlayback:
            return NSLocalizedString(@"chrome.memc.tooltip.fastPlayback", nil);
        case sp::SPInterpolationPolicyCode::DisplayCadence:
            return NSLocalizedString(@"chrome.memc.tooltip.displayRefresh", nil);
        case sp::SPInterpolationPolicyCode::MemoryLimit:
            return NSLocalizedString(@"chrome.memc.tooltip.memory", nil);
        case sp::SPInterpolationPolicyCode::EngineFailed:
            return NSLocalizedString(@"chrome.memc.tooltip.engineFailed", nil);
        case sp::SPInterpolationPolicyCode::ResourceUnavailable:
            return NSLocalizedString(@"chrome.memc.tooltip.unknown", nil);
        default:
            return @"";
    }
}

- (NSString *)frameInterpolationStatus {

    const sp::SPInterpolationPolicyCode staticCode =
        [self staticInterpolationBypassCode];
    if (staticCode == sp::SPInterpolationPolicyCode::DisplayCadence) {

        return [NSString stringWithFormat:
                   NSLocalizedString(@"memc.status.displayCadenceFmt", nil),
                   _displayMaximumFPS.load(),
                   _videoFps * 2.0 * _playbackRate.load()];
    }
    if (staticCode != sp::SPInterpolationPolicyCode::Active) {
        return SPFrameGeneratorLocalizedPolicyStatus(static_cast<int>(staticCode));
    }
    std::lock_guard<std::mutex> lock(_interpolationStatusMtx);
    return [_frameInterpolationStatusValue copy] ?: NSLocalizedString(@"memc.status.unknown", nil);
}

- (void)setVolume:(float)volume {
    // Preserve the previous value rather than publishing non-finite gain.
    if (!std::isfinite(volume)) return;
    _volume = MAX(0.0, MIN((double)volume, 5.0));
    if (_audioOutput && !_muted) [_audioOutput setVolume:_volume];
}

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    if (_audioOutput) [_audioOutput setVolume:muted ? 0.0 : _volume];
}

- (BOOL)isMuted { return _muted; }
- (float)volume { return (float)_volume; }

- (void)cancelPendingSubtitleLoad {
    _subLoadGen.fetch_add(1);
    [_subtitleRenderer invalidatePendingLoads];
}

- (BOOL)loadSubtitleFile:(NSString *)path {
    return [self loadSubtitleFile:path silent:NO completion:nil];
}

- (BOOL)loadSubtitleFile:(NSString *)path
                  silent:(BOOL)silent
              completion:(void (^)(BOOL))completion {
    if (!_subtitleRenderer) {
        if (completion) dispatch_async(dispatch_get_main_queue(),
                                       ^{ completion(NO); });
        return NO;
    }
    const int64_t loadGen = _subLoadGen.fetch_add(1) + 1;

    [_subtitleRenderer invalidatePendingLoads];

    NSString *pathCopy = [path copy];

    void (^reject)(NSString *) = ^(NSString *reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO);
            if (self->_subLoadGen.load() != loadGen) return;
            if (silent) return;
            if ([self->_delegate respondsToSelector:
                     @selector(playerCore:didFailWithError:)]) {
                NSString *msg = [NSString stringWithFormat:
                    NSLocalizedString(@"subtitle.load.failed", nil),
                    pathCopy.lastPathComponent, reason];

                [self->_delegate playerCore:self didFailWithError:
                    [self makeErrorWithDomain:@"KhuaPlayer" code:-30 description:msg
                                        phase:@"subtitle" diagnosis:@"subtitleLoad" terminal:NO]];
            }
        });
    };

    dispatch_async(dispatch_get_global_queue(
                       silent ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED, 0), ^{

        const unsigned long long kSubCap = 32ull * 1024 * 1024;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:pathCopy error:nil];

        if (!attrs || ![attrs[NSFileType] isEqual:NSFileTypeRegular]) {
            SPLOG(@"[Core] 外挂字幕属性不可读或非普通文件，拒绝加载: %@",
                  pathCopy.lastPathComponent);
            reject(NSLocalizedString(@"subtitle.load.reason.unreadable", nil));
            return;
        }
        unsigned long long fileSize = [attrs[NSFileSize] unsignedLongLongValue];
        if (fileSize > kSubCap) {
            SPLOG(@"[Core] 外挂字幕 %lluMB 超过 32MB 上限，拒绝加载: %@",
                  fileSize >> 20, pathCopy.lastPathComponent);
            reject(NSLocalizedString(@"subtitle.load.reason.tooLarge", nil));
            return;
        }

        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:pathCopy];
        NSData *data = fh ? [fh readDataUpToLength:(NSUInteger)(kSubCap + 1) error:nil] : nil;
        [fh closeFile];
        if (!data || data.length > kSubCap) {
            SPLOG(@"[Core] 外挂字幕读取失败或超限，拒绝加载: %@", pathCopy.lastPathComponent);
            reject(NSLocalizedString(@"subtitle.load.reason.unreadable", nil));
            return;
        }

        size_t lineCount = 0;
        {
            const char *p = (const char *)data.bytes;
            const char *end = p + data.length;
            while (p < end && lineCount <= 1000000) {
                const char *nl = (const char *)memchr(p, '\n', (size_t)(end - p));
                if (!nl) break;
                lineCount++;
                p = nl + 1;
            }
        }
        if (lineCount > 1000000) {
            SPLOG(@"[Core] 外挂字幕行数超限（>100 万行），拒绝加载: %@",
                  pathCopy.lastPathComponent);
            reject(NSLocalizedString(@"subtitle.load.reason.tooManyLines", nil));
            return;
        }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) {

            NSString *converted = nil;
            NSStringEncoding enc = [NSString stringEncodingForData:data
                                                   encodingOptions:nil
                                                   convertedString:&converted
                                               usedLossyConversion:nil];
            if (enc != 0) text = converted;
        }
        if (!text) {
            SPLOG(@"[Core] 外挂字幕编码无法识别（非 UTF-8），拒绝加载: %@",
                  pathCopy.lastPathComponent);
            reject(NSLocalizedString(@"subtitle.load.reason.encoding", nil));
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{

            if (self->_subLoadGen.load() != loadGen) {
                if (spDebug()) SPLOG(@"[Core] 外挂字幕读取已过期，丢弃: %@",
                                     pathCopy.lastPathComponent);
                if (completion) completion(NO);
                return;
            }

            [self->_subtitleRenderer loadSubtitleText:text completion:^(BOOL ok) {
                if (self->_subLoadGen.load() != loadGen) {
                    if (completion) completion(NO);
                    return;
                }
                if (!ok) {
                    reject(NSLocalizedString(@"subtitle.load.reason.noEvents", nil));
                    return;
                }

                {
                    std::lock_guard<std::mutex> lk(self->_subSwitchMtx);
                    self->_subtitleActive = NO;
                    self->_currentSubtitleTrackPub = -1;
                }
                [self refreshSubtitleDisplay];
                if (completion) completion(YES);
            }];
        });
    });
    return YES;
}

- (void)setAspectMode:(NSInteger)mode { [_renderer setAspectMode:(int)mode]; [self refreshSubtitleDisplay]; }
- (void)setForcedAspect:(double)ratio { [_renderer setForcedAspect:(float)ratio]; [self refreshSubtitleDisplay]; }
- (void)setCropAspect:(double)ratio { [_renderer setCropAspect:(float)ratio]; [self refreshSubtitleDisplay]; }
- (void)setRotation:(NSInteger)deg { [_renderer setRotation:(int)deg]; [self refreshSubtitleDisplay]; }
- (void)setMirror:(NSInteger)m { [_renderer setMirror:(int)m]; [self refreshSubtitleDisplay]; }

- (void)setXdrEnabled:(BOOL)enabled {
    if ([_renderer sdrBoostEnabled] == enabled) return;
    [_renderer setSDRBoostEnabled:enabled];
    if (spDebug()) SPLOG(@"[EDR] 请求=%d 可用=%d 余量=%.2f", enabled, [self xdrAvailable], [self displayEDRHeadroom]);
    if (_state == SPPlayerStatePlaying || _state == SPPlayerStateOpening) {
        _needsOutputModeRedraw.store(true);
    } else if (_lastFrameBuffer) {
        std::lock_guard<std::mutex> rlock(_renderMtx);
        [_renderer renderPixelBuffer:_lastFrameBuffer];
    }
}
- (BOOL)xdrEnabled { return [_renderer sdrBoostEnabled]; }
- (BOOL)xdrAvailable {
    if (_state == SPPlayerStateIdle || _state == SPPlayerStateFailed) return NO;
    if (_audioOnlySession.load()) return NO;
    if (!_hdrDescription || ![_hdrDescription isEqualToString:@"SDR"]) return NO;
    return [_renderer displayEdrCapable];
}
- (double)displayEDRHeadroom { return (double)[_renderer displayEDRHeadroom]; }
- (BOOL)displayEDRCapable { return [_renderer displayEdrCapable]; }
- (void)setBrightness:(float)v { [_renderer setBrightness:v]; [self refreshSubtitleDisplay]; }
- (void)setContrast:(float)v { [_renderer setContrast:v]; [self refreshSubtitleDisplay]; }
- (void)setSaturation:(float)v { [_renderer setSaturation:v]; [self refreshSubtitleDisplay]; }
- (void)setGamma:(float)v { [_renderer setGamma:v]; [self refreshSubtitleDisplay]; }

- (void)applyDisplayLinkRate {
    if (!_displayLink) return;
    NSScreen *scr = _view.window.screen ?: NSScreen.mainScreen;
    double panelMax = (scr && scr.maximumFramesPerSecond > 0)
                          ? (double)scr.maximumFramesPerSecond : 60.0;

    NSNumber *screenNumber = scr.deviceDescription[@"NSScreenNumber"];
    if (screenNumber) {
        CGDirectDisplayID displayID = (CGDirectDisplayID)screenNumber.unsignedIntValue;
        CGDisplayModeRef displayMode = CGDisplayCopyDisplayMode(displayID);
        if (displayMode) {
            double modeHz = CGDisplayModeGetRefreshRate(displayMode);
            CGDisplayModeRelease(displayMode);
            if (modeHz > 1.0 && modeHz < panelMax) panelMax = modeHz;
        }
    }
    double previousPanelMax = _displayMaximumFPS.exchange(panelMax);
    if (fabs(previousPanelMax - panelMax) > 0.5) {
        {
            std::lock_guard<std::mutex> lock(_interpolationTransitionMtx);
            _interpolationPolicyEpoch.fetch_add(1);
            _interpolationResetRequested.store(true);
        }
        [self wakeDecodeThread];
        _interpolationTransitionCv.notify_all();
    }
    // Tick at the panel's full refresh rate. Content-rate requests can be
    // quantized downward (23.976 fps may become 20 Hz), while near-divisor rates
    // beat against the content grid (24.000 versus 23.976 diverges every 41.7 s).
    // A finer tick grid keeps clock jitter below a frame interval. Rendering
    // still occurs at content cadence; the extra ticks only peek and read clocks.
    float pref = (float)panelMax;
    // Pin the preferred range to the panel maximum. Advertising an unreachable
    // 120 Hz maximum on a 60 Hz panel can select an unsatisfied fallback rate,
    // especially after the system changes the display refresh rate.
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(pref, pref, pref);
}

- (void)displayScreenChanged {
    NSScreen *scr = _view.window.screen ?: NSScreen.mainScreen;
    if (!scr || !_renderer) return;
    [self applyDisplayLinkRate];
    std::lock_guard<std::mutex> rlock(_renderMtx);
    [_renderer updateOutputModeWithMaxEDR:scr.maximumExtendedDynamicRangeColorComponentValue
                             potentialEDR:scr.maximumPotentialExtendedDynamicRangeColorComponentValue];
    // Static frames must be redrawn immediately to replace pixels encoded for the
    // previous output mode. During playing or opening, EDR activation can emit
    // repeated notifications, and a synchronous redraw may block in nextDrawable
    // for roughly 523 ms while the audio clock advances. Defer through a flag
    // consumed by tick: a new frame naturally uses the updated parameters, while
    // an idle tick redraws the latest frame when supply is sparse.
    if (_state == SPPlayerStatePlaying || _state == SPPlayerStateOpening) {
        _needsOutputModeRedraw.store(true);
    } else if (_lastFrameBuffer) {
        [_renderer renderPixelBuffer:_lastFrameBuffer];
    }

    [self notifyFrameInterpolationDidChange];

    id<SPPlayerCoreDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(playerCoreDidChangeXDRAvailability:)]) {
        [delegate playerCoreDidChangeXDRAvailability:self];
    }
}

- (void)captureScreenshotToPath:(NSString *)path completion:(void (^)(BOOL ok))completion {
    [self captureScreenshotToPath:path uniquify:NO completion:^(BOOL ok, NSString *finalPath) {
        if (completion) completion(ok);
    }];
}

static NSString *spClaimScreenshotPath(NSString *base) {
    NSString *ext = base.pathExtension;
    NSString *stem = base.stringByDeletingPathExtension;
    for (int serial = 1; serial < 1000; serial++) {
        NSString *cand = serial == 1 ? base
                                     : [NSString stringWithFormat:@"%@_%d.%@", stem, serial, ext];
        int fd = open(cand.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd >= 0) { close(fd); return cand; }
        if (errno != EEXIST) return nil;
    }
    return nil;
}

- (void)captureScreenshotToPath:(NSString *)path
                       uniquify:(BOOL)uniquify
                     completion:(void (^)(BOOL ok, NSString *finalPath))completion {
    if (!_lastFrameBuffer) {
        if (completion) completion(NO, path);
        return;
    }
    CVPixelBufferRef snapshot = CVPixelBufferRetain(_lastFrameBuffer);
    NSString *pathCopy = [path copy];
    // Save the frame upright, as the container's display matrix intends.
    const int rotation = _videoRotation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        static CIContext *sCtx;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sCtx = [CIContext context]; });
        BOOL ok = NO;
        NSString *target = pathCopy;
        BOOL claimed = NO;
        if (uniquify) {
            target = spClaimScreenshotPath(pathCopy);
            claimed = target != nil;
        }
        if (target) {

            CVPixelBufferRef ciSource = spCreateBiPlanarCopy(snapshot);
            CIImage *ci = ciSource ? [CIImage imageWithCVPixelBuffer:ciSource] : nil;
            if (ci && rotation) {
                ci = [ci imageByApplyingCGOrientation:
                    rotation == 90 ? kCGImagePropertyOrientationRight
                    : rotation == 180 ? kCGImagePropertyOrientationDown
                                      : kCGImagePropertyOrientationLeft];
            }
            CGImageRef cg = ci ? [sCtx createCGImage:ci fromRect:ci.extent] : NULL;
            if (ciSource) CVPixelBufferRelease(ciSource);
            if (cg) {
                NSURL *url = [NSURL fileURLWithPath:target];
                CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
                    (__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, NULL);
                if (dest) {
                    CGImageDestinationAddImage(dest, cg, NULL);
                    ok = CGImageDestinationFinalize(dest);
                    CFRelease(dest);
                }
                CGImageRelease(cg);
            }
            if (!ok && claimed) unlink(target.fileSystemRepresentation);
        }
        CVPixelBufferRelease(snapshot);
        NSString *finalPath = target ?: pathCopy;
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, finalPath); });
        }
    });
}

- (NSDictionary *)mediaInfo {
    return _mediaInfoSnapshot ?: @{};
}

- (void)clearVideoSurface {
    std::lock_guard<std::mutex> renderLock(_renderMtx);
    [_renderer clearToBlack];
}

- (BOOL)hasEverPresentedThisSession {
    return _sessionEverPresented.load();
}

- (BOOL)backgroundDirectoryScanReady {
    // Fill honestly, decide in one place: the complete admission rule lives
    // in spShouldAdmitBackgroundDirectoryScan (SPPlayerSessionPolicy.hpp).
    // Hand-copied early returns here previously drifted into two real bugs
    // (audio-only unreachable behind firstFramePending; short files starved
    // by the runway after demux EOF).
    if (!_running.load()) return NO;
    SPDirectoryScanAdmissionState scan;
    scan.running = true;
    scan.playing = (_state == SPPlayerStatePlaying);
    scan.paused = (_state == SPPlayerStatePaused);
    scan.ended = (_state == SPPlayerStateEnded);
    scan.audioOnly = _audioOnlySession.load();
    scan.demuxAtEOF = _demuxer && _demuxer->eof();
    scan.prefetch.alreadyIssued = false;
    scan.prefetch.currentOpenSession = _windowVisibleForRendering.load();
    scan.prefetch.audioOnly = scan.audioOnly;
    scan.prefetch.firstFramePending = _firstFramePending.load();
    scan.prefetch.committedThisSession =
        _renderer && _renderer.committedFrameCount > _openCommittedBase;
    scan.prefetch.submittedVideoGeneration =
        _lastSubmittedVideoGeneration.load(std::memory_order_acquire);
    scan.prefetch.currentSeekGeneration = _generation.load();
    scan.prefetch.seekPending = _seekPending.load();
    scan.prefetch.seekFramePending = _seekFramePending.load();
    scan.prefetch.catchUpPending = _catchUpTargetUs.valid();
    scan.prefetch.videoPacketCapacity =
        _videoPackets ? _videoPackets->capacity() : 0;
    scan.prefetch.videoPacketDepth = _videoPackets ? _videoPackets->size() : 0;
    scan.prefetch.nowUs = spNowUs();
    scan.prefetch.lastPresentationStarveUs = _presentStarveWallUs.load();
    return spShouldAdmitBackgroundDirectoryScan(scan);
}

- (void)setWindowVisibleForRendering:(BOOL)visible {
    _windowVisibleForRendering.store(visible);
    if (visible) {
        [_renderer setSubmitsSuspended:NO];
        [_renderer kickSubmitDrain];
    } else {
        [_renderer setSubmitsSuspended:YES];
    }
}

- (void)notePausedLayoutChange {
    if (_state == SPPlayerStatePlaying || !_lastFrameBuffer) return;
    CGSize px = [self currentViewportPx];
    if (px.width <= 0 || px.height <= 0) return;
    if (px.width == _lastViewportPx.width && px.height == _lastViewportPx.height) {
        return;
    }
    std::lock_guard<std::mutex> rlock(_renderMtx);
    [_renderer setViewportPixelSize:px];
    _lastViewportPx = px;

    [self updateSubtitleTextureForTime:_lastPresentedPtsUs];
    if (_lastFrameBuffer) [_renderer renderPixelBuffer:_lastFrameBuffer];
}

- (void)prewarmWindowDragEffect {
    [_renderer prewarmDragEffectPipelines];
}

- (void)setWindowDragEffectStrength:(float)strength colorStrength:(float)colorStrength anchorPx:(CGPoint)anchor {
    if (!_renderer) return;
    [_renderer setDragEffectStrength:strength colorStrength:colorStrength anchorPx:anchor];
    if (_state != SPPlayerStatePlaying && _lastFrameBuffer) {
        std::lock_guard<std::mutex> rlock(_renderMtx);
        [_renderer renderPixelBuffer:_lastFrameBuffer];
    }
}

static NSString *spCodecDisplayName(const std::string &name) {
    if (name.empty()) return nil;
    static NSDictionary<NSString *, NSString *> *table = @{
        @"hevc": @"HEVC", @"h264": @"H.264", @"av1": @"AV1", @"vp9": @"VP9", @"vp8": @"VP8",
        @"prores": @"ProRes", @"mpeg2video": @"MPEG-2", @"mpeg4": @"MPEG-4", @"vc1": @"VC-1",
        @"rv40": @"RealVideo 4", @"rv30": @"RealVideo 3", @"h263": @"H.263", @"dnxhd": @"DNxHD",
        @"mjpeg": @"MJPEG", @"vvc": @"VVC", @"theora": @"Theora", @"wmv3": @"WMV 9",
    };
    NSString *key = [NSString stringWithUTF8String:name.c_str()];
    return table[key] ?: key.uppercaseString;
}

- (NSDictionary *)buildMediaInfoSnapshot {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (_videoStreamIndex < 0) return d;
    const sp::StreamInfo &vs = _demuxer->streams()[_videoStreamIndex];
    d[NSLocalizedString(@"media.codec", nil)] = [NSString stringWithUTF8String:vs.codecLongName.c_str()];
    d[NSLocalizedString(@"media.resolution", nil)] = [NSString stringWithFormat:@"%d × %d", vs.width, vs.height];
    d[NSLocalizedString(@"media.fps", nil)] = [NSString stringWithFormat:@"%.2f fps", vs.fps];
    d[NSLocalizedString(@"media.bitrate", nil)] = vs.bitRate > 0 ? [NSString stringWithFormat:@"%.1f Mbps", vs.bitRate / 1e6]
                                : NSLocalizedString(@"media.value.unknown", nil);
    d[NSLocalizedString(@"media.duration", nil)] = [NSString stringWithFormat:NSLocalizedString(@"media.value.durationFmt", nil), _duration];
    NSString *unspecified = NSLocalizedString(@"media.value.unspecified", nil);
    NSString *colorNames[] = {unspecified, @"BT.709", unspecified, unspecified, unspecified, @"BT.470BG",
                              @"SMPTE170M", @"SMPTE240M", unspecified, @"BT.2020"};
    int pri = vs.colorPrimaries;
    d[NSLocalizedString(@"media.primaries", nil)] = (pri >= 0 && pri <= 9) ? colorNames[pri] : NSLocalizedString(@"media.value.unknown", nil);
    NSString *trcNames[] = {unspecified, @"BT.709", unspecified, unspecified, unspecified, unspecified,
                            @"SMPTE170M", @"SMPTE240M", @"Linear", unspecified, unspecified, unspecified,
                            unspecified, unspecified, @"BT.2020-10", @"BT.2020-12", @"PQ (HDR10)", unspecified, @"HLG"};
    int trc = vs.colorTrc;
    d[NSLocalizedString(@"media.trc", nil)] = (trc >= 0 && trc <= 18) ? trcNames[trc] : NSLocalizedString(@"media.value.unknown", nil);
    d[NSLocalizedString(@"media.depth", nil)] = [NSString stringWithFormat:@"%d-bit", vs.colorBits];

    NSString *hdrFmt = @"SDR";
    if (vs.isDovi) {
        hdrFmt = (vs.doviProfile == 8 && vs.doviBlCompatId > 0)
            ? [NSString stringWithFormat:@"Dolby Vision Profile 8.%d", vs.doviBlCompatId]
            : [NSString stringWithFormat:@"Dolby Vision Profile %d", vs.doviProfile];
    } else if (vs.hasHdr10Plus && vs.colorTrc == AVCOL_TRC_SMPTE2084) {
        hdrFmt = @"HDR10+";
    } else if (vs.colorTrc == AVCOL_TRC_SMPTE2084) {
        hdrFmt = @"HDR10";
    } else if (vs.colorTrc == AVCOL_TRC_ARIB_STD_B67) {
        hdrFmt = @"HLG";
    }
    d[NSLocalizedString(@"media.hdrFormat", nil)] = hdrFmt;
    _hdrDescription = hdrFmt;

    {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];

        _hdrCodecName = spCodecDisplayName(vs.codecName);
        NSString *fmtLine = hdrFmt;
        if (vs.isDovi) {
            NSString *compat = nil;
            switch (vs.doviBlCompatId) {
                case 1: compat = NSLocalizedString(@"hdr.compat.hdr10Base", nil); break;
                case 2: compat = NSLocalizedString(@"hdr.compat.sdrBase", nil); break;
                case 4: compat = NSLocalizedString(@"hdr.compat.hlgBase", nil); break;
                default: if (vs.doviProfile == 5) compat = NSLocalizedString(@"hdr.compat.iptNone", nil); break;
            }
            if (compat) fmtLine = [NSString stringWithFormat:NSLocalizedString(@"hdr.formatCompatFmt", nil), hdrFmt, compat];
            if (vs.hasHdr10Plus) fmtLine = [fmtLine stringByAppendingString:NSLocalizedString(@"hdr.plusSuffix", nil)];
        }
        [lines addObject:fmtLine];

        NSString *fpsStr = (vs.fps > 0)
            ? (fabs(vs.fps - round(vs.fps)) < 0.001
                   ? [NSString stringWithFormat:@"%.0f fps", vs.fps]
                   : [NSString stringWithFormat:@"%.3f fps", vs.fps])
            : NSLocalizedString(@"hdr.fpsUnknown", nil);
        [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"hdr.resolutionLineFmt", nil),
                          vs.width, vs.height, fpsStr]];
        NSString *gamut;
        switch (vs.colorPrimaries) {
            case AVCOL_PRI_BT2020:    gamut = @"BT.2020"; break;
            case AVCOL_PRI_SMPTE432:  gamut = @"P3-D65"; break;
            case AVCOL_PRI_SMPTE431:  gamut = @"P3-DCI"; break;
            case AVCOL_PRI_BT709:     gamut = @"BT.709"; break;
            case AVCOL_PRI_BT470BG:
            case AVCOL_PRI_SMPTE170M: gamut = @"BT.601"; break;
            default: gamut = NSLocalizedString(@"hdr.gamutUnknown", nil); break;
        }
        NSString *trcName = (vs.colorTrc == AVCOL_TRC_SMPTE2084) ? @"PQ"
                          : (vs.colorTrc == AVCOL_TRC_ARIB_STD_B67) ? @"HLG" : NSLocalizedString(@"hdr.sdrGamma", nil);
        [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"hdr.colorLineFmt", nil),
                          gamut, trcName, vs.colorBits]];
        if (vs.maxCll > 0) {
            [lines addObject:vs.maxFall > 0
                ? [NSString stringWithFormat:NSLocalizedString(@"hdr.peakAvgFmt", nil), vs.maxCll, vs.maxFall]
                : [NSString stringWithFormat:NSLocalizedString(@"hdr.peakFmt", nil), vs.maxCll]];
        }
        _hdrStaticDetail = [lines componentsJoinedByString:@"\n"];
    }
    if (vs.maxCll > 0) {
        d[NSLocalizedString(@"media.maxcll", nil)] = [NSString stringWithFormat:NSLocalizedString(@"media.value.maxcllFmt", nil), vs.maxCll];
        if (vs.maxFall > 0) d[NSLocalizedString(@"media.maxfall", nil)] = [NSString stringWithFormat:NSLocalizedString(@"media.value.maxfallFmt", nil), vs.maxFall];
    } else if (vs.colorTrc == AVCOL_TRC_SMPTE2084) {
        d[NSLocalizedString(@"media.maxcll", nil)] = NSLocalizedString(@"media.value.maxcllUnknown", nil);
    }
    d[NSLocalizedString(@"media.decoder", nil)] = _decoderNamePub ?: NSLocalizedString(@"media.value.none", nil);
    d[NSLocalizedString(@"media.container", nil)] = [NSString stringWithUTF8String:_demuxer->containerName().c_str()];
    int publishedAudioTrack = _currentAudioTrackPub.load();
    if (_hasAudio && publishedAudioTrack >= 0) {
        const sp::StreamInfo &as = _demuxer->streams()[publishedAudioTrack];
        NSString *audioDesc = as.channels > 0
            ? [NSString stringWithFormat:NSLocalizedString(@"media.value.audioChannelsFmt", nil), [NSString stringWithUTF8String:as.channelLayout.c_str()], as.channels]
            : NSLocalizedString(@"media.value.present", nil);

        std::string cn = as.codecName;
        if (cn == "eac3" || cn == "truehd") {
            audioDesc = [audioDesc stringByAppendingString:NSLocalizedString(@"media.value.maybeAtmos", nil)];
        }

        if (_audioActive && _audioOutput && [_audioOutput outputChannels] > 2) {
            audioDesc = [audioDesc stringByAppendingFormat:NSLocalizedString(@"media.value.audioOutputFmt", nil),
                         [_audioOutput outputLayoutName]];
        }
        d[NSLocalizedString(@"media.audio", nil)] = audioDesc;
    }
    return d;
}

- (void)setLoopPointA:(double)sec { _loopA = MAX(0.0, sec); }
- (void)setLoopPointB:(double)sec { _loopB = sec > 0 ? sec : 0.0; }
- (void)clearLoop { _loopA = -1; _loopB = -1; }

- (void)foldResumeSeekIntoPrepare {
    _preludeSeekDone = false;
    _preludeStartSeconds = 0;
    double startSec = _pendingStartSeconds;
    if (startSec > 0.5 && _duration > 0 && startSec < _duration - 1.0) {

        const int64_t tolUs = _videoStreamIndex >= 0
            ? sp::spSeekGridToleranceUs(_frameIntervalUs) : 0;
        if (_demuxer->seekToUs((int64_t)(startSec * 1e6), false, -1, nullptr,
                               tolUs) >= 0) {
            _preludeSeekDone = true;
            _preludeStartSeconds = startSec;
        } else {

            if (spDebug()) SPLOG(@"[Core] 续播 seek 失败 → 从头播放");
        }
    }
}

- (CGSize)currentViewportPx {
    CGFloat scale = _view.window ? _view.window.backingScaleFactor : 2.0;
    return CGSizeMake(_view.bounds.size.width * scale,
                      _view.bounds.size.height * scale);
}

- (void)wakeDecodeThread {
    {
        std::lock_guard<std::mutex> lock(_decodeMtx);
    }
    _decodeCv.notify_all();
}

- (void)stop {
    [self stopReleasingAudioScratch:NO];
}

- (void)closeMediaSession {
    [self stopReleasingAudioScratch:YES];
}

- (void)stopReleasingAudioScratch:(BOOL)releaseAudioScratch {

    const int64_t stopT0 = spNowUs();

    std::lock_guard<std::mutex> lifecycleLock(_lifecycleMtx);
    _openGeneration++;
    [self cancelIndexWait];
    if (_trialExecutor) _trialExecutor->cancelAll();

    _coarseLandingGen = -1;
    _settledCoarseLandingUs = -1;

    _pendingSpansUs.clear();
    _pendingScanInFlight = NO;
    _pendingScanLastUs = 0;
    _noContentSpansUs.clear();
    _mkvContentScanStarted = NO;
    _pubContentSearching = NO;
    _pubSourceGrowing = _pubSourceWaiting = _pubSourceStalled = NO;
    _pubSourcePathRev = 0;
    _damageSnapshotCache = nil;
    _damageNotifyPending = NO;
    _damageNotifyWallUs = 0;
    _durationExtended = NO;
    _durationSnapshotSec = 0;
    _seekHoleNotifiedGen = -1;
    // Invalidate before fencing/submission cleanup.  Any already-queued main
    // callback now fails closed, and a stale renderer completion cannot unlock
    // the next session because publication carries the full open generation.
    _rendererConfiguredOpenGeneration.store(-1, std::memory_order_release);
    [_thumbnailer shutdown];
    _thumbnailer = nil;

    _presentStarveWallUs.store(0);
    // A cold-open software race may already have passed its generation check
    // while holding _renderMtx. Waiting through the same lock guarantees no
    // cancelled frame can be submitted after stop returns/new open begins.
    {
        std::lock_guard<std::mutex> renderFence(_renderMtx);
    }
    [_audioOnlyTimer invalidate];
    _audioOnlyTimer = nil;
    _mediaInfoSnapshot = nil;
    _hdrDescription = nil;
    _decoderNamePub = nil;
    _hdrStaticDetail = nil;
    _hdrCodecName = nil;
    _audioTrackList = nil;
    _subtitleTrackList = nil;
    _generatedSubtitleActive.store(false);
    _currentSubtitleTrackPub = -1;
    _pendingAudioTrack.store(-2);
    _audioRebuildTrack.store(-2);
    _currentAudioTrackPub.store(-1);

    _loopA = -1;
    _loopB = -1;
    _frameStepAheadUs = 0;

    _demuxer->requestAbort();
    if (!_running) {
        if (_displayLink) { [_displayLink invalidate]; _displayLink = nil; }

        _videoPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
        _audioPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
        _frames->drain([](DecodedFrame f) { if (f.buffer) CVPixelBufferRelease(f.buffer); });
        spFrameQueueRelease(&_framesQueueClaimBytes);
        if (auto motionFrames = _motionFramesPublished.exchange(nullptr)) {
            motionFrames->drain([](DecodedFrame f) {
                if (f.buffer) CVPixelBufferRelease(f.buffer);
            });
            spFrameQueueRelease(&_motionQueueClaimBytes);
        }
        _frameInterpolationCommittedModeValue.store(SPFrameInterpolationModeOff);
        [_renderer discardPendingSubmits];
        _scrubHintPending.store(false);
        _scrubHintUs.store(-1);

        [self destroyMotionInterpolatorOnDecodeThread];
        [_generator discardReturnedFrames];
        _subLoadGen.fetch_add(1);
        [_subtitleRenderer resetTrack];
        [_renderer resetDoviSessionState];
        if (releaseAudioScratch) {
            [_audioOutput stop]; // also cancel a not-yet-ready unit's start request
            [_audioOutput releaseSessionScratch];
        }
        [self setState:SPPlayerStateIdle];
        return;
    }
    {

        std::lock_guard<std::mutex> lock(_interpolationTransitionMtx);
        _running = false;
    }
    _paused = false;
    _interpolationTransitionCv.notify_all();
    {
        std::lock_guard<std::mutex> lock(_stateMtx);
        _playCv.notify_all();
        _eofCv.notify_all();
    }
    {

        std::lock_guard<std::mutex> lock(_decodeMtx);
        _decodeCv.notify_all();
    }
    if (_audioOutput) [_audioOutput abortWrites];
    _videoPackets->close();
    _audioPackets->close();
    _frames->close();
    if (auto motionFrames = _motionFramesPublished.load()) motionFrames->close();

    const int64_t joinT0 = spNowUs();
    if (_demuxThread.joinable()) _demuxThread.join();
    const int64_t joinT1 = spNowUs();
    if (_decodeThread.joinable()) _decodeThread.join();
    const int64_t joinT2 = spNowUs();
    if (_audioThread.joinable()) _audioThread.join();
    const int64_t joinT3 = spNowUs();
    if (spDebug()) {
        SPLOG(@"[Stop] 前置=%.0fms join: demux=%.0fms decode=%.0fms audio=%.0fms",
              (joinT0 - stopT0) / 1000.0, (joinT1 - joinT0) / 1000.0,
              (joinT2 - joinT1) / 1000.0, (joinT3 - joinT2) / 1000.0);
    }

    // The stores before shutdown make the public state fail closed promptly,
    // but demux may already hold a non-negative pending track in a local and
    // publish rebuild/current after those stores. Joining is the ownership
    // boundary after which no worker can write this session state, so make the
    // stopped-session invariant final here. Demux cannot resurrect pending,
    // yet clearing it too also closes a caller racing before _running=false.
    _pendingAudioTrack.store(-2);
    _audioRebuildTrack.store(-2);
    _currentAudioTrackPub.store(-1);
    {

        std::lock_guard<std::mutex> lk(_audioParFixMtx);
        std::vector<uint8_t>().swap(_audioParFixBytes);
        _audioParFixTrack = -1;
        _audioParFixPending.store(false, std::memory_order_relaxed);
    }

    if (_lastFrameBuffer) { CVPixelBufferRelease(_lastFrameBuffer); _lastFrameBuffer = NULL; }
    if (_compareRealFrame) { CVPixelBufferRelease(_compareRealFrame); _compareRealFrame = NULL; }
    _compareRealFrameGen = -1;
    if (_rendererCompareActive) { [_renderer setCompareBuffer:NULL]; _rendererCompareActive = false; }
    _presentRetryPending = NO;
    _presentRetryCompletesPausedSeek = NO;
    _lastFrameGeneration = -1;
    _lastFrameSynthetic = NO;
    _lastFrameInterpolationEpoch = 0;
    _videoPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
    _audioPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
    _frames->drain([](DecodedFrame f) { if (f.buffer) CVPixelBufferRelease(f.buffer); });

    spFrameQueueRelease(&_framesQueueClaimBytes);
    if (auto motionFrames = _motionFramesPublished.exchange(nullptr)) {
        motionFrames->drain([](DecodedFrame f) {
            if (f.buffer) CVPixelBufferRelease(f.buffer);
        });
        spFrameQueueRelease(&_motionQueueClaimBytes);
    }
    _frameInterpolationCommittedModeValue.store(SPFrameInterpolationModeOff);
    _videoPackets->reopen();
    _audioPackets->reopen();
    _frames->reopen();

    [_renderer discardPendingSubmits];

    _scrubHintPending.store(false);
    _scrubHintUs.store(-1);

    if (_displayLink) { [_displayLink invalidate]; _displayLink = nil; }
    _seekDisplayTargetUs.clear();
    _seekFramePending.store(false);
    _needsOutputModeRedraw.store(false);
    _seekFlashDone.store(true);
    _firstFramePending.store(false);
    _seekMailbox.invalidate();
    _subLoadGen.fetch_add(1);
    [_subtitleRenderer resetTrack];

    [_renderer resetDoviSessionState];

    _renderer.subtitleTexture = nil;

    std::unordered_set<uint64_t>().swap(_subSeenEvents);
    _subCueBytes = 0;
    _subCueCount = 0;
    if (_audioOutput) [_audioOutput stop];
    if (releaseAudioScratch) [_audioOutput releaseSessionScratch];
    if (_audioDecoder) [_audioDecoder shutdown];
    _subtitleActive = NO;
    _subtitleIsSRT = NO;
    _subtitleIsMovText = NO;
    _subtitleIsVTT = NO;
    [_decoder shutdown];
    if (_videoParCopy) avcodec_parameters_free(&_videoParCopy);
    if (_thumbVideoPar) avcodec_parameters_free(&_thumbVideoPar);
    _demuxer->close();
    [self setState:SPPlayerStateIdle];
}

#pragma mark - Track selection

static NSString *spLangDisplayName(const std::string &lang) {
    if (lang.empty()) return nil;
    static NSDictionary<NSString *, NSString *> *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{@"chi": NSLocalizedString(@"lang.zh", nil), @"zho": NSLocalizedString(@"lang.zh", nil), @"chs": NSLocalizedString(@"lang.zhHans", nil), @"cht": NSLocalizedString(@"lang.zhHant", nil),
              @"eng": NSLocalizedString(@"lang.en", nil), @"jpn": NSLocalizedString(@"lang.ja", nil), @"kor": NSLocalizedString(@"lang.ko", nil), @"fra": NSLocalizedString(@"lang.fr", nil),
              @"fre": NSLocalizedString(@"lang.fr", nil), @"deu": NSLocalizedString(@"lang.de", nil), @"ger": NSLocalizedString(@"lang.de", nil), @"spa": NSLocalizedString(@"lang.es", nil),
              @"rus": NSLocalizedString(@"lang.ru", nil), @"ita": NSLocalizedString(@"lang.it", nil), @"por": NSLocalizedString(@"lang.pt", nil), @"tha": NSLocalizedString(@"lang.th", nil),
              @"vie": NSLocalizedString(@"lang.vi", nil), @"ara": NSLocalizedString(@"lang.ar", nil), @"hin": NSLocalizedString(@"lang.hi", nil), @"und": NSLocalizedString(@"lang.unknown", nil)};
    });
    NSString *tag = [NSString stringWithUTF8String:lang.c_str()].lowercaseString;
    return m[tag] ?: tag;
}

- (SPPreparedTrackSnapshot *)buildTrackSnapshotsWithContext:(AVFormatContext *)ctx {
    for (auto &kv : _audioParCopies) avcodec_parameters_free(&kv.second);
    _audioParCopies.clear();
    _audioTrackTimeBases.clear();
    _subTrackMeta.clear();
    NSMutableDictionary<NSNumber *, NSData *> *subPriv = [NSMutableDictionary dictionary];
    NSMutableArray *alist = [NSMutableArray array];
    NSMutableArray *slist = [NSMutableArray array];
    for (const sp::StreamInfo &si : _demuxer->streams()) {
        if (si.index < 0 || si.index >= (int)ctx->nb_streams) continue;
        AVStream *s = ctx->streams[si.index];
        NSString *lang = spLangDisplayName(si.language);
        NSString *title = si.title.empty() ? nil : [NSString stringWithUTF8String:si.title.c_str()];
        if (si.type == AVMEDIA_TYPE_AUDIO) {
            AVCodecParameters *pc = avcodec_parameters_alloc();
            if (!pc) continue;
            if (avcodec_parameters_copy(pc, s->codecpar) < 0) {
                avcodec_parameters_free(&pc);
                continue;
            }
            _audioParCopies[si.index] = pc;
            _audioTrackTimeBases[si.index] = s->time_base;

            NSMutableArray *parts = [NSMutableArray array];
            [parts addObject:title ?: lang ?: [NSString stringWithFormat:NSLocalizedString(@"track.audioFmt", nil), alist.count + 1]];
            if (title && lang) [parts addObject:lang];
            if (!si.codecName.empty()) {
                NSString *cn = [NSString stringWithUTF8String:si.codecName.c_str()].uppercaseString;
                [parts addObject:si.channels > 0
                    ? [NSString stringWithFormat:NSLocalizedString(@"track.audioChannelsFmt", nil), cn, si.channels] : cn];
            }
            [alist addObject:@{@"index": @(si.index),
                               @"title": [parts componentsJoinedByString:@" · "]}];
        } else if (si.type == AVMEDIA_TYPE_SUBTITLE && si.isTextSubtitle) {
            _subTrackMeta[si.index] = { (int)s->codecpar->codec_id, s->time_base };
            if ((s->codecpar->codec_id == AV_CODEC_ID_ASS ||
                 s->codecpar->codec_id == AV_CODEC_ID_SSA) &&
                s->codecpar->extradata && s->codecpar->extradata_size > 0) {
                subPriv[@(si.index)] = [NSData dataWithBytes:s->codecpar->extradata
                                                      length:(NSUInteger)s->codecpar->extradata_size];
            }
            [slist addObject:@{@"index": @(si.index),
                               @"title": title ?: lang ?:
                                   [NSString stringWithFormat:NSLocalizedString(@"track.subtitleFmt", nil), slist.count + 1]}];
        }
    }
    _subTrackPrivate = subPriv;
    return [[SPPreparedTrackSnapshot alloc]
        initWithAudioTracks:alist
             subtitleTracks:slist
     initialAudioTrackIndex:_audioStreamIndex
  initialSubtitleTrackIndex:(_subtitleStreamIndex >= 0) ? _subtitleStreamIndex : -1];
}

- (NSArray<NSDictionary *> *)audioTrackList { return _audioTrackList ?: @[]; }
- (NSArray<NSDictionary *> *)subtitleTrackList { return _subtitleTrackList ?: @[]; }
- (NSInteger)currentAudioTrackIndex {
    int p = _pendingAudioTrack.load();
    return spResolvePublishedAudioTrack(p, _currentAudioTrackPub.load());
}
- (NSInteger)currentSubtitleTrackIndex { return _currentSubtitleTrackPub; }
- (NSString *)hdrDescription { return _hdrDescription; }
- (NSString *)hdrDetailDescription {
    if (!_hdrStaticDetail) return nil;

    NSString *dec = _decoderNamePub ?: _preparedDecoderName;
    NSString *head = (_hdrCodecName && dec) ? [NSString stringWithFormat:@"%@ · %@", _hdrCodecName, dec]
                                            : (_hdrCodecName ?: dec);
    NSString *body = head ? [NSString stringWithFormat:@"%@\n%@", head, _hdrStaticDetail] : _hdrStaticDetail;
    return [NSString stringWithFormat:NSLocalizedString(@"hdr.outputLineFmt", nil),
            body, [_renderer outputModeDescription]];
}
- (double)subtitleScale { return _subtitleScale; }

- (void)handleAudioOutputLayoutChange {
    if (!_audioOutput || ![_audioOutput outputLayoutChangePending]) return;
    if (_state == SPPlayerStateOpening) return;
    [_audioOutput applyPendingOutputLayout];
    if (!_running.load() || !_hasAudio || !_audioActive) return;
    if (spDebug()) SPLOG(@"[Audio] 输出布局变化 → %@：原地 seek 重灌环，解码器由音频线程重建", [_audioOutput outputLayoutDescription]);
    if (_state != SPPlayerStateEnded) [self seekTo:_position precise:YES];
}

- (void)selectAudioTrackAtIndex:(NSInteger)streamIndex {
    if (!_running.load() || !_hasAudio) return;
    if (_audioTrackTimeBases.find((int)streamIndex) == _audioTrackTimeBases.end()) return;
    if (streamIndex == self.currentAudioTrackIndex) return;

    if (!_audioActive && ![self activateDormantAudioPipelineForTrack:(int)streamIndex]) return;
    _pendingAudioTrack.store((int)streamIndex);
    if (spDebug()) SPLOG(@"[Track] 请求切换音轨 → 流#%ld", (long)streamIndex);

    if (_state != SPPlayerStateEnded) [self seekTo:_position precise:YES];
}

- (BOOL)activateDormantAudioPipelineForTrack:(int)streamIndex {
    if (_audioThread.joinable() || _audioOnlySession.load()) return NO;
    auto itp = _audioParCopies.find(streamIndex);
    auto itt = _audioTrackTimeBases.find(streamIndex);
    if (itp == _audioParCopies.end() || itt == _audioTrackTimeBases.end()) return NO;
    SPAudioOutput *ao = [self ensureAudioOutput];
    if (!ao) return NO;
    SPAudioDecoder *nd = [[SPAudioDecoder alloc] init];
    nd.spLogId = _spLogId;
    if ([nd setupWithCodecParameters:itp->second outputChannelMask:[ao outputChannelMask]] != 0) {
        SPLOG(@"[Track] 音频管线未建立，流#%d 解码器也建不出来：保持静音", streamIndex);
        return NO;
    }
    if (_audioDecoder) [_audioDecoder shutdown];
    _audioDecoder = nd;
    _audioTimeBase = itt->second;
    [ao setVolume:(_muted ? 0.0f : (float)_volume)];
    [ao reset];
    _audioRateSwitchFrames = -1;
    _audioRateSwitchPending = NO;
    _audioActive = YES;
    [self resilientInvalidateSnapshot];
    _audioThread = std::thread([self] { [self audioLoop]; });
    if (_state == SPPlayerStatePlaying) [ao start];
    SPLOG(@"[Resilient] 音频管线原本未建立（初始 setup 失败）：按流#%d 建立解码器并启动音频线程", streamIndex);
    SP_RESLOG(@"手动选择音轨 流#%d：音频管线从静音状态建立", streamIndex);
    return YES;
}

static bool spFlacConfigCandidateForStream(const std::string &path, int streamIndex, std::vector<uint8_t> &extradataOut, std::string &what,
                                           const sptrial::InterruptCtx &ic, sptrial::Stats *statsOut) {
    sptrial::Stats stats;
    AVFormatContext *fc = sptrial::openInput(path, const_cast<sptrial::InterruptCtx *>(&ic));
    if (!fc) { stats.outcome = ic.cancelled() ? sptrial::Outcome::Cancelled : sptrial::Outcome::OpenFailed; if (statsOut) *statsOut = stats; return false; }
    bool ok = false;
    if ((unsigned)streamIndex < fc->nb_streams && fc->streams[streamIndex]->codecpar->codec_id == AV_CODEC_ID_FLAC &&
        fc->streams[streamIndex]->codecpar->extradata_size >= 34) {
        const AVCodecParameters *par = fc->streams[streamIndex]->codecpar;
        std::vector<spresil::FlacFrameHeader> frames;
        bool broken = false;
        sptrial::Budget b;
        b.maxTargetPkts = 48; b.maxAnyPkts = 4096; b.maxBytes = 32ll << 20; b.maxWallUs = 1500000;
        const bool complete = sptrial::forEachPacket(fc, streamIndex, b, stats, ic, [&](AVPacket *pkt) {
            spresil::FlacFrameHeader h;
            if (!pkt->data || !spresil::flacParseFrameHeader(pkt->data, (size_t)pkt->size, h) || !spresil::flacFrameCrc16Ok(pkt->data, (size_t)pkt->size)) {
                broken = true;
                return false;
            }
            frames.push_back(h);
            return true;
        });
        if (complete && !broken && !frames.empty()) ok = spresil::flacStreamInfoCandidate(par->extradata, (size_t)par->extradata_size, frames, extradataOut, what);
        if (!complete) stats.outcome = stats.outcome == sptrial::Outcome::Insufficient ? sptrial::Outcome::ReadFailed : stats.outcome;
    } else {
        stats.outcome = sptrial::Outcome::OpenFailed;
    }
    avformat_close_input(&fc);
    if (statsOut) *statsOut = stats;
    return ok;
}

static NSString *spTrialSummary(const sptrial::Stats &s) {
    return [NSString stringWithFormat:@"%lld 样本（干净 %lld）/ %d 错 / %d 掩错帧，%s，目标 %d 包 / 读 %d 包 %.1f MiB / %.1fms",
            (long long)s.samples, (long long)s.cleanSamples, s.sendErrors, s.flaggedFrames, sptrial::outcomeName(s.outcome),
            s.targetPkts, s.anyPkts, s.bytes / 1048576.0, s.wallUs / 1000.0];
}

struct SPAudioRecoveryRequest {
    std::string path;
    int track = -1;
    AVCodecID codecId = AV_CODEC_ID_NONE;
    std::vector<int> alternates;
    int64_t openGen = -1;
    int64_t seekGen = -1;
    int64_t failUs = -1;
    double failSec = 0;
    bool neverVoiced = false;

    bool openedIdentity = false;
    uint64_t openedDev = 0, openedIno = 0;
    int64_t openedSize = -1, openedMtimeNs = 0;
};
struct SPAudioRecoveryResult {
    bool flacTried = false;
    bool flacCandidate = false;
    std::vector<uint8_t> candidate;
    std::string what;
    sptrial::Stats flacStats;
    sptrial::Stats candidateStats;
    std::vector<std::pair<int, sptrial::Stats>> alternateStats;
    int alternate = -1;
    bool cancelled = false;

    sptrial::SourceIdentity source;
    bool sourceOk = false;
    const char *sourceWhy = "";
};

static bool spAudioRecoverySourceMatches(const SPAudioRecoveryRequest &req, SPAudioRecoveryResult &res) {
    if (!sptrial::captureSource(req.path, res.source)) { res.sourceWhy = "无法取得源身份"; return false; }
    if (req.openedIdentity && (res.source.dev != req.openedDev || res.source.ino != req.openedIno || res.source.size != req.openedSize ||
                               res.source.mtimeNs != req.openedMtimeNs)) {
        res.sourceWhy = "路径已不是本会话打开的文件";
        return false;
    }
    return true;
}

static void spAudioRecoveryTrial(const SPAudioRecoveryRequest &req, const std::atomic<bool> &cancelled, SPAudioRecoveryResult &res) {
    sptrial::InterruptCtx ic;
    ic.cancel = &cancelled;
    if (req.codecId == AV_CODEC_ID_FLAC) {
        ic.deadlineUs = sptrial::monotonicNowUs() + 1500000;
        std::vector<uint8_t> cand;
        res.flacTried = true;
        if (spFlacConfigCandidateForStream(req.path, req.track, cand, res.what, ic, &res.flacStats)) {
            sptrial::Budget b;
            b.maxTargetPkts = 16; b.maxAnyPkts = 2048; b.maxBytes = 32ll << 20; b.maxWallUs = 2000000;
            ic.deadlineUs = sptrial::monotonicNowUs() + b.maxWallUs;
            res.candidateStats = sptrial::audioTrialDecode(req.path, req.track, cand.data(), (int)cand.size(), b, ic);
            const sptrial::Stats &st = res.candidateStats;
            if (st.outcome == sptrial::Outcome::Evidence && st.cleanSamples > 0 && st.sendErrors == 0 && st.flaggedFrames == 0) {
                res.flacCandidate = true;
                res.candidate = std::move(cand);
                return;
            }
            if (st.outcome == sptrial::Outcome::Cancelled) { res.cancelled = true; return; }
        } else if (res.flacStats.outcome == sptrial::Outcome::Cancelled) {
            res.cancelled = true;
            return;
        }
    }
    if (!req.neverVoiced) return;
    for (int idx : req.alternates) {
        if (cancelled.load(std::memory_order_acquire)) { res.cancelled = true; return; }
        sptrial::Budget b;
        b.maxTargetPkts = 8; b.maxAnyPkts = 1024; b.maxBytes = 16ll << 20; b.maxWallUs = 1500000;
        ic.deadlineUs = sptrial::monotonicNowUs() + b.maxWallUs;
        const sptrial::Stats st = sptrial::audioTrialDecode(req.path, idx, nullptr, 0, b, ic);
        res.alternateStats.emplace_back(idx, st);
        if (st.outcome == sptrial::Outcome::Cancelled) { res.cancelled = true; return; }

        if (st.cleanSamples > 0 && st.sendErrors == 0) { res.alternate = idx; return; }
    }
}

- (BOOL)repairFlacStreamInfoInPlace:(AVCodecParameters *)apar streamIndex:(int)idx {
    NSString *path = _prepPath;
    if (!path || !apar || apar->extradata_size < 34) return NO;

    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    sptrial::InterruptCtx ic;
    ic.abort = [self, og] { return _openGeneration.load(std::memory_order_acquire) != og; };
    ic.deadlineUs = sptrial::monotonicNowUs() + 1500000;
    std::vector<uint8_t> cand;
    std::string what;
    sptrial::Stats readStats;
    const int64_t t0 = spNowUs();
    if (!spFlacConfigCandidateForStream(path.UTF8String, idx, cand, what, ic, &readStats)) {
        if (spDebug() && readStats.outcome != sptrial::Outcome::Insufficient)
            SPLOG(@"[Resilient] FLAC 流#%d 候选读取未完成：%@", idx, spTrialSummary(readStats));
        return NO;
    }
    sptrial::Budget b;
    b.maxTargetPkts = 16; b.maxAnyPkts = 2048; b.maxBytes = 32ll << 20; b.maxWallUs = 2000000;
    ic.deadlineUs = sptrial::monotonicNowUs() + b.maxWallUs;
    const sptrial::Stats st = sptrial::audioTrialDecode(path.UTF8String, idx, cand.data(), (int)cand.size(), b, ic);
    NSString *whatS = [NSString stringWithUTF8String:what.c_str()] ?: @"?";
    SPLOG(@"[Resilient] FLAC 流#%d 解码器建不出来，STREAMINFO 与完整帧链矛盾（%@）：候选私有试解 %.1fms → %@",
          idx, whatS, (spNowUs() - t0) / 1000.0, spTrialSummary(st));
    if (st.outcome != sptrial::Outcome::Evidence || st.cleanSamples <= 0 || st.sendErrors != 0 || st.flaggedFrames != 0) return NO;
    if (_openGeneration.load(std::memory_order_acquire) != og) return NO;
    uint8_t *e = (uint8_t *)av_mallocz(cand.size() + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!e) return NO;
    memcpy(e, cand.data(), cand.size());
    av_freep(&apar->extradata);
    apar->extradata = e;
    apar->extradata_size = (int)cand.size();

    auto itc = _audioParCopies.find(idx);
    if (itc != _audioParCopies.end() && itc->second) {
        uint8_t *ce = (uint8_t *)av_mallocz(cand.size() + AV_INPUT_BUFFER_PADDING_SIZE);
        if (ce) {
            memcpy(ce, cand.data(), cand.size());
            av_freep(&itc->second->extradata);
            itc->second->extradata = ce;
            itc->second->extradata_size = (int)cand.size();
        } else {
            SPLOG(@"[Resilient] FLAC 流#%d 参数副本改写分配失败：副本仍是原 STREAMINFO（之后按副本重建会失败并保留原解码器）", idx);
        }
    }
    SP_RESLOG(@"音轨 流#%d 的 FLAC STREAMINFO 与帧头矛盾（%@）：按帧头证据修正参数后建立解码器", idx, whatS);
    return YES;
}

- (void)applyAudioRecoveryResult:(std::shared_ptr<SPAudioRecoveryResult>)res request:(std::shared_ptr<SPAudioRecoveryRequest>)req cancelled:(BOOL)cancelled {
    NSString *whatS = [NSString stringWithUTF8String:res->what.c_str()] ?: @"?";
    if (res->flacTried) {
        SPLOG(@"[Resilient] FLAC 流#%d STREAMINFO 与完整帧链%s（%@）：候选读取 %@；候选私有试解 %@", req->track,
              res->flacStats.outcome == sptrial::Outcome::Insufficient || res->candidateStats.targetPkts > 0 ? "矛盾" : "核对未完成", whatS,
              spTrialSummary(res->flacStats), spTrialSummary(res->candidateStats));
    }
    for (const auto &kv : res->alternateStats) SPLOG(@"[Resilient] 备用音轨 流#%d 私有试解 → %@", kv.first, spTrialSummary(kv.second));
    if (cancelled || res->cancelled || _openGeneration.load(std::memory_order_acquire) != req->openGen || !_running.load() || !_hasAudio || !_audioActive) {
        SPLOG(@"[Resilient] 音轨恢复结果已过期（取消/会话已换）：丢弃");
        return;
    }
    if (_state == SPPlayerStateIdle || _state == SPPlayerStateOpening || _state == SPPlayerStateFailed) return;
    if (_currentAudioTrackPub.load() != req->track) { SPLOG(@"[Resilient] 音轨恢复结果作废：选轨已变（%d → %d）", req->track, _currentAudioTrackPub.load()); return; }
    if (_generation.load() != req->seekGen) {
        SPLOG(@"[Resilient] 音轨恢复结果作废：试解期间发生 seek，放弃本次（再次连续失败会重新请求）");
        _audioRecoveryRequested.store(false);
        return;
    }

    if (!res->sourceOk) { SPLOG(@"[Resilient] 音轨恢复结果作废：%@", [NSString stringWithUTF8String:res->sourceWhy] ?: @"?"); return; }
    if (res->flacCandidate) {

        if (_audioParCopies.find(req->track) == _audioParCopies.end() || res->candidate.empty()) return;
        try {
            std::lock_guard<std::mutex> lk(_audioParFixMtx);
            _audioParFixBytes = res->candidate;
            _audioParFixTrack = req->track;
            _audioParFixOpenGen = req->openGen;
        } catch (const std::bad_alloc &) { return; }
        _audioParFixPending.store(true, std::memory_order_release);
        _audioRebuildTrack.store(req->track);
        SP_RESLOG(@"音轨 流#%d 的 FLAC STREAMINFO 与帧头矛盾（%@）：按帧头证据修正参数副本，从 %.2fs 重放", req->track, whatS, req->failSec);
        [self seekTo:req->failSec precise:YES];
        return;
    }
    if (res->alternate >= 0) {
        if (_audioSessionPcmFrames.load() > 0) { SPLOG(@"[Resilient] 备用音轨结果作废：试解期间当前轨已出声"); return; }
        SP_RESLOG(@"所选音轨（流#%d）解码器建得出却解不出任何声音，改用文件里另一条可解音轨（流#%d），从 %.2fs 重放", req->track, res->alternate, req->failSec);
        _pendingAudioTrack.store(res->alternate);
        [self seekTo:req->failSec precise:YES];
        return;
    }
    SPLOG(@"[Resilient] 音轨 流#%d 持续解码失败，无配置候选也无可解备用轨：保持静音", req->track);
}

- (void)applyPendingAudioParFixOnAudioThread {
    int track = -1;
    int64_t og = -1;
    std::vector<uint8_t> bytes;
    {
        std::lock_guard<std::mutex> lk(_audioParFixMtx);
        if (!_audioParFixPending.load(std::memory_order_relaxed)) return;
        track = _audioParFixTrack;
        og = _audioParFixOpenGen;
        bytes.swap(_audioParFixBytes);
        _audioParFixPending.store(false, std::memory_order_relaxed);
    }
    if (bytes.empty() || og != _openGeneration.load(std::memory_order_acquire)) return;
    auto itp = _audioParCopies.find(track);
    if (itp == _audioParCopies.end() || !itp->second) return;
    uint8_t *e = (uint8_t *)av_mallocz(bytes.size() + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!e) {
        SPLOG(@"[Resilient] 音轨 流#%d 参数副本改写分配失败：保持原参数", track);
        return;
    }
    memcpy(e, bytes.data(), bytes.size());
    av_freep(&itp->second->extradata);
    itp->second->extradata = e;
    itp->second->extradata_size = (int)bytes.size();
}

- (void)recoverAudioAfterDecodeFailureAtUs:(int64_t)failUs openGen:(int64_t)openGen {
    if (_openGeneration.load(std::memory_order_acquire) != openGen || !_running.load() || !_hasAudio || !_audioActive) return;
    if (_state == SPPlayerStateIdle || _state == SPPlayerStateOpening || _state == SPPlayerStateFailed) return;
    const int cur = _currentAudioTrackPub.load();
    NSString *path = [_currentFilePath copy];
    auto itp = _audioParCopies.find(cur);
    if (!path || itp == _audioParCopies.end()) return;
    auto req = std::make_shared<SPAudioRecoveryRequest>();
    req->path = path.UTF8String;
    req->track = cur;
    req->codecId = itp->second->codec_id;
    req->openGen = openGen;
    req->seekGen = _generation.load();
    req->failUs = failUs;
    req->failSec = failUs >= 0 ? MAX(0.0, (failUs - _timelineOriginUs) / 1e6) : 0.0;
    req->neverVoiced = _audioSessionPcmFrames.load() == 0;
    for (const auto &kv : _audioParCopies) {
        const int idx = kv.first;
        if (idx == cur || !avcodec_find_decoder(kv.second->codec_id) || _audioTrackTimeBases.find(idx) == _audioTrackTimeBases.end()) continue;
        req->alternates.push_back(idx);
    }
    if (req->codecId != AV_CODEC_ID_FLAC && (!req->neverVoiced || req->alternates.empty())) {
        SPLOG(@"[Resilient] 音轨 流#%d 持续解码失败，无配置候选也无可解备用轨：保持静音", cur);
        return;
    }

    req->openedIdentity = _demuxer->openSourceIdentity(req->openedDev, req->openedIno, req->openedSize, req->openedMtimeNs);
    if (!_trialExecutor) _trialExecutor = std::make_unique<sptrial::Executor>(4);
    __weak SPPlayerCore *weakSelf = self;
    auto token = _trialExecutor->submit([weakSelf, req](const std::atomic<bool> &cancelled) {
        auto res = std::make_shared<SPAudioRecoveryResult>();
        if (spAudioRecoverySourceMatches(*req, *res)) {
            spAudioRecoveryTrial(*req, cancelled, *res);

            if (!cancelled.load(std::memory_order_acquire) && !res->cancelled) {
                res->sourceOk = sptrial::sourceUnchanged(res->source);
                if (!res->sourceOk) res->sourceWhy = "同路径文件已被替换";
            }
        }
        const BOOL wasCancelled = cancelled.load(std::memory_order_acquire);
        dispatch_async(dispatch_get_main_queue(), ^{
            SPPlayerCore *s = weakSelf;
            if (s) [s applyAudioRecoveryResult:res request:req cancelled:wasCancelled];
        });
    });
    if (!token) SPLOG(@"[Resilient] 音轨恢复：试解执行器排队已满，本次不试");
    else SPLOG(@"[Resilient] 音轨 流#%d 恢复请求已投给试解执行器（FLAC 候选 %s，备用轨 %zu 条，从未出声 %d）", cur,
               req->codecId == AV_CODEC_ID_FLAC ? "是" : "否", req->alternates.size(), (int)req->neverVoiced);
}

- (void)flacDurationCheckAfterEofWithGen:(int64_t)gen {
    if (!_audioDecoder || !_audioDecoder.nativeMd5Enabled) return;
    uint8_t md5[16];
    uint64_t samples = 0;
    if (![_audioDecoder nativeMd5Digest:md5 samples:&samples] || samples == 0) return;
    auto itp = _audioParCopies.find(_audioStreamIndex);
    if (itp == _audioParCopies.end() || !itp->second->extradata || itp->second->extradata_size < 34) return;
    spresil::FlacStreamInfo info;
    if (!spresil::flacParseStreamInfo(itp->second->extradata, (size_t)itp->second->extradata_size, info)) return;

    if (info.md5Present() && memcmp(info.md5, md5, 16) != 0) _endTruncationEvidence.store(true, std::memory_order_relaxed);
    if (!info.md5Present() || memcmp(info.md5, md5, 16) != 0 || info.totalSamples == 0 || info.totalSamples == samples || info.sampleRate == 0) return;
    const double newDur = (double)samples / (double)info.sampleRate;
    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_openGeneration.load(std::memory_order_acquire) != og || self->_generation.load() != gen) return;
        if (fabs(newDur - self->_duration) <= 0.5) return;
        SP_RESLOG(@"FLAC 总样本数声明 %llu 与实际解出 %llu 矛盾，而全流 MD5 与原存值相等：时长 %.2fs → %.2fs",
                            (unsigned long long)info.totalSamples, (unsigned long long)samples, self->_duration, newDur);
        self->_duration = newDur;
        [self notifyPosition];
        [self resilientInvalidateSnapshot];
    });
}

- (BOOL)requestAlternateVideoTrackReopenWithReason:(NSString *)why pending:(BOOL *)pending {
    if (pending) *pending = NO;
    if (!_demuxer || _videoStreamIndex < 0 || _videoIsAttachedPic) return NO;
    if (_videoAltRetryRequested.exchange(true)) return NO;
    const int cur = _videoStreamIndex;

    const int alt = _demuxer->alternateVideoStream(cur);
    if (alt == sp::Demuxer::kAlternateVideoUnknown) {
        _videoAltRetryRequested.store(false);
        if (pending) *pending = YES;
        if (!_videoAltPendingLogged.exchange(true))
            SPLOG(@"[Resilient] %@：demux 正在原地重开，备用视频轨查询暂无结论（稍后再触发时重查）", why);
        return NO;
    }
    if (alt < 0) return NO;
    const int64_t gen = _openGeneration.load();
    SPLOG(@"[Resilient] %@：视频轨 流#%d 不可解而文件另有视频轨 流#%d → 排除后重开", why, cur, alt);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_openGeneration.load() != gen) return;
        NSString *path = [self->_currentFilePath copy];
        if (!path) return;
        std::set<int> ex = self->_sessionExcludedVideo;
        ex.insert(cur);
        self->_pendingExcludedVideo = ex;
        self->_pendingExcludedVideoPath = path;
        const double pos = MAX(0.0, self->_position);
        SP_RESLOG(@"视频轨（流#%d）不可解，改用文件里另一条视频轨（流#%d）重开 @%.1fs", cur, alt, pos);
        [self openMediaAtURL:[NSURL fileURLWithPath:path] startAt:pos error:nil];
    });
    return YES;
}

- (void)selectSubtitleTrackAtIndex:(NSInteger)streamIndex {
    if (!_running.load()) return;
    _subLoadGen.fetch_add(1);
    _generatedSubtitleActive.store(false);
    if (streamIndex < 0) {
        {
            std::lock_guard<std::mutex> lk(_subSwitchMtx);
            _subtitleActive = NO;
            _currentSubtitleTrackPub = -1;
        }
        _streamDiscardDirty.store(true);
        [_subtitleRenderer resetTrack];
        _renderer.subtitleTexture = nil;
        [self refreshSubtitleDisplay];
        if (spDebug()) SPLOG(@"[Track] 字幕已关闭");
        return;
    }
    auto it = _subTrackMeta.find((int)streamIndex);
    if (it == _subTrackMeta.end()) return;
    if (streamIndex == _currentSubtitleTrackPub && _subtitleActive) return;
    {
        std::lock_guard<std::mutex> lk(_subSwitchMtx);
        _subtitleActive = NO;
        [_subtitleRenderer resetTrack];
        _renderer.subtitleTexture = nil;

        NSData *priv = _subTrackPrivate[@(streamIndex)];
        if (priv) [_subtitleRenderer setCodecPrivate:priv];
        _subtitleStreamIndex = (int)streamIndex;
        _subtitleTimeBase = it->second.tb;
        int cid = it->second.codecId;
        _subtitleIsSRT = (cid == AV_CODEC_ID_SUBRIP);
        _subtitleIsMovText = (cid == AV_CODEC_ID_MOV_TEXT);
        _subtitleIsVTT = (cid == AV_CODEC_ID_WEBVTT);
        _subReadOrder = 0;
        std::unordered_set<uint64_t>().swap(_subSeenEvents);
        _subCueBytes = 0;
        _subCueCount = 0;
        _subCapExceeded = NO;
        _currentSubtitleTrackPub = streamIndex;
        _subtitleActive = YES;
    }
    _streamDiscardDirty.store(true);
    if (spDebug()) SPLOG(@"[Track] 字幕轨切换 → 流#%ld", (long)streamIndex);

    if (_state != SPPlayerStateEnded) [self seekTo:_position precise:YES];
}

- (void)setSubtitleScale:(double)scale {
    double s = MAX(0.25, MIN(scale, 3.0));
    if (fabs(s - _subtitleScale) < 0.001) return;
    _subtitleScale = s;
    [_subtitleRenderer setFontScale:s];
    [self refreshSubtitleDisplay];
    if (spDebug()) SPLOG(@"[Track] 字幕大小=%.2f", s);
}

#pragma mark - Generated subtitles

- (void)beginGeneratedSubtitleTrackWithHeader:(NSString *)assHeader {
    if (!_running.load() || !_subtitleRenderer) return;
    _subLoadGen.fetch_add(1);
    {
        std::lock_guard<std::mutex> lk(_subSwitchMtx);
        _subtitleActive = NO;
        _currentSubtitleTrackPub = -1;
    }
    _streamDiscardDirty.store(true);
    [_subtitleRenderer invalidatePendingLoads];
    [_subtitleRenderer resetTrack];
    if (assHeader.length > 0) {
        [_subtitleRenderer setCodecPrivate:[assHeader dataUsingEncoding:NSUTF8StringEncoding]];
    }
    _renderer.subtitleTexture = nil;
    _generatedSubtitleActive.store(true);
    [self refreshSubtitleDisplay];
    if (spDebug()) SPLOG(@"[Captions] 生成字幕轨开始");
}

- (void)appendGeneratedSubtitleEvent:(NSString *)assEvent
                             startUs:(int64_t)startUs
                          durationUs:(int64_t)durationUs {
    if (!_generatedSubtitleActive.load() || !_subtitleRenderer) return;
    const char *utf8 = assEvent.UTF8String;
    if (!utf8) return;
    [_subtitleRenderer processChunk:(const uint8_t *)utf8 length:strlen(utf8)
                              ptsUs:startUs durationUs:durationUs];
    if (!_subtitleRefreshPending.exchange(true)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_subtitleRefreshPending.store(false);
            [self refreshSubtitleDisplay];
        });
    }
}

- (void)endGeneratedSubtitleTrack {
    if (!_generatedSubtitleActive.exchange(false)) return;
    if (!_subtitleRenderer) return;
    [_subtitleRenderer resetTrack];
    _renderer.subtitleTexture = nil;
    [self refreshSubtitleDisplay];
    if (spDebug()) SPLOG(@"[Captions] 生成字幕轨结束");
}

- (BOOL)generatedSubtitleActive { return _generatedSubtitleActive.load(); }
- (int64_t)timelineOriginUs { return _timelineOriginUs; }

- (BOOL)backgroundWorkIdle {
    const int64_t openGen = _openGeneration.load();
    const SPPlayerState phase = _backgroundPlaybackState.load(std::memory_order_acquire);
    SPBackgroundWorkAdmissionState s;
    switch (phase) {
        case SPPlayerStateIdle: s.phase = SPBackgroundPlaybackPhase::Idle; break;
        case SPPlayerStateOpening: s.phase = SPBackgroundPlaybackPhase::Opening; break;
        case SPPlayerStateReady: s.phase = SPBackgroundPlaybackPhase::Ready; break;
        case SPPlayerStatePlaying: s.phase = SPBackgroundPlaybackPhase::Playing; break;
        case SPPlayerStatePaused: s.phase = SPBackgroundPlaybackPhase::Paused; break;
        case SPPlayerStateEnded: s.phase = SPBackgroundPlaybackPhase::Ended; break;
        case SPPlayerStateFailed: s.phase = SPBackgroundPlaybackPhase::Failed; break;
    }
    s.running = _running.load();
    s.audioOnly = _audioOnlySession.load();
    s.firstFramePending = _firstFramePending.load();
    s.seekPending = _seekPending.load();
    s.seekFramePending = _seekFramePending.load();
    s.catchUpPending = _catchUpTargetUs.valid();
    s.scrubHintPending = _scrubHintPending.load();
    const int64_t seekGen = _generation.load();
    s.demuxSeekPending = _seekDemuxDoneGen.load() != seekGen;
    if (s.audioOnly && s.running &&
        (phase == SPPlayerStatePlaying || phase == SPPlayerStatePaused)) {
        // _audioOutput is a persistent per-core object. Its bufferedFrames and
        // isRunning accessors read only atomics; never touch replaceable queues.
        s.audioWorkPending = _audioFlushPending.load() || _audioTrimTargetUs.hasPending();
        s.audioAtEOF = _audioEofDrainedGen.load() == seekGen;
        s.audioOutputRunning = _audioOutput.isRunning;
        s.bufferedAudioFrames = _audioOutput.bufferedFrames;
    }
    s.nowUs = spNowUs();
    s.lastPresentationStarveUs = _presentStarveWallUs.load();
    // A concurrent replacement or state transition needs a new snapshot.
    if (_openGeneration.load() != openGen || _generation.load() != seekGen ||
        _backgroundPlaybackState.load(std::memory_order_acquire) != phase) return NO;
    return spShouldAdmitCaptionBackgroundWork(s);
}

- (void)refreshSubtitleDisplay {
    if (_state != SPPlayerStatePlaying && _lastFrameBuffer) {

        std::lock_guard<std::mutex> rlock(_renderMtx);
        [self updateSubtitleTextureForTime:_lastPresentedPtsUs];
        [_renderer renderPixelBuffer:_lastFrameBuffer];
    }
}

#pragma mark - Subtitles

- (void)decodeSubtitlePacket:(AVPacket *)pkt {
    if (pkt->size <= 0) return;
    if (_subCapExceeded) return;
    const uint8_t *data = pkt->data;
    NSUInteger len = (NSUInteger)pkt->size;
    if (_subtitleIsMovText) {

        if (len < 2) return;
        NSUInteger tlen = ((NSUInteger)data[0] << 8) | data[1];
        data += 2;
        len -= 2;
        if (tlen < len) len = tlen;
        if (len == 0) return;
    }
    NSString *text = [[NSString alloc] initWithBytes:data length:len
                                           encoding:NSUTF8StringEncoding];
    if (!text) return;
    int64_t startUs = av_rescale_q(pkt->pts, (AVRational){(int)_subtitleTimeBase.num,
                                  (int)_subtitleTimeBase.den}, AV_TIME_BASE_Q);
    int64_t durUs = av_rescale_q(pkt->duration, (AVRational){(int)_subtitleTimeBase.num,
                                   (int)_subtitleTimeBase.den}, AV_TIME_BASE_Q);

    uint64_t fp = (uint64_t)text.hash ^ ((uint64_t)startUs * 1000003ull) ^
                  ((uint64_t)durUs << 17) ^ ((uint64_t)len << 1);
    if (_subSeenEvents.find(fp) != _subSeenEvents.end()) return;

    if (_subCueBytes + len > 8 * 1024 * 1024 || _subCueCount + 1 > 100000) {
        _subCapExceeded = YES;
        SPLOG(@"[Core] 字幕轨超上限（%zuKB / %zu 条），停止追加（防内存失控）",
              _subCueBytes / 1024, _subCueCount);
        return;
    }
    _subSeenEvents.insert(fp);
    _subCueBytes += len;
    _subCueCount++;
    if (_subtitleIsSRT || _subtitleIsMovText || _subtitleIsVTT) {

        NSString *assLine = [self plainTextToAssDialogue:text];
        if (assLine) {
            [_subtitleRenderer processChunk:(const uint8_t *)assLine.UTF8String
                                     length:strlen(assLine.UTF8String)
                                      ptsUs:startUs durationUs:durUs];
        }
    } else {
        [_subtitleRenderer processChunk:(const uint8_t *)text.UTF8String
                                 length:strlen(text.UTF8String)
                                  ptsUs:startUs durationUs:durUs];
    }

    if (!_subtitleRefreshPending.exchange(true)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_subtitleRefreshPending.store(false);
            [self refreshSubtitleDisplay];
        });
    }
}

- (NSString *)plainTextToAssDialogue:(NSString *)packet {
    NSArray<NSString *> *lines = [packet componentsSeparatedByString:@"\n"];
    NSMutableString *text = [NSMutableString string];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:ws];
        if (trimmed.length == 0) continue;
        if (text.length > 0) [text appendString:@"\\N"];
        [text appendString:SPSubtitleInlineTagsToASS(trimmed)];
    }
    if (text.length == 0) return nil;
    return [NSString stringWithFormat:@"%d,0,Default,,0,0,0,,%@", _subReadOrder++, text];
}

static std::vector<uint8_t> spExtractAnnexBParamSets(const uint8_t *d, int size,
                                                     bool hevc, uint64_t *fpOut) {
    std::vector<uint8_t> out;
    uint64_t fp = 1469598103934665603ull;
    int i = 0;
    while (i + 4 < size) {
        int sc = -1, scLen = 0;
        for (int j = i; j + 3 < size; j++) {
            if (d[j] == 0 && d[j+1] == 0) {
                if (d[j+2] == 1) { sc = j; scLen = 3; break; }
                if (j + 4 < size && d[j+2] == 0 && d[j+3] == 1) { sc = j; scLen = 4; break; }
            }
        }
        if (sc < 0) break;
        int nalStart = sc + scLen;
        if (nalStart >= size) break;

        int nalEnd = size;
        for (int j = nalStart; j + 3 < size; j++) {
            if (d[j] == 0 && d[j+1] == 0 && (d[j+2] == 1 || (j + 4 < size && d[j+2] == 0 && d[j+3] == 1))) {
                nalEnd = j;
                break;
            }
        }
        int type = hevc ? ((d[nalStart] >> 1) & 0x3F) : (d[nalStart] & 0x1F);
        bool isParam = hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8);
        if (isParam && nalEnd > nalStart) {
            static const uint8_t sc4[4] = {0, 0, 0, 1};
            out.insert(out.end(), sc4, sc4 + 4);
            out.insert(out.end(), d + nalStart, d + nalEnd);
            for (int j = nalStart; j < nalEnd; j++) { fp ^= d[j]; fp *= 1099511628211ull; }
        }
        i = nalEnd;
    }
    if (fpOut) *fpOut = fp;
    return out;
}

#pragma mark - Worker loops

static void spApplyDecodeQoS() {
    qos_class_t cls = QOS_CLASS_USER_INITIATED;
#if !SP_APP_STORE
    if (getenv("SP_SW_QOS")) {
        const char *q = getenv("SP_SW_QOS");
        if (strcmp(q, "user_interactive") == 0) cls = QOS_CLASS_USER_INTERACTIVE;
        else if (strcmp(q, "utility") == 0) cls = QOS_CLASS_UTILITY;
        else if (strcmp(q, "background") == 0) cls = QOS_CLASS_BACKGROUND;
    }
#endif
    pthread_set_qos_class_self_np(cls, 0);
}

- (void)demuxLoopForOpenGeneration:(int64_t)sessionOpenGeneration {
    _streamDiscardDirty.store(true);

    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return;
    int64_t tagGen = _generation.load();
    int64_t coverageStartUs = _coverageOpenStartUs;

    for (AVPacket *p : _preludeAudioOverflow) {
        TaggedPacket tp = { p, tagGen };
        if (!_audioPackets->push(std::move(tp))) av_packet_free(&tp.pkt);
    }
    _preludeAudioOverflow.clear();

    auto waitIfSuperseded = [&](int64_t ownerGen) -> bool {
        if (_seekMailbox.peek()) return true;
        if (ownerGen == _generation.load()) return false;
        std::unique_lock<std::mutex> lock(_stateMtx);
        _playCv.wait(lock, [&] {
            return !_running.load() || _seekMailbox.peek();
        });
        return true;
    };
    int errStreak = 0;
    bool videoIsolationNoted = false;
    int totalErrStreak = 0;
    bool audioEofSent = false;
    bool volumeKeepAliveIssued = false;
    bool flacTailProofPending = _flacTailProofWanted;
    const int64_t demuxLoopStartUs = spNowUs();

    auto runFlacTailProof = [&] {
        flacTailProofPending = false;
        uint64_t endSample = 0;
        const bool found = _demuxer->flacLastFrameEndSample(_flacStreamInfo, sizeof _flacStreamInfo, endSample);
        const bool proven = found && endSample == _flacDeclaredTotal;
        if (proven) _flacMd5UnneededGen.store(sessionOpenGeneration, std::memory_order_release);
        if (spDebug()) SPLOG(@"[Audio] FLAC 尾帧核对：%@ 末样本 %llu / 声明 %llu → %@", found ? @"完整末帧" : @"未找到完整末帧",
                             (unsigned long long)endSample, (unsigned long long)_flacDeclaredTotal, proven ? @"停原生 MD5" : @"保留原生 MD5");
    };
    int64_t indexPrefetchNextAdmissionUs = 0;
    bool seekFirstPktPending = false;

    bool landingTrimPending = false;

    bool landingKeyPending = false;
    int64_t prevSeekTargetUs = INT64_MIN;
    int64_t prevSeekReqWallUs = 0;

    int packetsSinceCoarseSeek = INT_MAX;
    int64_t lastCoarseSeekWallUs = 0;
    constexpr int kScrubPrerollPackets = 30;
    constexpr int64_t kScrubDwellUs = 350000;

    constexpr int64_t kReadaheadRearmBytes = 6 * 1024 * 1024;
    int64_t readaheadAccumBytes = kReadaheadRearmBytes;
    int64_t lastSeekWallUs = 0;
    // Rearm auxiliary reads only during the post-seek refill window. Interleaved
    // reads ahead of a steady demux stream can disrupt kernel sequential readahead;
    // they are useful while refilling, before that readahead has ramped up.
    constexpr int64_t kRelayWindowBytes = 24 * 1024 * 1024;
    int64_t bytesSinceSeek = 0;

    int kfWarmIdx = 0;
    int64_t kfWarmLastUs = -1;
    int64_t kfWarmLastPokeWallUs = 0;
    bool kfWarmDone = false;
    int64_t lastInteractWallUs = 0;
    while (_running.load()) {
        @autoreleasepool {

        SPSeekRequestMailbox::Request seekReq;
        if (_seekMailbox.take(&seekReq)) {
            const int64_t seekUs = seekReq.targetUs;
            const int64_t seekGen = seekReq.gen;
            const BOOL seekForward = seekReq.forward;
            const int64_t seekOriginUs = seekReq.originUs;
            const int64_t seekAlignTolUs = seekReq.alignToleranceUs;

            coverageStartUs = seekForward ? -1 : seekUs;
            if (spDebug()) SPLOG(@"[Demux] seek 目标 %.2fs (gen=%lld)", seekUs / 1e6, seekGen);

            {
                int pendA = _pendingAudioTrack.load();
                if (pendA >= 0) {
                    if (pendA != _audioStreamIndex &&
                        _audioTrackTimeBases.count(pendA)) {
                        _audioStreamIndex = pendA;
                        _streamDiscardDirty.store(true);
                        _currentAudioTrackPub.store(pendA);
                        _audioRebuildTrack.store(pendA);
                        [self resilientClearTrackEvidence:spresil::Track::Audio];
                        if (spDebug()) SPLOG(@"[Track] 音轨已切换 → 流#%d", pendA);
                    }
                    // Clear only the request we consumed. A newer main-thread
                    // selection remains pending for its own latest-wins seek.
                    (void)_pendingAudioTrack.compare_exchange_strong(pendA, -2);
                }
            }

            [self drainSessionQueuesForSeek];

            if (waitIfSuperseded(seekGen)) continue;

            std::function<bool()> seekAbort = [&] {
                return _seekMailbox.peek() || !_running.load();
            };

            if (_demuxer->matroskaLike()) {
                __weak SPPlayerCore *weakSelf = self;
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf scheduleContentSearchCheckAfterMs:450]; });
            }
            int sret = _demuxer->seekToUs(seekUs, seekForward, seekOriginUs,
                                          &seekAbort, seekAlignTolUs);
            if (_demuxer->mkvContentScanPending()) {
                __weak SPPlayerCore *weakSelf = self;
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf startMkvContentScanIfPending]; });
            }

            if (sret >= 0) {
                const int64_t snapUs = _demuxer->takeSeekSnapUs();
                if (snapUs >= 0 && snapUs < seekUs) {
                    if (spDebug()) SPLOG(@"[Demux] seek 目标 %.2fs 之后没有内容：落点改为前一段 %.2fs（重发精确 seek）", seekUs / 1e6, snapUs / 1e6);
                    const int64_t og = _openGeneration.load(std::memory_order_acquire);
                    const double snapSec = snapUs / 1e6;
                    __weak SPPlayerCore *weakSelf = self;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        SPPlayerCore *s = weakSelf;
                        if (!s || s->_openGeneration.load(std::memory_order_acquire) != og || s->_seekMailbox.peek()) return;
                        [s seekTo:snapSec precise:YES];
                    });
                    [self notifySkippedMissingFrom:snapUs to:seekUs afterSeek:YES];
                }
            }

            if (waitIfSuperseded(seekGen)) continue;
            tagGen = seekGen;
            seekFirstPktPending = spDebug();

            landingTrimPending = sret >= 0 && _audioActive &&
                                 !_catchUpTargetUs.valid() && !spLandingTrimOff();
            landingKeyPending = sret >= 0;

            bool directionPrefetchSubmitted = false;
            if (sret >= 0 && prevSeekTargetUs != INT64_MIN) {
                const int64_t delta = seekUs - prevSeekTargetUs;

                if (delta != 0 && llabs(delta) <= 60 * 1000000LL &&
                    seekReq.requestWallUs - prevSeekReqWallUs <= 500000) {
                    directionPrefetchSubmitted = _demuxer->prefetchSeekNeighborhood(
                        seekUs + delta, 2, delta, seekForward);
                }
            }
            prevSeekTargetUs = seekUs;
            prevSeekReqWallUs = seekReq.requestWallUs;

            if (!_catchUpTargetUs.valid() && directionPrefetchSubmitted) {
                packetsSinceCoarseSeek = 0;
                lastCoarseSeekWallUs = spNowUs();
            } else {
                packetsSinceCoarseSeek = INT_MAX;
            }
            audioEofSent = false;
            lastInteractWallUs = spNowUs();

            bytesSinceSeek = 0;
            if (directionPrefetchSubmitted) {
                lastSeekWallUs = spNowUs();
                readaheadAccumBytes = 0;
            } else {
                lastSeekWallUs = 0;
                readaheadAccumBytes = kReadaheadRearmBytes;

                _demuxer->prefetchSequentialAhead(16 * 1024 * 1024);
            }
            _flushPending.store(true);
            _seekDemuxDoneGen.store(seekGen);
            [self wakeDecodeThread];
            if (sret < 0) {

                if (spDebug()) SPLOG(@"[Demux] seek 失败 ret=%d → 就地恢复", sret);
                int64_t failedGen = seekGen;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!spPlayerSeekCallbackIsCurrent(
                            sessionOpenGeneration,
                            self->_openGeneration.load(),
                            failedGen,
                            self->_generation.load())) return;
                    self->_seekDisplayTargetUs.clear();
                    self->_catchUpTargetUs.clear();
                    self->_audioTrimTargetUs.clear();
                    self->_seekFramePending.store(false);
                    self->_seekPending.store(false);
                    self->_seekFlashDone.store(true);

                    self->_seekSettleGen.store(self->_generation.load());
                });
            }

            continue;
        }

        if (!_seekPending.load() && _scrubHintPending.exchange(false)) {
            const int64_t hintUs = _scrubHintUs.load();
            if (hintUs >= 0) {
                _demuxer->prefetchSeekNeighborhood(hintUs, 1, 0);
                lastInteractWallUs = spNowUs();
            }
        }

        if (_paused.load() && !_seekPending.load() && !_scrubHintPending.load()) {
            std::unique_lock<std::mutex> lock(_stateMtx);
            _playCv.wait(lock, [&] {
                return !_running.load() || !_paused.load() ||
                       _seekPending.load() || _scrubHintPending.load();
            });
            if (!_running.load()) break;
            continue;
        }

        if (!volumeKeepAliveIssued && !_firstFramePending.load()) {
            volumeKeepAliveIssued = true;
            _demuxer->startVolumeKeepAliveIfNeeded();
        }

        if (flacTailProofPending && !_seekPending.load() && spNowUs() - demuxLoopStartUs >= 1000000) runFlacTailProof();

        if (!_audioOnlySession.load()) {
            const int64_t nowUs = spNowUs();
            if (nowUs >= indexPrefetchNextAdmissionUs) {
                indexPrefetchNextAdmissionUs = nowUs + 100000;

                if (_demuxer->indexPrefetchWanted() &&
                    nowUs >= _indexPrefetchHoverHoldUs.load(
                                 std::memory_order_relaxed)) {
                    SPIndexPrefetchAdmissionState admission;
                    admission.alreadyIssued = false;
                    admission.currentOpenSession =
                        sessionOpenGeneration == _openGeneration.load() &&
                        _windowVisibleForRendering.load();
                    admission.audioOnly = _audioOnlySession.load();
                    admission.firstFramePending = _firstFramePending.load();
                    admission.committedThisSession =
                        _renderer.committedFrameCount > _openCommittedBase;
                    admission.submittedVideoGeneration =
                        _lastSubmittedVideoGeneration.load(
                            std::memory_order_acquire);
                    admission.currentSeekGeneration = _generation.load();
                    admission.seekPending = _seekPending.load();
                    admission.seekFramePending = _seekFramePending.load();
                    admission.catchUpPending = _catchUpTargetUs.valid();
                    admission.videoPacketCapacity = _videoPackets->capacity();

                    admission.videoPacketDepth = _videoPackets->size();
                    admission.nowUs = nowUs;
                    admission.lastPresentationStarveUs =
                        _presentStarveWallUs.load();
                    if (spShouldIssueIndexPrefetch(admission)) {
                        _demuxer->prefetchIndexRegionAsync();
                    }
                }
            }
        }

        if (packetsSinceCoarseSeek >= kScrubPrerollPackets &&
            packetsSinceCoarseSeek != INT_MAX) {
            if (spNowUs() - lastCoarseSeekWallUs < kScrubDwellUs) {
                std::unique_lock<std::mutex> lock(_stateMtx);
                _playCv.wait_for(lock, std::chrono::milliseconds(20), [&] {
                    return !_running.load() || _seekMailbox.peek();
                });
                continue;
            }
            packetsSinceCoarseSeek = INT_MAX;
        }

        if (waitIfSuperseded(tagGen)) continue;
        if (_streamDiscardDirty.exchange(false)) {
            int sub = -1;
            { std::lock_guard<std::mutex> lk(_subSwitchMtx); if (_subtitleActive) sub = _subtitleStreamIndex; }
            _demuxer->applyStreamDiscard(_audioStreamIndex, sub);
        }
        int r = _demuxer->readPacket(pkt);
        const bool replayPkt = r > 0 && _demuxer->lastPacketIsReplay();

        if (_seekMailbox.peek() || tagGen != _generation.load()) {
            if (r > 0) av_packet_unref(pkt);
            continue;
        }
        if (r > 0 && packetsSinceCoarseSeek != INT_MAX &&
            pkt->stream_index == _videoStreamIndex) {
            packetsSinceCoarseSeek++;
        }
        if ((landingTrimPending || landingKeyPending) && r > 0 &&
            pkt->stream_index == _videoStreamIndex) {

            const bool isKey = (pkt->flags & AV_PKT_FLAG_KEY) && pkt->pts != AV_NOPTS_VALUE;
            const int64_t keyUs = isKey
                ? av_rescale_q(pkt->pts, _videoTimeBase, AV_TIME_BASE_Q) : -1;
            if (landingKeyPending) {
                landingKeyPending = false;
                if (isKey) _seekLandingKeyUs.publish(tagGen, keyUs);
            }
            if (landingTrimPending) {
                landingTrimPending = false;
                if (isKey) _audioLandingTrimUs.publish(tagGen, keyUs);
            }
        }
        if (seekFirstPktPending && r > 0 && pkt->stream_index == _videoStreamIndex) {

            seekFirstPktPending = false;
            int64_t req = _seekReqWallUs.load();
            if (req > 0) {
                SPLOG(@"[Scrub] 关键帧包读毕 %.0fms (bytes=%d)",
                      (spNowUs() - req) / 1000.0, pkt->size);
            }
        }
        if (r == 0) {

            if (_demuxer->hasRecoveryEvents()) [self resilientDrainDemuxRecoveryEvents];
            if (spDebug()) {
                if (_dbgEofLogs++ < 1) SPLOG(@"[Core] demux EOF 到达");
            }

            if (_audioActive && !audioEofSent) {
                audioEofSent = true;
                TaggedPacket eofTp = { nullptr, tagGen };
                (void)!_audioPackets->push(std::move(eofTp));
            }

            [self wakeDecodeThread];

            if (flacTailProofPending && !_seekPending.load()) runFlacTailProof();
            std::unique_lock<std::mutex> lock(_stateMtx);

            _eofCv.wait(lock, [&] {
                return !_running.load() || _seekMailbox.peek() ||
                       (!_seekPending.load() && _scrubHintPending.load());
            });
            continue;
        }
        if (r < 0) {

            if (r == AVERROR_EXIT) continue;

            if (_demuxer->lastReadErrorIsContent(r)) _endTruncationEvidence.store(true, std::memory_order_relaxed);
            if ((r == AVERROR(EAGAIN) || r == AVERROR_INVALIDDATA) && _demuxer->lastReadAdvanced()) {
                [self resilientNoteDemuxSkipAtPos:_demuxer->lastReadPos() error:r];
                errStreak = 0;
                continue;
            }

            errStreak = errStreak < 6 ? errStreak + 1 : 6;

            if (++totalErrStreak == 40) {
                int errorCode = r;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!spPlayerSessionIsCurrent(
                            sessionOpenGeneration,
                            self->_openGeneration.load())) return;
                    [self failWithFFmpegError:errorCode operation:NSLocalizedString(@"error.op.read", nil)];
                });
            }
            {

                std::unique_lock<std::mutex> lock(_stateMtx);
                _playCv.wait_for(lock, std::chrono::milliseconds(2 << errStreak), [&] {
                    return !_running.load() || _seekMailbox.peek() ||
                           (!_seekPending.load() && _scrubHintPending.load());
                });
            }
            continue;
        }
        errStreak = 0;
        totalErrStreak = 0;

        if (_demuxer->hasRecoveryEvents()) [self resilientDrainDemuxRecoveryEvents];

        if (!videoIsolationNoted && _demuxer->videoTrackIsolated()) {
            videoIsolationNoted = true;
            const int64_t og = _openGeneration.load(std::memory_order_acquire);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_openGeneration.load(std::memory_order_acquire) != og || self->_videoTrackGivenUp) return;
                self->_videoTrackGivenUp = YES;
                [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::None
                              confidence:spresil::Confidence::DecodeVerified
                                  fromUs:0 untilUs:(int64_t)(MAX(self->_duration, 0.5) * 1e6)];
                [self resilientLog:@"视频轨在容器层解包失败且无唯一候选，已隔离：只播放音频"];
            });
        }

        readaheadAccumBytes += pkt->size;
        bytesSinceSeek += pkt->size;
        if (readaheadAccumBytes >= kReadaheadRearmBytes) {
            readaheadAccumBytes = 0;
            if (bytesSinceSeek < kRelayWindowBytes &&
                spNowUs() - lastSeekWallUs > 600000 &&
                _videoPackets->size() < _videoPackets->capacity() * 3 / 4) {
                _demuxer->prefetchSequentialAhead(16 * 1024 * 1024);
            }
        }

        if (!kfWarmDone && _demuxer->onRemoteVolume()) {
            const int64_t nowW = spNowUs();
            if (nowW - kfWarmLastPokeWallUs > 500000 &&
                nowW - lastInteractWallUs > 2000000 &&

                _videoPackets->size() >=
                    MAX(_videoPackets->capacity() * 3 / 4, (size_t)2)) {
                kfWarmLastPokeWallUs = nowW;
                int r = _demuxer->warmNextKeyframeClusters(kfWarmIdx, &kfWarmLastUs);
                if (r < 0) {
                    kfWarmDone = true;
                    if (spDebug()) SPLOG(@"[Demux] 关键帧簇头预热铺完（%d 条目游标）", kfWarmIdx);
                } else {
                    kfWarmIdx = r;
                }
            }
        }
        if (pkt->pos >= 0) _lastDemuxedPos.store(pkt->pos, std::memory_order_relaxed);
        if (pkt->stream_index == _videoStreamIndex) {
            if (spDebug()) {
                int64_t pktPts = pkt->pts != AV_NOPTS_VALUE ? av_rescale_q(pkt->pts, _videoTimeBase, AV_TIME_BASE_Q) : -1;
                if (pktPts != _dbgFirstPktPts && pktPts > 0 && pktPts < 3e6 + 10) {
                    _dbgFirstPktPts = pktPts;
                    SPLOG(@"[Demux] 首包 pts=%.2fs", pktPts / 1e6);
                }
            }

            if (!_reorderCheckDone.load(std::memory_order_relaxed)) {
                if (pkt->pts == AV_NOPTS_VALUE || pkt->dts == AV_NOPTS_VALUE) {

                } else if (pkt->pts != pkt->dts) {
                    _reorderCheckDone.store(true);

                    _reorderProbePkt = nil;
                    _reorderProbeExtra = nil;
                } else if (++_reorderSuspectStreak >= 48) {
                    _reorderCheckDone.store(true);
                    [self scheduleBrokenReorderProbe];
                    _reorderProbePkt = nil;
                    _reorderProbeExtra = nil;
                }
            }

            const bool pktAllZero = _demuxer->lastPacketAllZero();

            if (!(pkt->flags & AV_PKT_FLAG_DISCARD) && !replayPkt) [self noteVideoContentPacket:pkt gen:tagGen startUs:coverageStartUs allZero:pktAllZero || _demuxer->lastPacketGarbage()];
            TaggedPacket tp = { av_packet_clone(pkt), tagGen };

            tp.discard = (pkt->flags & AV_PKT_FLAG_DISCARD) != 0;
            tp.allZero = pktAllZero ? 1 : 0;
            if (tp.pkt) {

                const bool wasEmpty = _videoPackets->size() == 0;
                if (!_videoPackets->push(std::move(tp))) av_packet_free(&tp.pkt);
                if (wasEmpty) [self wakeDecodeThread];
                else _decodeCv.notify_all();
            }
        } else if (pkt->stream_index == _audioStreamIndex && _audioActive) {
            TaggedPacket tp = { av_packet_clone(pkt), tagGen };
            tp.discard = replayPkt;

            if (tp.pkt && !_audioPackets->push(std::move(tp))) av_packet_free(&tp.pkt);
        } else {

            std::lock_guard<std::mutex> lk(_subSwitchMtx);
            if (_subtitleActive && pkt->stream_index == _subtitleStreamIndex) {
                [self decodeSubtitlePacket:pkt];
            }
        }
        av_packet_unref(pkt);
        } // @autoreleasepool
    }
    av_packet_free(&pkt);
}

#pragma mark - Motion interpolation on the decode thread

- (void)setInterpolationWorkerStatus:(NSString *)status
                               active:(BOOL)active
                                 code:(int)code {
    BOOL activeChanged = _frameInterpolationActiveValue.exchange(active) != active;
    int previousCode = _interpolationPolicyStatusCode.exchange(code);

    BOOL textChanged = NO;
    {
        std::lock_guard<std::mutex> lock(_interpolationStatusMtx);
        textChanged = status && ![_frameInterpolationStatusValue isEqualToString:status];
        if (previousCode != code || activeChanged || textChanged) {
            _frameInterpolationStatusValue = [status copy];
        }
    }
    if (previousCode == code && !activeChanged && !textChanged) return;
    if (spDebug()) {
        SPLOG(@"[MEMCPolicy] code=%d active=%d status=%@", code, active, status);
    }
    [self notifyFrameInterpolationDidChange];
}

- (void)destroyMotionInterpolatorOnDecodeThread {
    [_generator destroyEngine];
}

- (PushResult)enqueueDecodedVideoBuffer:(CVPixelBufferRef)buffer
                                  ptsUs:(int64_t)ptsUs
                             generation:(int64_t)generation
                    interruptGeneration:(uint64_t)interruptGeneration {
    if (!buffer) return PushResult::Closed;
    DecodedFrame frame;
    frame.buffer = buffer;
    frame.ptsUs = ptsUs;
    frame.gen = generation;
    PushResult result = _frames->pushInterruptibly(std::move(frame), interruptGeneration);
    if (result != PushResult::Pushed) return result;
    if (_firstFramePending.load()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self tryPresentFirstFrame]; });
    } else if (_seekFramePending.load()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self tryPresentSeekFrame]; });
    }
    return PushResult::Pushed;
}

- (PushResult)enqueueMotionVideoBuffer:(CVPixelBufferRef)buffer
                                 ptsUs:(int64_t)ptsUs
                            generation:(int64_t)generation
                              synthetic:(BOOL)synthetic
                      interpolationEpoch:(uint64_t)interpolationEpoch
                     interruptGeneration:(uint64_t)interruptGeneration {
    if (!buffer) return PushResult::Closed;
    auto motionFrames = _motionFramesPublished.load();
    if (!motionFrames) return PushResult::Interrupted;
    DecodedFrame frame;
    frame.buffer = buffer;
    frame.ptsUs = ptsUs;
    frame.gen = generation;
    frame.synthetic = synthetic;
    frame.interpolationEpoch = interpolationEpoch;
    PushResult result = motionFrames->pushInterruptibly(std::move(frame), interruptGeneration);
    if (result != PushResult::Pushed) return result;
    if (_firstFramePending.load()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self tryPresentFirstFrame]; });
    } else if (_seekFramePending.load()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self tryPresentSeekFrame]; });
    }
    return PushResult::Pushed;
}

- (void)applyPendingInterpolationResetOnDecodeThread {
    SPFrameInterpolationMode mode;
    uint64_t transitionEpoch;
    {

        std::lock_guard<std::mutex> lock(_interpolationTransitionMtx);
        if (!_interpolationResetRequested.exchange(false)) return;
        mode = (SPFrameInterpolationMode)_frameInterpolationModeValue.load();
        transitionEpoch = _interpolationPolicyEpoch.load();
    }

    [_generator applyModeReset:mode];

    SPFrameInterpolationMode committed =
        (SPFrameInterpolationMode)_frameInterpolationCommittedModeValue.load();
    if (mode == committed) {
        [_decoder
            setInterpolationScanEnabled:
                (mode == SPFrameInterpolationModeDoubleRate &&
                 !_interpolationCodedInterlacedSeen)
                    codecParameters:_videoParCopy];

        if (_running.load()) {
            _frames->reopen();
            if (auto motionFrames = _motionFramesPublished.load()) motionFrames->reopen();
        }

        if (mode == SPFrameInterpolationModeOff) {
            if (auto motionFrames = _motionFramesPublished.exchange(nullptr)) {
                spFrameQueueRelease(&_motionQueueClaimBytes);
                auto *droppedCounter = &_generator.counters->dropped;
                motionFrames->drain([droppedCounter](DecodedFrame f) {
                    if (f.synthetic) droppedCounter->fetch_add(1);
                    if (f.buffer) CVPixelBufferRelease(f.buffer);
                });
            }
        }
        {
            std::lock_guard<std::mutex> lock(_interpolationTransitionMtx);
            _interpolationTransitionAckEpoch.store(transitionEpoch);
        }
        _interpolationTransitionCv.notify_all();
        return;
    }

    if (mode == SPFrameInterpolationModeDoubleRate && !_motionFramesPublished.load()) {

        const double mult = 2.0;
        size_t cap = spVideoFrameQueueCapacity(_videoWidth, _videoHeight, _videoFps, mult);
        const size_t fb = (size_t)MAX(_videoWidth, 1) * (size_t)MAX(_videoHeight, 1) * 3;
        cap = spFrameQueueClaim(cap, fb, spVideoFrameQueueFloor(_videoFps, mult),
                                &_motionQueueClaimBytes, _spLogId);
        _motionFramesPublished.store(std::make_shared<BoundedQueue<DecodedFrame>>(cap));
        if (spDebug()) SPLOG(@"[MEMC] 按需创建插帧队列 cap=%zu", cap);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_running.load() ||
            self->_interpolationPolicyEpoch.load() != transitionEpoch ||
            self->_frameInterpolationModeValue.load() != (int)mode) {

            if (self->_running.load() &&
                self->_frameInterpolationModeValue.load() !=
                    self->_frameInterpolationCommittedModeValue.load()) {
                self->_interpolationResetRequested.store(true);
                [self wakeDecodeThread];
            }
            return;
        }

        auto motionFrames = self->_motionFramesPublished.load();
        self->_frames->reopen();
        if (motionFrames) motionFrames->reopen();

        if (mode == SPFrameInterpolationModeDoubleRate && motionFrames) {

            motionFrames->drain([](DecodedFrame f) {
                if (f.buffer) CVPixelBufferRelease(f.buffer);
            });
            self->_frames->drain([self, motionFrames](DecodedFrame f) {
                DecodedFrame moved;
                moved.buffer = f.buffer;
                moved.ptsUs = f.ptsUs;
                moved.gen = f.gen;
                if (!motionFrames->pushForTransition(std::move(moved)) && f.buffer) {
#if DEBUG && !SP_APP_STORE

#endif
                    CVPixelBufferRelease(f.buffer);
                }
            });
        } else if (motionFrames) {

            auto *droppedCounter = &self->_generator.counters->dropped;
            motionFrames->drain([self, droppedCounter](DecodedFrame f) {
                if (f.synthetic) {
                    droppedCounter->fetch_add(1);
                    if (f.buffer) CVPixelBufferRelease(f.buffer);
                    return;
                }
                DecodedFrame moved = f;
                moved.synthetic = false;
                moved.interpolationEpoch = 0;
                if (!self->_frames->pushForTransition(std::move(moved)) && f.buffer) {
#if DEBUG && !SP_APP_STORE

#endif
                    CVPixelBufferRelease(f.buffer);
                }
            });

            if (self->_presentRetryPending && self->_lastFrameSynthetic) {
                self->_generator.counters->dropped.fetch_add(1);
                self->_presentRetryPending = NO;
                self->_presentRetryCompletesPausedSeek = NO;
            }
            self->_lastFrameSynthetic = NO;
            self->_lastFrameInterpolationEpoch = 0;

            self->_motionFramesPublished.store(nullptr);

            spFrameQueueRelease(&self->_motionQueueClaimBytes);
        }

        {
            std::lock_guard<std::mutex> lock(self->_interpolationTransitionMtx);
            self->_frameInterpolationCommittedModeValue.store((int)mode);
            self->_interpolationTransitionAckEpoch.store(transitionEpoch);
        }
        self->_interpolationTransitionCv.notify_all();
        if (spDebug()) SPLOG(@"[MEMC] 路由提交 %@ epoch=%llu",
                             mode == SPFrameInterpolationModeDoubleRate ? @"2x" : @"off",
                             (unsigned long long)transitionEpoch);
    });

    std::unique_lock<std::mutex> transitionLock(_interpolationTransitionMtx);
    _interpolationTransitionCv.wait(transitionLock, [&] {
        return !_running.load() ||
               _interpolationTransitionAckEpoch.load() == transitionEpoch ||
               _interpolationPolicyEpoch.load() != transitionEpoch;
    });
    if (_running.load() &&
        _frameInterpolationModeValue.load() != _frameInterpolationCommittedModeValue.load()) {
        _interpolationResetRequested.store(true);
    }
    if (_running.load() &&
        _interpolationPolicyEpoch.load() == transitionEpoch &&
        _frameInterpolationCommittedModeValue.load() == (int)mode) {
        // The compressed-bitstream scanner is an On-only resource. Create or
        // destroy it only after the route transaction commits, so even the
        // short requested→committed transition window preserves strict Off.
        [_decoder
            setInterpolationScanEnabled:(mode == SPFrameInterpolationModeDoubleRate &&
                                         !_interpolationCodedInterlacedSeen)
                    codecParameters:_videoParCopy];
    }
}

- (void)processDecodedVideoOutput:(SPDecodedVideoOutput)output
                       generation:(int64_t)generation {
    CVPixelBufferRef buffer = output.pixelBuffer;
    int64_t ptsUs = output.ptsUs;
    if (!buffer) return;
#ifdef SP_ENHANCE
    // Observe actual geometry even while Off. Stream metadata may keep its old
    // dimensions after a decoder reconfiguration. Only publish changes, and
    // do not let an earlier seek generation overwrite the current frame fact.
    if (generation == _generation.load()) {
        const bool limited = sp::spInterpolationExceeds4KLimit(
            (uint32_t)CVPixelBufferGetWidth(buffer),
            (uint32_t)CVPixelBufferGetHeight(buffer));
        if (_interpolationDecodedResolutionLimited.load() != limited) {
            _interpolationDecodedResolutionLimited.store(limited);
            [self notifyFrameInterpolationDidChange];
        }
    }
#endif

    [self reinjectReturnedSourceFrames];

    if (_sessionRestampSeq) {
        if (_restampNextPtsUs < 0) _restampNextPtsUs = ptsUs;
        ptsUs = _restampNextPtsUs;
        _restampNextPtsUs += _frameIntervalUs;
    }
    [self routeSourceBuffer:buffer ptsUs:ptsUs generation:generation
                scanVerdict:output.scanVerdict scanCovered:output.scanCovered];
}

- (void)applyPendingInterpolationResetAndReinjectOnDecodeThread {
    [self applyPendingInterpolationResetOnDecodeThread];
    [self reinjectReturnedSourceFrames];
}

- (void)reinjectReturnedSourceFrames {
    if (![_generator hasReturnedFrames]) return;

    if (_reinjectingReturnedFrames) return;
    _reinjectingReturnedFrames = YES;
    [_generator drainReturnedFramesWithHandler:^(CVPixelBufferRef b, int64_t pts, int64_t gen) {

        [self routeSourceBuffer:b ptsUs:pts generation:gen
                    scanVerdict:SPDecodedVideoScanVerdictProgressive scanCovered:YES];
    }];
    _reinjectingReturnedFrames = NO;
}

- (void)routeSourceBuffer:(CVPixelBufferRef)buffer
                    ptsUs:(int64_t)ptsUs
               generation:(int64_t)generation
              scanVerdict:(SPDecodedVideoScanVerdict)scanVerdict
              scanCovered:(BOOL)scanCovered {
    while (true) {
        if (!_running.load()) {
            CVPixelBufferRelease(buffer);
            return;
        }

        int requested = _frameInterpolationModeValue.load();
        int committed = _frameInterpolationCommittedModeValue.load();
        if (_interpolationResetRequested.load() || requested != committed) {
            if (requested != committed) _interpolationResetRequested.store(true);

            [self applyPendingInterpolationResetAndReinjectOnDecodeThread];
            continue;
        }

        PushResult result;
        if (committed == SPFrameInterpolationModeOff) {
            uint64_t interruptGeneration = _frames->interruptGeneration();

            if (_interpolationResetRequested.load() ||
                _frameInterpolationModeValue.load() != committed ||
                _frameInterpolationCommittedModeValue.load() != committed) {
                continue;
            }
            result = [self enqueueDecodedVideoBuffer:buffer ptsUs:ptsUs
                                           generation:generation
                                  interruptGeneration:interruptGeneration];
        } else {
            auto motionFrames = _motionFramesPublished.load();
            if (!motionFrames) {
                _interpolationResetRequested.store(true);
                continue;
            }
            uint64_t interruptGeneration = motionFrames->interruptGeneration();
            if (_interpolationResetRequested.load() ||
                _frameInterpolationModeValue.load() != committed ||
                _frameInterpolationCommittedModeValue.load() != committed) {
                continue;
            }
            // Resolve CoreVideo attachments only after the On route commits.
            // The decoder's PTS/verdict/coverage sidecar is already bound to
            // this exact +1 buffer, so transition waits or a later decode can
            // never overwrite it. Strict Off still performs no attachment read.
            const BOOL scanInterlaced =
                scanVerdict == SPDecodedVideoScanVerdictInterlaced;
            const BOOL codedInterlaced = scanInterlaced &&
                _decoder.decodingBackend ==
                    SPVideoDecodingBackendVideoToolbox;
            if (codedInterlaced && !_interpolationCodedInterlacedSeen) {

                _interpolationCodedInterlacedSeen = YES;
                [_decoder setInterpolationScanEnabled:NO
                                      codecParameters:nullptr];

                [self destroyMotionInterpolatorOnDecodeThread];
                [self reinjectReturnedSourceFrames];
                continue;
            }
            // Unknown scan is fail-closed. CoreVideo field attachments remain
            // useful positive evidence, but cannot authorize interpolation on
            // their own because VT commonly omits them for field video.
            const BOOL scanCoversOutput =
                scanVerdict == SPDecodedVideoScanVerdictProgressive &&
                scanCovered;
            BOOL interlaced = scanInterlaced ||
                              _interpolationCodedInterlacedSeen ||
                              spPixelBufferIsInterlaced(buffer);
            BOOL scanUnknown = !_interpolationCodedInterlacedSeen &&
                               !scanInterlaced && !scanCoversOutput;
            sp::SPFrameGeneratorSubmitContext submit;
            submit.ptsUs = ptsUs;
            submit.generation = generation;
            submit.interlaced = interlaced;
            submit.scanUnknown = scanUnknown;
            submit.catchUpActive = _catchUpTargetUs.valid();
            submit.interruptGeneration = interruptGeneration;
            result = [_generator submitSourceBuffer:buffer context:submit];
        }

        if (result == PushResult::Pushed) {
#if DEBUG && !SP_APP_STORE

#endif
            return;
        }
        if (result == PushResult::Closed || !_running.load()) {
            CVPixelBufferRelease(buffer);
            return;
        }

        _interpolationResetRequested.store(true);
    }
}

- (void)decodeLoop {

    int64_t discardBelowUs = -1;
    int64_t videoEpochOffsetUs = 0;
    int64_t videoLastPktTsUs = -1;
    int64_t videoPrevPktPos = -1;
    int64_t videoReplayFrontierUs = -1;

    auto applyPendingFlush = [&] {
        if (!_flushPending.exchange(false)) return;
        [_decoder flush];
        _restampNextPtsUs = -1;
        [self laneResetForFlush];
        discardBelowUs = -1;
        videoEpochOffsetUs = 0;
        videoLastPktTsUs = -1;
        videoReplayFrontierUs = -1;
    };

    auto videoLookahead = [&](int64_t gen, int64_t breakBelow, int64_t breakAbove, int64_t countFrom, int& run, bool& returned) {
        _videoPackets->peekEach(64, [&](const TaggedPacket& q) {
            if (!q.pkt || q.control || q.gen != gen) return true;
            const int64_t raw = q.pkt->dts != AV_NOPTS_VALUE ? q.pkt->dts : q.pkt->pts;
            if (raw == AV_NOPTS_VALUE) return true;
            const int64_t us = av_rescale_q(raw, _videoTimeBase, AV_TIME_BASE_Q);
            if (us < breakBelow || us > breakAbove) { returned = true; return false; }
            if (us >= countFrom) ++run;
            return true;
        });
    };
    spApplyDecodeQoS();
    bool qosBoosted = false;
    while (true) {
        @autoreleasepool {
        // The trigger's own normal path is complete before the first freeze.
        // EOF rolls raw undo back before any ordinary VT drain.
        if (_lanePendingReadback) {
            if (_demuxer->eof() && _videoPackets->size() == 0) SP_G1_ABORT("eof");
            else [self laneTryCommitReadbackGeneration:_generation.load()
                                         lastTimestamp:&videoLastPktTsUs lastPosition:&videoPrevPktPos
                                          discardBelow:&discardBelowUs];
        }
        if (_interpolationResetRequested.load()) {
            [self applyPendingInterpolationResetAndReinjectOnDecodeThread];
        }

        if (_seekBoostDecode.exchange(false)) {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            qosBoosted = true;
        } else if (qosBoosted && !_catchUpTargetUs.valid() && !_seekPending.load()) {

            spApplyDecodeQoS();
            qosBoosted = false;
        }

        if (_seekDemuxDoneGen.load() != _generation.load()) {
            std::unique_lock<std::mutex> lock(_decodeMtx);
            _decodeCv.wait(lock, [&] {
                return !_running.load() ||
                       _seekDemuxDoneGen.load() == _generation.load();
            });
            if (!_running.load()) break;
        }
        applyPendingFlush();

        TaggedPacket tp;
        bool drainEOF = false;
        {
            std::unique_lock<std::mutex> lock(_decodeMtx);
            auto ready = [&] {
                return !_running.load() || _flushPending.load() ||
                       _videoPackets->size() > 0 ||
                       (!_lanePendingReadback && (!_laneReadbackUndo.empty() || _laneReadbackHasRollbackTail)) ||
                       _interpolationResetRequested.load() ||
                       (_lanePendingReadback && (_seekPending.load() ||
                           _lanePendingReadback->generation != _generation.load())) ||
                       (_demuxer->eof() && _eofDrainedGen.load() != _generation.load());
            };
            if (_lanePendingReadback) {
                const int64_t remaining = _lanePendingReadback->startedUs + 2000000 - sptrial::monotonicNowUs();
                if (remaining <= 0 || !_decodeCv.wait_for(lock, std::chrono::microseconds(remaining), ready)) {
                    lock.unlock(); SP_G1_ABORT("wait_timeout"); continue;
                }
                if (_seekPending.load() || _lanePendingReadback->generation != _generation.load()) {
                    lock.unlock(); SP_G1_ABORT("seek_or_generation"); continue;
                }
            } else {
                _decodeCv.wait(lock, ready);
            }
            if (!_running.load()) break;
            if (_flushPending.load()) {
                lock.unlock(); SP_G1_ABORT("flush_pending"); continue;
            }
            // EOF may have arrived while waiting, with undo still private.
            // Roll back before selecting input; never block on an empty main
            // queue while untouched deferred packets are available locally.
            if (_lanePendingReadback && _videoPackets->size() == 0 && _demuxer->eof()) {
                lock.unlock(); SP_G1_ABORT("eof"); continue;
            }
            if (_interpolationResetRequested.load()) {
                lock.unlock();
                [self applyPendingInterpolationResetAndReinjectOnDecodeThread];
                continue;
            }
            if (_videoPackets->size() == 0 && _laneReadbackUndo.empty() && !_laneReadbackHasRollbackTail &&
                _demuxer->eof() && _eofDrainedGen.load() != _generation.load()) {
                drainEOF = true;
            }
        }

        if (drainEOF) {
            SP_G1_ABORT("eof");

            [_decoder setCatchUpTargetUs:-1];
            int64_t gen = _generation.load();
            SPDecodedVideoOutput decoded = [_decoder decodePacketOutput:nullptr];
            if (spDebug() && decoded.pixelBuffer && _dbgDrainFrames < 12) {
                SPLOG(@"[Drain] 帧%d pts=%.3f", _dbgDrainFrames, decoded.ptsUs / 1e6);
            }
            if (decoded.pixelBuffer) {
                _dbgDrainFrames++;
                if (gen == _generation.load()) {
                    [self processDecodedVideoOutput:decoded generation:gen];
                } else {
                    CVPixelBufferRelease(decoded.pixelBuffer);
                }
            } else {

                if (_decoder.lastError != 0) {
                    _decErrStreak.fetch_add(1);
                    if (spDebug()) SPLOG(@"[Drain] 排空遇真实解码错误 err=%d（计入错误流检测）",
                                         _decoder.lastError);
                }
                if (spDebug()) SPLOG(@"[Drain] 排空完成 共%d帧", _dbgDrainFrames);
                _dbgDrainFrames = 0;
                [_generator breakPairChain];
                [self reinjectReturnedSourceFrames];
                _eofDrainedGen.store(gen);
            }
            continue;
        }

        // Rollback is the original untouched normal path, before later queued
        // packets. Pending undo stays private until commit or rejection.
        if (!_lanePendingReadback && _laneReadbackUndo.pop(tp)) {
            SP_G1_TRACE([self laneTraceGopEvent:"undo_pop" ordinal:++_laneGopTrace.popped packet:&tp disposition:"normal_path_next"]);
            // Full TaggedPacket (gen/control/discard/side data) is preserved.
        } else if (!_lanePendingReadback && _laneReadbackHasRollbackTail) {
            tp = _laneReadbackRollbackTail; _laneReadbackRollbackTail = {};
            _laneReadbackHasRollbackTail = NO;
            SP_G1_TRACE([self laneTraceGopEvent:"reject_tail_pop" ordinal:_laneGopTrace.deferred + 1 packet:&tp disposition:"normal_path_next"]);
        } else if (!_videoPackets->pop(tp)) break;
        if (_lanePendingReadback) {
            if ([self laneDeferReadbackTaggedPacket:&tp generation:tp.gen]) continue;
            if (!_laneReadbackUndo.empty()) {
                // The rejecting current packet was never cloned/transformed or
                // counted. Hold it after undo without allocating or losing it.
                SP_G1_TRACE([self laneTraceGopEvent:"reject_tail" ordinal:_laneGopTrace.deferred + 1 packet:&tp disposition:"after_undo"]);
                _laneReadbackRollbackTail = tp; tp = {};
                _laneReadbackHasRollbackTail = YES;
                continue;
            }
        }
        AVPacket *pkt = tp.pkt;
        if (!pkt) continue;
        applyPendingFlush();

        {
            int64_t curGen = _generation.load();
            bool accept = (tp.gen == curGen) ||
                          (_seekPending.load() && tp.gen >= _seekBurstBaseGen.load());
            if (!accept) {
                av_packet_free(&pkt);
                continue;
            }
        }

        const BOOL laneIsKey = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
        sptrial::PacketIdentity laneRawIdentity = sptrial::PacketIdentity::from(pkt);
        if (_laneReadbackOriginTicks != 0) laneRawIdentity.shiftTicks(_laneReadbackOriginTicks);

        {
            const int64_t rawPtsUs = pkt->pts != AV_NOPTS_VALUE ? av_rescale_q(pkt->pts, _videoTimeBase, AV_TIME_BASE_Q) : -1;
            const int64_t pktTsUs = pkt->dts != AV_NOPTS_VALUE ? av_rescale_q(pkt->dts, _videoTimeBase, AV_TIME_BASE_Q) : rawPtsUs;

            if (tp.discard && videoLastPktTsUs > videoReplayFrontierUs) videoReplayFrontierUs = videoLastPktTsUs;
            const bool inReplay = videoReplayFrontierUs >= 0 && pktTsUs >= 0 && pktTsUs <= videoReplayFrontierUs;
            if (!inReplay && videoReplayFrontierUs >= 0 && pktTsUs > videoReplayFrontierUs) videoReplayFrontierUs = -1;
            const bool judge = pktTsUs >= 0 && videoLastPktTsUs >= 0 && !tp.discard && !inReplay &&
                               tp.gen == _generation.load() && !_catchUpTargetUs.valid() && !_seekPending.load();
            const int64_t jumpUs = judge ? pktTsUs - videoLastPktTsUs : 0;
            if (judge && jumpUs < -1000000) {
                const int64_t candidate = videoLastPktTsUs + _frameIntervalUs - pktTsUs;
                const bool audioAgrees = _timelineEpochGen.load() == tp.gen &&
                    llabs(_timelineEpochOffsetUs.load() - (videoEpochOffsetUs + candidate)) < 500000;
                int run = 0; bool returned = false;
                if (!audioAgrees) videoLookahead(tp.gen, INT64_MIN, videoLastPktTsUs - 1000000, pktTsUs - 1000000, run, returned);
                if (spDebug()) {
                    SPLOG(@"[Epoch] 视频包 dts 倒退 %.3f→%.3f 候选偏移 %+.3fs audioAgrees=%d run=%d returned=%d q=%zu",
                          videoLastPktTsUs / 1e6, pktTsUs / 1e6, candidate / 1e6, (int)audioAgrees, run, (int)returned, _videoPackets->size());
                }
                if (audioAgrees || (run >= 6 && !returned)) {
                    videoEpochOffsetUs += candidate;
                    _timelineEpochOffsetUs.store(videoEpochOffsetUs);
                    _timelineEpochGen.store(tp.gen);
                    [self resilientNoteEpochOffsetUs:videoEpochOffsetUs video:YES];
                    SP_RESLOG(
                        @"视频时间轴持续重置 %+.3fs（%@）→ 建立映射偏移 %+.3fs",
                        -candidate / 1e6, audioAgrees ? @"与音频侧一致" : [NSString stringWithFormat:@"前看 %d 包成连续新轴", run],
                        videoEpochOffsetUs / 1e6);
                }
            } else if (judge && jumpUs > 1000000 && videoEpochOffsetUs > 0 && llabs(jumpUs - videoEpochOffsetUs) <= 500000 + _frameIntervalUs) {

                const bool audioAgrees = _timelineEpochGen.load() == tp.gen && llabs(_timelineEpochOffsetUs.load()) < 500000;
                int run = 0; bool returned = false;
                if (!audioAgrees) videoLookahead(tp.gen, pktTsUs - 1000000, INT64_MAX, INT64_MIN, run, returned);
                if (spDebug()) {
                    SPLOG(@"[Epoch] 视频包 dts 前跳 %.3f→%.3f = 已建立偏移 %+.3fs（回原轴候选）audioAgrees=%d run=%d returned=%d",
                          videoLastPktTsUs / 1e6, pktTsUs / 1e6, videoEpochOffsetUs / 1e6, (int)audioAgrees, run, (int)returned);
                }
                if (audioAgrees || (run >= 6 && !returned)) {
                    SP_RESLOG(@"视频时间轴回到原轴（前跳 %+.3fs 抵消映射偏移 %+.3fs，%@）→ 结束临时段",
                                        jumpUs / 1e6, videoEpochOffsetUs / 1e6,
                                        audioAgrees ? @"与音频侧一致" : [NSString stringWithFormat:@"前看 %d 包留在原轴", run]);
                    videoEpochOffsetUs = 0;
                    _timelineEpochOffsetUs.store(0);
                    _timelineEpochGen.store(tp.gen);
                    [self resilientNoteEpochOffsetUs:0 video:YES];
                }
            } else if (judge && jumpUs > 1000000 && jumpUs <= 120000000 && _containerIsMpegTs && videoPrevPktPos >= 0 && pkt->pos > videoPrevPktPos) {

                const int64_t candidate = -(jumpUs - _frameIntervalUs);
                const bool audioAgrees = _timelineEpochGen.load() == tp.gen &&
                    llabs(_timelineEpochOffsetUs.load() - (videoEpochOffsetUs + candidate)) < 500000;
                int run = 0; bool returned = false;
                if (!audioAgrees) videoLookahead(tp.gen, pktTsUs - 1000000, INT64_MAX, INT64_MIN, run, returned);
                int64_t pcrDeltaUs = -1;

                const bool zeroFilled = !audioAgrees && run >= 6 && !returned &&
                    _demuxer->tsRangeHasZeroFill(videoPrevPktPos, MAX(pkt->pos, _lastDemuxedPos.load(std::memory_order_relaxed)));
                if (!zeroFilled && !audioAgrees && run >= 6 && !returned) pcrDeltaUs = _demuxer->tsPcrDeltaUs(_videoStreamIndex, videoPrevPktPos, pkt->pos);
                if (spDebug()) {
                    SPLOG(@"[Epoch] 视频包 dts 前跳 %.3f→%.3f（%+.3fs）audioAgrees=%d run=%d returned=%d ΔPCR=%.3fs",
                          videoLastPktTsUs / 1e6, pktTsUs / 1e6, jumpUs / 1e6, (int)audioAgrees, run, (int)returned, pcrDeltaUs / 1e6);
                }
                if (audioAgrees || (pcrDeltaUs >= 0 && pcrDeltaUs < jumpUs - 1000000)) {
                    videoEpochOffsetUs += candidate;
                    _timelineEpochOffsetUs.store(videoEpochOffsetUs);
                    _timelineEpochGen.store(tp.gen);
                    [self resilientNoteEpochOffsetUs:videoEpochOffsetUs video:YES];
                    SP_RESLOG(
                        @"视频时间戳持续前移 %+.3fs 而载荷连续（%@）→ 建立映射偏移 %+.3fs",
                        jumpUs / 1e6, audioAgrees ? @"与音频侧一致" : [NSString stringWithFormat:@"ΔPCR 仅 %.3fs，前看 %d 包留在新轴", pcrDeltaUs / 1e6, run],
                        videoEpochOffsetUs / 1e6);
                }
            }
            if (pktTsUs >= 0 && !tp.discard && !inReplay) videoLastPktTsUs = pktTsUs;
            if (!tp.discard && !inReplay && pkt->pos >= 0) videoPrevPktPos = pkt->pos;
            if (videoEpochOffsetUs != 0) {

                const int64_t off = av_rescale_q(videoEpochOffsetUs, AV_TIME_BASE_Q, _videoTimeBase);
                if (pkt->pts != AV_NOPTS_VALUE) pkt->pts += off;
                if (pkt->dts != AV_NOPTS_VALUE) pkt->dts += off;
            }
        }
        const int64_t lanePktPtsUs = pkt->pts != AV_NOPTS_VALUE
            ? av_rescale_q(pkt->pts, _videoTimeBase, AV_TIME_BASE_Q)
            : (pkt->dts != AV_NOPTS_VALUE ? av_rescale_q(pkt->dts, _videoTimeBase, AV_TIME_BASE_Q) : -1);
        if (laneIsKey) {
            _laneReadbackKey = laneRawIdentity;
            _laneReadbackEpochUs = videoEpochOffsetUs;
            _laneReadbackConfigRevision = _laneConfigRevision;
            _laneReadbackAttempted = NO;
            _laneReadbackEpochValid = !tp.discard;
        } else if (videoEpochOffsetUs != _laneReadbackEpochUs || tp.discard) {
            _laneReadbackEpochValid = NO;
            _lanePendingReadback.reset();
        }
        if (tp.discard && lanePktPtsUs > discardBelowUs) discardBelowUs = lanePktPtsUs;

        if (_videoLayout.kind == spresil::Bitstream::Av1Obu && laneIsKey && pkt->size > 0 && pkt->data) {
            spresil::Av1ObuSpan seqSpan;
            if (spresil::av1FindObu(pkt->data, (size_t)pkt->size, 1, seqSpan) && seqSpan.len <= 4096) {
                const uint8_t *hdr = pkt->data + seqSpan.start;
                const bool haveCand = !_av1SeqCandidate.empty();
                const bool sameLen = haveCand && _av1SeqCandidate.size() == seqSpan.len;
                const bool sameBytes = sameLen && memcmp(_av1SeqCandidate.data(), hdr, seqSpan.len) == 0;
                int seqW = 0, seqH = 0;
                const bool parses = !sameBytes && spAv1SeqHeaderParse(hdr, seqSpan.len, &seqW, &seqH);
                const bool dryRun = _resilientDryRun.load(std::memory_order_relaxed);
                spresil::Av1SeqHeaderAction act = spresil::av1SeqHeaderAction(
                    parses, haveCand, sameLen, sameBytes, seqW != _av1SeqCandidateW || seqH != _av1SeqCandidateH, !dryRun);
                spresil::Av1SeqHeaderAction known;
                if (act == spresil::Av1SeqHeaderAction::Trial && _av1SeqMemo.lookup(hdr, seqSpan.len, _av1SeqCandidate, known)) {
                    act = known;
                } else if (act == spresil::Av1SeqHeaderAction::Trial && _av1SeqTrials >= kAv1SeqTrialBudget) {
                    act = spresil::Av1SeqHeaderAction::Adopt;
                } else if (act == spresil::Av1SeqHeaderAction::Trial) {
                    ++_av1SeqTrials;
                    const int64_t trialT0 = spNowUs();
                    const int own = spAv1TrialDecodeKeyTU(pkt->data, (size_t)pkt->size);
                    int alt = -1;
                    if (own == 0) {
                        try {
                            std::vector<uint8_t> swapped(pkt->data, pkt->data + pkt->size);
                            memcpy(swapped.data() + seqSpan.start, _av1SeqCandidate.data(), seqSpan.len);
                            alt = spAv1TrialDecodeKeyTU(swapped.data(), swapped.size());
                        } catch (const std::bad_alloc &) {
                            alt = -1;
                        }
                    }

                    act = own < 0 ? spresil::Av1SeqHeaderAction::Adopt : spresil::av1SeqHeaderTrialVerdict(own == 1, alt == 1);
                    if (own >= 0) _av1SeqMemo.record(hdr, seqSpan.len, _av1SeqCandidate, act);
                    if (spDebug()) {

                        SPLOG(@"[AV1] 关键帧 pts=%.3fs sequence header %dx%d ≠ 已验证副本 %dx%d（等长）：私有试解 带内=%d 副本=%d → %@（%.1fms，第 %d 次）",
                              lanePktPtsUs / 1e6, seqW, seqH, _av1SeqCandidateW, _av1SeqCandidateH, own, alt,
                              act == spresil::Av1SeqHeaderAction::Adopt ? @"合法切换，更新副本"
                              : act == spresil::Av1SeqHeaderAction::Replace ? @"带内头坏，以副本替换" : @"无证据，原样",
                              (spNowUs() - trialT0) / 1000.0, _av1SeqTrials);
                    }
                }
                if (act == spresil::Av1SeqHeaderAction::Adopt) {
                    _av1SeqCandidate.assign(hdr, hdr + seqSpan.len);
                    _av1SeqCandidateW = seqW;
                    _av1SeqCandidateH = seqH;
                } else if (act == spresil::Av1SeqHeaderAction::Replace && !dryRun && av_packet_make_writable(pkt) >= 0) {
                    memcpy(pkt->data + seqSpan.start, _av1SeqCandidate.data(), seqSpan.len);
                    if (++_av1SeqReplaced <= 3) {
                        SP_RESLOG(@"AV1 关键帧 pts=%.3fs 的 sequence header 载荷坏：以已验证副本原位替换（第 %d 次）",
                                            lanePktPtsUs / 1e6, _av1SeqReplaced);
                    }
                }
            }
        }

        if (!_resilientDryRun.load(std::memory_order_relaxed) && pkt->data &&
            (_videoIsProres || _videoIsMjpeg || _videoIsVp8 || _videoIsVp9)) {
            const sp::PacketCodecLane laneKind = _videoIsProres ? sp::PacketCodecLane::ProRes : _videoIsMjpeg ? sp::PacketCodecLane::Mjpeg
                                               : _videoIsVp8 ? sp::PacketCodecLane::Vp8 : sp::PacketCodecLane::Vp9;
            const std::vector<sp::PacketFixPlan> plans = sp::planPacketFixes(laneKind, pkt->data, (size_t)pkt->size, 16 - _proresGeomDropped);
            BOOL dropped = NO;
            for (const sp::PacketFixPlan &plan : plans) {
                if (plan.dropHard) {
                    ++_proresGeomDropped;
                    [self resilientNoteVideoDamageAtPts:lanePktPtsUs structure:spresil::PacketStructure::Broken key:laneIsKey size:pkt->size deliverable:NO];
                    if (_proresGeomDropped <= 3) {
                        SP_RESLOG(@"ProRes 帧 pts=%.3fs 的几何越界且无唯一候选：丢弃（不送硬解等慢失败，第 %d 次）",
                                            lanePktPtsUs / 1e6, _proresGeomDropped);
                    }
                    dropped = YES;
                    break;
                }
                if (av_packet_make_writable(pkt) < 0) break;
                sp::applyPacketFixes(pkt->data, (size_t)pkt->size, plan);
                switch (plan.kind) {
                case sp::PacketFixKind::ProResFrameSize:
                    if (++_proresGeomFixes <= 3)
                        SP_RESLOG(@"ProRes 帧 pts=%.3fs 的 frame_size 与容器包长恰差一位而帧内几何按包长闭合：改回包长（第 %d 次）",
                                            lanePktPtsUs / 1e6, _proresGeomFixes);
                    break;
                case sp::PacketFixKind::ProResGeometry:
                    if (++_proresGeomFixes <= 3)
                        SP_RESLOG(@"ProRes 帧 pts=%.3fs 的 %s 与帧内其余几何矛盾：唯一单比特候选改回（偏移 %zu → 0x%02x，第 %d 次）",
                                            lanePktPtsUs / 1e6, plan.what.c_str(), plan.fixes[0].at, plan.fixes[0].value, _proresGeomFixes);
                    break;
                case sp::PacketFixKind::JpegDhtCounts:
                    if (++_jpegCountFixes <= 3)
                        SP_RESLOG(@"MJPEG 包 pts=%.3fs 的 DHT 码长计数非法而段长链完整：唯一单比特候选改回（偏移 %zu → 0x%02x，第 %d 次）",
                                            lanePktPtsUs / 1e6, plan.fixes[0].at, plan.fixes[0].value, _jpegCountFixes);
                    break;
                case sp::PacketFixKind::JpegSegmentLengths:
                    if (++_jpegLengthFixes <= 3)
                        SP_RESLOG(@"MJPEG 包 pts=%.3fs 的 %zu 个段长字段与包内计数矛盾：按计数重建（首个偏移 %zu，第 %d 次）",
                                            lanePktPtsUs / 1e6, plan.count, plan.fixes[0].at, _jpegLengthFixes);
                    break;
                case sp::PacketFixKind::Vp8KeyframeSync:
                    if (++_vpSyncFixes <= 3)
                        SP_RESLOG(@"VP8 关键帧 pts=%.3fs 同步字一位坏（其余头字段合法）：改回 9d 01 2a（第 %d 次）",
                                            lanePktPtsUs / 1e6, _vpSyncFixes);
                    break;
                case sp::PacketFixKind::Vp9FixedFields:
                    if (++_vpSyncFixes <= 3)
                        SP_RESLOG(@"VP9 关键帧 pts=%.3fs 的 %s一位坏（其余头字段合法）：改回规范值（第 %d 次）",
                                            lanePktPtsUs / 1e6, plan.what == "frame_marker" ? "frame_marker" : "同步字", _vpSyncFixes);
                    break;
                case sp::PacketFixKind::Vp9SuperframeMarker:
                    if (++_vp9MarkerFixes <= 3)
                        SP_RESLOG(@"VP9 包 pts=%.3fs 的 superframe 索引一端 marker 坏（%s）：另一端与尺寸闭合唯一还原 0x%02x（第 %d 次）",
                                            lanePktPtsUs / 1e6, plan.what == "end" ? "尾" : "首", plan.fixes[0].value, _vp9MarkerFixes);
                    break;
                case sp::PacketFixKind::ProResDropHard:
                    break;
                }
            }
            if (dropped) {
                av_packet_free(&pkt);
                _laneGapPending = YES;
                continue;
            }
        }
        spresil::PacketInspection laneInsp =
            spresil::inspect(pkt->data, (size_t)pkt->size, _videoLayout, tp.allZero);
        const BOOL laneDry = _resilientDryRun.load(std::memory_order_relaxed);
        if (laneInsp.prefixFixAt != (size_t)-1 && laneInsp.prefixFixAt < (size_t)pkt->size && !laneDry &&
            av_packet_make_writable(pkt) >= 0) {

            pkt->data[laneInsp.prefixFixAt] = laneInsp.prefixFixByte;
            if (++_startCodePrefixFixes <= 3) {
                SP_RESLOG(@"MPEG 包 pts=%.3fs 的序列头起始码一字节坏（序列头本体与后继链完好）：就地改回（第 %d 次）",
                                    lanePktPtsUs / 1e6, _startCodePrefixFixes);
            }
            laneInsp = spresil::inspect(pkt->data, (size_t)pkt->size, _videoLayout);
        }
        const spresil::PacketStructure laneStructure = laneInsp.structure;
        const BOOL laneStructureDamaged = spresil::isDamageEvidence(laneStructure);
        const BOOL laneDeliverable = spresil::deliverable(laneInsp);
        BOOL laneRetained = NO;
        if (laneIsKey) [self laneBeginGopAtPts:lanePktPtsUs];
        if (laneStructureDamaged) {
            [self resilientNoteVideoDamageAtPts:lanePktPtsUs structure:laneStructure key:laneIsKey
                                            size:pkt->size deliverable:laneDeliverable];
            if (!laneDry) {
                if (!laneDeliverable) {

                    av_packet_free(&pkt);
                    _lanePendingReadback.reset();
                    _laneGapPending = YES;
                    continue;
                }

                if (laneInsp.resyncFrom > 0 && laneInsp.resyncFrom < (size_t)pkt->size) {

                    if (av_packet_make_writable(pkt) >= 0) {
                        const size_t tail = (size_t)pkt->size - laneInsp.resyncFrom;
                        memmove(pkt->data + laneInsp.safePrefix, pkt->data + laneInsp.resyncFrom, tail);
                        av_shrink_packet(pkt, (int)(laneInsp.safePrefix + tail));
                    }
                } else if (laneInsp.tailBroken && laneInsp.safePrefix < (size_t)pkt->size) {
                    av_shrink_packet(pkt, (int)laneInsp.safePrefix);
                }
                if (!_laneOnSW && _decoder.decodingBackend == SPVideoDecodingBackendVideoToolbox) {

                    [self laneRetainPacket:pkt];
                    laneRetained = YES;
                    if ([self laneRecoverWithPacket:pkt rawIdentity:laneRawIdentity generation:tp.gen]) {
                        _laneGapPending = NO;
                        av_packet_free(&pkt);
                        continue;
                    }
                }
            }
        } else if (_laneGapPending && !laneDry && !_lanePendingReadback) {
            if (laneIsKey) {
                _laneGapPending = NO;
            } else if (_decoder.decodingBackend == SPVideoDecodingBackendVideoToolbox) {

                [self laneRetainPacket:pkt];
                if (_laneKeyDecodedOnVT && [self laneRecoverWithPacket:pkt rawIdentity:laneRawIdentity generation:tp.gen]) {
                    _laneGapPending = NO;
                }
                av_packet_free(&pkt);
                continue;
            }

        }
        if (!laneRetained && _laneArmed) [self laneRetainPacket:pkt];

        if (_preparedDoviIPT && pkt->data && pkt->size > 8) {
            bool annexB = pkt->size > 4 && pkt->data[0] == 0 && pkt->data[1] == 0 &&
                          (pkt->data[2] == 1 || (pkt->data[2] == 0 && pkt->data[3] == 1));
            sp::DoviReshape rp;
            if (sp::doviParseRPUFromPacket(pkt->data, (size_t)pkt->size, annexB, rp,
                                           _doviNalLengthSize) &&
                rp.valid && !rp.usePrev) {
                float g[sp::kDoviGpuFloats];
                sp::doviToGpuFloats(rp, g);

                int64_t rpuPtsUs = pkt->pts != AV_NOPTS_VALUE
                    ? av_rescale_q(pkt->pts, _videoTimeBase, AV_TIME_BASE_Q) : -1;
                [_renderer queueDoviReshapeFloats:g ptsUs:rpuPtsUs];
                if (spDebug()) {
                    if (!_dbgDoviRpuLogged) {
                        _dbgDoviRpuLogged = true;
                        SPLOG(@"[DoVi] RPU: ycc[1]=%.6f ycc[2]=%.6f lms[0]=%.6f off=[%.2f %.2f %.2f] "
                              @"fullRange=%d minPq=%.0f maxPq=%.0f(≈%.0fnits) 曲线=%d 段数=[%d %d %d]",
                              rp.yccToRgb[1], rp.yccToRgb[2], rp.rgbToLms[0],
                              rp.yccOffset[0], rp.yccOffset[1], rp.yccOffset[2],
                              (int)rp.signalFullRange, rp.minPqNorm * 4095, rp.maxPqNorm * 4095,
                              10000 * pow(fmax((pow(rp.maxPqNorm, 1 / 78.84375) - 0.8359375), 0) /
                                          (18.8515625 - 18.6875 * pow(rp.maxPqNorm, 1 / 78.84375)), 1 / 0.1593017578125),
                              (int)rp.hasCurves,
                              rp.comps[0].numPieces, rp.comps[1].numPieces, rp.comps[2].numPieces);
                    }
                }
            }
        }

        int64_t cuT = _catchUpTargetUs.us();
        bool showPending = !_seekFlashDone.load() ||
                           (_firstFramePending.load() && cuT < 0);
        [_decoder setCatchUpTargetUs:(cuT >= 0 && !showPending) ? cuT : -1];

        int64_t gen = tp.gen;
        SPDecodedVideoOutput decoded = SPDecodedVideoOutputEmpty();
        BOOL laneHandled = NO;
        if (laneIsKey && _laneOnSW && !laneDry && !laneStructureDamaged) {

            laneHandled = [self laneAttemptReturnToVTWithKeyPacket:pkt output:&decoded generation:gen];
        }
        if (!laneHandled) decoded = [_decoder decodePacketOutput:pkt];

        if (laneIsKey && !laneHandled && _decoder.lastError == 0 &&
            _decoder.decodingBackend == SPVideoDecodingBackendVideoToolbox) {
            _laneKeyDecodedOnVT = YES;
        }
        CVPixelBufferRef &buf = decoded.pixelBuffer;
        int64_t &ptsUs = decoded.ptsUs;

        if (!buf && _decoder.lastError != 0) {
            if (spDebug()) {
                if (++_dbgBadFrames <= 3) SPLOG(@"[Core] 解码失败帧#%d size=%d err=%d", _dbgBadFrames, pkt->size, _decoder.lastError);
            }

            _decErrStreak.fetch_add(1);

            if (_laneOnSW) _laneSWSawError = YES;
            const BOOL laneOnVT = _decoder.decodingBackend == SPVideoDecodingBackendVideoToolbox;
            if (!laneIsKey && laneOnVT && (!laneStructureDamaged || laneDeliverable)) {
                _laneIntactFailSinceKey++;

                if (_laneKeyDecodedOnVT && _laneIntactFailSinceKey == 6 && !laneDry) {
                    if ([self laneRecoverWithPacket:pkt rawIdentity:laneRawIdentity generation:gen]) {
                        _laneGapPending = NO;
                    } else if (!_laneArmed) {
                        _laneArmed = YES;
                        SP_RESLOG(
                            @"关键帧 %.3fs 后连续 %d 帧 VT 失败：%@武装区间车道（下一关键帧起保留 GOP 包）",
                            _laneGopKeyPtsUs / 1e6, _laneIntactFailSinceKey,
                            _lanePendingReadback ? @"本 GOP 已从源回读、候选待接管；同时" : @"");
                    }
                } else if (_laneKeyDecodedOnVT && _laneIntactFailSinceKey == 6 && laneDry) {
                    SP_RESLOG(
                        @"干跑：关键帧 %.3fs 后连续 %d 帧 VT 失败（不切换）",
                        _laneGopKeyPtsUs / 1e6, _laneIntactFailSinceKey);
                }
            }
            if ((pkt->flags & AV_PKT_FLAG_KEY) && _videoParCopy && (!laneStructureDamaged || laneDeliverable)) {
                bool hevc = _videoParCopy->codec_id == AV_CODEC_ID_HEVC;
                bool h26x = hevc || _videoParCopy->codec_id == AV_CODEC_ID_H264;
                uint64_t fp = 0;
                std::vector<uint8_t> newExtra;
                size_t nxSize = 0;
                uint8_t *nx = av_packet_get_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA, &nxSize);
                if (nx && nxSize > 0) {
                    newExtra.assign(nx, nx + nxSize);
                    fp = 1469598103934665603ull;
                    for (uint8_t b : newExtra) { fp ^= b; fp *= 1099511628211ull; }
                } else if (h26x) {
                    newExtra = spExtractAnnexBParamSets(pkt->data, pkt->size, hevc, &fp);
                }

                bool haveNewParams = !newExtra.empty();
                bool persistentVtFail = !haveNewParams && _decErrStreak.load() >= 12 &&
                    _decoder.decodingBackend ==
                        SPVideoDecodingBackendVideoToolbox;
                uint64_t attemptFp = haveNewParams ? fp : 0xFA11BACCull;
                int64_t nowRb = spNowUs();
                bool coolingDown = (attemptFp == _rebuildFailFp &&
                                    nowRb - _rebuildFailAtUs < 2000000);
                if ((haveNewParams || persistentVtFail) && !coolingDown) {

                    AVCodecParameters *rpar = avcodec_parameters_alloc();
                    bool rparOk = rpar && avcodec_parameters_copy(rpar, _videoParCopy) >= 0;
                    if (rparOk && haveNewParams) {
                        av_freep(&rpar->extradata);
                        rpar->extradata = (uint8_t *)av_mallocz(newExtra.size() + AV_INPUT_BUFFER_PADDING_SIZE);
                        if (rpar->extradata) {
                            memcpy(rpar->extradata, newExtra.data(), newExtra.size());
                            rpar->extradata_size = (int)newExtra.size();
                        } else {
                            rpar->extradata_size = 0;
                            rparOk = false;
                        }
                    }
                    id<SPVideoDecoding> nd = nil;
                    if (rparOk && haveNewParams) {

                        rpar->width = 0;
                        rpar->height = 0;
                        SPVideoDecoder *vt2 = [[SPVideoDecoder alloc] init];
                        vt2.spLogId = _spLogId;

                        vt2.firstPacketHint = hevc ? sp::packetDataSnapshot(pkt) : nil;
                        int vtSetupRet = [vt2 setupWithCodecParameters:rpar
                                                    timeBaseNumerator:_videoTimeBase.num
                                                  timeBaseDenominator:_videoTimeBase.den];
                        vt2.firstPacketHint = nil;
                        if (vtSetupRet == 0) {
                            if (_interpolationCodedInterlacedSeen) {
                                // The media-session verdict is sticky, while
                                // rpar may still carry the container's stale
                                // progressive/unknown field_order. Carry the
                                // intent into the replacement VT session before
                                // its first decoded access unit.
                                [vt2 requestFrameLocalDeinterlacingForKnownCodedContent];
                            }
                            if (_frameInterpolationCommittedModeValue.load() ==
                                SPFrameInterpolationModeDoubleRate) {
                                [vt2 setInterpolationScanEnabled:
                                         !_interpolationCodedInterlacedSeen
                                               codecParameters:rpar];
                            }

                            SPDecodedVideoOutput candidate =
                                [vt2 decodePacketOutput:pkt];
                            if (candidate.pixelBuffer) {
                                nd = vt2;
                                decoded = candidate;
                            } else {
                                [vt2 shutdown];
                            }
                        } else {
                            [vt2 shutdown];
                        }
                    }
                    if (rparOk && !nd) {

                        rpar->width = _videoParCopy->width;
                        rpar->height = _videoParCopy->height;
                        SPFFmpegDecoder *sw2 = [[SPFFmpegDecoder alloc] init];
                        sw2.spLogId = _spLogId;
                        sw2.previewMode = _previewMode;
                        sw2.planarOutputEnabled = spPlanarOutputEnabled();
                        sw2.rgbSourceMatrix = _preparedColorSpace;
                        if ([sw2 setupWithCodecParameters:rpar
                                        timeBaseNumerator:_videoTimeBase.num
                                      timeBaseDenominator:_videoTimeBase.den] == 0) {
                            SPDecodedVideoOutput candidate =
                                [sw2 decodePacketOutput:pkt];
                            if (candidate.pixelBuffer || sw2.lastError == 0) {
                                nd = sw2;
                                decoded = candidate;
                            } else {
                                [sw2 shutdown];
                            }
                        } else {
                            [sw2 shutdown];
                        }
                    }
                    if (nd) {
                        if (spDebug()) SPLOG(@"[Core] 解码器重建成功 → %@（关键帧%s）",
                                             nd.decoderName, buf ? "已解出" : "已喂入");

                        [self laneDrainDecoder:_decoder generation:gen];
                        const BOOL wasVT = _decoder.decodingBackend == SPVideoDecodingBackendVideoToolbox;
                        [_decoder shutdown];
                        _decoder = nd;

                        _laneOnSW = wasVT && nd.decodingBackend == SPVideoDecodingBackendFFmpegSoftware &&
                                    !_resilientDryRun.load(std::memory_order_relaxed);
                        if (_laneOnSW && _laneReturnPendingVerify) {

                            _laneReturnFailures++;
                            SP_RESLOG(@"切回 VT 未经验证即退回软解（第 %d 次）", _laneReturnFailures);
                        }
                        _laneReturnPendingVerify = NO;
                        _laneSWSawError = NO;
                        [self publishReplacedDecoderName:nd];
                        _decErrStreak.store(0);
                        _rebuildFailFp = 0;

                        if (haveNewParams && _videoParCopy) {
                            ++_laneConfigRevision;
                            av_freep(&_videoParCopy->extradata);
                            _videoParCopy->extradata = (uint8_t *)av_mallocz(newExtra.size() + AV_INPUT_BUFFER_PADDING_SIZE);
                            if (_videoParCopy->extradata) {
                                memcpy(_videoParCopy->extradata, newExtra.data(), newExtra.size());
                                _videoParCopy->extradata_size = (int)newExtra.size();
                            } else {
                                _videoParCopy->extradata_size = 0;
                            }
                        }
                    } else {
                        _rebuildFailFp = attemptFp;
                        _rebuildFailAtUs = nowRb;

                        if (!haveNewParams && rparOk) {
                            _laneSWCandidateRejected = YES;
                            [self requestAlternateVideoTrackReopenWithReason:@"VT 持续失败且软解候选也解不了本关键帧" pending:NULL];
                        }
                        if (spDebug()) SPLOG(@"[Core] 解码器重建失败（保留原解码器）");
                    }
                    avcodec_parameters_free(&rpar);
                }
            }
        } else if (buf) {
            _decErrStreak.store(0);
            if (_decoder.decodingBackend == SPVideoDecodingBackendVideoToolbox) _laneReturnPendingVerify = NO;

            if (!_vtWarmMarked &&
                _decoder.decodingBackend ==
                    SPVideoDecodingBackendVideoToolbox) {
                _vtWarmMarked = YES;
                std::lock_guard<std::mutex> wl(sVtWarmMtx);
                sVtWarmKeys.insert(_vtWarmKey);
            }
        }
        av_packet_free(&pkt);
        if (!buf) continue;

        cuT = _catchUpTargetUs.us();
        if (cuT >= 0 && ptsUs < cuT && ptsUs >= 0 &&
            (_seekFlashDone.load() || _firstFramePending.load())) {
            CVPixelBufferRelease(buf);
            continue;
        }

        int64_t curGen = _generation.load();
        bool inBurst = _seekPending.load() && gen >= _seekBurstBaseGen.load();
        if (curGen == gen || inBurst) {

            if (cuT >= 0 && ptsUs >= cuT && !_firstFramePending.load()) {
                _seekFramePending.store(true);
            }

            if (discardBelowUs >= 0 && ptsUs <= discardBelowUs) {
                CVPixelBufferRelease(buf);
                continue;
            }
            if (ptsUs > _laneLastQueuedPtsUs) _laneLastQueuedPtsUs = ptsUs;
            [self processDecodedVideoOutput:decoded generation:gen];
        } else {

            CVPixelBufferRelease(buf);
        }
        } // @autoreleasepool
    }
    [self laneReleaseGop];
    SP_G1_REASON("decode_exit");
    [self laneDiscardReadbackState];
    [self destroyMotionInterpolatorOnDecodeThread];
    [_generator discardReturnedFrames];
}

- (void)setMotionCompareEnabled:(BOOL)enabled {
    _motionCompareEnabled.store(enabled);

    [_renderer setCompareSplitEnabled:enabled];

    if (_state != SPPlayerStatePlaying && _lastFrameBuffer) {
        std::lock_guard<std::mutex> rlock(_renderMtx);
        [self syncCompareSourceForSynthetic:_lastFrameSynthetic gen:_lastFrameGeneration];
        [_renderer renderPixelBuffer:_lastFrameBuffer];
    }
}

- (void)syncCompareSourceForSynthetic:(BOOL)synthetic gen:(int64_t)gen {
    bool want = _motionCompareEnabled.load(std::memory_order_relaxed) && synthetic &&
                _compareRealFrame && _compareRealFrameGen == gen;
    if (want) {
        [_renderer setCompareBuffer:_compareRealFrame];
        _rendererCompareActive = true;
    } else if (_rendererCompareActive) {
        [_renderer setCompareBuffer:NULL];
        _rendererCompareActive = false;
    }
}

#pragma mark - First-frame delivery

- (BOOL)presentDecodedFrame:(const DecodedFrame &)frame {
    // Defensive last line: callers are expected to gate before popping, but a
    // future direct-present path must not pair a new-session pixel buffer with
    // previous-session color/DoVi/layer state.
    if (_rendererConfiguredOpenGeneration.load(std::memory_order_acquire) !=
        _openGeneration.load(std::memory_order_acquire)) {
        return NO;
    }

    if (_presentRetryPending && _lastFrameSynthetic) {
        _generator.counters->dropped.fetch_add(1);
    }
    if (!frame.synthetic &&
        _frameInterpolationCommittedModeValue.load() != SPFrameInterpolationModeOff) {

        if (_compareRealFrame) CVPixelBufferRelease(_compareRealFrame);
        _compareRealFrame = CVPixelBufferRetain(frame.buffer);
        _compareRealFrameGen = frame.gen;
    }
    if (_rendererCompareActive || frame.synthetic) {
        [self syncCompareSourceForSynthetic:frame.synthetic gen:frame.gen];
    }
    [self updateSubtitleTextureForTime:frame.ptsUs];

    if (_preparedDoviIPT) {
        [_renderer bindDoviReshapeForPtsUs:frame.ptsUs frameIntervalUs:_frameIntervalUs];
    }
    BOOL submitted = [_renderer renderPixelBuffer:frame.buffer];
    _presentRetryPending = !submitted;
    if (submitted && frame.synthetic) _generator.counters->presented.fetch_add(1);
    if (submitted) {
        _sessionEverPresented.store(true);
        // Only the first accepted frame of a generation needs publication.
        // Avoid a contended atomic write on every steady-state video frame.
        if (_lastSubmittedVideoGeneration.load(std::memory_order_relaxed) !=
            frame.gen) {
            _lastSubmittedVideoGeneration.store(frame.gen,
                                                std::memory_order_release);
        }
    }
    if (_lastFrameBuffer) CVPixelBufferRelease(_lastFrameBuffer);
    _lastFrameBuffer = CVPixelBufferRetain(frame.buffer);
    _lastFrameGeneration = frame.gen;
    _lastFrameSynthetic = frame.synthetic;
    _lastFrameInterpolationEpoch = frame.interpolationEpoch;
    _presentRetryCompletesPausedSeek = NO;
    _lastPresentedPtsUs = frame.ptsUs;
    _position = frame.ptsUs / 1e6;

    if (_state == SPPlayerStatePlaying && !_seekPending.load() && !_firstFramePending.load()) {
        sp::noteContentRun(_contentRun, _position);
        if (_position > _duration && (_duration > 0 || _demuxer->sourceGrowing()))
            [self extendDurationToDeliveredContentSec:_position runStartSec:_contentRun.startSec];
    } else {
        _contentRun = sp::ContentRun{};
    }
    return submitted;
}

- (void)tryPresentFirstFrame {
    // Do not pop while renderer publication is pending: the same queued frame
    // remains available for the explicit retry after configuration completes.
    if (_rendererConfiguredOpenGeneration.load(std::memory_order_acquire) !=
        _openGeneration.load(std::memory_order_acquire)) return;
    if (!_firstFramePending.load()) return;
    auto finishFirstFrame = [&](int64_t ptsUs) {
        _firstFramePending.store(false);
        _seekFramePending.store(false);
        [self notifyPosition];
        if (spDebug()) {
            if (_dbgFirstFrameUs == 0) {
                _dbgFirstFrameUs = spNowUs();
                SPLOG(@"[Core] 首帧立即上屏: %lldms pts=%.2fs (从app启动)",
                      (_dbgFirstFrameUs - _appLaunchUs) / 1000, ptsUs / 1e6);
            }
        }
    };

    const BOOL motionPath = _frameInterpolationCommittedModeValue.load() ==
                            SPFrameInterpolationModeDoubleRate;
    auto motionFrames = motionPath ? _motionFramesPublished.load() : nullptr;
    if (motionPath && !motionFrames) return;
    BoundedQueue<DecodedFrame> *q = motionPath ? motionFrames.get() : _frames.get();
    DecodedFrame f;
    while (q->tryPop(f, std::chrono::milliseconds(0))) {
        SPImmediateFrameSelectionContext context;
        context.currentGeneration = _generation.load();
        context.minimumPtsUs = _catchUpTargetUs.us();
        if (motionPath) {
            context.syntheticPolicy = {
                true,
                _frameInterpolationModeValue.load() ==
                    SPFrameInterpolationModeDoubleRate,
                _interpolationPolicyEpoch.load(),
            };
        }
        SPFrameSelectionDecision decision =
            spEvaluateImmediateFrame(spFrameMetadata(f), context);
        if (decision.action != SPFrameSelectionAction::Select) {

            if (f.synthetic) _generator.counters->dropped.fetch_add(1);
            CVPixelBufferRelease(f.buffer);
            continue;
        }
        [self presentDecodedFrame:f];
        CVPixelBufferRelease(f.buffer);
        finishFirstFrame(f.ptsUs);
        return;
    }
}

#pragma mark - Audio worker

- (void)audioLoop {

    NSMutableData *pcm = [NSMutableData dataWithCapacity:32768];
    int64_t landTrimLoggedGen = -1;
    int audioOutlierRun = 0;
    int64_t audioEpochOffsetUs = 0;

    auto audioLookahead = [&](int64_t gen, int64_t fromUs, int64_t breakBelow, int64_t breakAbove, int64_t* firstPos, int& run, bool& broke) {
        int64_t prev = fromUs;
        _audioPackets->peekEach(64, [&](const TaggedPacket& q) {
            if (!q.pkt || q.control || q.gen != gen) return true;
            if (firstPos && *firstPos < 0 && q.pkt->pos >= 0) *firstPos = q.pkt->pos;
            if (q.pkt->pts == AV_NOPTS_VALUE) return true;
            const int64_t us = av_rescale_q(q.pkt->pts, _audioTimeBase, AV_TIME_BASE_Q) + audioEpochOffsetUs;
            if (us < prev - 40000 || us < breakBelow || us > breakAbove) { broke = true; return false; }
            prev = us; ++run; return true;
        });
    };
    int64_t audioPrevPktPos = -1;
    int audioErrRun = 0;
    int64_t audioErrFirstUs = -1;
    int audioAc3Fixes = 0;
    while (true) {
        @autoreleasepool {

            if (_audioFlushPending.exchange(false)) {
                [_audioDecoder flush];

                int64_t tgt = _audioTrimTargetUs.sample().us;
                _audioNextPtsUs = tgt >= 0 ? tgt : -1;
                audioOutlierRun = 0;
                audioEpochOffsetUs = 0;
                audioErrRun = 0;
            }

            if (_flacMd5UnneededGen.load(std::memory_order_relaxed) >= 0 &&
                _flacMd5UnneededGen.load(std::memory_order_acquire) == _openGeneration.load(std::memory_order_acquire) &&
                _audioDecoder.nativeMd5Active) {
                [_audioDecoder stopNativeMd5];
                if (spDebug()) SPLOG(@"[Audio] FLAC 原生 MD5 已停：尾帧证明声明总样本数与文件一致");
            }
            TaggedPacket tp;
            if (!_audioPackets->pop(tp)) break;
            if (tp.control) {

                if (_audioOutput && _running.load(std::memory_order_relaxed) &&
                    tp.gen == _generation.load()) {
                    const int32_t ctlEpoch = [_audioOutput currentEpoch];
                    [_audioOutput servicePendingRateSwitchWithEpoch:ctlEpoch];

                    if (_audioActive && _audioEofDrainedGen.load() == tp.gen) {
                        [_audioOutput drainStretchAtEOFWithEpoch:ctlEpoch];
                        if (spDebug()) SPLOG(@"[Audio] EOF 后切速：变速器残留再次排空");
                    }
                }
                continue;
            }
            if (!_running.load(std::memory_order_relaxed)) {

                if (tp.pkt) av_packet_free(&tp.pkt);
                continue;
            }
            AVPacket *pkt = tp.pkt;
            const int64_t audioPrevPos = audioPrevPktPos;
            const int64_t audioPktPos = pkt ? pkt->pos : -1;
            if (audioPktPos >= 0) audioPrevPktPos = audioPktPos;

            if (_audioFlushPending.exchange(false)) {
                [_audioDecoder flush];
                int64_t tgt2 = _audioTrimTargetUs.sample().us;
                _audioNextPtsUs = tgt2 >= 0 ? tgt2 : -1;
                audioOutlierRun = 0;
                audioEpochOffsetUs = 0;
                audioPrevPktPos = -1;
            }

            {
                int rb = _audioRebuildTrack.exchange(-2);

                if (_audioParFixPending.load(std::memory_order_acquire)) [self applyPendingAudioParFixOnAudioThread];

                if (rb < 0 && _audioOutput &&
                    _audioDecoder.outputChannels != [_audioOutput outputChannels]) {
                    rb = _currentAudioTrackPub.load();
                }
                if (rb >= 0) {
                    auto itp = _audioParCopies.find(rb);
                    auto itt = _audioTrackTimeBases.find(rb);
                    if (itp != _audioParCopies.end() && itt != _audioTrackTimeBases.end()) {
                        SPAudioDecoder *nd = [[SPAudioDecoder alloc] init];
                        nd.spLogId = _spLogId;
                        nd.nativeMd5Enabled = spFlacNativeMd5Wanted(itp->second, nullptr);
                        const uint64_t outMask = _audioOutput ? [_audioOutput outputChannelMask] : 0;
                        if ([nd setupWithCodecParameters:itp->second outputChannelMask:outMask] == 0) {
                            [_audioDecoder shutdown];
                            _audioDecoder = nd;
                            _audioTimeBase = itt->second;
                            if (spDebug()) SPLOG(@"[Track] 音频解码器已重建（流#%d）", rb);
                        } else {
                            SPLOG(@"[Track] 音轨 流#%d 解码器重建失败，保留原轨", rb);
                        }
                    }
                }
            }
            if (!pkt) {

                if (_running.load() && tp.gen == _generation.load()) {
                    int32_t drainEpoch = _audioOutput ? [_audioOutput currentEpoch] : 0;
                    while (true) {

                        if (!_running.load() || tp.gen != _generation.load()) break;
                        const int ch = _audioDecoder.outputChannels;
                        pcm.length = 0;
                        int r = [_audioDecoder decodePacket:nullptr into:pcm];
                        if (pcm.length > 0 && ch > 0 && _audioActive &&
                            tp.gen == _generation.load()) {
                            int frames = (int)(pcm.length / ((size_t)ch * sizeof(float)));
                            [_audioOutput writePCM:(const float *)pcm.bytes frames:frames
                                          channels:ch
                                              rate:_playbackRate.load()
                                     expectedEpoch:drainEpoch];
                        }
                        if (r <= 0) break;
                    }

                    if (_audioActive && _running.load() && tp.gen == _generation.load()) {
                        [_audioOutput drainStretchAtEOFWithEpoch:drainEpoch];
                    }
                    {

                        if (tp.gen == _generation.load()) [self flacDurationCheckAfterEofWithGen:tp.gen];

                        _audioEofDrainedGen.store(tp.gen);
                        if (tp.gen == _generation.load() && spDebug())
                            SPLOG(@"[Audio] EOF 尾样本已排空");
                    }
                }
                continue;
            }

            int32_t pktEpoch = _audioOutput ? [_audioOutput currentEpoch] : 0;
            if (tp.gen != _generation.load()) {
                av_packet_free(&pkt);
                continue;
            }
            if (tp.discard) {
                av_packet_free(&pkt);
                continue;
            }

            const int ch = _audioDecoder.outputChannels;
            const size_t frameBytes = (size_t)ch * sizeof(float);

            {
                const int cid = _audioDecoder.codecIdValue;
                if ((cid == AV_CODEC_ID_AC3 || cid == AV_CODEC_ID_EAC3) && pkt->size >= 8 && pkt->data) {
                    spresil::ByteFix fx;
                    if (spresil::ac3FrameSizeFix(pkt->data, (size_t)pkt->size, true, true, _audioDecoder.inputSampleRate, fx) && av_packet_make_writable(pkt) >= 0) {
                        const uint8_t was = pkt->data[fx.at];
                        pkt->data[fx.at] = fx.value;
                        if (++audioAc3Fixes <= 3) {
                            SP_RESLOG(@"%@ 帧 pts=%.3fs 帧头几何与包长矛盾、原存 CRC 支持唯一候选：字节 %zu 0x%02x→0x%02x（第 %d 次）",
                                                cid == AV_CODEC_ID_AC3 ? @"AC-3" : @"E-AC-3",
                                                pkt->pts != AV_NOPTS_VALUE ? av_rescale_q(pkt->pts, _audioTimeBase, AV_TIME_BASE_Q) / 1e6 : -1.0,
                                                fx.at, was, fx.value, audioAc3Fixes);
                        }
                    }
                }
            }

            {
                const int cid = _audioDecoder.codecIdValue;
                const bool rawPcm = cid >= AV_CODEC_ID_PCM_S16LE && cid < AV_CODEC_ID_ADPCM_IMA_QT;
                if (!rawPcm && pkt->size > 0 && pkt->data && spresil::allZero(pkt->data, (size_t)pkt->size)) {
                    av_packet_free(&pkt);
                    continue;
                }
            }
            pcm.length = 0;
            const int dres = [_audioDecoder decodePacket:pkt into:pcm];
            if (frameBytes == 0 || pcm.length % frameBytes != 0) pcm.length = 0;

            const sp::AudioDecodeSignal sig = sp::classifyAudioDecode(dres, pkt->size, (size_t)pcm.length, _audioDecoder.lastCleanFrames,
                                                                      _audioDecoder.lastErrorFlaggedFrames);
            if (sig.voiced) {
                audioErrRun = 0;
                _audioSessionPcmFrames.fetch_add((int64_t)(pcm.length / frameBytes));
            } else if (sig.failure) {
                if (audioErrRun++ == 0) {
                    audioErrFirstUs = pkt->pts != AV_NOPTS_VALUE ? av_rescale_q(pkt->pts, _audioTimeBase, AV_TIME_BASE_Q) : -1;
                    if (_demuxer && audioPktPos >= 0) _demuxer->noteAudioDecodeError(audioPktPos);
                }
                if (audioErrRun >= sp::kAudioDecodeFailureRunToRecover && tp.gen == _generation.load() && !_audioRecoveryRequested.exchange(true)) {
                    const int64_t failUs = audioErrFirstUs;
                    const int64_t og = _openGeneration.load(std::memory_order_acquire);
                    SPLOG(@"[Resilient] 音轨 流#%d 连续 %d 包解码失败（首包 %.3fs，本会话已出声 %lld 帧）→ 请求音轨恢复",
                          _audioStreamIndex, audioErrRun, failUs / 1e6, (long long)_audioSessionPcmFrames.load());
                    dispatch_async(dispatch_get_main_queue(), ^{ [self recoverAudioAfterDecodeFailureAtUs:failUs openGen:og]; });
                }
            }

            const auto trimSample = _audioTrimTargetUs.sample();
            const int64_t cuT = trimSample.us;

            if (tp.gen != _generation.load()) {
                av_packet_free(&pkt);
                continue;
            }

            int64_t pktUs = (pkt->pts != AV_NOPTS_VALUE)
                ? av_rescale_q(pkt->pts, _audioTimeBase, AV_TIME_BASE_Q) : AV_NOPTS_VALUE;
            av_packet_free(&pkt);
            if (pcm.length > 0 && _audioActive) {

                int frames = (int)(pcm.length / frameBytes);
                const float *samples = (const float *)pcm.bytes;
                int64_t contentUs = pktUs;
                if (cuT >= 0 && pktUs != AV_NOPTS_VALUE) {
                    int64_t endUs = pktUs + (int64_t)frames * 1000000 / 48000;
                    if (endUs <= cuT) {
                        continue;
                    }
                    if (pktUs < cuT) {
                        int skip = (int)((cuT - pktUs) * 48 / 1000);
                        if (skip > frames) skip = frames;
                        samples += (size_t)skip * ch;
                        frames -= skip;
                        contentUs = cuT;
                    }

                    _audioTrimTargetUs.consumeIfStill(trimSample);
                }

                if (_audioNextPtsUs < 0) {
                    const auto land = _audioLandingTrimUs.sample();
                    const auto d = spEvaluateLandingAudioTrim(
                        contentUs, frames, _audioNextPtsUs, land, tp.gen,
                        kSPLandingTrimMaxUs, AV_NOPTS_VALUE);

                    if (d.action != SPLandingTrimDecision::Pass && spDebug() &&
                        landTrimLoggedGen != tp.gen) {
                        landTrimLoggedGen = tp.gen;
                        SPLOG(@"[Seek] 落点音频修剪 %.0fms（音频 %.3fs → 关键帧 %.3fs）",
                              (land.us - contentUs) / 1000.0, contentUs / 1e6,
                              land.us / 1e6);
                    }
                    if (d.action == SPLandingTrimDecision::DropWhole) {
                        continue;
                    }
                    if (d.action == SPLandingTrimDecision::TrimHead) {
                        samples += (size_t)d.skipFrames * ch;
                        frames -= d.skipFrames;
                        contentUs = d.contentUs;
                    }
                }

                if (audioEpochOffsetUs != 0 && contentUs != AV_NOPTS_VALUE) contentUs += audioEpochOffsetUs;
                if (frames > 0 && contentUs != AV_NOPTS_VALUE && _audioNextPtsUs >= 0) {

                    int64_t delta;
                    if (contentUs >= _audioNextPtsUs) {
                        uint64_t d = (uint64_t)contentUs - (uint64_t)_audioNextPtsUs;
                        delta = d > 130000000ULL ? 130000000 : (int64_t)d;
                    } else {
                        uint64_t d = (uint64_t)_audioNextPtsUs - (uint64_t)contentUs;
                        delta = d > 130000000ULL ? -130000000 : -(int64_t)d;
                    }

                    if (audioOutlierRun > 0) {
                        audioOutlierRun--;
                        contentUs = _audioNextPtsUs;
                        delta = 0;
                    } else if (delta > 40000 || delta < -40000) {
                        int idx = 0, found = -1;
                        const int64_t lo = _audioNextPtsUs - 40000, hi = _audioNextPtsUs + 2000000;
                        const int64_t jumpedUs = contentUs;
                        const bool forward = delta > 0;
                        _audioPackets->peekEach(64, [&](const TaggedPacket& q) {
                            if (!q.pkt || q.control || q.gen != tp.gen) return true;
                            if (q.pkt->pts != AV_NOPTS_VALUE) {
                                const int64_t us = av_rescale_q(q.pkt->pts, _audioTimeBase, AV_TIME_BASE_Q) + audioEpochOffsetUs;
                                const bool reversed = forward ? us < jumpedUs - 40000 : us > jumpedUs + 40000;
                                if (us >= lo && us <= hi && reversed) { found = idx; return false; }
                            }
                            idx++;
                            return true;
                        });
                        if (found >= 0) {
                            if (spDebug()) SPLOG(@"[Audio] 孤立 PTS 离群 %+.0fms（%d 包后回到旧时间轴）→ 按连续样本入环",
                                                 delta / 1000.0, found + 1);
                            audioOutlierRun = found;
                            contentUs = _audioNextPtsUs;
                            delta = 0;
                        } else if (delta < -40000) {

                            int run = 0; bool broke = false;
                            audioLookahead(tp.gen, jumpedUs, INT64_MIN, _audioNextPtsUs - 40000, nullptr, run, broke);
                            const int64_t offset = _audioNextPtsUs - jumpedUs;
                            const bool videoAgrees = _timelineEpochGen.load() == tp.gen &&
                                llabs(_timelineEpochOffsetUs.load() - (audioEpochOffsetUs + offset)) < 500000;
                            if ((run >= 6 && !broke) || videoAgrees) {
                                audioEpochOffsetUs += offset;
                                _timelineEpochOffsetUs.store(audioEpochOffsetUs);
                                _timelineEpochGen.store(tp.gen);
                                [self resilientNoteEpochOffsetUs:audioEpochOffsetUs video:NO];
                                SP_RESLOG(
                                    @"音频时间轴持续重置 %+.0fms（前看 %d 包成连续新轴%@）→ 建立映射偏移 %+.3fs，内容按连续样本入环",
                                    delta / 1000.0, run, videoAgrees ? @"，与视频侧一致" : @"", audioEpochOffsetUs / 1e6);
                                contentUs = _audioNextPtsUs;
                                delta = 0;
                            }
                        } else if (delta > 40000 && audioEpochOffsetUs > 0 && llabs(delta - audioEpochOffsetUs) < 500000) {

                            int run = 0; bool broke = false;
                            audioLookahead(tp.gen, jumpedUs, jumpedUs - 40000, INT64_MAX, nullptr, run, broke);
                            const bool videoAgrees = _timelineEpochGen.load() == tp.gen && llabs(_timelineEpochOffsetUs.load()) < 500000;
                            if ((run >= 6 && !broke) || videoAgrees) {
                                SP_RESLOG(
                                    @"音频时间轴回到原轴（前跳 %+.0fms 抵消映射偏移 %+.3fs，前看 %d 包留在原轴%@）→ 结束临时段",
                                    delta / 1000.0, audioEpochOffsetUs / 1e6, run, videoAgrees ? @"，与视频侧一致" : @"");
                                contentUs -= audioEpochOffsetUs;
                                audioEpochOffsetUs = 0;
                                _timelineEpochOffsetUs.store(0);
                                _timelineEpochGen.store(tp.gen);
                                [self resilientNoteEpochOffsetUs:0 video:NO];
                                const int64_t residual = contentUs - _audioNextPtsUs;
                                if (residual > -40000 && residual < 40000) { contentUs = _audioNextPtsUs; delta = 0; }
                                else delta = residual;
                            }
                        } else if (delta > 1000000 && delta <= 120000000 && _containerIsMpegTs && audioPrevPos >= 0) {

                            int run = 0; bool broke = false;
                            int64_t posB = audioPktPos;
                            audioLookahead(tp.gen, jumpedUs, jumpedUs - 40000, INT64_MAX, &posB, run, broke);
                            const int64_t offset = -delta;
                            const bool videoAgrees = _timelineEpochGen.load() == tp.gen &&
                                llabs(_timelineEpochOffsetUs.load() - (audioEpochOffsetUs + offset)) < 500000;
                            int64_t pcrDeltaUs = -1;

                            const bool zeroFilled = !videoAgrees && run >= 6 && !broke && posB > audioPrevPos &&
                                _demuxer->tsRangeHasZeroFill(audioPrevPos, MAX(posB, _lastDemuxedPos.load(std::memory_order_relaxed)));
                            if (!zeroFilled && !videoAgrees && run >= 6 && !broke && posB > audioPrevPos) pcrDeltaUs = _demuxer->tsPcrDeltaUs(_audioStreamIndex, audioPrevPos, posB);
                            if (spDebug()) SPLOG(@"[Epoch] 音频 PTS 前跳 %+.0fms videoAgrees=%d run=%d broke=%d ΔPCR=%.3fs",
                                                 delta / 1000.0, (int)videoAgrees, run, (int)broke, pcrDeltaUs / 1e6);
                            if (videoAgrees || (pcrDeltaUs >= 0 && pcrDeltaUs < delta - 1000000)) {
                                audioEpochOffsetUs += offset;
                                _timelineEpochOffsetUs.store(audioEpochOffsetUs);
                                _timelineEpochGen.store(tp.gen);
                                [self resilientNoteEpochOffsetUs:audioEpochOffsetUs video:NO];
                                SP_RESLOG(
                                    @"音频时间戳持续前移 %+.0fms 而载荷连续（%@）→ 建立映射偏移 %+.3fs，内容按连续样本入环",
                                    delta / 1000.0, videoAgrees ? @"与视频侧一致" : [NSString stringWithFormat:@"ΔPCR 仅 %.3fs，前看 %d 包留在新轴", pcrDeltaUs / 1e6, run],
                                    audioEpochOffsetUs / 1e6);
                                contentUs = _audioNextPtsUs;
                                delta = 0;
                            }
                        }
                    }

                    sp::GapPlan holePlan;
                    if (delta > 40000 && contentUs > _audioNextPtsUs)
                        holePlan = [self audioGapPlanFrom:_audioNextPtsUs to:contentUs gen:tp.gen];
                    if (holePlan.verdict == sp::GapVerdict::SkipHole) {
                        static const float holeZeros[4096 * 8] = {0};
                        auto fillSilenceUs = [&](int64_t us) {
                            for (int64_t left = us * 48 / 1000; left > 0 && _running.load() && tp.gen == _generation.load();) {
                                const int n = left > 4096 ? 4096 : (int)left;
                                [_audioOutput writePCM:holeZeros frames:n channels:ch rate:_playbackRate.load() expectedEpoch:pktEpoch];
                                left -= n;
                            }
                        };

                        int64_t preStart = _audioNextPtsUs;
                        const int64_t nowU = _approxMediaNowUs.load();
                        if (nowU > preStart + 500000) {
                            preStart = MIN(nowU, holePlan.skipFromUs);
                            _audioResyncToNow.store(true);
                        }
                        fillSilenceUs(holePlan.skipFromUs - preStart);
                        [self queueAudioHoleJumpFrom:holePlan.skipFromUs to:holePlan.skipToUs gen:tp.gen
                                                head:_audioRingStartGen.load(std::memory_order_relaxed) != tp.gen];
                        fillSilenceUs(contentUs - holePlan.skipToUs);

                        [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::None
                                      confidence:spresil::Confidence::DecodeVerified fromUs:holePlan.skipFromUs untilUs:holePlan.skipToUs];
                        [self resilientNoteTrack:spresil::Track::Audio cls:spresil::DamageClass::None
                                      confidence:spresil::Confidence::DecodeVerified fromUs:holePlan.skipFromUs untilUs:holePlan.skipToUs];
                        SP_RESLOG(@"音视频在 %.3f–%.3fs 都没有内容：跳过（不补静音；缺口 %.3f–%.3fs 其余补静音）",
                                                                      holePlan.skipFromUs / 1e6, holePlan.skipToUs / 1e6,
                                                                      _audioNextPtsUs / 1e6, contentUs / 1e6);
                        if (!_running.load() || tp.gen != _generation.load()) continue;
                    } else if (delta > 40000 && delta <= 120000000) {

                        int64_t nowU = _approxMediaNowUs.load();
                        int64_t fillStart = _audioNextPtsUs;
                        if (nowU > fillStart + 500000) {
                            fillStart = MIN(nowU, contentUs);
                            _audioResyncToNow.store(true);
                            if (spDebug()) SPLOG(@"[Audio] 空洞填充跳过已流逝 %.1fs",
                                                 (fillStart - _audioNextPtsUs) / 1e6);
                        }
                        static const float zeros[4096 * 8] = {0};
                        int64_t fillFrames = (contentUs - fillStart) * 48 / 1000;
                        while (fillFrames > 0 && _running.load() &&
                               tp.gen == _generation.load()) {
                            int n = fillFrames > 4096 ? 4096 : (int)fillFrames;
                            [_audioOutput writePCM:zeros frames:n channels:ch
                                              rate:_playbackRate.load()
                                     expectedEpoch:pktEpoch];
                            fillFrames -= n;
                        }
                        if (spDebug()) SPLOG(@"[Audio] PTS 空洞 %.0fms → 补静音", delta / 1000.0);

                        if (!_running.load() || tp.gen != _generation.load()) {
                            continue;
                        }
                    } else if (delta < -40000 && delta >= -120000000) {

                        int64_t skip64 = -delta * 48 / 1000;
                        if (skip64 >= frames) { continue; }
                        int skip = (int)skip64;
                        samples += (size_t)skip * ch;
                        frames -= skip;
                        contentUs = _audioNextPtsUs;
                    }
                }
                if (frames > 0) {

                    const int64_t ringStartFramesSnap =
                        _audioOutput ? _audioOutput.clockFrames : 0;
                    const double writeRate = _playbackRate.load();

                    const bool segmentHead =
                        _audioRingStartGen.load(std::memory_order_relaxed) != tp.gen;
                    const int headFrames =
                        (segmentHead && frames > 4096) ? 4096 : frames;
                    BOOL accepted =
                        [_audioOutput writePCM:samples frames:headFrames channels:ch
                                          rate:writeRate
                                 expectedEpoch:pktEpoch];

                    if (accepted && segmentHead && tp.gen == _generation.load() &&
                        contentUs != AV_NOPTS_VALUE) {
                        _audioRingStartClockFrames.store(ringStartFramesSnap,
                                                         std::memory_order_relaxed);
                        _audioRingStartPtsUs.store(contentUs,
                                                   std::memory_order_relaxed);
                        _audioRingStartGen.store(tp.gen, std::memory_order_release);
                    }
                    if (accepted && headFrames < frames) {
                        accepted = [_audioOutput writePCM:samples + (size_t)headFrames * ch
                                                   frames:frames - headFrames
                                                 channels:ch
                                                     rate:writeRate
                                            expectedEpoch:pktEpoch];
                    }
                    _audioNextPtsUs = (contentUs != AV_NOPTS_VALUE)
                        ? contentUs + (int64_t)frames * 1000000 / 48000
                        : (_audioNextPtsUs >= 0 ? _audioNextPtsUs + (int64_t)frames * 1000000 / 48000 : -1);

                    if (_audioNextPtsUs >= 0) _audioRingEndPtsUs.store(_audioNextPtsUs);
                }
            }
        }
    }
    // Natural EOF is drained exactly once by the generation-tagged sentinel
    // above.  Reaching this point means the packet queue was closed by stop;
    // flushing again can only decode obsolete tail samples (abortWrites rejects
    // their publication) and needlessly extends the main-thread join.
}

- (void)serviceStreamExhaustionWithSteadyQueue:(BoundedQueue<DecodedFrame> *)steadyQueue {

    bool exhausted = _demuxer->eof() && _eofDrainedGen.load() == _generation.load() &&
                     _videoPackets->size() == 0 &&
                     (steadyQueue ? steadyQueue->size() : (size_t)0) == 0 &&
                     [_generator pendingSourceFrameCount] == 0;

    const bool audioBusy = exhausted && _audioActive &&
                           (_audioOutput.bufferedFrames > 0 || _audioPackets->size() > 0 ||
                            _audioEofDrainedGen.load() != _generation.load());
    const bool audioCarried = exhausted && _audioActive && _audioRingEndPtsUs.load() > 500000;
    if (exhausted && !_videoTrackGivenUp &&
        (!_sessionEverPresented.load() ||
         (_renderer.committedFrameCount == _openCommittedBase &&
          _renderer.hardRenderFailureCount > _openHardFailBase)) &&
        !_videoIsAttachedPic && _decErrStreak.load() >= 1) {

        BOOL altPending = NO;
        if ([self requestAlternateVideoTrackReopenWithReason:@"终局无画面" pending:&altPending]) return;

        if (altPending) return;

        if (!_swTerminalFallbackTried &&
            _decoder.decodingBackend == SPVideoDecodingBackendVideoToolbox &&
            !((audioBusy || audioCarried) && _laneSWCandidateRejected)) {
            _swTerminalFallbackTried = YES;
            _pendingForceSW = YES;
            NSString *retryPath = [_currentFilePath copy];
            _pendingForceSWPath = retryPath;
            SPLOG(@"[Core] 解码持续失败（streak=%d，VT 后端，无管线画面）→ 全量软解重试本文件",
                  _decErrStreak.load());

            const int64_t genAtFallback = _openGeneration;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_openGeneration != genAtFallback) return;
                [self openFileAtPath:retryPath error:nil];
            });
            return;
        }
        if (audioBusy || audioCarried) {

            _videoTrackGivenUp = YES;
            [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::None
                          confidence:spresil::Confidence::DecodeVerified
                              fromUs:0 untilUs:(int64_t)(MAX(_duration, _position + 0.5) * 1e6)];
            SPLOG(@"[Resilient] 视频轨不可解（streak=%d）而音频在播 → 视频标不可用，继续音频",
                  _decErrStreak.load());
            return;
        }
        SPLOG(@"[Core] 解码持续失败（streak=%d，无画面）→ 上报解码错误",
              _decErrStreak.load());
        [self setState:SPPlayerStateFailed];
        if (_displayLink) _displayLink.paused = YES;
        if (_audioOutput) [_audioOutput stop];
        if ([_delegate respondsToSelector:@selector(playerCore:didFailWithError:)]) {
            NSError *derr = [self makeErrorWithDomain:@"SPDecodeError" code:-102
                                          description:NSLocalizedString(@"error.decodeFailed", nil)
                                                phase:@"decode" diagnosis:@"decodeFailed" terminal:YES];
            [_delegate playerCore:self didFailWithError:derr];
        }
        return;
    }

    const bool endEvidence = exhausted && [self resilientEndHasEvidence];
    const double heldSec = _exhaustedSince > 0 ? spUptimeSec() - _exhaustedSince : -1.0;
    const sp::EndVerdict endVerdict = sp::evaluateVideoEnd(exhausted, audioBusy, _position, _duration, endEvidence, heldSec);
    if (!endVerdict.holding) _exhaustedSince = 0;
    else if (_exhaustedSince == 0) _exhaustedSince = spUptimeSec();
    if (endVerdict.durationUs > 0) {
        if (spDebug()) SPLOG(@"[Core] 内容耗尽于 %.2fs（声称时长 %.2fs，无独立损伤证据）→ 截断收尾", _position, _duration);
        _duration = endVerdict.durationUs / 1e6;
    }
    const BOOL partialEnd = endVerdict.partial;
    if (partialEnd) {
        const int64_t endUs = endVerdict.availableEndUs;
        _availableEndUs.store(endUs);
        [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::None
                      confidence:spresil::Confidence::DecodeVerified
                          fromUs:endUs untilUs:(int64_t)(_duration * 1e6)];
        if (_audioActive) {
            [self resilientNoteTrack:spresil::Track::Audio cls:spresil::DamageClass::None
                          confidence:spresil::Confidence::DecodeVerified
                              fromUs:endUs untilUs:(int64_t)(_duration * 1e6)];
        }
        SPLOG(@"[Resilient] PartialEnded：内容耗尽于 %.2fs（声称时长 %.2fs 保留）", _position, _duration);
    }
    if (endVerdict.ended) {
        if (spDebug()) {
            SPLOG(@"[Core] Ended 触发 lastPresented=%.3f dur=%.3f%@", _lastPresentedPtsUs / 1e6, _duration,
                  partialEnd ? @"（PartialEnded）" : @"");
        }
        if (!partialEnd) _position = _duration;
        [self flushExtendedDurationSnapshot];

        _seekPending.store(false);
        _seekFramePending.store(false);
        _seekSettleGen.store(_generation.load());
        [self setState:SPPlayerStateEnded];
        if (_displayLink) _displayLink.paused = YES;

        if (_audioOutput) [_audioOutput stop];
        [self notifyPosition];
#if !SP_APP_STORE

        if (spAutomation() && getenv("SP_AUTOREPLAY")) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self seekTo:3.0];
                if (spDebug()) SPLOG(@"[Test] Ended 后重播 seek→3s");
            });
        }
#endif
    }
}

#pragma mark - Seek-frame delivery

- (void)updateSubtitleTextureForTime:(int64_t)ptsUs {
    if (!_subtitleRenderer || !_subtitleRenderer.hasSubtitles) return;

    if (_lastViewportPx.width <= 0 || _lastViewportPx.height <= 0) {
        CGSize px = [self currentViewportPx];
        if (px.width <= 0 || px.height <= 0) return;
        _lastViewportPx = px;
    }
    id<MTLTexture> subTex = [_subtitleRenderer textureForTime:ptsUs
                                                viewportWidth:(int)_lastViewportPx.width
                                               viewportHeight:(int)_lastViewportPx.height];
    if (subTex) {
        _renderer.subtitleTexture = subTex;
        CGPoint o = _subtitleRenderer.textureOrigin;
        _renderer.subtitleRect = CGRectMake(o.x, o.y, subTex.width, subTex.height);
    } else if (_renderer.subtitleTexture) {
        _renderer.subtitleTexture = nil;
    }
}

- (BOOL)tryStepForwardFromFrameQueue {
    if (_state != SPPlayerStatePaused) return NO;
    if (_audioOnlySession.load() || _videoFps <= 0) return NO;

    if (_firstFramePending.load() || _seekPending.load() ||
        _seekFramePending.load() || _catchUpTargetUs.valid()) return NO;
    if (_lastPresentedPtsUs < 0) return NO;

    if (_rendererConfiguredOpenGeneration.load(std::memory_order_acquire) !=
        _openGeneration.load(std::memory_order_acquire)) return NO;

    if (_frameInterpolationCommittedModeValue.load() !=
        SPFrameInterpolationModeOff) return NO;
    BoundedQueue<DecodedFrame> *q = _frames.get();
    if (!q) return NO;

    SPStepFrameSelectionContext context;
    context.currentGeneration = _generation.load();
    context.lastPresentedPtsUs = _lastPresentedPtsUs;

    DecodedFrame f;
    while (q->tryPop(f, std::chrono::milliseconds(0))) {
        SPFrameSelectionDecision decision =
            spEvaluateStepFrame(spFrameMetadata(f), context);
        if (decision.action != SPFrameSelectionAction::Select) {

            CVPixelBufferRelease(f.buffer);
            continue;
        }
        const int64_t prevPtsUs = _lastPresentedPtsUs;

        [_subtitleRenderer forceNextSample];
        const BOOL submitted = [self presentDecodedFrame:f];
        CVPixelBufferRelease(f.buffer);
        if (!submitted) {

            _presentRetryCompletesPausedSeek = YES;
            [self armPausedSeekPresentation];
        }

        _frameStepAheadUs += MAX((int64_t)0, _lastPresentedPtsUs - prevPtsUs);
        [self notifyPosition];
        if (spDebug()) SPLOG(@"[Step] 弹帧 pts=%.3fs（领先音频 %.0fms）",
                             _lastPresentedPtsUs / 1e6, _frameStepAheadUs / 1000.0);
        return YES;
    }

    if (_demuxer->eof()) {
        if (spDebug()) SPLOG(@"[Step] 已在末帧，前向步进 no-op");
        return YES;
    }
    return NO;
}

- (void)tryPresentSeekFrame {
    if (_rendererConfiguredOpenGeneration.load(std::memory_order_acquire) !=
        _openGeneration.load(std::memory_order_acquire)) return;
    if (!_seekFramePending.load()) return;
    const BOOL motionPath = _frameInterpolationCommittedModeValue.load() ==
                            SPFrameInterpolationModeDoubleRate;
    auto motionFrames = motionPath ? _motionFramesPublished.load() : nullptr;
    if (motionPath && !motionFrames) return;
    BoundedQueue<DecodedFrame> *activeQueue =
        motionPath ? motionFrames.get() : _frames.get();
    DecodedFrame f;
    while (activeQueue->tryPop(f, std::chrono::milliseconds(0))) {
        SPSeekPreviewSelectionContext previewContext;
        previewContext.seekBurstBaseGeneration = _seekBurstBaseGen.load();
        if (motionPath) {
            previewContext.syntheticPolicy = {
                true,
                _frameInterpolationModeValue.load() ==
                    SPFrameInterpolationModeDoubleRate,
                _interpolationPolicyEpoch.load(),
            };
        }
        SPFrameSelectionDecision previewDecision =
            spEvaluateSeekPreviewFrame(spFrameMetadata(f), previewContext);
        if (previewDecision.action ==
                SPFrameSelectionAction::DropStaleInterpolationPolicy ||
            previewDecision.action ==
                SPFrameSelectionAction::DropBeforeSeekBurst) {

            if (f.synthetic) _generator.counters->dropped.fetch_add(1);
            CVPixelBufferRelease(f.buffer);
            continue;
        }
        _seekFlashDone.store(true);
        if (spDebug()) {
            int64_t req = _seekReqWallUs.load();
            SPLOG(@"[SeekFrame] 关键帧上屏 pts=%.2fs (目标 %.2fs) 延迟=%.1fms",
                  f.ptsUs / 1e6, _seekDisplayTargetUs.us() / 1e6,
                  req > 0 ? (spNowUs() - req) / 1000.0 : -1);
        }
        int64_t targetBeforePresent = _seekDisplayTargetUs.us();
        SPSeekSettlementDecision settlement = spEvaluateSeekSettlement(
            spFrameMetadata(f), _generation.load(), targetBeforePresent);
        if (settlement.settles && _state == SPPlayerStatePaused) {
            // Preview/key frames from rapid seeks must not consume the one-shot
            // subtitle throttle override. Arm it immediately beside the actual
            // settled-frame presentation so even back-to-back 60fps steps
            // sample libass at the exact selected PTS.
            [_subtitleRenderer forceNextSample];
        }
        BOOL submitted = [self presentDecodedFrame:f];
        CVPixelBufferRelease(f.buffer);
        [self noteFramePresentedForCoarseLanding:f.gen ptsUs:f.ptsUs submitted:submitted];

        if (settlement.settles) {
            if (submitted) _seekSettleGen.store(_generation.load());
            else _seekSettleRetryGen.store(_generation.load());
        }
        _seekFramePending.store(false);

        if (settlement.reachesPreciseTarget) {
            [self clearReachedSeekTargetAtPts:f.ptsUs direct:YES];
        }

        if (settlement.reanchorToCandidate) {

            [self reanchorClockToPts:f.ptsUs];
        }
        if (settlement.settles && _state == SPPlayerStatePaused) {

            _seekPending.store(!submitted);
            _presentRetryCompletesPausedSeek = !submitted &&
                f.gen == _generation.load();
            if (_displayLink) _displayLink.paused = submitted;
        } else if (settlement.settles) {

            _seekPending.store(false);
        }
        [self notifyPosition];
        return;
    }

}

- (void)reanchorClockToPts:(int64_t)ptsUs {
    int64_t anchorPts = ptsUs;
    if (_audioActive && _audioOutput && !_audioClockHandedOff) {
        const int64_t gen = _generation.load();
        const sp::SPCoarseAnchorDecision d = [self coarseAnchorDecisionFor:ptsUs
                                                               generation:gen];
        _audioClockBaseUs = d.baseUs;
        _audioBasePlayedFrames = d.baseFrames;
        anchorPts = d.baseUs +
            [self audioContentUsForFramesFrom:d.baseFrames to:_audioOutput.clockFrames];

        _coarseAnchorPendingGen =
            (d.pendingAdoption && _state != SPPlayerStatePaused) ? gen : -1;
        _coarseAnchorCandidateUs = ptsUs;
        if (spDebug() && llabs(anchorPts - ptsUs) > 30000) {
            if (d.source == sp::SPCoarseAnchorDecision::RingStart) {
                SPLOG(@"[Seek] 重锚到扬声器位置 %.3fs（候选帧 %.3fs，音频先行 %.0fms）",
                      anchorPts / 1e6, ptsUs / 1e6, (anchorPts - ptsUs) / 1000.0);
            } else if (_audioRingStartGen.load(std::memory_order_relaxed) == gen) {
                SPLOG(@"[Seek] 环起点 %.3fs 离落点画面 %.3fs 过远 → 按画面锚（坏交织）",
                      _audioRingStartPtsUs.load() / 1e6, ptsUs / 1e6);
            }
        }
    }
    _mediaClockPtsUs = anchorPts;
    _mediaClockWallUs = spNowUs();
}

- (sp::SPCoarseAnchorDecision)coarseAnchorDecisionFor:(int64_t)candidatePtsUs
                                           generation:(int64_t)gen {
    return sp::spEvaluateCoarseSeekAnchor(
        candidatePtsUs,
        _audioRingStartGen.load(std::memory_order_acquire),
        _audioRingStartPtsUs.load(std::memory_order_relaxed),
        _audioRingStartClockFrames.load(std::memory_order_relaxed),
        gen, _audioSegmentStartFrames,
        MAX((int64_t)1000000, _frameIntervalUs * 2));
}

- (void)adoptRingStartAnchorIfPublished {
    const int64_t gen = _generation.load();
    if (_coarseAnchorPendingGen != gen) { _coarseAnchorPendingGen = -1; return; }
    if (_audioRingStartGen.load(std::memory_order_acquire) != gen) return;
    _coarseAnchorPendingGen = -1;
    if (!_audioActive || !_audioOutput || _audioClockHandedOff) return;
    const sp::SPCoarseAnchorDecision d =
        [self coarseAnchorDecisionFor:_coarseAnchorCandidateUs generation:gen];
    if (d.source != sp::SPCoarseAnchorDecision::RingStart) {
        if (spDebug()) {
            SPLOG(@"[Seek] 环起点 %.3fs 离落点画面 %.3fs 过远 → 不换锚（坏交织）",
                  _audioRingStartPtsUs.load() / 1e6, _coarseAnchorCandidateUs / 1e6);
        }
        return;
    }
    _audioClockBaseUs = d.baseUs;
    _audioBasePlayedFrames = d.baseFrames;
    _pacePrevPresentUs = 0;
    if (spDebug() && llabs(d.baseUs - _coarseAnchorCandidateUs) > 5000) {
        SPLOG(@"[Seek] 环起点已发布 → 换锚到 %.3fs（落点画面 %.3fs，差 %.0fms）",
              d.baseUs / 1e6, _coarseAnchorCandidateUs / 1e6,
              (d.baseUs - _coarseAnchorCandidateUs) / 1000.0);
    }
}

- (void)applySteadyClockReanchorToPts:(int64_t)ptsUs {
    if ([self audioClockIsAuthoritative]) {
        _audioClockBaseUs = ptsUs;
        _audioBasePlayedFrames = _audioOutput.clockFrames;
    } else {
        _mediaClockPtsUs = ptsUs;
        _mediaClockWallUs = spNowUs();
    }
}

- (void)clearReachedSeekTargetAtPts:(int64_t)ptsUs direct:(BOOL)direct {

    if (_seekDisplayTargetUs.valid()) {
        const int64_t targetUs = _seekDisplayTargetUs.us();
        const int64_t gapTolUs = MAX((int64_t)1000000, _frameIntervalUs * 2);
        if (ptsUs - targetUs > gapTolUs) {
            BOOL hole = NO;
            {
                std::lock_guard<std::mutex> lk(_videoCoverageMtx);
                hole = _videoCoverageGen == _generation.load() &&
                       _videoCoverage.gapIsHole(targetUs, ptsUs, MAX((int64_t)200000, _frameIntervalUs * 2));
            }
            if (hole) {

                if (_holeHeadGen.load(std::memory_order_acquire) != _generation.load()) [self reanchorClockToPts:ptsUs];
                if (_seekHoleNotifiedGen != _generation.load()) {
                    _seekHoleNotifiedGen = _generation.load();
                    [self notifySkippedMissingFrom:targetUs to:ptsUs afterSeek:YES];
                }
            }
        }
    }

    _seekDisplayTargetUs.clear();
    _catchUpTargetUs.clear();
    if (spDebug()) {
        int64_t req = _seekReqWallUs.exchange(0);
        if (req > 0) SPLOG(@"[Seek] 目标帧到达%s pts=%.2fs 延迟=%.1fms",
                           direct ? "(直达)" : "", ptsUs / 1e6,
                           (spNowUs() - req) / 1000.0);
    }
}

- (BOOL)shouldReanchorForQueueHeadPts:(int64_t)headPtsUs clock:(int64_t)clockUs {
    const int64_t continuityUs = MAX((int64_t)1000000, _frameIntervalUs * 2);

    if (_holeHeadGen.load(std::memory_order_acquire) == _generation.load() && [self audioClockIsAuthoritative] &&
        _lastPresentedPtsUs < _holeHeadToUs.load(std::memory_order_relaxed) - continuityUs)
        return NO;
    const BOOL discontinuous = _lastPresentedPtsUs <= 0 ||
                               headPtsUs - _lastPresentedPtsUs > continuityUs;

    if (discontinuous && _sessionEverPresented.load() && [self audioClockIsAuthoritative] &&
        _audioEofDrainedGen.load() != _generation.load() &&
        (_audioOutput.bufferedFrames > 0 || _audioPackets->size() > 0)) {
        if (spDebug()) {
            int64_t now = spNowUs();
            if (now - _dbgReanchorLogUs > 1000000) {
                _dbgReanchorLogUs = now;
                SPLOG(@"[Resilient] 视频队首 %.3fs 超前音频钟 %.3fs（已上屏 %.3fs）：持帧等待，声音继续",
                      headPtsUs / 1e6, clockUs / 1e6, _lastPresentedPtsUs / 1e6);
            }
        }
        return NO;
    }
    if (spDebug()) {

        int64_t now = spNowUs();
        if (discontinuous || now - _dbgReanchorLogUs > 1000000) {
            _dbgReanchorLogUs = now;
            SPLOG(@"[Clk] ReanchorClock %@ 队首=%.3fs 时钟=%.3fs 已上屏=%.3fs audio=%d",
                  discontinuous ? @"放行" : @"抑制（持帧等回追）",
                  headPtsUs / 1e6, clockUs / 1e6, _lastPresentedPtsUs / 1e6,
                  (int)[self audioClockIsAuthoritative]);
        }
    }
    return discontinuous;
}

#pragma mark - Main-thread presentation scheduling

- (BOOL)servicePresentRetryWithMotionPath:(BOOL)motionPath
                            countPresented:(BOOL)countPresented
                       completedPausedSeek:(BOOL *)completedPausedSeekOut {
    if (completedPausedSeekOut) *completedPausedSeekOut = NO;
    if (!(_presentRetryPending && _lastFrameBuffer)) return NO;
    BOOL retryIsCurrent = _lastFrameGeneration == _generation.load();
    if (motionPath && _lastFrameSynthetic) {
        retryIsCurrent = retryIsCurrent &&
            _lastFrameInterpolationEpoch == _interpolationPolicyEpoch.load() &&
            _frameInterpolationModeValue.load() == SPFrameInterpolationModeDoubleRate;
    }
    if (!retryIsCurrent) {

        if (motionPath && _lastFrameSynthetic) _generator.counters->dropped.fetch_add(1);
        _presentRetryPending = NO;
        _presentRetryCompletesPausedSeek = NO;
        return NO;
    }
    [self updateSubtitleTextureForTime:_lastPresentedPtsUs];
    if ([_renderer renderPixelBuffer:_lastFrameBuffer]) {
        _presentRetryPending = NO;

        const int64_t retryGen = _seekSettleRetryGen.exchange(-1);
        if (retryGen >= 0 && retryGen == _generation.load()) {
            _seekSettleGen.store(retryGen);
        }

        [self noteFramePresentedForCoarseLanding:_lastFrameGeneration
                                           ptsUs:_lastPresentedPtsUs
                                       submitted:YES];
        if (motionPath && _lastFrameSynthetic) _generator.counters->presented.fetch_add(1);
        if (countPresented) { _pacePresented++; [self notePresentedFrameForRate]; }
        _sessionEverPresented.store(true);
        _lastSubmittedVideoGeneration.store(_lastFrameGeneration,
                                            std::memory_order_release);
        BOOL completesSeek = _presentRetryCompletesPausedSeek;
        _presentRetryCompletesPausedSeek = NO;
        if (completedPausedSeekOut) *completedPausedSeekOut = completesSeek;
    }
    return YES;
}

- (void)servicePausedTickWithMotionPath:(BOOL)motionPath
                           motionFrames:(const std::shared_ptr<BoundedQueue<DecodedFrame>> &)motionFrames {

        {
            BOOL completedSeek = NO;
            if ([self servicePresentRetryWithMotionPath:motionPath
                                          countPresented:NO
                                     completedPausedSeek:&completedSeek]) {
                if (completedSeek) {
                    _seekPending.store(false);
                    if (_state == SPPlayerStatePaused) _displayLink.paused = YES;
                }
                return;
            }
        }
        if (_seekPending.load() && !_seekFramePending.load()) {

            BoundedQueue<DecodedFrame> *q =
                motionPath ? motionFrames.get() : _frames.get();
            DecodedFrame f;
            while (q && q->tryPop(f, std::chrono::milliseconds(0))) {
                SPImmediateFrameSelectionContext context;
                context.currentGeneration = _generation.load();

                context.minimumPtsUs = _catchUpTargetUs.us();
                if (motionPath) {
                    context.syntheticPolicy = {
                        true,
                        _frameInterpolationModeValue.load() ==
                            SPFrameInterpolationModeDoubleRate,
                        _interpolationPolicyEpoch.load(),
                    };
                }
                SPFrameSelectionDecision decision =
                    spEvaluateImmediateFrame(spFrameMetadata(f), context);
                if (decision.action != SPFrameSelectionAction::Select) {
                    if (f.synthetic) _generator.counters->dropped.fetch_add(1);
                    CVPixelBufferRelease(f.buffer);
                    continue;
                }
                [_subtitleRenderer forceNextSample];
                BOOL submitted = [self presentDecodedFrame:f];
                CVPixelBufferRelease(f.buffer);
                [self noteFramePresentedForCoarseLanding:f.gen ptsUs:f.ptsUs submitted:submitted];
                _seekPending.store(!submitted);
                _presentRetryCompletesPausedSeek = !submitted;

                if (f.gen == _generation.load()) {
                    if (submitted) _seekSettleGen.store(f.gen);
                    else _seekSettleRetryGen.store(f.gen);
                }
                [self notifyPosition];
                if (_state == SPPlayerStatePaused) _displayLink.paused = submitted;
                break;
            }
        }
}

- (BOOL)selectSteadyFrame:(DecodedFrame *)outSelected
                    queue:(BoundedQueue<DecodedFrame> *)frames
         enforceSynthetic:(BOOL)enforceSynthetic
        currentGeneration:(int64_t)curGen
                presentUs:(int64_t *)presentUsInOut
               mediaNowUs:(int64_t *)mediaNowUsInOut {
    BOOL got = NO;
    DecodedFrame selectedFrame = {};

    const int64_t lateReplaceUs =
        (int64_t)(1e6 / MAX(30.0, _displayMaximumFPS.load()));
    {
        DecodedFrame f;
        while (frames->peek(f)) {
            SPSteadyFrameSelectionContext context;
            context.presentUs = *presentUsInOut;
            context.currentGeneration = curGen;
            context.seekTargetUs = _seekDisplayTargetUs.us();
            context.hasSelectedFrame = got;
            context.lateReplaceThresholdUs = lateReplaceUs;
            if (enforceSynthetic) {
                context.syntheticPolicy = {
                    true,
                    _frameInterpolationModeValue.load() ==
                        SPFrameInterpolationModeDoubleRate,
                    _interpolationPolicyEpoch.load(),
                };
            }
            SPFrameSelectionDecision decision =
                spEvaluateSteadyFrame(spFrameMetadata(f), context);
            if (decision.action == SPFrameSelectionAction::HoldFuture) break;
            if (decision.action == SPFrameSelectionAction::ReanchorClock) {

                if (![self shouldReanchorForQueueHeadPts:f.ptsUs
                                                   clock:*presentUsInOut]) break;
                [self applySteadyClockReanchorToPts:f.ptsUs];
                *mediaNowUsInOut = f.ptsUs;
                *presentUsInOut = f.ptsUs;
                continue;
            }
            // Validate the peeked frame's identity while popping. A concurrent
            // seek can drain the queue and publish a new generation between peek
            // and pop; applying the old decision to that head could discard the
            // first post-seek keyframe. Re-evaluate if the head was replaced.
            const DecodedFrame peeked = f;
            if (!frames->tryPopIf(f, [&](const DecodedFrame& h) {
                    return h.buffer == peeked.buffer && h.ptsUs == peeked.ptsUs &&
                           h.gen == peeked.gen;
                })) {
                continue;
            }
            if (decision.action ==
                    SPFrameSelectionAction::DropStaleInterpolationPolicy ||
                decision.action ==
                    SPFrameSelectionAction::DropStaleGeneration ||
                decision.action ==
                    SPFrameSelectionAction::DropBeforeSeekTarget) {
                if (f.synthetic) _generator.counters->dropped.fetch_add(1);
                CVPixelBufferRelease(f.buffer);
                continue;
            }
            if (decision.reachesSeekTarget) {
                [self clearReachedSeekTargetAtPts:f.ptsUs direct:NO];
            }
            if (got) {
                if (selectedFrame.synthetic) _generator.counters->dropped.fetch_add(1);
                CVPixelBufferRelease(selectedFrame.buffer);
                _paceDropped++;
                _lateDropCounter.fetch_add(1, std::memory_order_relaxed);

#if SP_APP_STORE
                static const bool vstatsDrop = false;
#else
                static const bool vstatsDrop = getenv("SP_VSTATS") != nullptr;
#endif
                if (vstatsDrop) {
                    SPLOG(@"[LateDrop] 丢pts=%.3fs 改取=%.3fs 上屏钟=%.3fs 队深=%zu",
                          selectedFrame.ptsUs / 1e6, f.ptsUs / 1e6,
                          *presentUsInOut / 1e6, frames->size());
                }
            }
            selectedFrame = f;
            got = YES;
        }
    }
    if (got) *outSelected = selectedFrame;
    return got;
}

- (BOOL)audioOnlySession { return _audioOnlySession.load(); }

- (void)audioOnlyTimerTick {
    if (!_running.load() || !_audioOnlySession.load()) return;
    if (_state != SPPlayerStatePlaying) return;
    [self publishSourceGrowthIfChanged];
    _seekPending.store(false);
    if (_seekSettleGen.load() != _generation.load()) {
        _seekSettleGen.store(_generation.load());
    }
    if (spDebug() && spClkDbg()) {
        SPLOG(@"[ClkDbg/AO] base=%.2f played=%lld baseP=%lld run=%d hand=%d trim=%.2f",
              _audioClockBaseUs / 1e6, _audioOutput ? _audioOutput.clockFrames : -1,
              _audioBasePlayedFrames, (int)(_audioOutput && _audioOutput.isRunning),
              (int)_audioClockHandedOff, _audioTrimTargetUs.sample().us / 1e6);
    }
    int64_t nowUs = [self currentMediaNowUs];
    if (nowUs > 0) _position = nowUs / 1e6;
    const int64_t audioEndUs = _audioRingEndPtsUs.load();

    if (nowUs > 0 && audioEndUs > 0 && (_duration > 0 || _demuxer->sourceGrowing())) {
        const double contentSec = MIN(nowUs, audioEndUs) / 1e6;

        if (contentSec > _duration) [self extendDurationToDeliveredContentSec:contentSec runStartSec:0.0];
    }
    [self notifyPosition];

    const bool audioDrained = _audioEofDrainedGen.load() == _generation.load() && _audioOutput && _audioOutput.bufferedFrames == 0;
    const sp::EndVerdict endVerdict = sp::evaluateAudioOnlyEnd(audioDrained, audioEndUs, _duration,
                                                               audioDrained && [self resilientEndHasEvidence]);
    if (endVerdict.ended) {
        const BOOL partial = endVerdict.partial;
        _position = endVerdict.positionUs / 1e6;
        if (partial) {
            _availableEndUs.store(audioEndUs);
            [self resilientNoteTrack:spresil::Track::Audio cls:spresil::DamageClass::None
                          confidence:spresil::Confidence::DecodeVerified
                              fromUs:audioEndUs untilUs:(int64_t)(_duration * 1e6)];
            SPLOG(@"[Resilient] PartialEnded（纯音频）：内容耗尽于 %.2fs（声称时长 %.2fs 保留）", _position, _duration);
        }
        if (spDebug()) SPLOG(@"[Core] 纯音频 Ended（dur=%.2f%@）", _duration, partial ? @"，PartialEnded" : @"");
        [self flushExtendedDurationSnapshot];
        [self setState:SPPlayerStateEnded];
        if (_audioOutput) [_audioOutput stop];
        [self notifyPosition];

        _audioOnlyTimer.fireDate = NSDate.distantFuture;
    }
}

- (void)schedulePendingScanForMode:(uint8_t)mode {
    if (mode != (uint8_t)spgrow::Mode::Growing) {
        if (!_pendingSpansUs.empty()) {
            _pendingSpansUs.clear();
            [self resilientInvalidateSnapshot];
        }
        return;
    }
    const int64_t now = spNowUs();
    if (_pendingScanInFlight || now - _pendingScanLastUs < 2000000) return;
    _pendingScanInFlight = YES;
    _pendingScanLastUs = now;
    if (!_pendingScanQueue)
        _pendingScanQueue = dispatch_queue_create("sp.pendingScan",
                                                  dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    std::shared_ptr<PendingScanJob> job = _demuxer->pendingScanJob();
    {
        std::lock_guard<std::mutex> lk(job->mapMtx);
        job->durationUs = (int64_t)(_duration * 1e6);
    }
    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    __weak SPPlayerCore *weakSelf = self;
    dispatch_async(_pendingScanQueue, ^{
        auto spans = std::make_shared<std::vector<std::pair<int64_t, int64_t>>>(spRunPendingScan(*job));
        dispatch_async(dispatch_get_main_queue(), ^{
            SPPlayerCore *s = weakSelf;
            if (!s || s->_openGeneration.load(std::memory_order_acquire) != og) return;
            s->_pendingScanInFlight = NO;
            if (*spans == s->_pendingSpansUs) return;
            s->_pendingSpansUs = std::move(*spans);
            if (spDebug()) SPLOG(@"[Grow] 未下载区间 %zu 段（首段 %.1f–%.1fs）", s->_pendingSpansUs.size(),
                                 s->_pendingSpansUs.empty() ? 0.0 : s->_pendingSpansUs[0].first / 1e6,
                                 s->_pendingSpansUs.empty() ? 0.0 : s->_pendingSpansUs[0].second / 1e6);
            [s resilientInvalidateSnapshot];
        });
    });
}

- (void)startMkvContentScanIfPending {
    if (_mkvContentScanStarted || !_demuxer || !_demuxer->mkvContentScanPending()) return;
    std::shared_ptr<MkvContentScanJob> job = _demuxer->takeMkvContentScanJob();
    if (!job) return;
    _mkvContentScanStarted = YES;
    if (!_pendingScanQueue)
        _pendingScanQueue = dispatch_queue_create("sp.pendingScan",
                                                  dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    if (job->durationUs <= 0) job->durationUs = (int64_t)(_duration * 1e6);
    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    __weak SPPlayerCore *weakSelf = self;
    if (spDebug()) SPLOG(@"[Resilient] 内容地图：后台预扫开始（%@）", [NSString stringWithUTF8String:job->path.c_str()].lastPathComponent);
    dispatch_async(_pendingScanQueue, ^{
        spRunMkvContentScan(*job, [weakSelf, og](std::vector<std::pair<int64_t, int64_t>> spans) {
            auto boxed = std::make_shared<std::vector<std::pair<int64_t, int64_t>>>(std::move(spans));
            dispatch_async(dispatch_get_main_queue(), ^{
                SPPlayerCore *s = weakSelf;
                if (!s || s->_openGeneration.load(std::memory_order_acquire) != og) return;
                if (*boxed == s->_noContentSpansUs) return;
                s->_noContentSpansUs = std::move(*boxed);
                if (spDebug()) {
                    NSMutableString *desc = [NSMutableString string];
                    for (size_t i = 0; i < s->_noContentSpansUs.size() && i < 6; ++i)
                        [desc appendFormat:@"%@[%.1f, %.1f)", i ? @" " : @"", s->_noContentSpansUs[i].first / 1e6, s->_noContentSpansUs[i].second / 1e6];
                    NSLog(@"[c%u][Resilient] 内容地图：无内容区间 %zu 段 %@%@", s->_spLogId, s->_noContentSpansUs.size(), desc, s->_noContentSpansUs.size() > 6 ? @" …" : @"");
                }
                [s resilientInvalidateSnapshot];
            });
        });
    });
}

- (void)scheduleContentSearchCheckAfterMs:(int64_t)ms {
    if (_contentSearchCheckQueued) return;
    _contentSearchCheckQueued = YES;
    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    __weak SPPlayerCore *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        SPPlayerCore *s = weakSelf;
        if (!s) return;
        s->_contentSearchCheckQueued = NO;
        if (s->_openGeneration.load(std::memory_order_acquire) != og) return;
        [s publishSourceGrowthIfChanged];
        if (s->_pubContentSearching) [s scheduleContentSearchCheckAfterMs:250];
    });
}

- (BOOL)contentSearching { return _pubContentSearching; }

- (void)publishSourceGrowthIfChanged {
    if (!_demuxer) return;
    [self startMkvContentScanIfPending];

    const int64_t searchSince = _demuxer->contentSearchSinceUs();
    const BOOL searching = searchSince > 0 && spNowUs() - searchSince > 400000;
    if (searching != _pubContentSearching) {
        _pubContentSearching = searching;
        if (spDebug()) SPLOG(@"[Resilient] 内容地图：%@", searching ? @"正在找下一段内容（提示）" : @"找完（收起提示）");
        if ([_delegate respondsToSelector:@selector(playerCoreDidChangeSourceGrowth:)])
            [_delegate playerCoreDidChangeSourceGrowth:self];
        if (searching) [self scheduleContentSearchCheckAfterMs:250];
    }
    const Demuxer::SourceGrowthState g = _demuxer->sourceGrowthState();
    if (g.mode != (uint8_t)spgrow::Mode::Static || !_pendingSpansUs.empty()) [self schedulePendingScanForMode:g.mode];
    const BOOL growing = g.mode == 2 || g.mode == 3;

    if (g.waiting) _lastSourceWaitSeenUs = spNowUs();
    const BOOL seekWaiting = _seekPending.load() && spNowUs() - _lastSourceWaitSeenUs < 1500000;
    const BOOL waiting = growing && (_rebufferHold || (g.waiting && spNowUs() - g.waitingSinceUs > 500000) || seekWaiting);

    const BOOL stalled = waiting && g.idleUs >= spgrow::kStalledHintUs;

    BOOL renamed = NO;
    if (g.pathRev != _pubSourcePathRev) {
        _pubSourcePathRev = g.pathRev;
        const std::string p = _demuxer->sourceCurrentPath();
        NSString *np = p.empty() ? nil : [NSString stringWithUTF8String:p.c_str()];
        if (np && _currentFilePath && ![np isEqualToString:_currentFilePath]) {
            SPLOG(@"[Grow] 文件改名：%@ → %@", _currentFilePath.lastPathComponent, np.lastPathComponent);
            _currentFilePath = [np copy];
            renamed = YES;
        }
    }
    if (!renamed && growing == _pubSourceGrowing && waiting == _pubSourceWaiting && stalled == _pubSourceStalled) return;
    _pubSourceGrowing = growing;
    _pubSourceWaiting = waiting;
    _pubSourceStalled = stalled;
    if (spDebug()) SPLOG(@"[Grow] 来源状态 growing=%d waiting=%d stalled=%d hint=%d size=%lld", (int)growing, (int)waiting,
                         (int)stalled, (int)g.downloadHint, (long long)g.liveSize);
    if ([_delegate respondsToSelector:@selector(playerCoreDidChangeSourceGrowth:)])
        [_delegate playerCoreDidChangeSourceGrowth:self];
}

- (BOOL)sourceGrowing { return _pubSourceGrowing; }
- (BOOL)sourceWaiting { return _pubSourceWaiting || _indexWaiting; }
- (BOOL)sourceStalled { return _pubSourceStalled || (_indexWaiting && _indexWaitStalled); }
- (BOOL)sourceWaitingForIndex { return _indexWaiting; }

- (void)startIndexWaitForPath:(NSString *)path state:(std::shared_ptr<IndexWaitState>)state {
    [self cancelIndexWait];
    _indexWaiting = YES;
    _indexWaitStalled = _indexWaitPrepVerdict == IndexWaitVerdict::Stalled;
    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    SPLOG(@"[Grow] 索引在文件末尾、文件还在下载：等索引到了再打开 %@", path.lastPathComponent);
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    _indexWaitTimer = t;
    const std::string p = path.UTF8String;
    __weak SPPlayerCore *weakSelf = self;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    __block BOOL sentStalled = _indexWaitStalled;
    dispatch_source_set_event_handler(t, ^{
        const IndexWaitVerdict v = spProbeIndexWait(p, *state);
        const bool done = v == IndexWaitVerdict::Ready || v == IndexWaitVerdict::Finished || v == IndexWaitVerdict::NotWritten;
        if (done) dispatch_source_cancel(t);
        const BOOL nowStalled = v == IndexWaitVerdict::Stalled;
        if (!done && nowStalled == sentStalled) return;
        sentStalled = nowStalled;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPPlayerCore *s = weakSelf;
            if (!s || !s->_indexWaiting || s->_openGeneration.load(std::memory_order_acquire) != og) return;
            if (done) {
                [s cancelIndexWait];
                SPLOG(@"[Grow] %@：重新打开", v == IndexWaitVerdict::Ready ? @"索引已下载到" : @"写入方已完成");
                if ([s->_delegate respondsToSelector:@selector(playerCoreWaitedSourceBecameReady:)])
                    [s->_delegate playerCoreWaitedSourceBecameReady:s];
                return;
            }
            const BOOL stalled = v == IndexWaitVerdict::Stalled;
            if (stalled == s->_indexWaitStalled) return;
            s->_indexWaitStalled = stalled;
            if ([s->_delegate respondsToSelector:@selector(playerCoreDidChangeSourceGrowth:)])
                [s->_delegate playerCoreDidChangeSourceGrowth:s];
        });
    });
    dispatch_resume(t);
}

- (void)cancelIndexWait {
    if (_indexWaitTimer) {
        dispatch_source_cancel(_indexWaitTimer);
        _indexWaitTimer = nil;
    }
    _indexWaiting = NO;
    _indexWaitStalled = NO;
}

- (void)displayLinkTick:(CADisplayLink *)link {
    if (!_running) return;
    if (_audioOnlySession.load()) return;

    if (_rendererConfiguredOpenGeneration.load(std::memory_order_acquire) !=
        _openGeneration.load(std::memory_order_acquire)) return;
    if (!_renderer.isReady) return;
#if SP_APP_STORE
    static const bool vstatsOn = false;
#else
    static const bool vstatsOn = getenv("SP_VSTATS") != nullptr;
#endif

    if (vstatsOn) {

#if !SP_APP_STORE
        static const bool schedProbeOn = getenv("SP_SCHEDPROBE") != nullptr;
        static dispatch_once_t schedProbeOnce;
        if (schedProbeOn) dispatch_once(&schedProbeOnce, ^{
            std::thread([] {
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
                int64_t prev = spNowUs();
                for (;;) {
                    usleep(2000);
                    const int64_t now = spNowUs();
                    if (now - prev > 30000) {
                        NSLog(@"[SchedGap] wall=%.1fms", (now - prev) / 1000.0);
                    }
                    prev = now;
                }
            }).detach();
        });
#endif
        static thread_t mainPort = pthread_mach_thread_np(pthread_self());
        const int64_t nowUs = spNowUs();
        thread_basic_info_data_t ti;
        mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
        if (thread_info(mainPort, THREAD_BASIC_INFO, (thread_info_t)&ti,
                        &cnt) == KERN_SUCCESS) {
            const int64_t cpuUs =
                (int64_t)ti.user_time.seconds * 1000000 +
                ti.user_time.microseconds +
                (int64_t)ti.system_time.seconds * 1000000 +
                ti.system_time.microseconds;
            if (_tickPrevEntryUs > 0) {
                _tickLastGapUs = nowUs - _tickPrevEntryUs;
                _tickLastCpuDeltaUs = cpuUs - _tickPrevCpuUs;
                _tickLastLinkDeltaUs =
                    (int64_t)((link.timestamp - _tickPrevLinkTs) * 1e6);
            }
            _tickPrevEntryUs = nowUs;
            _tickPrevCpuUs = cpuUs;
            _tickPrevLinkTs = link.timestamp;
        }
    }

    const BOOL motionPath = _frameInterpolationCommittedModeValue.load() ==
                            SPFrameInterpolationModeDoubleRate;
    auto motionFrames = motionPath ? _motionFramesPublished.load() : nullptr;

    BoundedQueue<DecodedFrame> *steadyQueue =
        motionPath ? motionFrames.get() : _frames.get();

    CGSize px = [self currentViewportPx];
    if (px.width > 0 && px.height > 0 &&
        (px.width != _lastViewportPx.width || px.height != _lastViewportPx.height)) {
        [_renderer setViewportPixelSize:px];
        _lastViewportPx = px;
    }

    if (_state == SPPlayerStatePaused) {
        [self servicePausedTickWithMotionPath:motionPath motionFrames:motionFrames];
        return;
    }
    if (_state != SPPlayerStatePlaying) return;

    if (_coarseAnchorPendingGen >= 0) [self adoptRingStartAnchorIfPublished];

    if (_pubSourceGrowing || _pubSourceWaiting || _pubContentSearching || !_pendingSpansUs.empty() || ((++_growthPublishTick) & 7u) == 0)
        [self publishSourceGrowthIfChanged];
    if (_rebufferHold) {
        const size_t q = _videoPackets->size();

        size_t exitAt = _rebufferExitPackets ? _rebufferExitPackets
                                             : kSPRebufferExitPacketsBase;

        const BOOL growing = _demuxer->sourceGrowing();
        if (growing && _frameIntervalUs > 0) exitAt = MAX(exitAt, (size_t)(2000000 / _frameIntervalUs));
        const size_t cap34 = MAX(_videoPackets->capacity() * 3 / 4, (size_t)1);
        if (exitAt > cap34) exitAt = cap34;

        if (q >= exitAt || _demuxer->eof() ||
            (spNowUs() - _rebufferHoldStartUs > 1500000 && !_demuxer->sourceWaiting())) {
            if (spDebug()) SPLOG(@"[Core] 重缓冲结束 %.0fms（包队列=%zu 阈值=%zu）",
                                 (spNowUs() - _rebufferHoldStartUs) / 1000.0, q, exitAt);
            _rebufferHold = NO;
            _rebufferLastExitWallUs = spNowUs();
            _mediaClockPtsUs = _lastPresentedPtsUs;
            _mediaClockWallUs = spNowUs();
            if (_audioActive && _audioOutput) [_audioOutput start];
        } else {
            return;
        }
    } else if ((_demuxer->onRemoteVolume() || _demuxer->sourceGrowing()) &&
               !_seekPending.load() && !_seekFramePending.load() &&
               !_catchUpTargetUs.valid() && !_demuxer->eof()) {
        const size_t frameDepth = steadyQueue ? steadyQueue->size() : 0;
        const size_t q = _videoPackets->size();

        const BOOL postSeekWindow = spNowUs() - _lastDoSeekWallUs < 2500000;

        const size_t cap34 = MAX(_videoPackets->capacity() * 3 / 4, (size_t)1);
        const BOOL enterHold = postSeekWindow
            ? (frameDepth <= 1 && q < MIN((size_t)16, cap34))
            : (frameDepth == 0 && q < MIN((size_t)4, cap34));
        if (enterHold) {
            _rebufferHold = YES;
            _rebufferHoldStartUs = spNowUs();

            _presentStarveWallUs.store(spNowUs());

            _rebufferExitPackets =
                spNowUs() - _rebufferLastExitWallUs < 3000000
                    ? kSPRebufferExitPacketsBoosted : kSPRebufferExitPacketsBase;
            if (_audioActive && _audioOutput) [_audioOutput stop];
            if (spDebug()) SPLOG(@"[Core] 供给不足 → 重缓冲持帧（q=%zu 帧=%zu%s）",
                                 q, frameDepth, postSeekWindow ? " seek后宽进" : "");
            return;
        }
    }

    int64_t mediaNowUs;
    BOOL useAudioClock = [self audioClockIsAuthoritative];

    if (spDebug() && spClkDbg()) {
        NSTimeInterval nowD = spUptimeSec();
        if (nowD - _dbgClkDbgLast > 1.0) {
            _dbgClkDbgLast = nowD;
            SPLOG(@"[ClkDbg] handedOff=%d eofDrained=%d running=%d buffered=%lld pktQ=%zu",
                  (int)_audioClockHandedOff, (int)(_audioEofDrainedGen.load() == _generation.load()),
                  (int)(_audioOutput && _audioOutput.isRunning),
                  _audioOutput ? _audioOutput.bufferedFrames : -1, _audioPackets->size());
        }
    }
    if (!useAudioClock && _audioClockHandedOff &&
        _audioEofDrainedGen.load() != _generation.load() &&
        _audioActive && _audioOutput && _audioOutput.isRunning &&
        _audioOutput.bufferedFrames >= (int64_t)(kSPAudioClockHz * 0.1)) {
        if (_audioResyncToNow.exchange(false)) {

            _audioClockBaseUs = _approxMediaNowUs.load();
            _audioBasePlayedFrames = _audioOutput.clockFrames;
        }
        _audioClockHandedOff = NO;
        _audioStarveSince = 0;
        useAudioClock = YES;
        if (spDebug()) {

            int64_t wallPosUs = [self wallClockNowUs];
            int64_t audioPosUs = [self audioClockNowUs];
            SPLOG(@"[Core] 音频恢复，时钟收回音频主钟 墙钟=%.3fs 音频=%.3fs 回跳=%.0fms",
                  wallPosUs / 1e6, audioPosUs / 1e6, (wallPosUs - audioPosUs) / 1000.0);
        }
    }
    if (useAudioClock) {

        bool starved = _audioOutput.bufferedFrames == 0 && _audioPackets->size() == 0;
        NSTimeInterval nowT = spUptimeSec();
        if (!starved) {
            _audioStarveSince = 0;
        } else if (_audioStarveSince == 0) {
            _audioStarveSince = nowT;
        }

        if (starved && (_audioEofDrainedGen.load() == _generation.load() ||
                        (nowT - _audioStarveSince > 0.3 &&
                         (_videoPackets->size() > 0 || _demuxer->eof())))) {

            _mediaClockPtsUs = [self audioClockNowUs];
            _mediaClockWallUs = spNowUs();
            _audioClockHandedOff = YES;
            useAudioClock = NO;
            if (spDebug()) SPLOG(@"[Core] 音频耗尽，时钟移交墙钟 @%.2fs", _mediaClockPtsUs / 1e6);
        }
    }

    mediaNowUs = useAudioClock ? [self audioClockNowUs] : [self wallClockNowUs];
    _approxMediaNowUs.store(mediaNowUs);

    int64_t presentUs = mediaNowUs;
    {
        double ahead = link.targetTimestamp - CACurrentMediaTime();
        if (ahead > 0) {
            if (ahead > 0.1) ahead = 0.1;
            presentUs += (int64_t)(ahead * 1e6 * _playbackRate.load());
        }

        presentUs += MIN((int64_t)3000, _frameIntervalUs / 8);
    }
    if (vstatsOn && _pacePrevPresentUs > 0) {

        double tickSec = link.targetTimestamp - link.timestamp;
        if (tickSec <= 0 || tickSec > 0.1) tickSec = 1.0 / 60.0;
        const int64_t jumpLimitUs = MAX((int64_t)30000,
            (int64_t)(tickSec * 1e6 * _playbackRate.load() * 1.8));
        int64_t jump = presentUs - _pacePrevPresentUs;
        if (jump > jumpLimitUs) {
            _paceClockJumps++;
            if (jump > _paceClockJumpMaxUs) _paceClockJumpMaxUs = jump;
            if (vstatsOn) {

                SPLOG(@"[TickGap] 钟跳=%.1fms 入口间隔=%.1fms vsync间隔=%.1fms "
                      @"mainCPU=%.1fms",
                      jump / 1000.0, _tickLastGapUs / 1000.0,
                      _tickLastLinkDeltaUs / 1000.0,
                      _tickLastCpuDeltaUs / 1000.0);
            }
        }
    }
    if (vstatsOn) _pacePrevPresentUs = presentUs;

    int64_t edrNowUs = spNowUs();
    if (edrNowUs - _edrPollAtUs > 250000) {
        _edrPollAtUs = edrNowUs;
        NSScreen *scr = _view.window.screen;

        CGFloat edrCur = scr ? scr.maximumExtendedDynamicRangeColorComponentValue : 0;
#if !SP_APP_STORE

        static const double pinned = (spAutomation() && getenv("SP_EDR_HEADROOM"))
                                         ? atof(getenv("SP_EDR_HEADROOM")) : 0.0;
        if (pinned > 0) edrCur = pinned;
#endif
        if (scr && fabs(edrCur - _edrLastPushed) > 0.01) {
            _edrLastPushed = edrCur;
            [_renderer setDisplayEDRHeadroom:edrCur];
        }
    }
    DecodedFrame selected = {};
    BOOL got = NO;
    int64_t curGen = _generation.load();

    if (steadyQueue) {
        got = [self selectSteadyFrame:&selected queue:steadyQueue
                     enforceSynthetic:motionPath
                    currentGeneration:curGen presentUs:&presentUs
                           mediaNowUs:&mediaNowUs];
    }
    if (got) {
        int64_t tickT0 = vstatsOn ? spNowUs() : 0;

        _needsOutputModeRedraw.store(false);

        BOOL submitted = [self presentDecodedFrame:selected];
        if (submitted) { _pacePresented++; [self notePresentedFrameForRate]; }
        if (vstatsOn) {
            int64_t tickT1 = spNowUs();
            int64_t dt = tickT1 - tickT0;
            if (dt > _paceTickMaxUs) _paceTickMaxUs = dt;
            if (dt > 10000) _paceSlowTicks++;
            if (submitted) {
                const int64_t committedPTSUs = selected.ptsUs;
                const BOOL committedSynthetic = selected.synthetic;
                if (_pacePrevCommitWallUs > 0) {
                    int64_t gap = tickT1 - _pacePrevCommitWallUs;
                    if (gap > _paceCommitGapMaxUs) _paceCommitGapMaxUs = gap;
                    if (gap > 40000 && spDebug()) {
                        SPLOG(@"[PaceGap] wall=%.1fms pts=%.3f→%.3fs media=%.1fms synthetic=%d→%d",
                              gap / 1000.0, _pacePrevCommitPTSUs / 1e6,
                              committedPTSUs / 1e6,
                              _pacePrevCommitPTSUs == AV_NOPTS_VALUE
                                  ? 0.0
                                  : (committedPTSUs - _pacePrevCommitPTSUs) / 1000.0,
                              _pacePrevCommitSynthetic, committedSynthetic);
                    }
                }
                _pacePrevCommitWallUs = tickT1;
                _pacePrevCommitPTSUs = committedPTSUs;
                _pacePrevCommitSynthetic = committedSynthetic;
            }
        }
        CVPixelBufferRelease(selected.buffer);
        _seekPending.store(false);
        [self noteFramePresentedForCoarseLanding:selected.gen ptsUs:selected.ptsUs
                                       submitted:submitted];

        if (selected.gen == _generation.load() &&
            _seekSettleGen.load() != selected.gen) {
            if (submitted) _seekSettleGen.store(selected.gen);
            else _seekSettleRetryGen.store(selected.gen);
        }

        if (_loopA >= 0 && _loopB > _loopA && _position >= _loopB) {
            [self seekTo:_loopA];
            return;
        }
        if (spDebug()) {
            _dbgTickCount++;
            int64_t nowU = spNowUs();

            if (spSyncProbe() && _dbgTickCount % 30 == 15 && _audioActive &&
                _audioOutput && _audioOutput.isRunning && !_audioClockHandedOff) {
                const int64_t ringEnd = _audioRingEndPtsUs.load();
                if (ringEnd >= 0) {
                    const int64_t speakerPts = ringEnd -
                        (int64_t)((double)_audioOutput.bufferedFrames / kSPAudioClockHz *
                                  1e6 * _playbackRate.load());
                    const int64_t drift = speakerPts - _approxMediaNowUs.load();
                    if (llabs(drift) > 60000) {
                        SPLOG(@"[Sync] 失步 %+.0fms（扬声器内容 %.3fs vs 媒体钟 %.3fs）",
                              drift / 1000.0, speakerPts / 1e6,
                              _approxMediaNowUs.load() / 1e6);
                    }
                }
            }
            if (_dbgTickCount % 30 == 0) {
                double tickRate = _dbgTickLastUs > 0 ? 30e6 / (double)(nowU - _dbgTickLastUs) : 0;
                SPLOG(@"[Core] pos=%.2fs dur=%.2fs framesQ=%zu tickHz=%.1f rate=%.2fx",
                      _position, _duration,
                      steadyQueue ? steadyQueue->size() : 0,
                      tickRate, _playbackRate.load());
                _dbgTickLastUs = nowU;
            }
        }
    } else {
        if (!_seekPending.load()) {
            size_t activeQueueSize = steadyQueue ? steadyQueue->size() : 0;
            if (activeQueueSize == 0 && !_demuxer->eof()) {
                _paceStarved++;

                _presentStarveWallUs.store(spNowUs());
            }
        }

        const BOOL retried = [self servicePresentRetryWithMotionPath:motionPath
                                                      countPresented:YES
                                                 completedPausedSeek:NULL];

        if (retried) {

            if (!_presentRetryPending) _needsOutputModeRedraw.store(false);
        } else if (_needsOutputModeRedraw.load() && _lastFrameBuffer) {
            if ([_renderer renderPixelBuffer:_lastFrameBuffer]) {
                _needsOutputModeRedraw.store(false);
            }
        }

        if (!_seekPending.load()) {
            double clockPos = MIN((double)mediaNowUs / 1e6, _duration);
            if (clockPos > _position) _position = clockPos;
        }
    }
    if (vstatsOn) {
        int64_t nowV = spNowUs();
        if (_paceLogAtUs == 0) _paceLogAtUs = nowV;
        if (nowV - _paceLogAtUs >= 5000000) {
            SPLOG(@"[Pace] 5s: 提交=%lld 迟到丢帧=%lld 饥饿tick=%lld 队深=%zu 慢tick=%lld 最慢=%.1fms 钟跳=%lld 最大跳=%.1fms MEMC(gen=%llu submitted=%llu drop=%llu bypass=%llu) 提交间隔峰值=%.1fms",
                  _pacePresented, _paceDropped, _paceStarved,
                  steadyQueue ? steadyQueue->size() : 0,
                  _paceSlowTicks, _paceTickMaxUs / 1000.0,
                  _paceClockJumps, _paceClockJumpMaxUs / 1000.0,
                  (unsigned long long)_generator.counters->generated.load(),
                  (unsigned long long)_generator.counters->presented.load(),
                  (unsigned long long)_generator.counters->dropped.load(),
                  (unsigned long long)_generator.counters->bypassed.load(),
                  _paceCommitGapMaxUs / 1000.0);
            _pacePresented = _paceDropped = _paceStarved = 0;
            _paceSlowTicks = 0; _paceTickMaxUs = 0;
            _paceClockJumps = 0; _paceClockJumpMaxUs = 0;
            _paceCommitGapMaxUs = 0;
            _paceLogAtUs = nowV;
        }
    }
    {

        NSTimeInterval now = spUptimeSec();
        if (now - _lastPosNotify >= 0.033) {
            _lastPosNotify = now;
            [self notifyPosition];
        }
    }

    [self serviceStreamExhaustionWithSteadyQueue:steadyQueue];
}

#pragma mark - seek

- (void)drainSessionQueuesForSeek {
    _videoPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
    _audioPackets->drain([](TaggedPacket t) { av_packet_free(&t.pkt); });
    _frames->drain([](DecodedFrame f) {
        if (f.buffer) CVPixelBufferRelease(f.buffer);
    });
    if (auto motionFrames = _motionFramesPublished.load()) {
        auto *droppedCounter = &_generator.counters->dropped;
        motionFrames->drain([droppedCounter](DecodedFrame f) {
            if (f.synthetic) droppedCounter->fetch_add(1);
            if (f.buffer) CVPixelBufferRelease(f.buffer);
        });
    }
}

- (void)doSeek:(int64_t)us
    trimTargetUs:(int64_t)trimTargetUs
       catchUpUs:(int64_t)catchUpUs
         forward:(BOOL)forward
alignToleranceUs:(int64_t)alignToleranceUs {
    _seekPending.store(true);

    _speculativeFirstFrameRevoked.store(true, std::memory_order_release);
    _lastDoSeekWallUs = spNowUs();

    _frameStepAheadUs = 0;

    _pacePrevPresentUs = 0;
    [_thumbnailer noteInteraction];

    _demuxer->preemptIndexPrefetch();

    _demuxer->preemptScrubTasks();

    _scrubHintPending.store(false);
    _rebufferExitPackets = kSPRebufferExitPacketsBase;
    _rebufferLastExitWallUs = 0;
    if (_rebufferHold) {
        _rebufferHold = NO;
        if (_audioActive && _audioOutput) [_audioOutput start];
    }

    _interpolationResetRequested.store(true);
    int64_t newGen = _generation.fetch_add(1) + 1;
    _seekSettleRetryGen.store(-1);

    _settledCoarseLandingUs = -1;
    _coarseLandingGen = trimTargetUs < 0 ? newGen : -1;
    _catchUpTargetUs.set(catchUpUs);
    _audioTrimTargetUs.set(trimTargetUs);
    _seekDemuxDoneGen.store(-1);
    _seekBoostDecode.store(true);

    _audioEofDrainedGen.store(-1);
    _audioClockHandedOff = NO;
    _audioStarveSince = 0;
    _audioResyncToNow.store(false);
    {
        std::lock_guard<std::mutex> lk(_holeJumpMtx);
        _holeJumps.clear();
        _holeJumpCount.store(0);
    }
    _approxMediaNowUs.store(us);

    if (_presentRetryPending && _lastFrameSynthetic) {
        _generator.counters->dropped.fetch_add(1);
    }
    if (_lastFrameBuffer) { CVPixelBufferRelease(_lastFrameBuffer); _lastFrameBuffer = NULL; }
    if (_compareRealFrame) { CVPixelBufferRelease(_compareRealFrame); _compareRealFrame = NULL; }
    _compareRealFrameGen = -1;
    if (_rendererCompareActive) { [_renderer setCompareBuffer:NULL]; _rendererCompareActive = false; }
    _presentRetryPending = NO;
    _presentRetryCompletesPausedSeek = NO;
    _lastFrameGeneration = -1;
    _lastFrameSynthetic = NO;
    _lastFrameInterpolationEpoch = 0;
    [self drainSessionQueuesForSeek];

    _audioFlushPending.store(true);

    if (_preparedDoviIPT) [_renderer clearDoviReshapeQueue];
    _audioRingStartPtsUs.store(-1);
    _audioRingEndPtsUs.store(-1);

    _coarseAnchorPendingGen = -1;

    if (_audioOutput) [_audioOutput reset];
    _audioClockBaseUs = us;
    _audioBasePlayedFrames = _audioOutput ? _audioOutput.clockFrames : 0;

    _audioSegmentStartFrames = _audioBasePlayedFrames;
    _audioRateSwitchFrames = -1;
    _audioRateSwitchPending = NO;
    {

        int64_t originUs = -1;
        if (forward) {
            int64_t floorUs = _lastPresentedPtsUs;
            if (_forwardSeekFloorUs > floorUs) floorUs = _forwardSeekFloorUs;
            originUs = floorUs;
            _forwardSeekFloorUs = us > floorUs ? us : floorUs;
        } else {
            _forwardSeekFloorUs = -1;
        }
        _seekMailbox.publish({ .targetUs = us, .gen = newGen,
                               .forward = forward, .originUs = originUs,
                               .requestWallUs = spNowUs(),
                               .alignToleranceUs = alignToleranceUs });
    }
    {
        std::lock_guard<std::mutex> lock(_stateMtx);
        _playCv.notify_all();
        _eofCv.notify_all();
    }

    if (_demuxer) _demuxer->wakeSourceWait();
}

#pragma mark - State and notifications

- (void)setState:(SPPlayerState)state {
    if (_state == state) return;
    const BOOL leftOpening = (_state == SPPlayerStateOpening);
    _state = state;
    _backgroundPlaybackState.store(state, std::memory_order_release);
    if ([_delegate respondsToSelector:@selector(playerCore:didChangeState:)]) {
        [_delegate playerCore:self didChangeState:state];
    }

    if (leftOpening && _audioOutput && [_audioOutput outputLayoutChangePending]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleAudioOutputLayoutChange]; });
    }
}

- (void)notifyPosition {
    if (spDebug()) {

        int64_t gen = _generation.load();
        if (gen == _dbgPosJumpLastGen && _dbgPosJumpLastPos >= 0 &&
            _position < _dbgPosJumpLastPos - 0.3) {
            SPLOG(@"[PosJump] 位置回跳 %.3fs → %.3fs (Δ=%.0fms) handedOff=%d seekPending=%d",
                  _dbgPosJumpLastPos, _position, (_position - _dbgPosJumpLastPos) * 1000.0,
                  (int)_audioClockHandedOff, (int)_seekPending.load());
        }
        _dbgPosJumpLastPos = _position;
        _dbgPosJumpLastGen = gen;
    }
    if ([_delegate respondsToSelector:@selector(playerCore:didUpdatePosition:duration:)]) {
        [_delegate playerCore:self didUpdatePosition:_position duration:_duration];
    }
}

NSErrorUserInfoKey const SPPlayerErrorPhaseKey = @"SPPlayerErrorPhase";
NSErrorUserInfoKey const SPPlayerErrorDiagnosisKey = @"SPPlayerErrorDiagnosis";
NSErrorUserInfoKey const SPPlayerErrorTerminalKey = @"SPPlayerErrorTerminal";

- (NSError *)makeErrorWithDomain:(NSString *)domain code:(NSInteger)code description:(NSString *)desc
                           phase:(NSString *)phase diagnosis:(NSString *)diagnosis terminal:(BOOL)terminal {
    return [NSError errorWithDomain:domain code:code
                           userInfo:@{NSLocalizedDescriptionKey : desc, SPPlayerErrorPhaseKey : phase,
                                      SPPlayerErrorDiagnosisKey : diagnosis, SPPlayerErrorTerminalKey : @(terminal)}];
}

#pragma mark - Resilient playback

- (void)resilientResetForNewSession {
    {
        std::lock_guard<std::mutex> lk(_damageMtx);
        _damageMap.clear();
    }
    _damageGen.fetch_add(1);
    _damageHasEvidence.store(false);
    _availableEndUs.store(-1);
    _endTruncationEvidence.store(false);

    _videoCoverageGen = -1;
    {
        std::lock_guard<std::mutex> lk(_holeJumpMtx);
        _holeJumps.clear();
        _holeJumpCount.store(0);
    }
    _holeHeadGen.store(-1);
    _holeHeadToUs.store(-1);
    _lastDemuxedPos.store(-1);

    dispatch_async(dispatch_get_main_queue(), ^{ [self resilientDeliverDamageNotifyForGen:-1]; });
    _dbgResilLogs.store(0, std::memory_order_relaxed);

#if SP_APP_STORE
    _resilientDryRun.store(false);
#else
    const char *env = getenv("SP_RESILIENT");
    _resilientDryRun.store(env && strcmp(env, "0") == 0);
#endif
    [self laneReleaseGop];
    _laneIntactFailSinceKey = 0;
    _laneKeyDecodedOnVT = NO;
    _laneArmed = NO;
    _laneOnSW = NO;
    _laneSWSawError = NO;
    _laneGapPending = NO;
    _laneReturnFailures = 0;
    _laneReplayFailures = 0;
    _laneGopFromKey = NO;
    _laneGopKeyPtsUs = -1;
    _laneReadbackKey = {};
    _laneReadbackAttempts = 0;
    SP_G1_REASON("new_session");
    [self laneDiscardReadbackState];
    _laneReadbackAttempted = NO;
    _laneReadbackEpochValid = NO;
    _laneConfigRevision = _laneReadbackConfigRevision = 0;
    _laneLastQueuedPtsUs = -1;
    _laneReturnPendingVerify = NO;
    _laneSWCandidateRejected = NO;
    _videoTrackGivenUp = NO;
}

- (void)resilientLog:(NSString *)msg {
    if (!spDebug()) return;
    const int n = _dbgResilLogs.load(std::memory_order_relaxed);
    if (n > 40) return;
    _dbgResilLogs.fetch_add(1, std::memory_order_relaxed);
    if (n < 40) SPLOG(@"[Resilient] %@", msg);
    else SPLOG(@"[Resilient] （后续日志按配额省略）");
}

- (void)resilientNoteTrack:(spresil::Track)track cls:(spresil::DamageClass)cls
                confidence:(spresil::Confidence)conf fromUs:(int64_t)fromUs untilUs:(int64_t)untilUs {
    if (untilUs <= fromUs) return;
    {
        std::lock_guard<std::mutex> lk(_damageMtx);
        _damageMap.note(track, cls, conf, fromUs, untilUs);
    }
    _damageHasEvidence.store(true);
    _damageGen.fetch_add(1);
    [self resilientScheduleDamageNotify];
}

- (bool)resilientEndHasEvidence {
    return _damageHasEvidence.load(std::memory_order_relaxed) || _endTruncationEvidence.load(std::memory_order_relaxed) ||
           (_demuxer && _demuxer->demuxDamageEvidence());
}

- (void)noteVideoContentPacket:(const AVPacket *)pkt gen:(int64_t)gen startUs:(int64_t)startUs allZero:(bool)allZero {
    if (pkt->pts == AV_NOPTS_VALUE || !pkt->data || pkt->size <= 0) return;
    if (allZero) return;
    const int64_t ptsUs = av_rescale_q(pkt->pts, _videoTimeBase, AV_TIME_BASE_Q);
    const int64_t gapTolUs = MAX((int64_t)1000000, _frameIntervalUs * 2);
    std::lock_guard<std::mutex> lk(_videoCoverageMtx);
    if (_videoCoverageGen != gen) {
        _videoCoverageGen = gen;
        _videoCoverage.reset(startUs);
    }
    _videoCoverage.note(ptsUs, gapTolUs);
}

- (sp::GapPlan)audioGapPlanFrom:(int64_t)fromUs to:(int64_t)toUs gen:(int64_t)gen {
    const int64_t gapTolUs = MAX((int64_t)1000000, _frameIntervalUs * 2);
    const int64_t tolUs = MAX((int64_t)200000, _frameIntervalUs * 2);
    const bool hasVideo = !_audioOnlySession.load() && _videoStreamIndex >= 0;
    int64_t waitedUs = 0;
    int64_t lastUs = spNowUs();
    for (;;) {
        sp::GapPlan plan;
        int64_t maxPts;
        {
            std::lock_guard<std::mutex> lk(_videoCoverageMtx);
            const sp::ContentCoverage empty;
            const sp::ContentCoverage& cov = _videoCoverageGen == gen ? _videoCoverage : empty;
            plan = sp::judgeAudioGap(fromUs, toUs, gapTolUs, hasVideo, cov, tolUs);
            maxPts = cov.maxPtsUs;
        }
        NSString *why = nil;
        if (plan.verdict == sp::GapVerdict::Undecided) {

            const bool drained = _audioOutput && _audioOutput.bufferedFrames < (int64_t)(kSPAudioClockHz * 0.2) && waitedUs > 50000;
            if (_demuxer->eof() || drained) {
                plan = maxPts >= 0 ? sp::planTrailingHole(fromUs, toUs, maxPts, gapTolUs, tolUs) : sp::GapPlan{};
                why = _demuxer->eof() ? @"demux EOF" : @"声音将尽";
            } else if (!_running.load() || gen != _generation.load()) {
                return {};
            } else if (waitedUs > 3000000) {
                plan = {};
                why = @"等待 3 s 仍未决";
            }
        } else {
            why = @"视频覆盖";
        }
        if (why) {
            if (spDebug() && plan.verdict != sp::GapVerdict::SkipHole)
                SPLOG(@"[Hole] 缺口 %.3f–%.3fs 不跳（%@）：视频覆盖到 %.3fs，等了 %.0fms",
                      fromUs / 1e6, toUs / 1e6, why, maxPts / 1e6, waitedUs / 1000.0);
            return plan;
        }

        if (_paused.load(std::memory_order_relaxed)) {
            std::unique_lock<std::mutex> lk(_stateMtx);
            _playCv.wait(lk, [&] {
                return !_running.load() || !_paused.load(std::memory_order_relaxed) || _seekPending.load() ||
                       gen != _generation.load();
            });
            lastUs = spNowUs();
            continue;
        }
        const int64_t now = spNowUs();
        waitedUs += now - lastUs;
        lastUs = now;
        usleep(5000);
    }
}

- (void)queueAudioHoleJumpFrom:(int64_t)fromUs to:(int64_t)toUs gen:(int64_t)gen head:(BOOL)head {
    if (!_audioOutput) return;
    if (head) {
        _holeHeadToUs.store(toUs, std::memory_order_relaxed);
        _holeHeadGen.store(gen, std::memory_order_release);
    }
    const int64_t frame = _audioOutput.clockFrames + _audioOutput.bufferedFrames;
    std::lock_guard<std::mutex> lk(_holeJumpMtx);
    _holeJumps.push_back({frame, fromUs, toUs, gen, (bool)head});
    _holeJumpCount.store((int)_holeJumps.size(), std::memory_order_release);
}

- (void)foldDueHoleJumps {

    if (!_audioOutput || !_audioOutput.isRunning) return;
    const int64_t played = _audioOutput.clockFrames;
    const int64_t gen = _generation.load();
    std::vector<SPHoleJump> applied;
    {
        std::lock_guard<std::mutex> lk(_holeJumpMtx);
        size_t keep = 0;
        for (size_t i = 0; i < _holeJumps.size(); ++i) {
            const SPHoleJump& j = _holeJumps[i];
            if (j.gen != gen) continue;
            if (j.frame <= played) { applied.push_back(j); continue; }
            _holeJumps[keep++] = j;
        }
        _holeJumps.resize(keep);
        _holeJumpCount.store((int)keep, std::memory_order_release);
    }
    for (const SPHoleJump& j : applied) {

        _audioClockBaseUs = j.toUs;
        _audioBasePlayedFrames = j.frame;
        _pacePrevPresentUs = 0;
        if (spDebug()) SPLOG(@"[Hole] 时钟跳过空洞 %.3f → %.3fs%@", j.fromUs / 1e6, j.toUs / 1e6, j.head ? @"（段首）" : @"");

        if (!(j.head && _seekHoleNotifiedGen == j.gen))
            [self notifySkippedMissingFrom:j.fromUs to:j.toUs afterSeek:(j.head && j.gen > 0)];
    }
}

- (void)notifySkippedMissingFrom:(int64_t)fromUs to:(int64_t)toUs afterSeek:(BOOL)afterSeek {
    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    __weak SPPlayerCore *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPPlayerCore *s = weakSelf;
        if (!s || s->_openGeneration.load(std::memory_order_acquire) != og) return;
        if ([s->_delegate respondsToSelector:@selector(playerCore:didSkipMissingContentFrom:to:afterSeek:)])
            [s->_delegate playerCore:s didSkipMissingContentFrom:fromUs / 1e6 to:toUs / 1e6 afterSeek:afterSeek];
    });
}

- (void)extendDurationToDeliveredContentSec:(double)contentSec runStartSec:(double)runStartSec {
    double d = sp::extendDurationToContent(_duration, contentSec, _durationExtended, runStartSec);

    if (contentSec > d && _demuxer && _demuxer->sourceGrowing()) d = contentSec;
    if (!(d > _duration)) return;
    if (!_durationExtended) {
        _durationExtended = YES;
        if (spDebug()) SPLOG(@"[Core] 实际内容 %.3fs 越过声称时长 %.3fs：声称时长随交付内容延长", contentSec, _duration);
    }
    _duration = d;

    if (d - _durationSnapshotSec >= 0.25) [self flushExtendedDurationSnapshot];
}

- (void)flushExtendedDurationSnapshot {
    if (!_durationExtended || !(_duration > _durationSnapshotSec) || !_damageHasEvidence.load(std::memory_order_relaxed)) return;
    _durationSnapshotSec = _duration;
    [self resilientInvalidateSnapshot];
}

- (void)resilientScheduleDamageNotify {

    if (_damageNotifyHopQueued.exchange(true, std::memory_order_acq_rel)) return;
    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    __weak SPPlayerCore *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPPlayerCore *s = weakSelf;
        if (s) [s resilientDeliverDamageNotifyForGen:og];
    });
}

- (void)resilientDeliverDamageNotifyForGen:(int64_t)og {
    if (og >= 0 && _openGeneration.load(std::memory_order_acquire) != og) { _damageNotifyHopQueued.store(false, std::memory_order_release); return; }
    const int64_t now = spNowUs();
    const int64_t wait = 250000 - (now - _damageNotifyWallUs);
    if (wait > 0 && og >= 0) {
        if (_damageNotifyPending) return;
        _damageNotifyPending = YES;
        __weak SPPlayerCore *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait * NSEC_PER_USEC), dispatch_get_main_queue(), ^{
            SPPlayerCore *s = weakSelf;
            if (!s) return;
            s->_damageNotifyPending = NO;
            [s resilientDeliverDamageNotifyForGen:og];
        });
        return;
    }
    _damageNotifyWallUs = now;
    _damageNotifyHopQueued.store(false, std::memory_order_release);
    if ([_delegate respondsToSelector:@selector(playerCoreDidUpdateTimelinePreview:)]) {
        [_delegate playerCoreDidUpdateTimelinePreview:self];
    }
}

- (void)resilientInvalidateSnapshot {
    _damageGen.fetch_add(1);
    [self resilientScheduleDamageNotify];
}

- (void)resilientClearTrackEvidence:(spresil::Track)track {
    {
        std::lock_guard<std::mutex> lk(_damageMtx);
        _damageMap.clearTrack(track);
    }
    [self resilientInvalidateSnapshot];
}

- (void)resilientNoteVideoDamageAtPts:(int64_t)ptsUs structure:(spresil::PacketStructure)structure
                                  key:(BOOL)key size:(int)size deliverable:(BOOL)deliverable {
    if (ptsUs >= 0) {
        [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::Partial
                      confidence:spresil::Confidence::ScanValidated
                          fromUs:ptsUs untilUs:ptsUs + MAX(_frameIntervalUs, (int64_t)1)];
    }
    NSString *kind = structure == spresil::PacketStructure::AllZero ? @"全零"
                   : deliverable ? @"部分可交付" : @"结构不闭合";
    if (!_laneArmed) {
        _laneArmed = YES;

        if (key && !_resilientDryRun.load(std::memory_order_relaxed)) _laneGopFromKey = YES;
        SP_RESLOG(@"首个损伤包 pts=%.3fs（%@，%d 字节，%@）：武装区间车道",
                            ptsUs / 1e6, kind, size, key ? @"关键帧" : @"非关键帧");
    } else if (_dbgResilLogs.load(std::memory_order_relaxed) < 12) {
        SP_RESLOG(@"损伤包 pts=%.3fs（%@，%d 字节）%@",
                            ptsUs / 1e6, kind, size,
                            _resilientDryRun.load() ? @"，干跑不丢弃" : deliverable ? @"，裁边交付" : @"，丢弃");
    }
}

- (void)resilientNoteEpochOffsetUs:(int64_t)offsetUs video:(BOOL)isVideo {
    (isVideo ? _epochOffsetVideoUs : _epochOffsetAudioUs).store(offsetUs);
    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_openGeneration.load(std::memory_order_acquire) != og) return;
        int64_t target = INT64_MAX;
        if (self->_videoStreamIndex >= 0) target = MIN(target, self->_epochOffsetVideoUs.load());
        if (self->_audioActive) target = MIN(target, self->_epochOffsetAudioUs.load());
        if (target == INT64_MAX) target = 0;
        const int64_t delta = target - self->_epochDurationAppliedUs;
        if (delta == 0 || self->_duration <= 0) return;
        SPLOG(@"[Resilient] 时间轴映射偏移 视频 %+.3fs / 音频 %+.3fs → 声称时长 %.2fs → %.2fs", self->_epochOffsetVideoUs.load() / 1e6,
              self->_epochOffsetAudioUs.load() / 1e6, self->_duration, self->_duration + delta / 1e6);
        self->_duration += delta / 1e6;
        self->_epochDurationAppliedUs = target;
        [self notifyPosition];
    });
}

- (void)resilientDrainDemuxRecoveryEvents {
    auto events = _demuxer->takeRecoveryEvents();
    for (const auto& e : events) {
        if (e.newDurationUs > 0) {

            const double newDur = e.newDurationUs / 1e6;
            const int64_t og = _openGeneration.load(std::memory_order_acquire);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_openGeneration.load(std::memory_order_acquire) != og) return;
                if (newDur > self->_duration + 0.5) {
                    SPLOG(@"[Resilient] 容器恢复后时长 %.2fs → %.2fs", self->_duration, newDur);
                    self->_duration = newDur;
                    [self notifyPosition];
                }
            });
        }

        SP_RESLOG(@"容器恢复：%@",
                            [NSString stringWithUTF8String:e.text.c_str()] ?: @"?");
        if (e.fromUs >= 0 && e.untilUs > e.fromUs) {
            [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::Partial
                          confidence:spresil::Confidence::ScanValidated fromUs:e.fromUs untilUs:e.untilUs];
            if (_audioActive) {
                [self resilientNoteTrack:spresil::Track::Audio cls:spresil::DamageClass::Partial
                              confidence:spresil::Confidence::ScanValidated fromUs:e.fromUs untilUs:e.untilUs];
            }
        }
    }
}

- (void)resilientNoteDemuxSkipAtPos:(int64_t)pos error:(int)err {
    if (!spDebug()) return;
    if (_dbgResilLogs.load(std::memory_order_relaxed) < 12) {
        SP_RESLOG(@"demux 越过损坏区（%s）pos=%lld：直接继续，不退避",
                            av_err2str(err), (long long)pos);
    }
}

- (void)laneReleaseGop {
    for (AVPacket *p : _laneGop) { AVPacket *tmp = p; av_packet_free(&tmp); }
    _laneGop.clear();
    _laneGopBytes = 0;
    _laneGopOverflow = NO;
}

- (void)laneResetForFlush {
    SP_G1_REASON("flush_reset");
    [self laneDiscardReadbackState];
    [self laneReleaseGop];
    _laneIntactFailSinceKey = 0;
    _laneKeyDecodedOnVT = NO;
    _laneGapPending = NO;
    _laneGopFromKey = NO;
    _laneLastQueuedPtsUs = -1;
    _laneReturnPendingVerify = NO;
    _laneReadbackKey = {};
    _laneReadbackEpochValid = NO;
    _laneReadbackAttempted = NO;
}

- (void)laneBeginGopAtPts:(int64_t)ptsUs {
    _lanePendingReadback.reset();
    [self laneReleaseGop];
    _laneIntactFailSinceKey = 0;
    _laneKeyDecodedOnVT = NO;
    _laneGopKeyPtsUs = ptsUs;
    _laneGopFromKey = _laneArmed && !_resilientDryRun.load(std::memory_order_relaxed);
}

- (BOOL)laneCanReplayGop {
    return _laneArmed && _laneGopFromKey && !_laneGopOverflow && !_laneGop.empty();
}

- (void)laneRetainPacket:(AVPacket *)pkt {
    if (!_laneArmed || _laneGopOverflow || _resilientDryRun.load(std::memory_order_relaxed)) return;
    size_t packetBytes = pkt->size >= 0 ? (size_t)pkt->size : SIZE_MAX;
    for (int i = 0; i < pkt->side_data_elems && packetBytes != SIZE_MAX; ++i) {
        const size_t n = pkt->side_data[i].size;
        packetBytes = n <= SIZE_MAX - packetBytes ? packetBytes + n : SIZE_MAX;
    }
    if (!sp::appendGopReplayPacket(_laneGop, _laneGopBytes, packetBytes,
            [&] { return av_packet_clone(pkt); },
            [](AVPacket* packet) { av_packet_free(&packet); })) {
        [self laneReleaseGop];
        _laneGopOverflow = YES;
        _laneGopFromKey = NO;
    }
}

- (void)laneDrainDecoder:(id<SPVideoDecoding>)dec generation:(int64_t)gen {
    if (!dec) return;
    [dec setCatchUpTargetUs:-1];
    for (int i = 0; i < 64; ++i) {
        if (!_running.load() || gen != _generation.load() || _flushPending.load()) break;
        SPDecodedVideoOutput o = [dec decodePacketOutput:nullptr];
        if (!o.pixelBuffer) break;
        if (o.ptsUs > _laneLastQueuedPtsUs) {
            _laneLastQueuedPtsUs = o.ptsUs;
            [self processDecodedVideoOutput:o generation:gen];
        } else {
            CVPixelBufferRelease(o.pixelBuffer);
        }
    }
}

- (void)publishReplacedDecoderName:(id<SPVideoDecoding>)nd {

    NSString *name = nd.decoderName;
    const int64_t og = _openGeneration.load(std::memory_order_acquire);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_openGeneration.load(std::memory_order_acquire) != og) return;
        self->_decoderNamePub = name;

        if (self->_mediaInfoSnapshot) {
            NSMutableDictionary *m = [self->_mediaInfoSnapshot mutableCopy];
            m[NSLocalizedString(@"media.decoder", nil)] =
                name ?: NSLocalizedString(@"media.value.none", nil);
            self->_mediaInfoSnapshot = [m copy];
        }
        id<SPPlayerCoreDelegate> d = self->_delegate;
        if ([d respondsToSelector:@selector(playerCoreDidChangeDecoder:)]) {
            [d playerCoreDidChangeDecoder:self];
        }
    });
}

- (SPFFmpegDecoder *)laneMakeSoftwareCandidate {
    if (!_videoParCopy) return nil;
    SPFFmpegDecoder *sw = [[SPFFmpegDecoder alloc] init];
    sw.spLogId = _spLogId;
    sw.previewMode = _previewMode;
    sw.planarOutputEnabled = spPlanarOutputEnabled();
    sw.rgbSourceMatrix = _preparedColorSpace;
    if ([sw setupWithCodecParameters:_videoParCopy
                   timeBaseNumerator:_videoTimeBase.num
                 timeBaseDenominator:_videoTimeBase.den] != 0) {
        [sw shutdown];
        return nil;
    }
    return sw;
}

#if DEBUG && !SP_APP_STORE
// Only this sink is observed by the test executable. No callback changes Core
// state; the probe dispatches public actions asynchronously to its main queue.
- (void)laneEmitGopTrace:(const SPGopTraceRecord&)e {
    fprintf(stderr, "G1TRACE v=%u id=%llu event=%s gen=%lld currentGen=%lld us=%lld started=%lld "
            "frontier=%lld ord=%llu pos=%lld pts=%lld dts=%lld size=%d stream=%d flags=%d "
            "packetGen=%lld control=%d discard=%d sideData=%d deferred=%u undo=%u bytes=%llu reason=%s disposition=%s "
            "keyPos=%lld triggerPos=%lld revision=%llu epoch=%lld\n",
            e.version, (unsigned long long)e.id, e.event, (long long)e.gen, (long long)e.currentGen,
            (long long)e.atUs, (long long)e.startedUs, (long long)e.frontier, (unsigned long long)e.ordinal,
            (long long)e.pos, (long long)e.pts, (long long)e.dts, e.packetSize, e.stream, e.flags,
            (long long)e.packetGen, e.control, e.discard, e.sideData, e.deferred, e.undo, (unsigned long long)e.bytes, e.reason, e.disposition,
            (long long)e.keyPos, (long long)e.triggerPos, (unsigned long long)e.configRevision, (long long)e.epochUs);
}
- (void)laneSetGopTraceReason:(const char *)reason {
    if (_laneGopTrace.id && reason) _laneGopTrace.reason = reason;
}
- (void)laneTraceGopEvent:(const char *)event ordinal:(uint64_t)ordinal
                 packet:(const TaggedPacket *)tagged disposition:(const char *)disposition {
    if (!_laneGopTrace.id) return;
    SPGopTraceRecord e;
    e.id = _laneGopTrace.id; e.gen = _laneGopTrace.gen; e.currentGen = _generation.load();
    e.atUs = sptrial::monotonicNowUs(); e.startedUs = _laneGopTrace.startedUs;
    e.frontier = _laneLastQueuedPtsUs; e.event = event; e.reason = _laneGopTrace.reason;
    e.disposition = disposition; e.ordinal = ordinal;
    e.deferred = _laneGopTrace.deferred; e.undo = (uint32_t)_laneReadbackUndo.count;
    e.bytes = _laneGopTrace.bytes;
    e.keyPos = _laneGopTrace.keyPos; e.triggerPos = _laneGopTrace.triggerPos;
    e.configRevision = _laneGopTrace.configRevision; e.epochUs = _laneGopTrace.epochUs;
    if (tagged) {
        e.packetGen = tagged->gen; e.control = tagged->control; e.discard = tagged->discard;
        if (tagged->pkt) {
            const auto *p = tagged->pkt;
            e.pos = p->pos; e.pts = p->pts; e.dts = p->dts; e.packetSize = p->size;
            e.stream = p->stream_index; e.flags = p->flags; e.sideData = p->side_data_elems;
        }
    }
    [self laneEmitGopTrace:e];
}
- (void)laneBeginGopTrace {
    _laneGopTrace = {};
    const char *enabled = getenv("SP_TEST_GOP_TRACE"); // only an installed fault candidate reaches here
    if (!enabled || strcmp(enabled, "1") != 0) return;
    const auto &p = *_lanePendingReadback;
    _laneGopTrace.id = spGopTraceNextId.fetch_add(1, std::memory_order_relaxed);
    _laneGopTrace.gen = p.generation; _laneGopTrace.startedUs = p.startedUs;
    _laneGopTrace.keyPos = p.key.pos; _laneGopTrace.triggerPos = p.trigger.pos;
    _laneGopTrace.configRevision = p.revision; _laneGopTrace.epochUs = p.epochUs;
    _laneGopTrace.reason = "installed";
    [self laneTraceGopEvent:"begin" ordinal:0 packet:nullptr disposition:"pending"];
}
- (void)laneEndGopTrace:(const char *)disposition {
    if (!_laneGopTrace.id || _laneGopTrace.terminal) return;
    _laneGopTrace.terminal = true;
    [self laneTraceGopEvent:"terminal" ordinal:0 packet:nullptr disposition:disposition];
}
#endif

// Stop/flush/new-session discard ownership; ordinary same-generation failure
// instead leaves the untouched FIFO for the normal decode loop.
- (void)laneDiscardReadbackState {
    SP_G1_TRACE(
        if (_laneGopTrace.id) {
            if (!_laneGopTrace.terminal) [self laneEndGopTrace:"discard_cancelled"];
            else if (!_laneReadbackUndo.empty() || _laneReadbackHasRollbackTail)
                [self laneTraceGopEvent:"undo_discard" ordinal:0 packet:nullptr disposition:"discard_cancelled"];
        }
    );
    _lanePendingReadback.reset();
    _laneReadbackUndo.clear();
    av_packet_free(&_laneReadbackRollbackTail.pkt);
    _laneReadbackRollbackTail = {};
    _laneReadbackHasRollbackTail = NO;
    SP_G1_TRACE(_laneGopTrace = {});
}

- (void)laneAbortPendingReadbackReason:(const char *)reason {
    if (_lanePendingReadback && spDebug()) SPLOG(@"[GopReadback] 中止：%s（前沿 %.6f 已暂存 %zu 帧 镜像 %zu 包）", reason ? reason : "validity",
                                                 _laneLastQueuedPtsUs / 1e6, _lanePendingReadback->count, _lanePendingReadback->mirroredPackets);
    [self laneAbortPendingReadback];
}

- (void)laneAbortPendingReadback {
    if (!_lanePendingReadback) return;
    const BOOL cancelled = !_running.load() || _seekPending.load() || _flushPending.load() ||
        _lanePendingReadback->generation != _generation.load();
    SP_G1_TRACE([self laneEndGopTrace:cancelled ? "discard_cancelled" : "rollback_pending"]);
    _lanePendingReadback.reset();
    if (cancelled) _laneReadbackUndo.clear(); // every deferred packet belongs to the cancelled generation
}

// Source/config/key/epoch proof stays unchanged while normal packet bookkeeping
// is suspended. An independently published audio epoch change also cancels it.
- (BOOL)lanePendingReadbackValidForGeneration:(int64_t)gen {
    if (!_lanePendingReadback) return NO;
    const auto& p = *_lanePendingReadback;
#if DEBUG && !SP_APP_STORE
    const auto check = [&](bool ok, const char *reason) {
        if (!ok) [self laneSetGopTraceReason:reason];
        return ok;
    };
    return check(_running.load(), "stopped") &&
        check(!_seekPending.load(), "seek_pending") &&
        check(!_flushPending.load(), "flush_pending") &&
        check(gen == _generation.load() && gen == p.generation, "generation") &&
        check(!_laneOnSW && _decoder == p.primary && [_decoder isKindOfClass:[SPVideoDecoder class]] &&
              _decoder.decodingBackend == SPVideoDecodingBackendVideoToolbox, "backend") &&
        check(_laneReadbackEpochValid && p.epochUs == _laneReadbackEpochUs, "epoch") &&
        check(p.revision == _laneConfigRevision && _laneReadbackConfigRevision == p.revision, "config") &&
        check(p.publishedEpochGen == _timelineEpochGen.load() && p.publishedEpochUs == _timelineEpochOffsetUs.load(), "published_epoch") &&
        check(SPGopPendingReadback::sameIdentity(p.key, _laneReadbackKey), "key") &&
        check(!p.frozen || p.frozenFrontier == _laneLastQueuedPtsUs, "frontier") &&
        check(sptrial::monotonicNowUs() - p.startedUs < 2000000, "deadline") &&
        check(p.source.current && p.source.current(), "source");
#else
    return _running.load() && !_seekPending.load() && !_flushPending.load() &&
        gen == _generation.load() && gen == p.generation && !_laneOnSW &&
        _decoder == p.primary && [_decoder isKindOfClass:[SPVideoDecoder class]] &&
        _decoder.decodingBackend == SPVideoDecodingBackendVideoToolbox &&
        _laneReadbackEpochValid && p.epochUs == _laneReadbackEpochUs &&
        p.revision == _laneConfigRevision && _laneReadbackConfigRevision == p.revision &&
        p.publishedEpochGen == _timelineEpochGen.load() && p.publishedEpochUs == _timelineEpochOffsetUs.load() &&
        SPGopPendingReadback::sameIdentity(p.key, _laneReadbackKey) &&
        (!p.frozen || p.frozenFrontier == _laneLastQueuedPtsUs) &&
        sptrial::monotonicNowUs() - p.startedUs < 2000000 &&
        p.source.current && p.source.current();
#endif
}

// Only the loop top calls this, after the trigger's complete original path.
// Freeze performs exactly one final VT drain. No VT send/drain follows until
// commit or rollback; useful output must be strictly above that fixed frontier.
- (BOOL)laneTryCommitReadbackGeneration:(int64_t)gen
                         lastTimestamp:(int64_t *)lastTimestamp
                          lastPosition:(int64_t *)lastPosition
                           discardBelow:(int64_t *)discardBelow {
    BOOL committed = NO;
    try {
        if (![self lanePendingReadbackValidForGeneration:gen]) { SP_G1_ABORT(nullptr); return NO; }
        auto& p = *_lanePendingReadback;
        if (!p.frozen) {
            [self laneDrainDecoder:p.primary generation:gen];
            if (![self lanePendingReadbackValidForGeneration:gen]) { SP_G1_ABORT(nullptr); return NO; }
            p.frozenFrontier = _laneLastQueuedPtsUs;
            p.frozen = true;
            SP_G1_TRACE([self laneTraceGopEvent:"frozen" ordinal:0 packet:nullptr disposition:"pending"]);
            if (spDebug()) SPLOG(@"[GopReadback] frozen frontier=%.6f", p.frozenFrontier/1e6);
        }
        p.discardThrough(p.frozenFrontier);
        if (p.count == 0) {
            if (p.mirroredPackets >= 32 || p.mirroredBytes >= 16u * 1024 * 1024) SP_G1_ABORT(p.mirroredPackets >= 32 ? "packet_limit" : "byte_limit");
            return NO;
        }
        if (![self lanePendingReadbackValidForGeneration:gen]) { SP_G1_ABORT(nullptr); return NO; }
        auto ready = std::move(_lanePendingReadback);
        SPFFmpegDecoder* candidate = ready->candidate;
        [_decoder shutdown];
        _decoder = candidate;
        ready->candidate = nil; // RAII no longer owns the committed decoder
        committed = YES;
        SP_G1_REASON("useful_output_committed");
        SP_G1_TRACE([self laneEndGopTrace:"commit_drop_undo"]);
        // These raw packets bypassed normal timestamp bookkeeping exactly once.
        // Their constant epoch was checked, so advance history without replaying
        // any payload, statistics, fixes, cache or time-axis inference.
        if (ready->mirroredPackets) {
            *lastTimestamp = ready->lastNormalTimestampUs;
            *lastPosition = ready->lastPos;
        }
        _laneReadbackUndo.clear();
        [self publishReplacedDecoderName:candidate];
        _decErrStreak.store(0);
        _laneOnSW = YES;
        _laneArmed = YES;
        _laneSWSawError = NO;
        _laneGapPending = NO;
        _laneIntactFailSinceKey = 0;
        if (_laneReturnPendingVerify) { ++_laneReturnFailures; _laneReturnPendingVerify = NO; }
        size_t queued = 0;
        for (size_t i = 0; i < ready->count; ++i) {
            auto& output = ready->frames[i];
            if (output.ptsUs > _laneLastQueuedPtsUs) {
                _laneLastQueuedPtsUs = output.ptsUs;
                [self processDecodedVideoOutput:output generation:gen];
                output.pixelBuffer = nullptr;
                ++queued;
            }
        }
        *discardBelow = std::max(*discardBelow, _laneLastQueuedPtsUs);
        if (_laneGopKeyPtsUs >= 0 && _laneLastQueuedPtsUs > _laneGopKeyPtsUs)
            [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::Partial
                          confidence:spresil::Confidence::DecodeVerified
                              fromUs:_laneGopKeyPtsUs untilUs:_laneLastQueuedPtsUs];
        SP_RESLOG(
            @"按需回读 GOP 接管：%zu 包、读取 %.1f MiB，后续镜像 %zu 包，提交 %zu 帧，%.1fms（会话 %d/4）",
            ready->replayPackets, ready->readBytes / 1048576.0, ready->mirroredPackets, queued,
            (sptrial::monotonicNowUs() - ready->startedUs) / 1000.0, _laneReadbackAttempts);
        [self laneReleaseGop];
        _laneGopFromKey = NO;
        return YES;
    } catch (const std::bad_alloc&) { SP_G1_ABORT("allocation_exception"); return committed; }
}

// Intercepts ONE actual raw TaggedPacket before normal bookkeeping or fixes.
// YES transfers its ownership to undo, even if candidate decode subsequently
// fails. NO keeps it intact for the caller, after all previously deferred input.
- (BOOL)laneDeferReadbackTaggedPacket:(TaggedPacket *)tagged generation:(int64_t)gen {
    BOOL owned = NO;
    try {
        if (![self lanePendingReadbackValidForGeneration:gen]) { SP_G1_ABORT(nullptr); return NO; }
        auto& p = *_lanePendingReadback;
        AVPacket* packet = tagged->pkt;
        if (!p.frozen || !packet || tagged->control || tagged->discard ||
            (packet->flags & (AV_PKT_FLAG_KEY | AV_PKT_FLAG_DISCARD)) ||
            av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, nullptr)) {
            SP_G1_ABORT("next_packet_boundary"); return NO;
        }
        auto raw = sptrial::PacketIdentity::from(packet);
        if (_laneReadbackOriginTicks != 0 && !raw.shiftTicks(_laneReadbackOriginTicks)) { SP_G1_ABORT("origin_overflow"); return NO; }
        const size_t packetBytes = sptrial::replayPacketBytes(packet);
        const int64_t ticks = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
        const int64_t timestampUs = ticks != AV_NOPTS_VALUE ? av_rescale_q(ticks, _videoTimeBase, AV_TIME_BASE_Q) : -1;
        // Defer no new timeline inference: a possible reset/gap returns to the
        // original path, which can inspect its ordinary queue and audio proof.
        const bool sameAxis = timestampUs >= 0 && p.lastNormalTimestampUs >= 0 &&
            (timestampUs >= p.lastNormalTimestampUs ? timestampUs - p.lastNormalTimestampUs :
                p.lastNormalTimestampUs - timestampUs) <= 1000000;
        if (!raw.valid() || raw.stream != p.key.stream || raw.pos <= p.lastPos || !sameAxis ||
            !sptrial::replayNalTypes(packet, _videoLayout, false, true) ||
            p.mirroredPackets >= 32 || packetBytes > 16u * 1024 * 1024 - p.mirroredBytes) {
            SP_G1_ABORT("raw_or_limit"); return NO;
        }
        sptrial::OwnedPacket derived(av_packet_clone(packet));
        if (!derived) { SP_G1_ABORT("clone_allocation"); return NO; }
        const auto inspection = spresil::inspect(derived->data, derived->size, _videoLayout);
        if (!spresil::deliverable(inspection)) { SP_G1_ABORT("undeliverable"); return NO; }
        if (inspection.resyncFrom > 0 && inspection.resyncFrom < (size_t)derived->size) {
            if (av_packet_make_writable(derived.get()) < 0) { SP_G1_ABORT("clone_writable"); return NO; }
            const size_t tail = derived->size - inspection.resyncFrom;
            std::memmove(derived->data + inspection.safePrefix, derived->data + inspection.resyncFrom, tail);
            av_shrink_packet(derived.get(), (int)(inspection.safePrefix + tail));
        } else if (inspection.tailBroken && inspection.safePrefix < (size_t)derived->size) {
            if (av_packet_make_writable(derived.get()) < 0) { SP_G1_ABORT("clone_writable"); return NO; }
            av_shrink_packet(derived.get(), (int)inspection.safePrefix);
        }
        if (!sptrial::replayNalTypes(derived.get(), _videoLayout, false)) { SP_G1_ABORT("derived_nal"); return NO; }
        // Main-queue timestamps already subtract container origin. Apply ONLY
        // the established Core epoch to this independent clone, once.
        const int64_t offset = av_rescale_q(p.epochUs, AV_TIME_BASE_Q, _videoTimeBase);
        for (int64_t* ts : {&derived->pts, &derived->dts}) if (*ts != AV_NOPTS_VALUE) {
            if ((offset > 0 && *ts > INT64_MAX - offset) || (offset < 0 && *ts < INT64_MIN - offset)) {
                SP_G1_ABORT("epoch_overflow"); return NO;
            }
            *ts += offset;
        }
        if (![self lanePendingReadbackValidForGeneration:gen]) { SP_G1_ABORT(nullptr); return NO; }
#if DEBUG && !SP_APP_STORE
        const TaggedPacket traceOriginal = *tagged; // nonowning, only before original can be released
#endif
        if (!_laneReadbackUndo.push(*tagged)) { SP_G1_ABORT("undo_capacity"); return NO; }
        owned = YES;
        ++p.mirroredPackets; p.mirroredBytes += packetBytes;
        SP_G1_TRACE(
            _laneGopTrace.deferred = (uint32_t)p.mirroredPackets;
            _laneGopTrace.bytes = p.mirroredBytes;
            [self laneTraceGopEvent:"defer" ordinal:p.mirroredPackets packet:&traceOriginal disposition:"undo_owned"]
        );
        p.lastPos = raw.pos; p.lastNormalTimestampUs = timestampUs;
        SPDecodedVideoOutput output = [p.candidate decodePacketOutput:derived.get()];
        // A later successful receive must never hide an earlier decoder error.
        if (p.candidate.lastError != 0) {
            if (output.pixelBuffer) CVPixelBufferRelease(output.pixelBuffer);
            SP_G1_ABORT("candidate_decode_error"); return YES;
        }
        if (!p.stage(output, p.frozenFrontier)) SP_G1_ABORT("stage_budget");
        else if (![self lanePendingReadbackValidForGeneration:gen]) SP_G1_ABORT(nullptr);
        return YES;
    } catch (const std::bad_alloc&) { SP_G1_ABORT("allocation_exception"); return owned; }
}

// Use the retained path first. Only an incomplete cache enters the isolated
// source readback; healthy playback records integers and never opens a reader.
- (BOOL)laneRecoverWithPacket:(AVPacket *)packet
                 rawIdentity:(const sptrial::PacketIdentity&)raw
                  generation:(int64_t)gen {
    try {
    if (_lanePendingReadback || !_laneReadbackUndo.empty() || _laneReadbackHasRollbackTail) return NO;
    if ([self laneCanReplayGop]) return [self laneSwitchToSoftwareWithReplayGeneration:gen];
    if (_laneReadbackAttempted || _laneReadbackAttempts >= 4 || !_laneReadbackEpochValid ||
        _laneReadbackConfigRevision != _laneConfigRevision || !_laneReadbackContainer ||
        !_laneReadbackKey.valid() || !raw.valid() || _preparedDoviIPT || !_videoParCopy ||
        _laneOnSW || ![_decoder isKindOfClass:[SPVideoDecoder class]] ||
        _decoder.decodingBackend != SPVideoDecodingBackendVideoToolbox ||
        _videoLayout.kind != spresil::Bitstream::LengthPrefixed ||
        (_videoParCopy->codec_id != AV_CODEC_ID_H264 && _videoParCopy->codec_id != AV_CODEC_ID_HEVC) ||
        _seekPending.load() || _flushPending.load() || !_running.load() || gen != _generation.load()) return NO;
    _laneReadbackAttempted = YES;
    ++_laneReadbackAttempts;
    const uint64_t revision = _laneConfigRevision;
    const int64_t started = sptrial::monotonicNowUs();
    const int64_t publishedEpochGen = _timelineEpochGen.load();
    const int64_t publishedEpochUs = _timelineEpochOffsetUs.load();
    sptrial::InterruptCtx interrupt;
    interrupt.deadlineUs = started + 2000000;
    interrupt.abort = [self, gen, revision, publishedEpochGen, publishedEpochUs] {
        return !self->_running.load() || gen != self->_generation.load() || self->_flushPending.load() ||
            self->_seekPending.load() || revision != self->_laneConfigRevision ||
            publishedEpochGen != self->_timelineEpochGen.load() || publishedEpochUs != self->_timelineEpochOffsetUs.load();
    };
    auto view = _demuxer->captureReadSourceView();
    if (!view) { if (spDebug()) SPLOG(@"[GopReadback] source view unavailable"); return NO; }
    const AVInputFormat* format = av_find_input_format(_laneReadbackContainer == 1 ? "mov" : "matroska");
    const int64_t epochTicks = av_rescale_q(_laneReadbackEpochUs, AV_TIME_BASE_Q, _videoTimeBase);
    if ((_laneReadbackOriginTicks < 0 && epochTicks > INT64_MAX + _laneReadbackOriginTicks) ||
        (_laneReadbackOriginTicks > 0 && epochTicks < INT64_MIN + _laneReadbackOriginTicks)) return NO;
    auto replay = sptrial::readClosedGop(view, format, _laneReadbackKey, raw, _videoParCopy,
                                       _videoTimeBase, _videoLayout, packet,
                                       epochTicks - _laneReadbackOriginTicks, interrupt);
    if (spDebug()) SPLOG(@"[GopReadback] matched=%d packets=%zu bytes=%lld key=(%lld,%lld,%lld,%d) trigger=(%lld,%lld,%lld,%d) frontier=%.6f",
        (int)replay.matched, replay.packets.size(), (long long)replay.bytesRead, (long long)_laneReadbackKey.pos, (long long)_laneReadbackKey.pts, (long long)_laneReadbackKey.dts, _laneReadbackKey.size,
        (long long)raw.pos, (long long)raw.pts, (long long)raw.dts, raw.size, _laneLastQueuedPtsUs / 1e6);
    if (!replay.matched || interrupt.cancelled() || !view.current()) return NO;
    auto pending = std::make_unique<SPGopPendingReadback>();
    pending->candidate = [self laneMakeSoftwareCandidate];
    if (!pending->candidate) return NO;
    pending->primary = _decoder; pending->source = std::move(view);
    pending->key = _laneReadbackKey; pending->trigger = raw; pending->lastPos = raw.pos;
    pending->generation = gen; pending->epochUs = _laneReadbackEpochUs;
    pending->revision = revision; pending->startedUs = started;
    pending->publishedEpochGen = publishedEpochGen; pending->publishedEpochUs = publishedEpochUs;
    int64_t rawTicks = raw.dts != AV_NOPTS_VALUE ? raw.dts : raw.pts;
    if ((_laneReadbackOriginTicks > 0 && rawTicks < INT64_MIN + _laneReadbackOriginTicks) ||
        (_laneReadbackOriginTicks < 0 && rawTicks > INT64_MAX + _laneReadbackOriginTicks)) return NO;
    rawTicks -= _laneReadbackOriginTicks;
    pending->lastNormalTimestampUs = av_rescale_q(rawTicks, _videoTimeBase, AV_TIME_BASE_Q);
    pending->replayPackets = replay.packets.size(); pending->readBytes = replay.bytesRead;
    const int64_t frontier = _laneLastQueuedPtsUs;
    [pending->candidate setCatchUpTargetUs:frontier > 0 ? frontier : -1];
    size_t replayed = 0;
    for (const auto& retained : replay.packets) {
        if (interrupt.cancelled() || !pending->source.current()) return NO;
        SPDecodedVideoOutput output = [pending->candidate decodePacketOutput:retained.get()];
        ++replayed;
        if (pending->candidate.lastError != 0) {
            if (output.pixelBuffer) CVPixelBufferRelease(output.pixelBuffer);
            if (spDebug()) SPLOG(@"[GopReadback] 候选重放第 %zu/%zu 包报错 err=%d（pts=%lld）：放弃", replayed, replay.packets.size(),
                                 pending->candidate.lastError, (long long)retained->pts);
            return NO;
        }
        if (!pending->stage(output, frontier)) { if (spDebug()) SPLOG(@"[GopReadback] 暂存预算不足：放弃"); return NO; }
    }
    [pending->candidate setCatchUpTargetUs:-1];
    if (spDebug()) SPLOG(@"[GopReadback] 候选重放 %zu 包 → 前沿之上 %zu 帧", replayed, pending->count);
    if (pending->count == 0 || interrupt.cancelled() || !pending->source.current()) return NO;
    _lanePendingReadback = std::move(pending);
    SP_G1_TRACE([self laneBeginGopTrace]);
    return NO; // trigger finishes its original path; only the next loop may freeze VT
    } catch (const std::bad_alloc&) { SP_G1_ABORT("allocation_exception"); return NO; }
}

- (BOOL)laneSwitchToSoftwareWithReplayGeneration:(int64_t)gen {
    const int64_t t0 = spNowUs();
    SPFFmpegDecoder *sw = [self laneMakeSoftwareCandidate];
    if (!sw) {
        _laneReplayFailures++;
        [self resilientLog:@"区间软解候选建不出来"];
        return NO;
    }
    const int64_t front = _laneLastQueuedPtsUs;

    [sw setCatchUpTargetUs:front > 0 ? front : -1];
    int produced = 0, queued = 0;
    BOOL aborted = NO;
    for (AVPacket *p : _laneGop) {
        if (!_running.load() || gen != _generation.load() || _flushPending.load()) { aborted = YES; break; }
        SPDecodedVideoOutput o = [sw decodePacketOutput:p];
        if (!o.pixelBuffer) continue;
        produced++;
        if (o.ptsUs > _laneLastQueuedPtsUs) {
            _laneLastQueuedPtsUs = o.ptsUs;
            [self processDecodedVideoOutput:o generation:gen];
            queued++;
        } else {
            CVPixelBufferRelease(o.pixelBuffer);
        }
    }
    [sw setCatchUpTargetUs:-1];
    if (aborted) {
        [sw shutdown];
        return NO;
    }

    if (produced == 0 && sw.lastError != 0) {
        [sw shutdown];
        _laneReplayFailures++;
        _laneSWCandidateRejected = YES;
        [self requestAlternateVideoTrackReopenWithReason:@"区间软解候选重放无输出" pending:NULL];
        if (sp::laneShouldDisarmAfterReplayFailure(_laneReplayFailures)) _laneArmed = NO;
        SP_RESLOG(@"区间软解候选重放 %zu 包无有效输出（err=%d）：保留 VT",
                            _laneGop.size(), sw.lastError);
        return NO;
    }

    [self laneDrainDecoder:_decoder generation:gen];

    if (!_running.load() || gen != _generation.load() || _flushPending.load()) {
        [sw shutdown];
        return NO;
    }
    [_decoder shutdown];
    _decoder = sw;
    [self publishReplacedDecoderName:sw];
    _decErrStreak.store(0);
    _laneOnSW = YES;
    if (_laneReturnPendingVerify) {
        _laneReturnFailures++;
        _laneReturnPendingVerify = NO;
    }
    _laneSWSawError = NO;
    _laneIntactFailSinceKey = 0;
    const int64_t nowUs = _laneLastQueuedPtsUs;
    if (_laneGopKeyPtsUs >= 0 && nowUs > _laneGopKeyPtsUs) {
        [self resilientNoteTrack:spresil::Track::Video cls:spresil::DamageClass::Partial
                      confidence:spresil::Confidence::DecodeVerified
                          fromUs:_laneGopKeyPtsUs untilUs:nowUs];
    }
    SP_RESLOG(
        @"区间软解接管：关键帧 %.3fs 起回读重放 %zu 包（%.1f MiB）→ 解出 %d 帧、入队 %d 帧（前沿 %.3fs）%.1fms",
        _laneGopKeyPtsUs / 1e6, _laneGop.size(), _laneGopBytes / 1048576.0, produced, queued,
        front / 1e6, (spNowUs() - t0) / 1000.0);
    return YES;
}

- (BOOL)laneAttemptReturnToVTWithKeyPacket:(AVPacket *)pkt output:(SPDecodedVideoOutput *)out
                                generation:(int64_t)gen {
    if (_laneSWSawError) {
        _laneSWSawError = NO;
        return NO;
    }
    if (!sp::laneMayAttemptReturnToVT(_laneReturnFailures) || !_videoParCopy) return NO;
    const int64_t t0 = spNowUs();
    SPVideoDecoder *vt = [[SPVideoDecoder alloc] init];
    vt.spLogId = _spLogId;
    const bool hevc = _videoParCopy->codec_id == AV_CODEC_ID_HEVC;
    vt.firstPacketHint = hevc ? sp::packetDataSnapshot(pkt) : nil;
    const int setupRet = [vt setupWithCodecParameters:_videoParCopy
                                   timeBaseNumerator:_videoTimeBase.num
                                 timeBaseDenominator:_videoTimeBase.den];
    vt.firstPacketHint = nil;
    if (setupRet != 0) {
        [vt shutdown];
        _laneReturnFailures++;
        SP_RESLOG(@"切回 VT：会话建立失败 %d（保留软解）", setupRet);
        return NO;
    }
    if (_interpolationCodedInterlacedSeen) {
        // Same sticky media-session verdict as the replacement session above.
        [vt requestFrameLocalDeinterlacingForKnownCodedContent];
    }
    if (_frameInterpolationCommittedModeValue.load() == SPFrameInterpolationModeDoubleRate) {
        [vt setInterpolationScanEnabled:!_interpolationCodedInterlacedSeen codecParameters:_videoParCopy];
    }
    SPDecodedVideoOutput candidate = [vt decodePacketOutput:pkt];
    if (!candidate.pixelBuffer && vt.lastError != 0) {
        [vt shutdown];
        _laneReturnFailures++;
        SP_RESLOG(@"切回 VT：关键帧 %.3fs 试解失败 err=%d（保留软解，第 %d 次）",
                            _laneGopKeyPtsUs / 1e6, vt.lastError, _laneReturnFailures);
        return NO;
    }

    const BOOL acceptedOnly = !candidate.pixelBuffer;

    [self laneDrainDecoder:_decoder generation:gen];

    if (!_running.load() || gen != _generation.load() || _flushPending.load()) {
        if (candidate.pixelBuffer) CVPixelBufferRelease(candidate.pixelBuffer);
        [vt shutdown];
        return NO;
    }
    [_decoder shutdown];
    _decoder = vt;
    [self publishReplacedDecoderName:vt];
    _laneOnSW = NO;
    _laneKeyDecodedOnVT = YES;
    _laneReturnPendingVerify = acceptedOnly;
    _decErrStreak.store(0);
    *out = candidate;
    SP_RESLOG(@"切回 VT：关键帧 %.3fs %@（%.1fms）",
                        _laneGopKeyPtsUs / 1e6, acceptedOnly ? @"已受理（输出推迟，待本 GOP 验证）" : @"验证通过",
                        (spNowUs() - t0) / 1000.0);
    return YES;
}

- (nullable SPDamageSnapshot *)damageSnapshot {
    const uint64_t gen = _damageGen.load();
    if (_damageSnapshotCache && _damageSnapshotCache.generation == gen) return _damageSnapshotCache;
    std::vector<spresil::DamageSpan> spans;
    std::vector<spresil::DamageMap::MainSpan> main;
    {
        std::lock_guard<std::mutex> lk(_damageMtx);
        if (_damageMap.empty() && _pendingSpansUs.empty() && _noContentSpansUs.empty()) { _damageSnapshotCache = nil; return nil; }
        spans = _damageMap.spans();
        main = _damageMap.composeMain(!_audioOnlySession.load(), _audioActive);
    }
    NSMutableData *mainData = [NSMutableData dataWithCapacity:main.size() * sizeof(SPDamageSpanRecord)];
    for (const auto &m : main) {
        SPDamageSpanRecord r = { (int32_t)m.cls, -1, m.fromUs, m.untilUs };
        [mainData appendBytes:&r length:sizeof r];
    }
    NSMutableData *trackData = [NSMutableData dataWithCapacity:spans.size() * sizeof(SPDamageSpanRecord)];
    for (const auto &sp : spans) {
        SPDamageSpanRecord r = { (int32_t)sp.cls, (int32_t)sp.track, sp.fromUs, sp.untilUs };
        [trackData appendBytes:&r length:sizeof r];
    }
    NSMutableData *pendingData = [NSMutableData dataWithCapacity:(_pendingSpansUs.size() + _noContentSpansUs.size()) * sizeof(SPDamageSpanRecord)];
    for (const auto &p : _pendingSpansUs) {
        SPDamageSpanRecord r = { (int32_t)SPDamageClassPending, -1, p.first, p.second };
        [pendingData appendBytes:&r length:sizeof r];
    }
    for (const auto &p : _noContentSpansUs) {
        SPDamageSpanRecord r = { (int32_t)SPDamageClassPending, -1, p.first, p.second };
        [pendingData appendBytes:&r length:sizeof r];
    }
    _damageSnapshotCache = [[SPDamageSnapshot alloc] initWithGeneration:gen
                                                             durationUs:(int64_t)(_duration * 1e6)
                                                         availableEndUs:_availableEndUs.load()
                                                                   main:mainData
                                                               perTrack:trackData
                                                                pending:pendingData];
    return _damageSnapshotCache;
}

- (double)availableEndSeconds {
    const int64_t us = _availableEndUs.load();
    return us >= 0 ? us / 1e6 : -1;
}

- (double)resilientSnapSeekSeconds:(double)seconds forward:(BOOL)forward {

    if (!_noContentSpansUs.empty()) {
        const int64_t target = (int64_t)(seconds * 1e6);
        for (const auto &sp : _noContentSpansUs) {
            if (target < sp.first || target >= sp.second) continue;
            const int64_t durUs = (int64_t)(_duration * 1e6);
            int64_t snapped;
            if (sp.second < durUs - 500000) snapped = sp.second;
            else snapped = MAX((int64_t)0, sp.first - 2 * _frameIntervalUs);
            if (spDebug()) SPLOG(@"[Resilient] seek %.3fs 落在已确认无内容区 [%.1f, %.1f) → %.3fs", seconds, sp.first / 1e6, sp.second / 1e6, snapped / 1e6);
            if (snapped > target) [self notifySkippedMissingFrom:target to:snapped afterSeek:YES];
            else [self notifySkippedMissingFrom:snapped to:target afterSeek:YES];
            seconds = snapped / 1e6;
            break;
        }
    }
    if (!_damageHasEvidence.load(std::memory_order_relaxed)) return seconds;
    std::vector<spresil::DamageMap::MainSpan> main;
    {
        std::lock_guard<std::mutex> lk(_damageMtx);
        if (_damageMap.empty()) return seconds;
        main = _damageMap.composeMain(!_audioOnlySession.load(), _audioActive);
    }
    const int64_t durUs = (int64_t)(_duration * 1e6);
    const int64_t target = (int64_t)(seconds * 1e6);

    (void)forward;
    int64_t snapped = spresil::DamageMap::snapTarget(main, target, YES, durUs);
    if (snapped < 0) {
        snapped = spresil::DamageMap::snapTarget(main, target, NO, durUs);
        if (snapped < 0) return seconds;
    }
    if (snapped != target) {

        if (snapped >= target) snapped = MIN(snapped, durUs);
        else snapped = MAX((int64_t)0, snapped - 2 * _frameIntervalUs);
        if (spDebug()) SPLOG(@"[Resilient] seek %.3fs 落在不可用区 → 吸附到 %.3fs（%@）",
                             seconds, snapped / 1e6, forward ? @"向后" : @"向前");
        return snapped / 1e6;
    }
    return seconds;
}

- (void)failWithFFmpegError:(int)code operation:(NSString *)op {
    if ([_delegate respondsToSelector:@selector(playerCore:didFailWithError:)]) {
        NSError *err = [self makeErrorWithDomain:@"SPDemuxerError" code:code
                                     description:[NSString stringWithFormat:NSLocalizedString(@"error.operationFailedFmt", nil), op, av_err2str(code)]
                                           phase:@"read" diagnosis:@"readWarning" terminal:NO];
        [_delegate playerCore:self didFailWithError:err];
    }
}

#pragma mark - Properties

- (BOOL)seekSettled {

    return _seekSettleGen.load() == _generation.load();
}

- (SPPlayerState)state { return _state; }

- (void)noteFramePresentedForCoarseLanding:(int64_t)frameGen
                                     ptsUs:(int64_t)ptsUs
                                 submitted:(BOOL)submitted {
    if (_coarseLandingGen < 0) return;
    const SPCoarseLandingDecision d = spConfirmCoarseSeekLanding(
        frameGen, ptsUs, submitted, _generation.load(), _coarseLandingGen,
        _seekLandingKeyUs.sample());
    if (d.outcome == SPCoarseLandingDecision::Pending) return;
    if (d.outcome == SPCoarseLandingDecision::Confirmed) {
        _settledCoarseLandingUs = d.landingUs;
    }
    if (spDebug() && d.outcome == SPCoarseLandingDecision::Rejected) {
        SPLOG(@"[SeekFrame] 落点属性本代无值 gen=%lld pts=%.3fs（首个上屏帧非落点 KEY）",
              frameGen, ptsUs / 1e6);
    }
    _coarseLandingGen = -1;
}

- (double)lastSettledCoarseSeekLandingSeconds {
    return _settledCoarseLandingUs >= 0 ? _settledCoarseLandingUs / 1e6 : -1;
}

- (double)position { return _position; }
- (double)duration { return _duration; }
- (BOOL)isPlaying { return _state == SPPlayerStatePlaying; }

- (NSString *)currentFilePath { return _currentFilePath; }

- (SPVideoInfo)videoInfo {
    SPVideoInfo info;

    info.width = (int)llround(_videoWidth * (_videoSar > 0 ? _videoSar : 1.0));
    info.height = _videoHeight;
    // Report the upright display size so windows fit rotated phone video.
    if (sp::spRotationSwapsAxes(_videoRotation)) std::swap(info.width, info.height);
    info.fps = _videoFps;
    info.duration = _duration;
    info.hasAudio = _hasAudio ? 1 : 0;
    return info;
}

@end

#pragma mark - Decoder prewarming

extern "C" void SPPrewarmVideoDecoders(void) {
    if (gVtWarmIssued.exchange(true)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (gRealOpenIssued.load()) return;
        int64_t t0 = spNowUs();
        [SPVideoDecoder warmUpDecoderForCodecID:AV_CODEC_ID_H264];
        if (gRealOpenIssued.load()) return;
        [SPVideoDecoder warmUpDecoderForCodecID:AV_CODEC_ID_HEVC];

        if (spDebug()) NSLog(@"[Launch] VT预热(main入口): %lldms", (spNowUs() - t0) / 1000);
    });
}

@implementation SPDamageSnapshot
- (instancetype)initWithGeneration:(uint64_t)generation durationUs:(int64_t)durationUs
                    availableEndUs:(int64_t)availableEndUs main:(NSData *)main perTrack:(NSData *)perTrack
                           pending:(NSData *)pending {
    if ((self = [super init])) {
        _generation = generation;
        _durationUs = durationUs;
        _availableEndUs = availableEndUs;
        _main = [main copy];
        _perTrack = [perTrack copy];
        _pending = [pending copy];
    }
    return self;
}
@end
