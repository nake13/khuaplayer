#pragma once

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "TsRapPolicy.hpp"
#include "SPResilience.hpp"
#include "Recovery/RecoveryTypes.hpp"
#include "SPReadSourceView.hpp"

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/rational.h>
}

namespace sptrial { class SourceInput; }
namespace spresil { struct MkvContentMap; struct Mp4KeyEntry; }
namespace sp {

struct LocalFileIO;

struct SourceGrowthPub {
    std::atomic<uint8_t> mode{0};              // spgrow::Mode（SPSourceGrowthPolicy.hpp）
    std::atomic<int64_t> waitingSinceUs{0};
    std::atomic<int64_t> lastGrowthUs{0};
    std::atomic<int64_t> liveSize{0};
    std::atomic<bool> downloadHint{false};
    std::atomic<int64_t> pendingZeroPos{-1};
    std::atomic<bool> inPlaceFill{false};

    std::atomic<uint32_t> pathRev{0};
    std::mutex pathMtx;
    std::string path;
};
struct AuxIOCancelToken;

struct PendingScanJob {
    std::string path;
    bool remote = false;
    std::shared_ptr<SourceGrowthPub> pub;
    std::atomic<bool> cancelled{false};
    std::mutex mapMtx;
    std::vector<std::pair<int64_t, int64_t>> map;
    int64_t durationUs = 0;

    int64_t granule = 0;
    int64_t sampledSize = -1;
    std::vector<uint8_t> present;
    size_t cursor = 0;
};

std::vector<std::pair<int64_t, int64_t>> spRunPendingScan(PendingScanJob& job);

struct MkvContentScanJob {
    std::string path;
    dev_t dev = 0;
    ino_t ino = 0;
    int64_t size = 0;
    bool remote = false;
    uint8_t kind = 0;                          // ContentKind：1 Mkv / 2 Ts / 3 Mp4
    std::vector<int> tracks;                   // MKV
    int videoTrack = 0;                        // MKV
    int tsVideoPid = -1;                       // TS
    std::shared_ptr<const std::vector<spresil::Mp4KeyEntry>> mp4Entries;
    int mp4NalLen = 4;
    bool mp4Hevc = false;
    int64_t timestampScale = 1000000;
    int64_t durationUs = 0;
    int64_t timelineOriginUs = 0;
    std::atomic<bool> cancelled{false};
    std::atomic<int> yield{0};
    std::atomic<bool> done{false};
    std::atomic<uint64_t> version{0};
    std::mutex mapMtx;
    std::shared_ptr<spresil::MkvContentMap> map;
    int64_t bytesRead = 0, elapsedUs = 0;
};

void spRunMkvContentScan(MkvContentScanJob& job, const std::function<void(std::vector<std::pair<int64_t, int64_t>>)>& progress);

struct IndexWaitState {
    bool started = false;
    uint8_t mode = 0;           // spgrow::Mode
    int64_t atOpenSize = -1, atOpenMtimeNs = 0;
    int64_t lastSize = -1, lastMtimeNs = 0;
    int64_t lastGrowthUs = 0, probeStartUs = 0;
    int64_t openWallNs = 0;
    bool hadHint = false;
};
enum class IndexWaitVerdict : uint8_t {
    NotWritten = 0,
    Waiting = 1,
    Stalled = 2,
    Ready = 3,
    Finished = 4,
};
IndexWaitVerdict spProbeIndexWait(const std::string& path, IndexWaitState& st);
struct ScrubShared;

struct ScrubPrefetchRange { int64_t offset = 0; int64_t length = 0; };

struct StreamInfo {
    int index = -1;
    AVMediaType type = AVMEDIA_TYPE_UNKNOWN;
    int64_t durationUs = 0;
    int64_t startTimeUs = 0;
    double fps = 0.0;
    int width = 0;
    int height = 0;
    int rotation = 0;            // Clockwise display rotation: 0, 90, 180 or 270.

    AVRational sampleAspect {1, 1};
    int64_t bitRate = 0;
    std::string codecName;
    std::string codecLongName;
    AVRational timeBase {0, 1};

    int colorPrimaries = AVCOL_PRI_UNSPECIFIED;
    int colorTrc = AVCOL_TRC_UNSPECIFIED;
    int colorSpace = AVCOL_SPC_UNSPECIFIED;
    int colorRange = AVCOL_RANGE_UNSPECIFIED;

    int colorBits = 8;
    int maxCll = 0;
    int maxFall = 0;
    bool isDovi = false;         // Dolby Vision
    int doviProfile = 0;

    int doviBlCompatId = 0;

    bool hasHdr10Plus = false;

    int channels = 0;
    std::string channelLayout;

    std::string language;
    std::string title;
    bool isTextSubtitle = false;
};

class Demuxer {
public:
    Demuxer();
    ~Demuxer();

    Demuxer(const Demuxer&) = delete;
    Demuxer& operator=(const Demuxer&) = delete;

    int open(const std::string& path, bool analyze = true);

    int analyzeStreams();

    void applyStreamDiscard(int audioIndex, int subtitleIndex);
    void close();

    void noteAudioDecodeError(int64_t pktPos) { audioErrPosMailbox_.store(pktPos, std::memory_order_relaxed); }

    bool videoTrackIsolated() const { return videoIsolated_; }

    const std::vector<StreamInfo>& streams() const { return streams_; }
    int videoStream() const { return videoStream_; }
    int audioStream() const { return audioStream_; }
    int subtitleStream() const { return subtitleStream_; }
    AVFormatContext* ctx() const { return fmtCtx_; }

    void releaseRetiredContexts();
    bool eof() const { return eof_.load(); }
    int64_t durationUs() const { return durationUs_; }
    const std::string& containerName() const { return container_; }

    int64_t timelineOriginUs() const { return timelineOriginUs_; }

    int readPacket(AVPacket* pkt);

    bool lastPacketIsReplay() const { return lastPacketReplay_; }

    bool lastPacketAllZero() const { return lastPacketAllZero_; }
    bool lastPacketGarbage() const { return lastPacketGarbage_; }

    int seekToUs(int64_t us, bool forwardKeyframe = false,
                 int64_t forwardMinExclusiveUs = -1,
                 const std::function<bool()>* abortFn = nullptr,
                 int64_t alignToleranceUs = 0);

    void requestAbort();

    bool onRemoteVolume() const { return remoteVolume_; }

    struct SourceGrowthState {
        uint8_t mode = 0;          // spgrow::Mode：0 Static / 1 Probing / 2 Growing / 3 Final
        bool waiting = false;
        int64_t waitingSinceUs = 0;
        int64_t idleUs = 0;
        int64_t liveSize = 0;
        bool downloadHint = false;
        uint32_t pathRev = 0;
        int64_t pendingZeroPos = -1;
        bool inPlaceFill = false;
    };
    SourceGrowthState sourceGrowthState() const;

    int64_t takeSeekSnapUs() { const int64_t v = mkvContent_.lastSnapUs; mkvContent_.lastSnapUs = -1; return v; }
    std::string sourceCurrentPath() const;

    std::shared_ptr<PendingScanJob> pendingScanJob();

    std::shared_ptr<MkvContentScanJob> takeMkvContentScanJob();
    bool mkvContentScanPending() const { return mkvContentJobPending_.load(std::memory_order_relaxed); }

    int64_t contentSearchSinceUs() const { return contentSearchSinceUs_.load(std::memory_order_relaxed); }
    bool matroskaLike() const { return mkvLike_ && !tsLike_; }
    bool sourceWaiting() const { return growthPub_->waitingSinceUs.load(std::memory_order_relaxed) != 0; }
    bool sourceGrowing() const {
        const uint8_t m = growthPub_->mode.load(std::memory_order_relaxed);
        return m == 2 || m == 3;
    }

    void wakeSourceWait();

    void setGrowthYield(std::function<bool()> shouldYield);

    int64_t fileSizeBytes() const;

    // Fault-time only, safe to capture from the decode thread. Holds the open
    // inode and a copy of its overlay, with an independent pread cursor. Remote
    // volumes and sources changed since open are excluded. No AVStream access.
    ReadSourceView captureReadSourceView() const;

    bool lastReadAdvanced() const { return lastReadAdvanced_; }
    int64_t lastReadPos() const { return lastReadPos_; }

    bool lastReadErrorIsContent(int err) const;

    const spresil::OpenDiagnosis& openDiagnosis() const { return openDiag_; }
    spresil::OpenFailureHint openFailureHint() const { return spresil::hintFor(openDiag_); }
    bool openedAfterZeroHeadRetry() const { return openZeroHeadRetry_; }

    bool demuxDamageEvidence() const { return demuxDamageEvidence_.load(std::memory_order_relaxed); }

    bool flacLastFrameEndSample(const uint8_t* streamInfo, size_t n, uint64_t& endSample);

    struct RecoveryEvent {
        std::string text;
        int64_t fromUs = -1;
        int64_t untilUs = -1;
        int64_t newDurationUs = -1;
    };
    bool hasRecoveryEvents() const { return recoveryEventsPending_.load(std::memory_order_relaxed); }
    std::vector<RecoveryEvent> takeRecoveryEvents();
    const std::string& openRecoveryKind() const { return openRecovery_; }

    int64_t tsPcrDeltaUs(int streamIndex, int64_t posA, int64_t posB);

    bool tsRangeHasZeroFill(int64_t posA, int64_t posB);

    static constexpr int kAlternateVideoUnknown = -2;
    void setExcludedVideoStreams(const std::vector<int>& idx) { excludedVideo_.clear(); excludedVideo_.insert(idx.begin(), idx.end()); }
    int alternateVideoStream(int excluding) const;

    bool openSourceIdentity(uint64_t& dev, uint64_t& ino, int64_t& size, int64_t& mtimeNs) const;

    struct IOStats {
        uint64_t reads = 0;
        uint64_t readBytes = 0;
        uint64_t ioUs = 0;
        uint64_t jumps = 0;
    };
    IOStats ioStats() const;

    void setDebugLogSink(std::function<void(const char*)> sink) { debugLogSink_ = std::move(sink); }

    void prefetchIndexRegionAsync();

    void preemptIndexPrefetch();

    void deferIndexPrefetch();

    bool indexPrefetchWanted() const {
        return localIO_ != nullptr &&
               !prefetchIssued_.load(std::memory_order_acquire) &&
               !indexPrefetchBlocked_.load(std::memory_order_acquire);
    }

    void startVolumeKeepAliveIfNeeded();

    void preemptScrubTasks();
    bool prefetchSeekNeighborhood(int64_t predictedUs, int count, int64_t stepUs,
                                  bool forwardKeyframe = false);

    void prefetchSequentialAhead(int64_t aheadBytes);

    int warmNextKeyframeClusters(int fromIdx, int64_t* lastUsInOut);

private:
    void buildStreamInfo(AVStream* s);
    void selectStreams();
    int rawSeekToAbsUs(int64_t absUs, int streamIndex,
                       bool forwardKeyframe = false);

    int64_t findTsRapPos(int64_t absUs, int streamIndex, bool forward,
                         int64_t floorAbsUs, const std::function<bool()>* abortFn,
                         int64_t* outPtsUs, bool* cappedOut);

    void noteTsKeyframePtsUs(int64_t relPtsUs);
    void computeTimelineOrigin();
    void rebuildStreamTable();
    bool attachLocalIO(const std::string& path, const std::shared_ptr<LocalFileIO>& source = {});
    void detachLocalIO();

    AVFormatContext* fmtCtx_ = nullptr;
    AVIOContext* avio_ = nullptr;

    mutable std::mutex ioMtx_;
    std::shared_ptr<LocalFileIO> localIO_;
    // Keeps the original inode alive across failed open/recovery attempts. Only
    // the open owner uses this handle; attachment cancellation is not identity.
    std::shared_ptr<LocalFileIO> openingSource_;
    std::shared_ptr<LocalFileIO> ioSnapshot() const {
        std::lock_guard<std::mutex> lk(ioMtx_);
        return localIO_;
    }
    std::atomic<bool> prefetchIssued_{false};

    std::shared_ptr<std::atomic<bool>> prefetchCompleted_;

    std::atomic<uint64_t> prefetchDeferSeq_{0};
    std::atomic<bool> indexPrefetchBlocked_{false};

    std::shared_ptr<std::atomic<int>> auxWorkers_ =
        std::make_shared<std::atomic<int>>(0);

    std::shared_ptr<std::atomic<int64_t>> ioActivityUs_ =
        std::make_shared<std::atomic<int64_t>>(0);
    std::shared_ptr<SourceGrowthPub> growthPub_ = std::make_shared<SourceGrowthPub>();
    mutable std::mutex pendingJobMtx_;
    std::shared_ptr<PendingScanJob> pendingJob_ = std::make_shared<PendingScanJob>();
    bool byteTimeMapCaptured_ = false;

    int64_t refreshTriedAt_ = -1;
    int64_t refreshTriedSize_ = -1;
    int64_t refreshTriedMtimeNs_ = 0;
    void captureByteTimeMap();
    std::shared_ptr<const std::function<bool()>> growthYield_;
    bool growthResyncPending_ = false;

    int readFrameGrowthAware(AVPacket* pkt);
    bool growthActive() const;

    int growthRefreshOnStructuralEof();
    bool admitAuxWorker(const char* what);

    std::shared_ptr<AuxIOCancelToken> prefetchCancel_;

    std::atomic<bool> remoteVolume_{false};
    std::atomic<bool> keepAliveStarted_{false};
    std::shared_ptr<AuxIOCancelToken> keepAliveCancel_;

    void ensureScrubWorker();

    bool submitScrubRanges(const ScrubPrefetchRange* ranges, int count);
    bool submitScrubTimeTarget(int64_t absUs, bool forwardKeyframe);
    std::shared_ptr<ScrubShared> scrub_;
    std::string path_;
    std::vector<StreamInfo> streams_;
    int videoStream_ = -1;
    int audioStream_ = -1;
    int subtitleStream_ = -1;
    std::atomic<bool> eof_{false};
    std::atomic<bool> abortIO_{false};
    const spresil::AbortFn abortFn_ = [this] { return abortIO_.load(); };

    std::atomic<pthread_t> openThread_{nullptr};
    std::atomic<int64_t> durationUs_{0};
    int64_t timelineOriginUs_ = 0;

    std::vector<int64_t> originOffsetCache_;
    std::string container_;

    bool tsMpegTs_ = false;
    bool discardEligible_ = false;
    bool tsLike_ = false;

    int64_t tsGopUs_ = 0;
    int64_t tsLastKeyPtsUs_ = INT64_MIN;

    bool tsRapScanRetired_ = false;
    bool tsRapScanDisabled_ = false;

    void resetRecoverySessionState();
    void resetContainerRecoveryState();

    enum class RecoveryOutcome { Rejected, AppliedButReplayFailed, AppliedAndResumed };
    bool withPatchedFileReader(const std::function<void(const spresil::Reader&, int64_t)>& fn);
    bool withPatchedLocalReader(const std::function<void(const spresil::Reader&, int64_t)>& fn);
    bool installPatches(const std::vector<spresil::Patch>& patches, bool invalidateAvio);
    RecoveryOutcome replayFromRecoveryTarget(int64_t targetUs, const std::string& what);

    int openInputOnce(const std::string& path, int64_t skipInitialBytes, int64_t formatProbeSize,
                      const std::shared_ptr<LocalFileIO>& source = {},
                      std::unique_ptr<sptrial::SourceInput>* sourceBudget = nullptr, int64_t deadlineUs = 0);
    int recheckWeakProbe(const std::string& path, int64_t skipInitialBytes, int64_t formatProbeSize);
    void diagnoseOpenFailure(const std::string& path);
    bool lastReadAdvanced_ = false;
    int64_t lastReadPos_ = 0;
    uint64_t readFaultsAtRead_ = 0;
    spresil::OpenDiagnosis openDiag_;
    bool openZeroHeadRetry_ = false;
    bool neutralProbeName_ = false;
    std::string neutralProbeUrl_;
    bool streamInfoAttempted_ = false;              // tied to this exact context, including failures
    int streamInfoResult_ = 0;
    int analyzeInputOnce(size_t* pgsFilled = nullptr);
    bool resilientRecoveryEnabled_ = true;
    bool analyzed_ = false;
    std::vector<spresil::Patch> pendingPatches_;
    bool pendingFlvIgnorePrevTag_ = false;
    std::string openRecovery_;
    unsigned openStreamCount_ = 0;
    std::set<int> excludedVideo_;

    mutable std::mutex altVideoMtx_;
    std::shared_ptr<const std::vector<int>> altVideoCands_;
    bool altVideoReopening_ = false;
    unsigned altVideoStreamsSeen_ = 0;

    uint64_t altVideoCodecSig_ = 0;
    uint64_t streamCodecSig() const;
    void publishAltVideoCandidates();
    void markAltVideoReopening();
    int64_t lastGoodPos_ = 0;
    int64_t lastGoodAbsUs_ = -1;
    std::vector<int64_t> lastGoodAbsUsPerStream_;
    std::vector<int64_t> lastGoodPosPerStream_;
    struct RecoveryVideoPacket {
        int64_t pts = AV_NOPTS_VALUE, dts = AV_NOPTS_VALUE, pos = -1;
        int size = 0, stream = -1;
        bool valid() const { return pts != AV_NOPTS_VALUE && pts == dts && pos >= 0 && size > 0 && pos <= INT64_MAX - size && stream >= 0; }
        bool matches(const AVPacket* p) const { return valid() && p->pts == pts && p->dts == dts && p->pos == pos && p->size == size && p->stream_index == stream; }
    };
    RecoveryVideoPacket lastRecoveryVideoPacket_, resumeVideoAnchor_;
    int64_t recoverySeekTargetUs() const;

    int64_t resumeDiscardAbsUs_ = -1;
    bool lastPacketReplay_ = false;
    bool lastPacketAllZero_ = false;
    bool lastPacketGarbage_ = false;
    std::vector<int64_t> resumeFrontierUs_;
    std::vector<int64_t> resumeFrontierPos_;
    void armResumeDiscard(int64_t target);
    int64_t earlyEofRecoveryPos_ = -1;
    bool annexBTailRetryUsed_ = false;
    bool annexBTailSourceInvalid_ = false;          // Fault-time identity failure poisons this context until a real reopen.
    void attemptAnnexBTailDrain(AVPacket* packet, int& readResult);
    void resetAnnexBTailPermission();
    int readErrorRecoveries_ = 0;
    int lastDiscardAudio_ = -1;
    int lastDiscardSub_ = -1;
    bool discardApplied_ = false;
    std::atomic<int64_t> audioErrPosMailbox_{-1};
    bool videoIsolated_ = false;
    bool videoIsolationTried_ = false;
    bool gapRecoveryEligible_ = false;
    int64_t gapThresholdBytes_ = 0;
    std::vector<spresil::MkvTrackDecl> gapTrackDecls_;
    int gapTrackDeclReads_ = 0;

    enum class ContentKind : uint8_t { None = 0, Mkv = 1, Ts = 2, Mp4 = 3 };
    struct MkvContentState {
        ContentKind kind = ContentKind::None;
        int tsVideoPid = -1;
        bool tsProbed = false;
        bool evidence = false;
        std::shared_ptr<const std::vector<spresil::Mp4KeyEntry>> mp4Entries;
        int mp4NalLen = 4;
        bool mp4Hevc = false;
        int mp4GarbageRun = 0;
        int64_t lastJumpPos = -1;
        std::shared_ptr<spresil::MkvContentMap> map;
        std::vector<int> tracks;
        int videoTrack = 0;
        int64_t headerEnd = -1;
        bool prepared = false;
        bool prepareFailed = false;
        bool cuesChecked = false;
        bool cuesUsable = false;
        int64_t cuesFrom = -1, cuesTo = -1;
        AVFormatContext* indexCtx = nullptr;
        std::vector<int64_t> indexedClusters;
        int jumps = 0;
        int scansLogged = 0;
        int64_t lastSnapUs = -1;
        std::shared_ptr<MkvContentScanJob> job;
        uint64_t mergedVersion = 0;
    } mkvContent_;
    std::mutex mkvContentJobMtx_;
    std::shared_ptr<MkvContentScanJob> mkvContentJobHandoff_;
    std::atomic<bool> mkvContentJobPending_{false};
    std::atomic<int64_t> contentSearchSinceUs_{0};
    void mkvContentStartJob();
    void mkvContentMergeJob();
    void mkvContentCancelJob();
    int64_t mkvLandingCutAt_ = -1;
    bool mkvCutFromSeekLanding_ = false;
    bool mkvContentPrepare();
    bool contentMapEligible() const { return (mkvLike_ && !tsLike_) || tsMpegTs_ || (sampleEofRetryEligible_ && !fmp4Like_); }
    bool mp4PacketGarbage(const AVPacket* pkt) const;
    bool tsSyncAtPos(int64_t pos);
    int64_t tsIslandBisect(int64_t absUs, int64_t from, int64_t to, int streamIndex);
    bool mkvCuesUsable();
    bool mkvContentScan(int64_t from, int64_t limit, bool stopAfterIsland, const std::function<bool()>* abortFn, const char* why);
    void mkvContentPublish();
    bool mkvContentSnapSeek(int64_t& absUs, const std::function<bool()>* abortFn);
    bool mkvContentJumpAfterCut(AVPacket* pkt, int& ret);
    bool mkvContentSeekToCluster(int64_t clusterPos, int64_t timecode);
    int gapLegalLogged_ = 0;
    std::vector<std::pair<int64_t, int64_t>> recoveryRegions_;
    mutable std::mutex recoveryMtx_;
    std::vector<RecoveryEvent> recoveryEvents_;
    std::atomic<bool> recoveryEventsPending_{false};
    int64_t pendingDurationUs_ = -1;

    std::vector<AVFormatContext*> retiredCtx_;
    bool retainRetiredCtx_ = true;

    void closeInputOnly();
    void pushRecoveryEvent(const std::string& text, int64_t fromUs, int64_t untilUs, int64_t newDurationUs = -1);
    void noteOpenRecovery(const std::string& kind, const std::string& text);

    bool withFileReader(const std::string& path, const std::function<void(const spresil::Reader&, int64_t)>& fn,
                        bool tolerateAppend = false);
    bool withLocalReader(const std::function<void(const spresil::Reader&, int64_t)>& fn);

    bool onOpenThread() const { return openThread_.load(std::memory_order_acquire) == pthread_self(); }

    static constexpr int64_t kRemoteScanCap = 4ll * 1024 * 1024;
    int64_t scanCap(int64_t localCap, int64_t remoteCap = kRemoteScanCap) const {
        return remoteVolume_ ? std::min(localCap, remoteCap) : localCap;
    }

    struct PlanIOCounters { std::atomic<uint64_t> reads{0}, bytes{0}, us{0}; };
    mutable PlanIOCounters planIO_;
    mutable PlanIOCounters laneIO_;

    spresil::Reader abandonableReader(const std::shared_ptr<LocalFileIO>& io, PlanIOCounters* counters);

    spresil::Reader localRawReader();
    struct PlanMark { uint64_t reads = 0, bytes = 0, us = 0; int64_t t0 = 0; };
    std::function<void(const char*)> debugLogSink_;
    std::string planNote_;
    std::string openPlanSummary_;
    static void noteIORead(PlanIOCounters& c, int64_t got, int64_t us);
    void notePlanRead(int64_t got, int64_t us) const { noteIORead(planIO_, got, us); }
    PlanMark planMark() const;
    std::string planItem(const PlanMark& m, const char* name);
    void planLog(const char* fmt, ...) const __attribute__((format(printf, 2, 3)));
    ReadSourceView captureOpeningReadSourceView(const std::vector<spresil::Patch>& overlay) const;
    spresil::RecoveryPlan planOpenRecovery(const std::string& path, const std::vector<spresil::Patch>& overlay);
    bool tryFixedHeaderReopenAfterMisdetect(const std::string& path);

    bool reopenInPlace(const std::vector<spresil::Patch>& patches, bool flvIgnorePrevTag, const char* why, bool allowFewerStreams = false,
                       bool allowParamChange = false, int64_t targetOverrideUs = -1, bool boundedCandidate = false,
                       bool linearPresentationTimeline = false);
    bool attemptEarlyEofRecovery();
    bool attemptReadErrorRecovery(int err, int64_t posBefore, int64_t posAfter);
    bool recoverRegion(int64_t from, int64_t to, const char* why);
    bool gapIsLegalSkippedData(int64_t from, int64_t to);
    bool tryNoPlayableTrackReopen(const std::string& path, bool analyze);
    bool attemptVideoTrackIsolation();
    // ── MP4 / MOV / fMP4 ──
    bool sampleEofRetryEligible_ = false;
    int sampleEofRetriesTotal_ = 0;
    int sampleEofSkips_ = 0;
    int sampleEofSkipsLogged_ = 0;
    std::atomic<bool> demuxDamageEvidence_{false};
    bool mkvLike_ = false;
    bool mkvExtentChecked_ = false;
    bool mp3DeclChecked_ = false;
    int64_t contentEndPos_ = -1;
    int64_t zeroTailCheckedAnchor_ = -1;
    int zeroTailChecks_ = 0;
    int markEof();

    bool rereadAfterRecovery(AVPacket* pkt, int& ret);

    int reopenForOpenPlanner(const std::string& path, const std::vector<spresil::Patch>& patches, bool analyze);

    bool reopenCandidateOrFallBack(const spresil::RecoveryPlan& plan, bool analyze, bool needDims, const char* what);
    void noteTruncationEvidenceAtEof();
    void noteMkvSegmentExtentAtEof();

    bool evidenceSourceUnchanged();

    void releaseLaneScratch();
    bool fmp4Like_ = false;
    bool fmp4LayoutReady_ = false;
    spresil::BitstreamLayout fmp4VideoLayout_;
    int fmp4BrokenRun_ = 0;
    int fmp4RealignAttempts_ = 0;
    uint8_t mp4BrokenHistory_ = 0;
    int mp4TableAttempts_ = 0;
    int mp4WindowAttempts_ = 0, mp4WindowReopens_ = 0;
    std::vector<std::pair<int64_t, int64_t>> mp4WindowRegions_;
    std::set<int64_t> mp4RapVerifiedPos_;
    int mp4RapFixes_ = 0;

    struct Mp4CttsTrial {
        std::atomic<bool> done{false};
        std::atomic<bool> abort{false};
        bool ok = false;
        std::vector<spresil::Patch> patches;
        std::string detail;
    };
    std::shared_ptr<Mp4CttsTrial> cttsTrial_;
    std::vector<spresil::Mp4TrackCfg> fmp4Cfgs_;
    spresil::Mp4FragAnchors fmp4Anchors_;
    bool fmp4CfgLoaded_ = false;
    int64_t fmp4FragCursor_ = 0;
    int64_t fmp4FragCheckedUntil_ = 0;
    std::set<int64_t> fmp4CheckedMoofs_;
    int fmp4FragAttempts_ = 0;
    bool h264PpsChecked_ = false;
    bool attemptMp4SampleTableRecovery(int64_t faultPosition);
    bool attemptFmp4RealignRecovery(int64_t samplePos);
    bool tryMp4MetadataReopen();
    void verifyMp4SeekRap(int64_t absUs, int streamIndex, bool forwardKeyframe, int& ret);

    std::deque<AVPacket*> seekPushback_;
    void dropSeekPushback();
    void tryMp4CttsRecovery();
    bool applyMp4CttsTrial();
    bool attemptFmp4FragmentCheck(int64_t pktPos);
    bool attemptH264PpsEntropyFix(AVPacket* pkt);

    bool psLike_ = false;                            // MPEG-PS
    int64_t psLastCheckedPos_ = -1;
    int psPesAttempts_ = 0;

    struct TsPcrIdentity { int stream = -1; spresil::TsPcrQuery query; };
    mutable std::mutex tsPcrMtx_;
    std::shared_ptr<const std::vector<TsPcrIdentity>> tsPcrIds_;
    uint64_t tsPcrSig_ = 0;
    bool publishTsPcrIdentities(bool force);
    spresil::TsVideoPidMap tsHdrPids_;
    bool tsHdrPidsScanned_ = false;
    bool tsPsiLocal_ = false;
    spresil::TsPsiMap tsPsiMap_;
    spresil::TsPsiSessionBudget tsPsiBudget_;

    bool tsPsiProvisional_ = false;
    bool tsHdrOpenWindowClean_ = false;
    size_t tsHdrOpenPatchCount_ = 0;
    uint64_t tsHdrOpenViewRev_ = 0;
    void scanTsRecoveryPids(const spresil::Reader&, int64_t, const spresil::AbortFn*, bool full = false);
    void ensureTsRecoveryPids();
    bool completeTsPsiScan(spresil::TsRecoveryLane lane, int audioPid);
    void clearTsRecoveryCarry();
    bool validateTsRecoveryCandidate(spresil::RecoveryPlan&, spresil::TsRecoveryLane, int64_t, int = -1, int64_t* = nullptr);
    spresil::TsHeaderScanState tsHdrState_;
    int64_t tsHdrScannedUntil_ = 0;
    int tsHdrAttempts_ = 0;
    bool rawAudioLike_ = false;
    bool rawAudioAdts_ = false;
    int64_t rawAudioScannedUntil_ = 0;
    int rawAudioAttempts_ = 0;
    bool rawAudioDone_ = false;
    int tsAdtsPid_ = -1;
    bool tsAdtsChecked_ = false;
    spresil::TsAdtsScanState tsAdtsState_;
    int64_t tsAdtsScannedUntil_ = 0;
    int tsAdtsAttempts_ = 0;
    spresil::TsPesScanState tsPesState_;
    int64_t tsPesScannedUntil_ = 0;
    int tsPesAttempts_ = 0;
    int64_t tsScanHoldUntilUs_ = 0;

    struct TsLaneWindow {
        std::vector<uint8_t> buf;
        int64_t pos = -1;
        size_t len = 0;
        std::weak_ptr<LocalFileIO> io;
        uint64_t viewRev = 0;
        spresil::TsGeometry geom;
        bool geomValid = false;
        std::weak_ptr<LocalFileIO> geomIo;
        uint64_t geomRev = 0;
    };
    TsLaneWindow tsLaneWin_;
    spresil::TsByteSource tsLaneSource(const spresil::Reader& rd, int64_t size, int64_t from, int64_t needTo, int64_t fillTo,
                                       spresil::TsGeometry& geom);
    std::vector<uint8_t> psLaneBlock_;
    bool mpeg2SeqChecked_ = false;
    int mpeg2VideoPktsSeen_ = 0;
    bool attemptPsPesRecovery(int64_t pesPos);
    bool tryTsPmtReopen(bool analyze);
    bool tryTsTransportReopen(bool analyze);
    bool attemptTsTransportRecovery(int64_t untilPos, bool flush = false);
    bool tryRawAudioFramesReopen();
    bool attemptRawAudioFrameRecovery(int64_t untilPos);
    int resolveTsAdtsPid();
    bool tryTsAdtsReopen();
    bool attemptTsAdtsRecovery(int64_t untilPos, bool flush = false);
    bool loadTsVideoPids();
    bool tryTsPesHeaderReopen();
    bool attemptTsPesHeaderRecovery(int64_t untilPos, bool flush = false);
    bool attemptMpeg2SeqHeaderFix(AVPacket* pkt);
    // ── Matroska ──
    std::vector<int> mkvFlacTracks_;
    bool mkvFlacTracksScanned_ = false;
    int64_t mkvFirstClusterPos_ = -1;
    int mkvFlacLaceAttempts_ = 0;
    std::vector<std::pair<int64_t, int64_t>> mkvFlacLaceRegions_;
    bool tryMkvHeaderReopen();
    bool loadMkvFlacTracks();
    bool tryMkvFlacLacingReopen();
    bool attemptMkvFlacLacingRecovery(int64_t pos);
    // ── AVI ──
    bool aviLike_ = false;
    bool aviChunkSizeTried_ = false;
    std::vector<int> aviIdxCursor_;
    bool tryAviChunkSizeReopen();
    bool attemptAviChunkSizeRecovery(int64_t lostTsUs, const std::string& why);
    // ── FLV ──
    bool flvLike_ = false;                           // flv / live_flv
    bool flvExplosionTried_ = false;
    spresil::FlvAvcScanState flvAvcState_;
    int flvAvcAttempts_ = 0;
    bool attemptFlvStreamExplosionRecovery();
    bool tryFlvAvcSubtypeReopen();
    bool attemptFlvAvcSubtypeRecovery(int64_t untilPos);
    // ── ASF / RealMedia ──
    bool asfLike_ = false;
    int64_t asfLastCheckedPacketPos_ = -1;
    int64_t asfLastDeliveredPos_ = -1;
    int64_t asfCountScannedUntil_ = -1;
    int asfCountAttempts_ = 0;
    spresil::AsfObjectScanState asfObjState_;
    int64_t asfObjScannedUntil_ = -1;
    int asfObjAttempts_ = 0;
    bool tryAsfGeometryReopen();
    bool tryRmStreamMapReopen();
    bool attemptAsfPayloadCountRecovery(int64_t fromPos);
    bool attemptAsfObjectRecovery(int64_t untilPos, bool flush = false);
    void invalidateAvioBuffer();
    int64_t byteToUsGuess(int64_t bytePos) const;
};

} // namespace sp
