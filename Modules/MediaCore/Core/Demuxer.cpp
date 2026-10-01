#include "Demuxer.hpp"
#include "SPDisplayRotation.hpp"
#include "SPContainerRecovery.hpp"
#include "Recovery/RecoveryTsPsi.hpp"
#include "Recovery/RecoveryMkvContentMap.hpp"
#include "Recovery/RecoveryTsContentMap.hpp"
#include "Recovery/RecoveryMp4ContentMap.hpp"
#include "Resilience/ResilienceBitstream.hpp"

#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/avassert.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/dovi_meta.h>
extern "C" {
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
}
#include <algorithm>
#include <csignal>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <chrono>
#include <condition_variable>
#include <map>
#include <mutex>
#include <pthread.h>
#include <libproc.h>
#include <sys/mount.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <thread>
#include <time.h>
#include <unistd.h>

#include "../Bridge/SPRuntimeGates.hpp"
#include "SPTrialDecode.hpp"
#include "SPSourceInput.hpp"
#include "SPMp4InferredRecovery.hpp"
#include "MatroskaCuesLocator.hpp"
#include "SeekTargets.hpp"
#include "SPSourceGrowthPolicy.hpp"

namespace sp {

static bool isRealVideoStream(const AVStream* s);

struct LocalFileIO {
    int fd = -1;
    int64_t size = 0;
    dev_t sourceDev = 0;
    ino_t sourceIno = 0;
    timespec sourceMtime{};
    bool localFilesystem = false;
    std::atomic<bool> viewAttached{true};
    std::atomic<bool> openingViewActive{false};
    std::atomic<uint64_t> viewRevision{0};
    // Only fault-time snapshots and overlay mutations take this lock. Normal
    // AVIO reads and mutations remain serialized on the demux/open thread.
    mutable std::mutex viewMutex;
    int64_t pos = 0;
    std::atomic<bool>* abortFlag = nullptr;
    bool debug = false;

    std::shared_ptr<std::atomic<int64_t>> activityUs;

    std::atomic<int64_t> lastStallEndUs{0};
    int64_t lastReportUs = 0;
    Demuxer::IOStats lastReport;
    Demuxer::IOStats st;

    std::atomic<bool> inRead{false};
    std::atomic<bool> abortRequested{false};
    std::atomic<pthread_t> ioThread{};

    std::atomic<bool> readerActive{false};
    std::mutex jobMtx;
    std::condition_variable jobCv;
    bool jobPending = false;
    bool jobDone = false;
    bool quit = false;
    int64_t jobPos = 0;
    size_t jobWant = 0;
    uint8_t* jobBuf = nullptr;
    int64_t jobHardStallUs = 0;
    ssize_t jobN = 0;
    int jobErrno = 0;

    uint64_t readFaults = 0;

    bool remote = false;
    int64_t seqBytes = 0;
    static constexpr int kStageCap = 1024 * 1024;

    int stageCap = kStageCap;

    struct ReadBlock {
        uint8_t* buf = nullptr;
        int64_t pos = 0;
        int len = 0;
        uint64_t used = 0;
    };
    static constexpr int kReadBlocks = 3;
    static constexpr uint64_t kReadBlockIdle = 64;
    ReadBlock blocks[kReadBlocks];
    uint64_t blockTick = 0;

    std::vector<uint8_t> auxLanding;
    static constexpr size_t kAuxLandingCap = 1u << 20;

    struct LaneCacheBlock {
        std::vector<uint8_t> bytes;
        int64_t pos = -1;
        size_t len = 0;
        uint64_t used = 0;
    };
    LaneCacheBlock laneCache[2];
    uint64_t laneCacheTick = 0;
    static constexpr size_t kLaneCacheBlock = 64 * 1024;

    spresil::PatchOverlay patches;

    int64_t virtualSize = 0;

    std::vector<std::pair<int64_t, int64_t>> contentGaps;
    int64_t contentCutAt = -1;
    bool contentSuspectEnabled = false;
    int64_t bytesSinceDeliver = 0;
    int64_t contentSuspectAt = -1;
    static constexpr int64_t kContentSuspectBytes = 16ll * 1024 * 1024;

    std::atomic<uint8_t> growthMode{0};         // spgrow::Mode
    std::atomic<bool> growthWaitAllowed{false};

    std::shared_ptr<const std::function<bool()>> growthYield;
    bool growthInterrupted = false;

    struct GrowthState {
        spgrow::FileStamp atOpen;
        int64_t lastUs = 0;
        spgrow::FileStamp lastStamp;
        int64_t lastObserveUs = 0;
        int64_t staticUntilUs = 0;

        bool watch = false;
        std::string path;
        int writerOpen = -1;
        int64_t writerCheckedUs = 0;
        int64_t probeStartUs = 0;
        int64_t hintCheckedUs = 0;
        bool hint = false;
        bool hadHint = false;

        bool inPlaceFill = false;
        int64_t zeroRealFrom = -1;
        int64_t zeroRealUntil = -1;
        int zeroTornRetries = 0;

        std::vector<std::pair<int64_t, int64_t>> tornVerified;
        int64_t openWallNs = 0;
        int64_t openMonoUs = 0;
        bool zeroEofOutsidePlay = false;

        int64_t zeroSuspectFrom = -1;
        int64_t zeroSuspectUntil = -1;
        int64_t zeroCutLen = 0;
    } growth;
    std::mutex growthMtx;
    std::condition_variable growthCv;
    std::shared_ptr<SourceGrowthPub> growthPub;

    bool jobStat = false;
    bool jobStatWantPath = false;
    struct stat jobSb {};
    int jobStatErrno = 0;
    std::string jobStatPath;
    bool jobStatAria2 = false;

    ~LocalFileIO() {
        for (ReadBlock& b : blocks) av_free(b.buf);
        if (fd >= 0) ::close(fd);
    }
};

static bool spLocalSourceUnchanged(const LocalFileIO& io) {

    const auto mode = (spgrow::Mode)io.growthMode.load(std::memory_order_relaxed);
    const int64_t baseSize = io.size;
    const timespec baseMtime = io.sourceMtime;
    struct stat sb {};
    if (!(io.fd >= 0 && fstat(io.fd, &sb) == 0 && S_ISREG(sb.st_mode) &&
          sb.st_dev == io.sourceDev && sb.st_ino == io.sourceIno)) return false;

    if (mode == spgrow::Mode::Growing || mode == spgrow::Mode::Final) return sb.st_size >= baseSize;
    return sb.st_size == baseSize &&
        sb.st_mtimespec.tv_sec == baseMtime.tv_sec && sb.st_mtimespec.tv_nsec == baseMtime.tv_nsec;
}

static spgrow::FileStamp spStampOf(const struct stat& sb) {
    return {(int64_t)sb.st_size, (int64_t)sb.st_mtimespec.tv_sec * 1000000000LL + sb.st_mtimespec.tv_nsec};
}

static int spRemoteReadGranule(int64_t seqBytes) {
    if (seqBytes < 8LL * 1024 * 1024) return 256 * 1024;
    if (seqBytes < 24LL * 1024 * 1024) return 512 * 1024;
    return LocalFileIO::kStageCap;
}

static void spIONoopSignal(int) {}
static void spEnsureIOInterruptSignalInstalled() {
    static std::once_flag once;
    std::call_once(once, [] {
        struct sigaction sa {};
        sa.sa_handler = spIONoopSignal;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;
        sigaction(SIGUSR2, &sa, nullptr);
    });
}

static void spSleepUninterruptible(int64_t us) {
    const int64_t deadline = spNowUs() + us;
    for (int64_t now = spNowUs(); now < deadline; now = spNowUs()) {
        struct timespec ts { 0, 0 };
        const int64_t rem = deadline - now;
        ts.tv_sec = rem / 1000000;
        ts.tv_nsec = (rem % 1000000) * 1000;
        nanosleep(&ts, nullptr);
    }
}

static void spLocalIOReaderLoop(std::shared_ptr<LocalFileIO> io) {
    pthread_setname_np("sp.demux.io");

    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    for (;;) {
        std::unique_lock<std::mutex> lk(io->jobMtx);
        io->jobCv.wait(lk, [&] { return io->jobPending || io->quit; });
        if (!io->jobPending) break;
        io->jobPending = false;
        if (io->jobStat) {

            const bool wantPath = io->jobStatWantPath;
            lk.unlock();
            struct stat sb {};
            int err = io->abortRequested.load() ? EINTR : (fstat(io->fd, &sb) == 0 ? 0 : errno);
            std::string path;
            bool aria2 = false;
            if (!err && wantPath) {
                char buf[MAXPATHLEN] = {0};
                if (fcntl(io->fd, F_GETPATH, buf) != -1) {
                    path = buf;
                    struct stat ab {};
                    aria2 = stat((path + ".aria2").c_str(), &ab) == 0;
                }
            }
            lk.lock();
            io->jobSb = sb;
            io->jobStatErrno = err;
            io->jobStatPath = std::move(path);
            io->jobStatAria2 = aria2;
            io->jobDone = true;
            lk.unlock();
            io->jobCv.notify_all();
            continue;
        }
        const int64_t pos = io->jobPos;
        const size_t want = io->jobWant;
        uint8_t* dst = io->jobBuf;
        const int64_t hardStallUs = io->jobHardStallUs;
        lk.unlock();
        io->ioThread.store(pthread_self(), std::memory_order_relaxed);
        io->inRead.store(true);
        ssize_t n = -1;
        int err = EINTR;
        if (hardStallUs > 0) spSleepUninterruptible(hardStallUs);
        if (!io->abortRequested.load()) {
            do {
                n = pread(io->fd, dst, want, pos);
                err = n < 0 ? errno : 0;

            } while (n < 0 && err == EINTR && !io->abortRequested.load());
        }
        io->inRead.store(false);
        lk.lock();
        io->jobN = n;
        io->jobErrno = err;
        io->jobDone = true;
        lk.unlock();
        io->jobCv.notify_all();
    }
}

static bool spLocalIOSubmitRead(LocalFileIO* io, uint8_t* dst, size_t want, int64_t pos,
                                int64_t hardStallUs, ssize_t* outN, int* outErrno) {
    std::unique_lock<std::mutex> lk(io->jobMtx);
    io->jobStat = false;
    io->jobPos = pos;
    io->jobWant = want;
    io->jobBuf = dst;
    io->jobHardStallUs = hardStallUs;
    io->jobDone = false;
    io->jobPending = true;
    io->jobCv.notify_all();
    io->jobCv.wait(lk, [&] {
        return io->jobDone || io->abortRequested.load() ||
               (io->abortFlag && io->abortFlag->load());
    });
    if (!io->jobDone) {
        io->jobPending = false;
        return false;
    }
    *outN = io->jobN;
    *outErrno = io->jobErrno;
    return true;
}

static void spLocalIOInlineRead(LocalFileIO* io, uint8_t* dst, size_t want, int64_t pos,
                                int64_t hardStallUs, ssize_t* outN, int* outErrno) {
    io->ioThread.store(pthread_self(), std::memory_order_relaxed);
    io->inRead.store(true);

    if (io->abortFlag && io->abortFlag->load()) {
        io->inRead.store(false);
        *outN = -1;
        *outErrno = EINTR;
        return;
    }
    if (hardStallUs > 0) spSleepUninterruptible(hardStallUs);
    ssize_t n;
    int savedErrno = 0;
    do {
        n = pread(io->fd, dst, want, pos);
        savedErrno = n < 0 ? errno : 0;

    } while (n < 0 && savedErrno == EINTR &&
             !(io->abortFlag && io->abortFlag->load()));
    io->inRead.store(false);
    *outN = n;
    *outErrno = savedErrno;
}

static bool spLocalIOStat(LocalFileIO* io, bool wantPath, struct stat* sb, int* statErrno, std::string* path, bool* aria2) {
    auto inlineStat = [&] {
        *statErrno = fstat(io->fd, sb) == 0 ? 0 : errno;
        if (!*statErrno && wantPath) {
            char buf[MAXPATHLEN] = {0};
            if (fcntl(io->fd, F_GETPATH, buf) != -1) {
                *path = buf;
                struct stat ab {};
                *aria2 = stat((*path + ".aria2").c_str(), &ab) == 0;
            }
        }
        return true;
    };
    if (!io->readerActive.load(std::memory_order_relaxed)) return inlineStat();
    std::unique_lock<std::mutex> lk(io->jobMtx);
    io->jobStat = true;
    io->jobStatWantPath = wantPath;
    io->jobDone = false;
    io->jobPending = true;
    io->jobCv.notify_all();
    io->jobCv.wait(lk, [&] {
        return io->jobDone || io->abortRequested.load() || (io->abortFlag && io->abortFlag->load());
    });
    if (!io->jobDone) {
        io->jobPending = false;
        io->jobStat = false;
        return false;
    }
    io->jobStat = false;
    *sb = io->jobSb;
    *statErrno = io->jobStatErrno;
    *path = std::move(io->jobStatPath);
    *aria2 = io->jobStatAria2;
    return true;
}

static void spGrowthObserve(LocalFileIO* io, const struct stat& sb, int64_t mono, bool pathChecked,
                            const std::string& path, bool aria2) {
    const spgrow::FileStamp st = spStampOf(sb);
    if (st != io->growth.lastStamp) {
        io->growth.lastStamp = st;
        io->growth.lastUs = mono;
    }
    io->growth.lastObserveUs = mono;
    SourceGrowthPub* pub = io->growthPub.get();
    if (pathChecked) {
        io->growth.hintCheckedUs = mono;
        if (!path.empty()) io->growth.path = path;
        io->growth.hint = !path.empty() && (spgrow::pathHasDownloadSuffix(path) || aria2);
        if (io->growth.hint) io->growth.hadHint = true;
        if (pub) {
            pub->downloadHint.store(io->growth.hint, std::memory_order_relaxed);
            if (!path.empty()) {
                std::lock_guard<std::mutex> lk(pub->pathMtx);
                if (pub->path != path) {
                    const bool renamed = !pub->path.empty();
                    pub->path = path;
                    if (renamed) pub->pathRev.fetch_add(1, std::memory_order_release);
                }
            }
        }
    }
    if (pub) pub->lastGrowthUs.store(io->growth.lastUs, std::memory_order_relaxed);
}

static void spGrowthAdoptSize(LocalFileIO* io, const struct stat& sb) {
    if ((int64_t)sb.st_size != io->size) {
        std::lock_guard<std::mutex> lk(io->viewMutex);
        if (io->virtualSize == io->size || io->virtualSize < (int64_t)sb.st_size) io->virtualSize = (int64_t)sb.st_size;
        io->size = (int64_t)sb.st_size;
        io->sourceMtime = sb.st_mtimespec;
    }
    if (io->growthPub) io->growthPub->liveSize.store(io->size, std::memory_order_relaxed);
}

static void spSetGrowthMode(LocalFileIO* io, SourceGrowthPub* pub, spgrow::Mode mode) {
    io->growthMode.store((uint8_t)mode, std::memory_order_relaxed);
    if (pub) pub->mode.store((uint8_t)mode, std::memory_order_relaxed);
}

static int spPathWriterOpen(const std::string& path) {

    struct stat target {};
    if (::stat(path.c_str(), &target) != 0) return -1;
    const int64_t t0 = spNowUs();
    int result = -1, inspected = 0;
    bool unknown = false;
    int bytes = proc_listpids(PROC_UID_ONLY, getuid(), nullptr, 0);
    if (bytes > 0) {
        std::vector<pid_t> pids((size_t)bytes / sizeof(pid_t) + 64);
        bytes = proc_listpids(PROC_UID_ONLY, getuid(), pids.data(), (int)(pids.size() * sizeof(pid_t)));
        const pid_t self = getpid();
        const int n = bytes > 0 ? std::min<int>((int)pids.size(), bytes / (int)sizeof(pid_t)) : 0;
        std::vector<proc_fdinfo> fds;
        for (int i = 0; i < n && result != 1; ++i) {
            const pid_t pid = pids[(size_t)i];
            if (pid <= 0 || pid == self) continue;
            const int need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nullptr, 0);
            if (need <= 0) { unknown = true; continue; }
            fds.resize((size_t)need / sizeof(proc_fdinfo) + 8);
            const int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds.data(), (int)(fds.size() * sizeof(proc_fdinfo)));
            if (got <= 0) { unknown = true; continue; }
            ++inspected;
            for (int k = 0; k < got / (int)sizeof(proc_fdinfo); ++k) {
                if (fds[(size_t)k].proc_fdtype != PROX_FDTYPE_VNODE) continue;
                vnode_fdinfo vi {};
                if (proc_pidfdinfo(pid, fds[(size_t)k].proc_fd, PROC_PIDFDVNODEINFO, &vi, sizeof(vi)) != (int)sizeof(vi)) continue;
                if ((dev_t)vi.pvi.vi_stat.vst_dev == target.st_dev && vi.pvi.vi_stat.vst_ino == target.st_ino &&
                    (vi.pfi.fi_openflags & FWRITE)) { result = 1; break; }
            }
        }
        if (result != 1) result = inspected > 0 ? 0 : -1;
    }
    if (spDebug())
        fprintf(stderr, "[Grow] 写入方查询 %.2f ms（检查 %d 个进程%s）→ %d\n", (spNowUs() - t0) / 1000.0, inspected,
                unknown ? "，另有读不到 fd 表的" : "", result);
    return result;
}

static int spGrowthWriterOpen(LocalFileIO* io, int64_t mono) {
    if (io->remote || io->growth.path.empty()) return -1;
    if (io->growth.writerCheckedUs && mono - io->growth.writerCheckedUs < 1000000) return io->growth.writerOpen;
    io->growth.writerCheckedUs = mono;
    const int result = spPathWriterOpen(io->growth.path);
    if (io->debug && result != io->growth.writerOpen)
        fprintf(stderr, "[Grow] 写入方%s\n", result == 1 ? "仍开着文件" : result == 0 ? "已关闭文件" : "无法确认");
    io->growth.writerOpen = result;
    return result;
}

static bool spGrowthWantPath(const LocalFileIO* io, int64_t mono) {
    return io->growth.hintCheckedUs == 0 || mono - io->growth.hintCheckedUs >= 1000000;
}

static int64_t spLocalIOReadOutsideAvio(LocalFileIO* io, int64_t pos, uint8_t* out, size_t n, bool retainLanding);

static int spPendingZeroStill(LocalFileIO* io, int64_t pos, int64_t len) {
    uint8_t look[spgrow::kPendingZeroRun];
    const size_t want = (size_t)std::min<int64_t>(std::max<int64_t>(len, 1), sizeof look);
    const int64_t got = spLocalIOReadOutsideAvio(io, pos, look, want, true);
    if (got < 0) return (int)got;
    return got > 0 && spresil::allZero(look, (size_t)got) && (got == (int64_t)want || pos + got >= io->size) ? 1 : 0;
}

constexpr int64_t kSuspectZeroRun = 32;
constexpr int64_t kSuspectZeroSpan = 256 * 1024;
constexpr int64_t kSuspectZeroMaxWaitUs = 2000000;

static bool spZeroIsSparse(const LocalFileIO* io, int64_t pos, int64_t len) {
    if (io->remote || !io->localFilesystem || io->fd < 0) return false;
    const int64_t a = (pos + 4095) & ~(int64_t)4095;
    if (a + 4096 > pos + len) return false;
    const off_t d = lseek(io->fd, (off_t)a, SEEK_DATA);
    return d > (off_t)a || (d < 0 && errno == ENXIO);
}

static int spLocalIOAwaitGrowth(LocalFileIO* io, int64_t zeroAt = -1, int64_t zeroLen = spgrow::kPendingZeroRun) {
    if (!io->growthWaitAllowed.load(std::memory_order_relaxed)) return 0;
    if (io->growthMode.load(std::memory_order_relaxed) == (uint8_t)spgrow::Mode::Static &&
        spNowUs() < io->growth.staticUntilUs) return 0;
    auto aborted = [io] { return io->abortRequested.load() || (io->abortFlag && io->abortFlag->load()); };
    SourceGrowthPub* pub = io->growthPub.get();
    int64_t waitStartUs = 0;
    auto leaveWait = [&] {
        if (pub && waitStartUs) {
            pub->waitingSinceUs.store(0, std::memory_order_relaxed);
            pub->pendingZeroPos.store(-1, std::memory_order_relaxed);
        }
    };
    for (;;) {
        if (aborted()) { leaveWait(); return AVERROR_EXIT; }
        if (io->growthYield && *io->growthYield && (*io->growthYield)()) {
            leaveWait();
            io->growthInterrupted = true;
            return AVERROR_EOF;
        }
        if (zeroAt >= 0) {
            const int still = spPendingZeroStill(io, zeroAt, zeroLen);
            if (still < 0) { leaveWait(); return AVERROR_EXIT; }
            if (still && zeroLen < spgrow::kPendingZeroRun && waitStartUs && spNowUs() - waitStartUs >= kSuspectZeroMaxWaitUs) {
                leaveWait();
                io->growth.zeroRealFrom = zeroAt;
                io->growth.zeroRealUntil = zeroAt + zeroLen;
                return 0;
            }
            if (!still) {

                std::unique_lock<std::mutex> lk(io->growthMtx);
                io->growthCv.wait_for(lk, std::chrono::milliseconds(30), [&] { return aborted(); });
                leaveWait();
                io->growth.zeroSuspectFrom = zeroAt;
                io->growth.zeroSuspectUntil = zeroAt + kSuspectZeroSpan;
                return aborted() ? AVERROR_EXIT : 1;
            }
        }
        const int64_t mono = spNowUs();

        const bool wantPath = spGrowthWantPath(io, mono);
        struct stat sb {};
        int statErrno = 0;
        std::string path;
        bool aria2 = false;
        if (!spLocalIOStat(io, wantPath, &sb, &statErrno, &path, &aria2)) { leaveWait(); return AVERROR_EXIT; }
        if (!statErrno) spGrowthObserve(io, sb, mono, wantPath, path, aria2);
        spgrow::Inputs in;
        in.mode = (spgrow::Mode)io->growthMode.load(std::memory_order_relaxed);
        in.atOpen = io->growth.atOpen;
        in.now = statErrno ? spgrow::FileStamp{} : spStampOf(sb);
        in.readPos = io->pos;
        in.downloadHint = io->growth.hint;
        in.hadDownloadHint = io->growth.hadHint;
        struct timespec wall {};
        clock_gettime(CLOCK_REALTIME, &wall);
        in.wallNowNs = (int64_t)wall.tv_sec * 1000000000LL + wall.tv_nsec;
        in.monoNowUs = mono;
        in.lastGrowthUs = io->growth.lastUs;
        in.probeStartUs = io->growth.probeStartUs;
        in.pendingZero = zeroAt >= 0;
        in.inPlaceFill = io->growth.inPlaceFill;
        in.openWallNs = io->growth.openWallNs;

        if (!statErrno && (in.now.size <= in.readPos || in.pendingZero) &&
            (in.mode == spgrow::Mode::Growing || in.pendingZero || in.wallNowNs - in.now.mtimeNs < spgrow::kRecentMtimeNs ||
             in.openWallNs - in.now.mtimeNs < spgrow::kRecentMtimeNs))
            in.writerOpen = spGrowthWriterOpen(io, mono);
        const spgrow::Decision d = spgrow::decide(in);
        if (d.mode == spgrow::Mode::Probing && in.mode != spgrow::Mode::Probing) io->growth.probeStartUs = mono;

        spSetGrowthMode(io, pub, d.mode);
        if (d.mode == spgrow::Mode::Growing) {
            if (in.mode != spgrow::Mode::Growing) io->growth.lastUs = mono;
            if (!statErrno) spGrowthAdoptSize(io, sb);
        }
        if (pub) pub->lastGrowthUs.store(io->growth.lastUs, std::memory_order_relaxed);
        if (d.action == spgrow::Action::Retry) { leaveWait(); return 1; }
        if (d.action == spgrow::Action::EndOfFile) {
            leaveWait();
            if (d.mode == spgrow::Mode::Static) io->growth.staticUntilUs = mono + 250000;
            if (zeroAt >= 0) {

                io->growth.zeroRealFrom = zeroAt;
                io->growth.zeroRealUntil = zeroAt + zeroLen;
                if (io->debug && d.mode != spgrow::Mode::Static)
                    fprintf(stderr, "[Grow] 零区 @%lld 按真空洞交付（写入方已停止 / 已完成）\n", (long long)zeroAt);
                return 0;
            }
            if (io->debug && in.mode != spgrow::Mode::Static && in.mode != d.mode)
                fprintf(stderr, "[Grow] 来源判定完成（%s）：交还真 EOF size=%lld 空闲 %.1fs hint=%d/%d writer=%d\n",
                        in.mode == spgrow::Mode::Probing ? "宽限期内未变长" : "写入方已停止", (long long)io->size,
                        (mono - io->growth.lastUs) / 1e6, (int)io->growth.hint, (int)io->growth.hadHint, in.writerOpen);
            return 0;
        }
        if (!waitStartUs) {
            waitStartUs = mono;
            if (zeroAt >= 0 && !io->growth.inPlaceFill) {
                io->growth.inPlaceFill = true;
                if (pub) pub->inPlaceFill.store(true, std::memory_order_relaxed);
            }
            if (pub) {
                pub->pendingZeroPos.store(zeroAt, std::memory_order_relaxed);
                pub->waitingSinceUs.store(mono, std::memory_order_relaxed);
            }

            static std::atomic<int64_t> lastLogUs{0};
            if (io->debug && mono - lastLogUs.load(std::memory_order_relaxed) >= 1000000) {
                lastLogUs.store(mono, std::memory_order_relaxed);
                if (zeroAt >= 0)
                    fprintf(stderr, "[Grow] 待填零区等待 pos=%lld size=%lld mode=%d writer=%d\n", (long long)zeroAt,
                            (long long)io->size, (int)d.mode, in.writerOpen);
                else
                    fprintf(stderr, "[Grow] 写入前沿等待 pos=%lld size=%lld mode=%d hint=%d\n", (long long)io->pos,
                            (long long)io->size, (int)d.mode, (int)io->growth.hint);
            }
        }
        std::unique_lock<std::mutex> lk(io->growthMtx);
        io->growthCv.wait_for(lk, std::chrono::microseconds(spgrow::kPollUs), [&] { return aborted(); });
    }
}

static int64_t spAuxStallUs() {
#if !SP_APP_STORE
    static const int64_t us = [] {
        const char* s = getenv("SP_IO_STALL_AUX");
        const long ms = spDebug() && s ? atol(s) : 0;
        return ms > 0 ? (int64_t)ms * 1000 : (int64_t)0;
    }();
    return us;
#else
    return 0;
#endif
}

static int64_t spLocalIOReadOutsideAvio(LocalFileIO* io, int64_t pos, uint8_t* out, size_t n, bool retainLanding = true) {
    if (!io || io->fd < 0 || pos < 0 || (!out && n)) return AVERROR(EINVAL);
    if ((io->abortFlag && io->abortFlag->load()) || io->abortRequested.load()) return AVERROR_EXIT;
    if (n == 0) return 0;
    const int64_t stallUs = spAuxStallUs();
    bool viaReader = io->readerActive.load(std::memory_order_relaxed);
    if (viaReader) {
        const size_t want = std::min(n, LocalFileIO::kAuxLandingCap);

        if (io->auxLanding.capacity() > 512u * 1024 && want < io->auxLanding.capacity() / 4) std::vector<uint8_t>().swap(io->auxLanding);
        if (io->auxLanding.size() < want) {
            try { io->auxLanding.resize(want); } catch (const std::bad_alloc&) { std::vector<uint8_t>().swap(io->auxLanding); viaReader = false; }
        }
    }
    size_t done = 0;
    while (done < n) {
        ssize_t got = -1;
        int err = 0;
        if (viaReader) {
            const size_t chunk = std::min(n - done, io->auxLanding.size());
            if (!spLocalIOSubmitRead(io, io->auxLanding.data(), chunk, pos + (int64_t)done, done == 0 ? stallUs : 0, &got, &err)) return AVERROR_EXIT;
            if (got > 0) memcpy(out + done, io->auxLanding.data(), (size_t)got);
        } else {
            spLocalIOInlineRead(io, out + done, n - done, pos + (int64_t)done, done == 0 ? stallUs : 0, &got, &err);
        }
        if (got < 0) {
            if (viaReader && !retainLanding) std::vector<uint8_t>().swap(io->auxLanding);
            return err == EINTR ? AVERROR_EXIT : AVERROR(err);
        }
        if (got == 0) break;
        done += (size_t)got;
    }
    if (viaReader && !retainLanding) std::vector<uint8_t>().swap(io->auxLanding);
    return (int64_t)done;
}

static int64_t spLocalIOReadSwap(LocalFileIO* io, int64_t pos, size_t n, std::vector<uint8_t>& dst) {
    if (!io || io->fd < 0 || pos < 0) return AVERROR(EINVAL);
    if ((io->abortFlag && io->abortFlag->load()) || io->abortRequested.load()) return AVERROR_EXIT;
    bool swapPath = n > 0 && n <= LocalFileIO::kAuxLandingCap && io->readerActive.load(std::memory_order_relaxed);
    if (swapPath) {

        if (io->auxLanding.capacity() > 512u * 1024 && n < io->auxLanding.capacity() / 4) std::vector<uint8_t>().swap(io->auxLanding);
        if (io->auxLanding.size() < n) {
            try { io->auxLanding.resize(n); } catch (const std::bad_alloc&) { std::vector<uint8_t>().swap(io->auxLanding); swapPath = false; }
        }
    }
    if (!swapPath) {
        try { if (dst.size() < n) dst.resize(n); } catch (const std::bad_alloc&) { return AVERROR(ENOMEM); }
        return spLocalIOReadOutsideAvio(io, pos, dst.data(), n);
    }
    const int64_t stallUs = spAuxStallUs();
    size_t done = 0;
    while (done < n) {
        ssize_t got = -1;
        int err = 0;
        if (!spLocalIOSubmitRead(io, io->auxLanding.data() + done, n - done, pos + (int64_t)done, done == 0 ? stallUs : 0, &got, &err)) return AVERROR_EXIT;
        if (got < 0) return err == EINTR ? AVERROR_EXIT : AVERROR(err);
        if (got == 0) break;
        done += (size_t)got;
    }
    std::swap(io->auxLanding, dst);
    return (int64_t)done;
}

static int64_t spLocalIOReadIntoOwned(LocalFileIO* io, int64_t pos, uint8_t* owned, size_t n) {
    if (!io || io->fd < 0 || pos < 0 || (!owned && n)) return AVERROR(EINVAL);
    if ((io->abortFlag && io->abortFlag->load()) || io->abortRequested.load()) return AVERROR_EXIT;
    if (n == 0) return 0;
    const int64_t stallUs = spAuxStallUs();
    const bool viaReader = io->readerActive.load(std::memory_order_relaxed);
    size_t done = 0;
    while (done < n) {
        ssize_t got = -1;
        int err = 0;
        if (viaReader) {
            if (!spLocalIOSubmitRead(io, owned + done, n - done, pos + (int64_t)done, done == 0 ? stallUs : 0, &got, &err)) return AVERROR_EXIT;
        } else {
            spLocalIOInlineRead(io, owned + done, n - done, pos + (int64_t)done, done == 0 ? stallUs : 0, &got, &err);
        }
        if (got < 0) return err == EINTR ? AVERROR_EXIT : AVERROR(err);
        if (got == 0) break;
        done += (size_t)got;
    }
    return (int64_t)done;
}

template <class R, class Work>
static bool spRunAbandonable(const std::shared_ptr<LocalFileIO>& io, const char* threadName, Work&& work, R& out) {
    struct Slot {
        std::atomic<bool> cancel{false};
        bool done = false;
        R result{};
    };
    if (!io || io->abortRequested.load() || (io->abortFlag && io->abortFlag->load())) return false;
    std::shared_ptr<Slot> slot;
    try { slot = std::make_shared<Slot>(); } catch (const std::bad_alloc&) { return false; }

    qos_class_t qos = qos_class_self();
    if (qos == QOS_CLASS_UNSPECIFIED) qos = QOS_CLASS_USER_INITIATED;
    try {
        std::thread([io, slot, threadName, qos, work = std::forward<Work>(work)]() mutable {
            pthread_setname_np(threadName);
            pthread_set_qos_class_self_np(qos, 0);
            if (const int64_t stallUs = spAuxStallUs()) spSleepUninterruptible(stallUs);
            R r = work(slot->cancel);
            {
                std::lock_guard<std::mutex> lk(io->jobMtx);
                slot->result = std::move(r);
                slot->done = true;
            }
            io->jobCv.notify_all();
        }).detach();
    } catch (...) { return false; }
    std::unique_lock<std::mutex> lk(io->jobMtx);

    const auto abandoned = [&] { return io->abortRequested.load() || (io->abortFlag && io->abortFlag->load()); };
    while (!slot->done && !abandoned()) io->jobCv.wait_for(lk, std::chrono::milliseconds(50));
    if (!slot->done) {
        slot->cancel.store(true, std::memory_order_release);
        return false;
    }
    out = std::move(slot->result);
    return true;
}

struct AuxIOCancelToken {
    std::atomic<bool> cancel{false};
    std::atomic<bool> inRead{false};
    std::atomic<pthread_t> tid{};

    std::mutex waitMtx;
    std::condition_variable waitCv;
};

static ssize_t spAuxPread(AuxIOCancelToken& t, int fd, void* buf, size_t len,
                          int64_t off) {
    t.tid.store(pthread_self(), std::memory_order_relaxed);
    t.inRead.store(true);

    if (t.cancel.load()) {
        t.inRead.store(false);
        errno = EINTR;
        return -1;
    }
    ssize_t n;
    do {
        n = pread(fd, buf, len, off);
    } while (n < 0 && errno == EINTR && !t.cancel.load());
    t.inRead.store(false);
    return n;
}

static void spAuxCancel(const std::shared_ptr<AuxIOCancelToken>& t) {
    if (!t) return;
    spEnsureIOInterruptSignalInstalled();
    t->cancel.store(true);
    { std::lock_guard<std::mutex> lk(t->waitMtx); }
    t->waitCv.notify_all();
    if (!t->inRead.load()) return;
    std::shared_ptr<AuxIOCancelToken> keep = t;
    std::thread([keep] {
        for (int i = 0; i < 4 && keep->inRead.load(); ++i) {
            pthread_t th = keep->tid.load(std::memory_order_relaxed);
            if (th) pthread_kill(th, SIGUSR2);
            struct timespec ts { 0, 50 * 1000 * 1000 };
            nanosleep(&ts, nullptr);
        }
    }).detach();
}

static std::atomic<int> gAuxIOWorkers{0};
static constexpr int kAuxIOWorkerCapGlobal = 16;
static constexpr int kAuxIOWorkerCapPerDemux = 4;
struct AuxWorkerScope {
    std::shared_ptr<std::atomic<int>> mine;

    explicit AuxWorkerScope(std::shared_ptr<std::atomic<int>> m = nullptr,
                            bool adoptReservation = false)
        : mine(std::move(m)) {
        if (!adoptReservation) {
            gAuxIOWorkers.fetch_add(1);
            if (mine) mine->fetch_add(1);
        }
    }
    ~AuxWorkerScope() {
        gAuxIOWorkers.fetch_sub(1);
        if (mine) mine->fetch_sub(1);
    }
};

struct AuxWorkerReservation {
    std::shared_ptr<std::atomic<int>> mine;
    bool armed = false;
    ~AuxWorkerReservation() {
        if (armed) {
            gAuxIOWorkers.fetch_sub(1);
            if (mine) mine->fetch_sub(1);
        }
    }
    void handOff() { armed = false; }
};

bool Demuxer::admitAuxWorker(const char* what) {
    const int g = gAuxIOWorkers.fetch_add(1) + 1;
    const int m = auxWorkers_ ? auxWorkers_->fetch_add(1) + 1 : 0;
    const bool globalFull = g > kAuxIOWorkerCapGlobal;
    const bool mineFull = auxWorkers_ && m > kAuxIOWorkerCapPerDemux;
    if (!globalFull && !mineFull) return true;
    gAuxIOWorkers.fetch_sub(1);
    if (auxWorkers_) auxWorkers_->fetch_sub(1);
    if (spDebug()) {
        fprintf(stderr, "[DemuxIO] 辅助 worker 拒绝启动（%s）：%s配额已满 "
                        "(全局 %d/%d 本实例 %d/%d)\n",
                what, globalFull ? "全局" : "实例",
                gAuxIOWorkers.load(), kAuxIOWorkerCapGlobal,
                auxWorkers_ ? auxWorkers_->load() : -1, kAuxIOWorkerCapPerDemux);
    }
    return false;
}

static void spScrubStopAndInterrupt(const std::shared_ptr<ScrubShared>& st);

static int spLocalIOReadRaw(void* opaque, uint8_t* buf, int len);

static int spZeroCheckMode(const LocalFileIO* io) {
    const uint8_t m = io->growthMode.load(std::memory_order_relaxed);
    const bool changing = m == (uint8_t)spgrow::Mode::Growing || m == (uint8_t)spgrow::Mode::Probing;

    if (!io->growthWaitAllowed.load(std::memory_order_relaxed)) return (changing || io->growth.inPlaceFill) && io->growthPub ? 1 : 0;
    if (changing) return 2;
    return m == (uint8_t)spgrow::Mode::Static && io->growth.watch && spNowUs() >= io->growth.staticUntilUs ? 2 : 0;
}

static constexpr int64_t kZeroCutStale = -2;

constexpr int64_t kTornZeroRun = 16;
constexpr int kTornSettleMs = 25;

static int spHasZeroRun(const uint8_t* data, int64_t n, int64_t run, int64_t pos) {
    const int64_t blk = run / 2;
    int found = 0;
    for (int64_t b = 0; b + blk <= n; b += blk)
        if (spresil::allZero(data + b, (size_t)blk)) {
            int64_t z = b, e = b + blk;
            while (z > 0 && data[z - 1] == 0) --z;
            while (e < n && data[e] == 0) ++e;
            if (e - z >= run) {
                found = 1;
                if ((pos + e - 1) / 4096 != (pos + z) / 4096 || (pos + z) % 4096 == 0) return 2;
            }
            b = e - e % blk;
        }
    return found;
}

static bool spTornVerifiedCovers(const LocalFileIO* io, int64_t a, int64_t b) {
    const auto& v = io->growth.tornVerified;
    auto it = std::upper_bound(v.begin(), v.end(), std::make_pair(a, INT64_MAX));
    return it != v.begin() && (it - 1)->first <= a && (it - 1)->second >= b;
}

static void spTornVerifiedAdd(LocalFileIO* io, int64_t a, int64_t b) {
    auto& v = io->growth.tornVerified;
    auto it = std::lower_bound(v.begin(), v.end(), std::make_pair(a, INT64_MIN));
    if (it != v.begin() && (it - 1)->second >= a) --it;
    auto end = it;
    while (end != v.end() && end->first <= b) {
        a = std::min(a, end->first);
        b = std::max(b, end->second);
        ++end;
    }
    it = v.erase(it, end);
    v.insert(it, {a, b});
}

static bool spReadIsStable(LocalFileIO* io, const uint8_t* data, int64_t n, int64_t pos) {
    thread_local std::vector<uint8_t> again;
    if ((int64_t)again.size() < n) again.resize((size_t)n);
    const int64_t got = spLocalIOReadOutsideAvio(io, pos, again.data(), (size_t)n, true);
    return got == n && memcmp(again.data(), data, (size_t)n) == 0;
}

static int64_t spZeroHeadDecide(LocalFileIO* io, int64_t n, int64_t pos) {
    constexpr int64_t kRun = spgrow::kPendingZeroRun;
    const int64_t m = n + kRun;
    std::vector<uint8_t> fresh((size_t)m);
    const int64_t got = spLocalIOReadOutsideAvio(io, pos, fresh.data(), (size_t)m, true);
    if (got < 0) return got;
    int64_t lead = 0;
    while (lead < got && fresh[(size_t)lead] == 0) ++lead;
    if (lead < n) return kZeroCutStale;
    const bool toEof = lead > 0 && pos + lead >= io->size;
    const bool suspect = lead >= kSuspectZeroRun && pos >= io->growth.zeroSuspectFrom && pos < io->growth.zeroSuspectUntil;
    if ((lead >= kRun || toEof || suspect) &&
        spgrow::pendingZeroEligible(io->growth.atOpen, {io->size, 0}, spZeroIsSparse(io, pos, lead))) {
        io->growth.zeroCutLen = std::min(lead, kRun);
        return 0;
    }
    io->growth.zeroRealFrom = pos;
    io->growth.zeroRealUntil = pos + lead;
    return n;
}

static int64_t spPendingZeroCut(LocalFileIO* io, uint8_t* data, int64_t n, int64_t pos) {
    constexpr int64_t kRun = spgrow::kPendingZeroRun;
    constexpr int64_t kBlk = 4096;
    auto eligible = [&](int64_t at, int64_t len) {
        return spgrow::pendingZeroEligible(io->growth.atOpen, {io->size, 0}, spZeroIsSparse(io, at, len));
    };
    auto inRealRun = [&](int64_t at) {
        return io->growth.zeroRealUntil > io->growth.zeroRealFrom && at >= io->growth.zeroRealFrom && at <= io->growth.zeroRealUntil;
    };
    int64_t b = (kBlk - pos % kBlk) % kBlk;
    while (b + kBlk <= n) {
        if (!spresil::allZero(data + b, (size_t)kBlk)) { b += kBlk; continue; }
        int64_t z = b;
        while (z > 0 && data[z - 1] == 0) --z;
        int64_t e = b + kBlk;
        while (e < n && data[e] == 0) ++e;
        const int64_t zAbs = pos + z;
        const int64_t next = e + (kBlk - (pos + e) % kBlk) % kBlk;
        if (inRealRun(zAbs)) {
            io->growth.zeroRealUntil = std::max(io->growth.zeroRealUntil, pos + e);
            b = next;
            continue;
        }
        if (e < n) {
            if (e - z >= kRun) {
                if (eligible(zAbs, e - z)) { io->growth.zeroCutLen = kRun; return z; }
                io->growth.zeroRealFrom = zAbs;
                io->growth.zeroRealUntil = pos + e;
            }
            b = next;
            continue;
        }
        if (z > 0) return z;
        return spZeroHeadDecide(io, n, pos);
    }

    const int64_t sFrom = std::max(pos, io->growth.zeroSuspectFrom), sTo = std::min(pos + n, io->growth.zeroSuspectUntil);
    if (sFrom < sTo) {
        constexpr int64_t kSub = 16;
        for (int64_t q = ((sFrom + kSub - 1) / kSub) * kSub - pos; q + kSub <= sTo - pos;) {
            if (!spresil::allZero(data + q, (size_t)kSub)) { q += kSub; continue; }
            int64_t z = q, e = q + kSub;
            while (z > 0 && data[z - 1] == 0) --z;
            while (e < n && data[e] == 0) ++e;
            if (e < n && e - z >= kSuspectZeroRun && !inRealRun(pos + z) && eligible(pos + z, e - z)) {
                io->growth.zeroCutLen = e - z;
                return z;
            }
            q = ((e + kSub - 1) / kSub) * kSub;
        }
    }

    if (n > 0 && data[n - 1] == 0) {
        int64_t z = n - 1;
        while (z > 0 && data[z - 1] == 0) --z;
        if (inRealRun(pos + z)) return n;
        if (z > 0) return z;
        return spZeroHeadDecide(io, n, pos);
    }
    return n;
}

static bool spReadBlocksUsable(const LocalFileIO* io) {
    if (io->remote) return true;
    const uint8_t m = io->growthMode.load(std::memory_order_relaxed);
    if (m == (uint8_t)spgrow::Mode::Final) return true;
    if (io->growth.inPlaceFill) return false;
    const bool changing = m == (uint8_t)spgrow::Mode::Growing || m == (uint8_t)spgrow::Mode::Probing;
    return !(changing && io->size == io->growth.atOpen.size);
}

static LocalFileIO::ReadBlock* spReadBlockAt(LocalFileIO* io, int64_t pos) {
    for (LocalFileIO::ReadBlock& b : io->blocks)
        if (b.len > 0 && pos >= b.pos && pos < b.pos + b.len) return &b;
    return nullptr;
}

static LocalFileIO::ReadBlock* spReadBlockVictim(LocalFileIO* io, int64_t pos) {
    LocalFileIO::ReadBlock *empty = nullptr, *fresh = nullptr, *lru = nullptr;
    for (LocalFileIO::ReadBlock& b : io->blocks) {
        if (b.len > 0 && b.pos + b.len == pos) return &b;
        if (!b.buf) {
            if (!fresh) fresh = &b;
        } else if (b.len == 0) {
            if (!empty) empty = &b;
        } else if (!lru || b.used < lru->used) {
            lru = &b;
        }
    }
    return empty ? empty : fresh ? fresh : lru;
}

static bool spContentReadCut(LocalFileIO* io, int64_t start) {
    if (!io->contentGaps.empty()) {
        auto it = std::upper_bound(io->contentGaps.begin(), io->contentGaps.end(), std::make_pair(start, INT64_MAX));
        if (it != io->contentGaps.begin()) {
            --it;
            if (start >= it->first && start < it->second) { io->contentCutAt = start; return true; }
        }
    }
    if (io->contentSuspectEnabled && io->bytesSinceDeliver >= LocalFileIO::kContentSuspectBytes) {
        io->contentSuspectAt = start;
        return true;
    }
    return false;
}

static int spLocalIORead(void* opaque, uint8_t* buf, int len) {
    auto* io = (LocalFileIO*)opaque;
    const int64_t start = io->pos;

    if ((io->contentSuspectEnabled || !io->contentGaps.empty()) &&
        io->growthMode.load(std::memory_order_relaxed) == (uint8_t)spgrow::Mode::Static) {
        if (spContentReadCut(io, start)) return AVERROR_EOF;

        if (!io->contentGaps.empty()) {
            auto it = std::upper_bound(io->contentGaps.begin(), io->contentGaps.end(), std::make_pair(start, INT64_MAX));
            if (it != io->contentGaps.end() && it->first > start && it->first < start + len) len = (int)(it->first - start);
        }
    }
    int n = spLocalIOReadRaw(opaque, buf, len);
    if (n > 0 && io->contentSuspectEnabled) io->bytesSinceDeliver += n;
    if (io->virtualSize > io->size && start < io->virtualSize && (n == AVERROR_EOF || (n >= 0 && start + n < io->virtualSize && start + n >= io->size))) {

        const int got = n > 0 ? n : 0;
        const int want = (int)std::min<int64_t>(len, io->virtualSize - start);
        if (want > got) {
            memset(buf + got, 0, (size_t)(want - got));
            io->pos = start + want;
            n = want;
        }
    }
    if (n > 0 && !io->patches.empty()) {
        const int64_t end = start + n;
        for (const spresil::Patch& pt : io->patches) {
            const int64_t pEnd = pt.offset + (int64_t)pt.bytes.size();
            if (pt.offset >= end || pEnd <= start) continue;
            const int64_t from = std::max(start, pt.offset);
            const int64_t to = std::min(end, pEnd);
            memcpy(buf + (from - start), pt.bytes.data() + (from - pt.offset), (size_t)(to - from));
        }
    }
    return n;
}

static int spLocalIOReadRaw(void* opaque, uint8_t* buf, int len) {
    auto* io = (LocalFileIO*)opaque;
    if (io->abortFlag && io->abortFlag->load()) return AVERROR_EXIT;

    const uint8_t gm = io->growthMode.load(std::memory_order_relaxed);
    if ((gm == (uint8_t)spgrow::Mode::Growing || (gm == (uint8_t)spgrow::Mode::Static && io->growth.watch)) &&
        io->growthWaitAllowed.load(std::memory_order_relaxed)) {
        const int64_t mono = spNowUs();

        const int64_t observeEveryUs = mono - io->growth.openMonoUs < 2000000 ? 100000 : 1000000;
        if (mono - io->growth.lastObserveUs >= observeEveryUs) {
            struct stat sb {};
            int statErrno = 0;
            std::string path;
            bool aria2 = false;
            const bool wantPath = spGrowthWantPath(io, mono);
            if (!spLocalIOStat(io, wantPath, &sb, &statErrno, &path, &aria2)) return AVERROR_EXIT;
            if (!statErrno) {
                spGrowthObserve(io, sb, mono, wantPath, path, aria2);
                if (gm == (uint8_t)spgrow::Mode::Static && spStampOf(sb) != io->growth.atOpen) {

                    spSetGrowthMode(io, io->growthPub.get(), spgrow::Mode::Growing);
                    if (io->debug) fprintf(stderr, "[Grow] 播放途中发现文件在变：转入增长模式 size=%lld\n", (long long)sb.st_size);
                }
                if (io->growthMode.load(std::memory_order_relaxed) == (uint8_t)spgrow::Mode::Growing) spGrowthAdoptSize(io, sb);
            }
        }
    }

    if (io->activityUs) io->activityUs->store(spNowUs(), std::memory_order_relaxed);
#if !SP_APP_STORE

    static const std::pair<int64_t, int64_t> stallCfg = [] {
        long periodMs = 0, stallMs = 0;
        if (spDebug())
            if (const char* s = getenv("SP_IO_STALL"))
                sscanf(s, "%ld,%ld", &periodMs, &stallMs);
        return std::pair<int64_t, int64_t>(periodMs * 1000, stallMs * 1000);
    }();
    static const bool stallHard = [] {
        const char* s = getenv("SP_IO_STALL_HARD");
        return spDebug() && s && *s && strcmp(s, "0") != 0;
    }();
    int64_t hardStallUs = 0;
    if (stallCfg.first >= 0 && stallCfg.second > 0) {
        int64_t now = spNowUs();
        int64_t last = io->lastStallEndUs.load(std::memory_order_relaxed);
        if (now - last >= stallCfg.first &&
            io->lastStallEndUs.compare_exchange_strong(last, now + stallCfg.second)) {
            int64_t deadline = now + stallCfg.second;
            fprintf(stderr, "[DemuxIO] SP_IO_STALL 注入 %lldms%s\n",
                    (long long)(stallCfg.second / 1000), stallHard ? "（hard）" : "");
            if (stallHard) {
                hardStallUs = stallCfg.second;
            } else {
                while (spNowUs() < deadline &&
                       !(io->abortFlag && io->abortFlag->load()))
                    usleep(50000);
            }
        }
    }
#else
    const int64_t hardStallUs = 0;
#endif
    int64_t t0 = spNowUs();

    if (io->abortFlag && io->abortFlag->load()) return AVERROR_EXIT;

    if (!spReadBlocksUsable(io)) {
        for (LocalFileIO::ReadBlock& b : io->blocks) b.len = 0;
    } else {
        if (LocalFileIO::ReadBlock* b = spReadBlockAt(io, io->pos)) {
            const int take = (int)std::min<int64_t>(len, b->pos + b->len - io->pos);
            memcpy(buf, b->buf + (io->pos - b->pos), (size_t)take);
            b->used = io->blockTick;
            io->pos += take;
            io->seqBytes += take;
            return take;
        }
    }

    size_t want = (size_t)len;
    if (io->remote) {
        const int granule = spRemoteReadGranule(io->seqBytes);
        if (granule > len) want = (size_t)granule;
    }
    LocalFileIO::ReadBlock* blk = nullptr;
    if ((int64_t)want <= io->stageCap) {
        blk = spReadBlockVictim(io, io->pos);
        if (!blk->buf) blk->buf = (uint8_t*)av_malloc((size_t)io->stageCap);
        if (blk->buf) blk->len = 0;
        else blk = nullptr;
    }
    if (!blk) want = (size_t)len;
    uint8_t* dst = blk ? blk->buf : buf;

    const bool viaReader = blk && io->readerActive.load(std::memory_order_relaxed);
    ssize_t n = -1;
    int savedErrno = 0;
    if (viaReader) {
        if (!spLocalIOSubmitRead(io, dst, want, io->pos, hardStallUs, &n, &savedErrno)) {
            io->st.ioUs += (uint64_t)(spNowUs() - t0);
            return AVERROR_EXIT;
        }
    } else {
        spLocalIOInlineRead(io, dst, want, io->pos, hardStallUs, &n, &savedErrno);
    }
    int64_t t1 = spNowUs();
    io->st.ioUs += (uint64_t)(t1 - t0);
    if (n < 0) {
        if (savedErrno == EINTR) return AVERROR_EXIT;
        ++io->readFaults;
        return AVERROR(savedErrno);
    }
    if (n == 0) {

        const int g = spLocalIOAwaitGrowth(io);
        if (g > 0) return spLocalIOReadRaw(opaque, buf, len);
        return g < 0 ? g : AVERROR_EOF;
    }

    const int zeroMode = spZeroCheckMode(io);
    if (zeroMode) {

        const int64_t k = spPendingZeroCut(io, dst, (int64_t)n, io->pos);
        if (k == kZeroCutStale) return spLocalIOReadRaw(opaque, buf, len);
        if (k < 0) return AVERROR_EXIT;

        const int64_t deliver = k == 0 ? 0 : k;
        const bool inPlace = io->growth.inPlaceFill || io->size == io->growth.atOpen.size;

        const bool writerEvidence = io->growth.inPlaceFill || io->growthMode.load(std::memory_order_relaxed) == (uint8_t)spgrow::Mode::Growing;
        const bool writerActive = writerEvidence && spNowUs() - io->growth.lastUs < 1500000;
        if (deliver > 0 && inPlace && writerActive && !io->remote && io->growth.zeroTornRetries < 8 &&
            !spTornVerifiedCovers(io, io->pos, io->pos + deliver)) {
            auto aborted = [io] { return io->abortRequested.load() || (io->abortFlag && io->abortFlag->load()); };

            const bool fresh = io->pos < io->growth.zeroSuspectUntil && io->pos + deliver > io->growth.zeroSuspectFrom;
            const int rounds = fresh ? 3 : spHasZeroRun(dst, deliver, kTornZeroRun, io->pos) == 2 ? 2 : 1;
            for (int round = 0; round < rounds; ++round) {
                {
                    std::unique_lock<std::mutex> lk(io->growthMtx);
                    io->growthCv.wait_for(lk, std::chrono::milliseconds(round == 0 ? kTornSettleMs : round == 1 ? 75 : 150),
                                          [&] { return aborted(); });
                }
                if (aborted()) return AVERROR_EXIT;
                if (!spReadIsStable(io, dst, deliver, io->pos)) {
                    ++io->growth.zeroTornRetries;
                    return spLocalIOReadRaw(opaque, buf, len);
                }
            }
            spTornVerifiedAdd(io, io->pos, io->pos + deliver);
        }
        io->growth.zeroTornRetries = 0;
        if (k == 0 && zeroMode == 1) {
            io->growth.zeroEofOutsidePlay = true;
            return AVERROR_EOF;
        }
        if (k == 0) {
            const int g = spLocalIOAwaitGrowth(io, io->pos, io->growth.zeroCutLen);
            if (g > 0) return spLocalIOReadRaw(opaque, buf, len);
            if (g < 0) return g;
        } else if (k < (int64_t)n) {
            n = (ssize_t)k;
        }
    }

    if (blk) {
        blk->pos = io->pos;
        blk->len = spReadBlocksUsable(io) ? (int)n : 0;
        blk->used = ++io->blockTick;
        for (LocalFileIO::ReadBlock& b : io->blocks)
            if (b.buf && &b != blk && io->blockTick - b.used > LocalFileIO::kReadBlockIdle) {
                av_freep(&b.buf);
                b.len = 0;
            }
    }
    io->st.reads++;
    io->st.readBytes += (uint64_t)n;
    if (n > len) n = len;
    if (dst != buf) memcpy(buf, dst, (size_t)n);
    io->pos += n;
    io->seqBytes += n;

    if (io->debug) {
        if (io->lastReportUs == 0) io->lastReportUs = t1;
        if (t1 - io->lastReportUs >= 10 * 1000000) {
            const Demuxer::IOStats& s = io->st;
            fprintf(stderr,
                    "[DemuxIO] 10s: reads=%llu bytes=%.1fMB io=%.0fms jumps=%llu\n",
                    (unsigned long long)(s.reads - io->lastReport.reads),
                    (s.readBytes - io->lastReport.readBytes) / 1048576.0,
                    (s.ioUs - io->lastReport.ioUs) / 1000.0,
                    (unsigned long long)(s.jumps - io->lastReport.jumps));
            io->lastReport = s;
            io->lastReportUs = t1;
        }
    }
    return (int)n;
}

static int64_t spLocalIOSeek(void* opaque, int64_t offset, int whence) {
    auto* io = (LocalFileIO*)opaque;
    whence &= ~AVSEEK_FORCE;
    const int64_t logicalSize = io->virtualSize > io->size ? io->virtualSize : io->size;
    if (whence == AVSEEK_SIZE) return logicalSize;
    int64_t target;
    switch (whence) {
        case SEEK_SET: target = offset; break;
        case SEEK_CUR: target = io->pos + offset; break;
        case SEEK_END: target = logicalSize + offset; break;
        default: return AVERROR(EINVAL);
    }
    if (target < 0) return AVERROR(EINVAL);

    if (target != io->pos && !(spReadBlocksUsable(io) && spReadBlockAt(io, target))) {
        io->st.jumps++;
        io->seqBytes = 0;
    }
    io->pos = target;
    return target;
}

static bool spIsPlainPath(const std::string& path) {
    return path.find("://") == std::string::npos && !path.empty();
}

bool Demuxer::attachLocalIO(const std::string& path, const std::shared_ptr<LocalFileIO>& source) {
    if (!spIsPlainPath(path)) return false;
    if (source && !spLocalSourceUnchanged(*source)) return false;
    int fd = source ? fcntl(source->fd, F_DUPFD_CLOEXEC, 0) : ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat sb {};
    if (fstat(fd, &sb) != 0 || !S_ISREG(sb.st_mode)) {
        ::close(fd);
        return false;
    }

    (void)fcntl(fd, F_RDAHEAD, 1);

    remoteVolume_ = false;
    struct statfs sfs {};
    if (fstatfs(fd, &sfs) == 0) {
        const char* t = sfs.f_fstypename;
        remoteVolume_ = strcmp(t, "smbfs") == 0 || strcmp(t, "afpfs") == 0 ||
                        strcmp(t, "nfs") == 0 || strcmp(t, "webdav") == 0;
    }

    std::shared_ptr<LocalFileIO> io;
    try { io = std::make_shared<LocalFileIO>(); }
    catch (const std::bad_alloc&) { ::close(fd); return false; }
    io->fd = fd;
    io->size = source ? source->size : (int64_t)sb.st_size;
    io->sourceDev = source ? source->sourceDev : sb.st_dev;
    io->sourceIno = source ? source->sourceIno : sb.st_ino;
    io->sourceMtime = source ? source->sourceMtime : sb.st_mtimespec;
    io->growthPub = growthPub_;
    io->growthYield = growthYield_;
    if (source) {

        io->growthMode.store(source->growthMode.load(std::memory_order_relaxed), std::memory_order_relaxed);
        io->growth = source->growth;
    } else {
        io->growth.atOpen = spStampOf(sb);
        io->growth.lastStamp = io->growth.atOpen;
        io->growth.lastUs = spNowUs();
        io->growth.openMonoUs = io->growth.lastUs;
        {
            struct timespec wall {};
            clock_gettime(CLOCK_REALTIME, &wall);
            io->growth.openWallNs = (int64_t)wall.tv_sec * 1000000000LL + wall.tv_nsec;
            const int64_t ageNs = io->growth.openWallNs - io->growth.atOpen.mtimeNs;
            io->growth.watch = ageNs < spgrow::kWatchRecentNs || spgrow::pathHasDownloadSuffix(path);
        }
        growthPub_->mode.store(0, std::memory_order_relaxed);
        growthPub_->waitingSinceUs.store(0, std::memory_order_relaxed);
        growthPub_->lastGrowthUs.store(0, std::memory_order_relaxed);
        growthPub_->downloadHint.store(false, std::memory_order_relaxed);
        growthPub_->pendingZeroPos.store(-1, std::memory_order_relaxed);
        growthPub_->inPlaceFill.store(false, std::memory_order_relaxed);
        growthPub_->liveSize.store((int64_t)sb.st_size, std::memory_order_relaxed);
        std::lock_guard<std::mutex> lk(growthPub_->pathMtx);
        growthPub_->path.clear();
        std::lock_guard<std::mutex> jlk(pendingJobMtx_);
        pendingJob_->cancelled.store(true);
        pendingJob_ = std::make_shared<PendingScanJob>();
        byteTimeMapCaptured_ = false;
    }
    if (source && !spLocalSourceUnchanged(*io)) return false;
    io->localFilesystem = (sfs.f_flags & MNT_LOCAL) != 0;
    io->abortFlag = &abortIO_;
    io->debug = spDebug();
    io->remote = remoteVolume_;

    if (!source && io->growth.watch && io->localFilesystem && !io->remote && io->size > 0) {
        const off_t hole = lseek(io->fd, 0, SEEK_HOLE);
        if (hole >= 0 && (int64_t)hole < io->size &&
            (spgrow::pathHasDownloadSuffix(path) || spPathWriterOpen(path) == 1)) {
            io->growth.inPlaceFill = true;
            growthPub_->inPlaceFill.store(true, std::memory_order_relaxed);
        }
    }
    io->patches = spresil::PatchOverlay(pendingPatches_);
    io->virtualSize = io->size;
    for (const spresil::Patch& pt : io->patches) io->virtualSize = std::max<int64_t>(io->virtualSize, pt.offset + (int64_t)pt.bytes.size());

    int bufKB = 256;
#if !SP_APP_STORE
    if (const char* e = getenv("SP_IO_BUFKB")) {
        int v = atoi(e);
        if (v >= 4 && v <= 4096) bufKB = v;
    }
#endif
    size_t bufSize = (size_t)bufKB * 1024;
    if ((int64_t)bufSize > io->stageCap) io->stageCap = (int)bufSize;
    uint8_t* buf = (uint8_t*)av_malloc(bufSize);
    if (!buf) return false;
    AVIOContext* ctx = avio_alloc_context(buf, (int)bufSize, 0 /*write*/, io.get(),
                                          spLocalIORead, nullptr, spLocalIOSeek);
    if (!ctx) { av_free(buf); return false; }
    avio_ = ctx;
    io->activityUs = ioActivityUs_;
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        localIO_ = io;
    }

    bool inlineIO = false;
#if !SP_APP_STORE
    if (const char* e = getenv("SP_IO_INLINE")) inlineIO = *e && strcmp(e, "0") != 0;
#endif
    if (!inlineIO) {
        try {
            std::thread(spLocalIOReaderLoop, io).detach();
            io->readerActive.store(true);
        } catch (...) {
            if (spDebug()) fprintf(stderr, "[DemuxIO] 读线程启动失败，退回内联 pread\n");
        }
    }
    fmtCtx_->pb = ctx;
    fmtCtx_->flags |= AVFMT_FLAG_CUSTOM_IO;
    return true;
}

void Demuxer::detachLocalIO() {
    if (avio_) {

        av_freep(&avio_->buffer);
        avio_context_free(&avio_);
    }
    std::shared_ptr<LocalFileIO> io;
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        io.swap(localIO_);

    }
    if (io) {
        io->viewAttached.store(false, std::memory_order_release);

        io->abortRequested.store(true);
        {
            std::lock_guard<std::mutex> lk(io->jobMtx);
            io->quit = true;
            io->jobPending = false;
        }
        io->jobCv.notify_all();
    }
}

void Demuxer::wakeSourceWait() {
    auto io = ioSnapshot();
    if (!io) return;
    { std::lock_guard<std::mutex> lk(io->growthMtx); }
    io->growthCv.notify_all();
}

void Demuxer::setGrowthYield(std::function<bool()> shouldYield) {
    growthYield_ = std::make_shared<const std::function<bool()>>(std::move(shouldYield));
}

Demuxer::SourceGrowthState Demuxer::sourceGrowthState() const {
    SourceGrowthState st;
    const SourceGrowthPub& p = *growthPub_;
    st.mode = p.mode.load(std::memory_order_relaxed);
    st.waitingSinceUs = p.waitingSinceUs.load(std::memory_order_relaxed);
    st.waiting = st.waitingSinceUs != 0;
    const int64_t last = p.lastGrowthUs.load(std::memory_order_relaxed);
    st.idleUs = last > 0 ? spNowUs() - last : 0;
    st.liveSize = p.liveSize.load(std::memory_order_relaxed);
    st.downloadHint = p.downloadHint.load(std::memory_order_relaxed);
    st.pathRev = p.pathRev.load(std::memory_order_acquire);
    st.pendingZeroPos = p.pendingZeroPos.load(std::memory_order_relaxed);
    st.inPlaceFill = p.inPlaceFill.load(std::memory_order_relaxed);
    return st;
}

void Demuxer::captureByteTimeMap() {
    byteTimeMapCaptured_ = true;
    std::vector<std::pair<int64_t, int64_t>> m;
    if (fmtCtx_) {
        const int si = videoStream_ >= 0 ? videoStream_ : 0;
        if (si < (int)fmtCtx_->nb_streams) {
            AVStream* st = fmtCtx_->streams[si];
            const int n = avformat_index_get_entries_count(st);
            const int step = n > 4096 ? n / 4096 + 1 : 1;
            m.reserve((size_t)(n / step + 1));
            for (int i = 0; i < n; i += step) {
                const AVIndexEntry* e = avformat_index_get_entry(st, i);
                if (!e || e->pos < 0 || e->timestamp == AV_NOPTS_VALUE) continue;
                m.emplace_back(e->pos, av_rescale_q(e->timestamp, st->time_base, AV_TIME_BASE_Q) - timelineOriginUs_);
            }
            std::sort(m.begin(), m.end());

            std::vector<std::pair<int64_t, int64_t>> mono;
            for (const auto& p : m)
                if (mono.empty() || (p.first > mono.back().first && p.second > mono.back().second)) mono.push_back(p);
            m.swap(mono);
        }
    }
    std::shared_ptr<PendingScanJob> job;
    {
        std::lock_guard<std::mutex> jlk(pendingJobMtx_);
        job = pendingJob_;
    }
    std::lock_guard<std::mutex> lk(job->mapMtx);
    job->map = std::move(m);
}

std::shared_ptr<PendingScanJob> Demuxer::pendingScanJob() {
    const std::string cur = sourceCurrentPath();
    std::lock_guard<std::mutex> jlk(pendingJobMtx_);
    std::lock_guard<std::mutex> lk(pendingJob_->mapMtx);
    if (!pendingJob_->pub) {
        pendingJob_->remote = remoteVolume_;
        pendingJob_->pub = growthPub_;
    }
    if (!cur.empty()) pendingJob_->path = cur;
    else if (pendingJob_->path.empty()) pendingJob_->path = path_;
    return pendingJob_;
}

static int64_t spPendingPosToUs(const std::vector<std::pair<int64_t, int64_t>>& m, int64_t pos, int64_t size, int64_t dur) {
    if (m.size() >= 2) {
        auto it = std::upper_bound(m.begin(), m.end(), std::make_pair(pos, INT64_MAX));
        std::pair<int64_t, int64_t> a{0, 0}, b{size, dur};
        if (it == m.begin()) b = *it;
        else if (it == m.end()) a = m.back();
        else { a = *(it - 1); b = *it; }
        if (b.first <= a.first) return a.second;
        return a.second + (int64_t)((double)(b.second - a.second) * (double)(pos - a.first) / (double)(b.first - a.first));
    }
    return size > 0 ? (int64_t)((double)dur * (double)pos / (double)size) : 0;
}

std::vector<std::pair<int64_t, int64_t>> spRunPendingScan(PendingScanJob& job) {
    std::vector<std::pair<int64_t, int64_t>> out;
    if (!job.pub || job.cancelled.load()) return out;
    const auto mode = (spgrow::Mode)job.pub->mode.load(std::memory_order_relaxed);
    if (mode != spgrow::Mode::Growing) return out;
    std::string path;
    {
        std::lock_guard<std::mutex> lk(job.mapMtx);
        path = job.path;
    }
    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return out;
    struct stat sb {};
    if (fstat(fd, &sb) != 0 || sb.st_size <= 0) { ::close(fd); return out; }
    const int64_t size = sb.st_size;
    std::vector<std::pair<int64_t, int64_t>> map;
    int64_t dur;
    {
        std::lock_guard<std::mutex> lk(job.mapMtx);
        map = job.map;
        dur = job.durationUs;
    }
    if (dur <= 0) { ::close(fd); return out; }
    std::vector<std::pair<int64_t, int64_t>> bytes;
    if (!job.pub->inPlaceFill.load(std::memory_order_relaxed)) {
        bytes.emplace_back(size, INT64_MAX);
    } else {

        if (!job.remote) {
            for (int64_t off = 0; off < size && !job.cancelled.load();) {
                const off_t d = lseek(fd, (off_t)off, SEEK_DATA);
                if (d < 0) { if (errno == ENXIO) bytes.emplace_back(off, size); break; }
                if (d > off) bytes.emplace_back(off, (int64_t)d);
                const off_t h = lseek(fd, d, SEEK_HOLE);
                if (h <= d) break;
                off = h;
            }
        }
        if (bytes.empty()) {

            if (job.sampledSize != size) {
                job.granule = std::max<int64_t>(1 << 20, size / 4096);
                job.present.assign((size_t)((size + job.granule - 1) / job.granule), 0);
                job.sampledSize = size;
                job.cursor = 0;
            }
            const size_t nChunks = job.present.size();
            size_t budget = job.remote ? 128 : 1024;
            uint8_t probe[4096];
            for (size_t k = 0; k < nChunks && budget > 0 && !job.cancelled.load(); ++k) {
                const size_t c = (job.cursor + k) % nChunks;
                if (job.present[c]) continue;
                --budget;
                const int64_t off = (int64_t)c * job.granule;
                const ssize_t got = pread(fd, probe, (size_t)std::min<int64_t>(sizeof probe, size - off), off);
                if (got > 0 && !spresil::allZero(probe, (size_t)got)) job.present[c] = 1;
                job.cursor = (c + 1) % nChunks;
            }
            for (size_t c = 0; c < nChunks; ++c) {
                if (job.present[c]) continue;
                const int64_t a = (int64_t)c * job.granule, b = std::min(size, a + job.granule);
                if (!bytes.empty() && bytes.back().second == a) bytes.back().second = b;
                else bytes.emplace_back(a, b);
            }
        }
    }
    ::close(fd);
    for (const auto& r : bytes) {
        if (r.second != INT64_MAX && r.second - r.first < 64 * 1024) continue;
        const int64_t t0 = std::max<int64_t>(0, spPendingPosToUs(map, r.first, size, dur));
        const int64_t t1 = r.second == INT64_MAX ? dur : std::min(dur, spPendingPosToUs(map, r.second, size, dur));
        if (t1 - t0 < 100000) continue;
        if (!out.empty() && t0 <= out.back().second) out.back().second = std::max(out.back().second, t1);
        else out.emplace_back(t0, t1);
    }
    return out;
}

static bool spMp4TopLevelMoovComplete(int fd, int64_t size) {
    auto be32 = [](const uint8_t* p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; };
    auto printable = [](const uint8_t* p) {
        for (int i = 0; i < 4; ++i) if (p[i] < 0x20 || p[i] > 0x7e) return false;
        return true;
    };
    int64_t off = 0;
    for (int guard = 0; guard < 4096 && off + 8 <= size; ++guard) {
        uint8_t h[16] = {};
        if (pread(fd, h, sizeof h, off) < 8 || !printable(h + 4)) return false;
        uint64_t sz = be32(h);
        int hdr = 8;
        if (sz == 1) { sz = (uint64_t)be32(h + 8) << 32 | be32(h + 12); hdr = 16; }
        else if (sz == 0) sz = (uint64_t)(size - off);
        if (sz < (uint64_t)hdr) return false;
        if (memcmp(h + 4, "moov", 4) == 0) {
            if (off + (int64_t)sz > size) return false;
            uint8_t c[8] = {};
            return pread(fd, c, sizeof c, off + hdr) == (ssize_t)sizeof c && printable(c + 4);
        }
        off += (int64_t)sz;
    }
    return false;
}

IndexWaitVerdict spProbeIndexWait(const std::string& path, IndexWaitState& st) {
    struct stat sb {};
    if (stat(path.c_str(), &sb) != 0 || !S_ISREG(sb.st_mode)) return st.started ? IndexWaitVerdict::Finished : IndexWaitVerdict::NotWritten;
    const int64_t mono = spNowUs();
    const spgrow::FileStamp now = spStampOf(sb);
    const bool first = !st.started;
    if (first) {
        st.started = true;
        struct timespec w0 {};
        clock_gettime(CLOCK_REALTIME, &w0);
        st.openWallNs = (int64_t)w0.tv_sec * 1000000000LL + w0.tv_nsec;
        st.atOpenSize = st.lastSize = now.size;
        st.atOpenMtimeNs = st.lastMtimeNs = now.mtimeNs;
        st.lastGrowthUs = mono;
    } else if (now.size != st.lastSize || now.mtimeNs != st.lastMtimeNs) {
        st.lastSize = now.size;
        st.lastMtimeNs = now.mtimeNs;
        st.lastGrowthUs = mono;
    }
    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        const bool ready = spMp4TopLevelMoovComplete(fd, now.size);
        ::close(fd);
        if (ready) return IndexWaitVerdict::Ready;
    }
    struct stat side {};
    const bool hint = spgrow::pathHasDownloadSuffix(path) || stat((path + ".aria2").c_str(), &side) == 0;
    if (hint) st.hadHint = true;
    struct statfs sfs {};
    const bool local = statfs(path.c_str(), &sfs) == 0 && (sfs.f_flags & MNT_LOCAL) != 0;
    spgrow::Inputs in;
    in.mode = (spgrow::Mode)st.mode;
    in.atOpen = {st.atOpenSize, st.atOpenMtimeNs};
    in.now = now;
    in.readPos = now.size;
    in.pendingZero = true;
    in.downloadHint = hint;
    in.hadDownloadHint = st.hadHint;
    struct timespec wall {};
    clock_gettime(CLOCK_REALTIME, &wall);
    in.wallNowNs = (int64_t)wall.tv_sec * 1000000000LL + wall.tv_nsec;
    in.monoNowUs = mono;
    in.lastGrowthUs = st.lastGrowthUs;
    in.probeStartUs = st.probeStartUs;
    in.openWallNs = st.openWallNs;
    in.writerOpen = local ? spPathWriterOpen(path) : -1;
    const spgrow::Decision d = spgrow::decide(in);
    if (d.mode == spgrow::Mode::Probing && in.mode != spgrow::Mode::Probing) st.probeStartUs = mono;
    st.mode = (uint8_t)d.mode;
    if (d.action == spgrow::Action::EndOfFile)
        return first ? IndexWaitVerdict::NotWritten : IndexWaitVerdict::Finished;
    return mono - st.lastGrowthUs >= spgrow::kStalledHintUs ? IndexWaitVerdict::Stalled : IndexWaitVerdict::Waiting;
}

std::string Demuxer::sourceCurrentPath() const {
    std::lock_guard<std::mutex> lk(growthPub_->pathMtx);
    return growthPub_->path;
}

void Demuxer::requestAbort() {
    abortIO_.store(true);

    if (pthread_t th = openThread_.load(std::memory_order_acquire)) {
        spEnsureIOInterruptSignalInstalled();
        pthread_kill(th, SIGUSR2);
    }

    std::shared_ptr<AuxIOCancelToken> pc, kc;
    std::shared_ptr<ScrubShared> sc;
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        pc = prefetchCancel_;
        kc = keepAliveCancel_;
        sc = scrub_;
    }
    spAuxCancel(pc);
    spAuxCancel(kc);
    if (sc) spScrubStopAndInterrupt(sc);
    auto io = ioSnapshot();
    if (!io) return;
    spEnsureIOInterruptSignalInstalled();
    io->abortRequested.store(true);

    { std::lock_guard<std::mutex> lk(io->jobMtx); }
    io->jobCv.notify_all();
    { std::lock_guard<std::mutex> lk(io->growthMtx); }
    io->growthCv.notify_all();
    if (!io->inRead.load()) return;
    pthread_kill(io->ioThread.load(std::memory_order_relaxed), SIGUSR2);

    std::weak_ptr<LocalFileIO> weak = io;
    std::thread([weak] {
        struct timespec ts { 0, 100 * 1000 * 1000 };
        nanosleep(&ts, nullptr);
        if (auto s = weak.lock()) {
            if (s->abortRequested.load() && s->inRead.load()) {
                pthread_kill(s->ioThread.load(std::memory_order_relaxed), SIGUSR2);
            }
        }
    }).detach();
}

Demuxer::IOStats Demuxer::ioStats() const {
    auto io = ioSnapshot();
    return io ? io->st : IOStats{};
}

int64_t Demuxer::fileSizeBytes() const {
    auto io = ioSnapshot();
    return io ? io->size : 0;
}

ReadSourceView Demuxer::captureReadSourceView() const {
    try {
    ReadSourceView view;
    auto io = ioSnapshot();
    if (!io || !io->localFilesystem || io->remote || !io->viewAttached.load(std::memory_order_acquire) ||
        io->abortRequested.load() || !spLocalSourceUnchanged(*io)) return view;
    spresil::PatchOverlay patches;
    uint64_t revision;
    {
        std::lock_guard<std::mutex> lk(io->viewMutex);
        patches = io->patches;
        view.size = std::max(io->size, io->virtualSize);
        revision = io->viewRevision.load(std::memory_order_relaxed);
    }
    view.physicalSize = io->size;
    view.current = [io, revision] {
        return io->viewAttached.load(std::memory_order_acquire) && !io->abortRequested.load() &&
            io->viewRevision.load(std::memory_order_acquire) == revision && spLocalSourceUnchanged(*io);
    };
    const int64_t logicalSize = view.size;
    view.read = [io, patches = std::move(patches), logicalSize](int64_t pos, uint8_t* buf, size_t want) -> int64_t {
        if (pos < 0 || (!buf && want)) return AVERROR(EINVAL);
        if (pos >= logicalSize || want == 0) return 0;
        want = (size_t)std::min<uint64_t>(want, (uint64_t)(logicalSize - pos));
        size_t got = 0;
        if (pos < io->size) {
            const size_t physicalWant = (size_t)std::min<uint64_t>(want, (uint64_t)(io->size - pos));
            const ssize_t n = ::pread(io->fd, buf, physicalWant, (off_t)pos);
            if (n < 0) return AVERROR(errno);
            got = (size_t)n;
            // A short physical read is not a virtual hole: never manufacture
            // bytes after an unexpected truncation or interrupted source read.
            if (got < physicalWant) return AVERROR(EIO);
        }
        if (got < want) std::memset(buf + got, 0, want - got);
        const int64_t end = pos + (int64_t)want;
        for (const auto& patch : patches) {
            if (patch.offset < 0 || patch.bytes.size() > (uint64_t)(INT64_MAX - patch.offset)) continue;
            const int64_t from = std::max(pos, patch.offset);
            const int64_t to = std::min(end, patch.offset + (int64_t)patch.bytes.size());
            if (to > from) std::memcpy(buf + (from - pos), patch.bytes.data() + (from - patch.offset), (size_t)(to - from));
        }
        return (int64_t)want;
    };
    if (!view.current()) return {};
    return view;
    } catch (const std::bad_alloc&) {
        return {};
    }
}

// Only used synchronously inside public open(): failed attachments may have
// detached, while this transaction still owns the original inode. The monotonic
// active flag invalidates callbacks before their Demuxer-owned cancel pointer
// can expire. Nothing in this view may be handed to an auxiliary worker.
ReadSourceView Demuxer::captureOpeningReadSourceView(const std::vector<spresil::Patch>& overlay) const {
    try {
        const auto io = openingSource_;
        if (!io || !io->localFilesystem || io->remote || !io->openingViewActive.load(std::memory_order_acquire) ||
            abortIO_.load() || !spLocalSourceUnchanged(*io)) return {};
        int64_t logicalSize = io->size;
        for (const auto& p : overlay) {
            if (p.offset < 0 || p.bytes.size() > static_cast<uint64_t>(INT64_MAX - p.offset)) return {};
            logicalSize = std::max(logicalSize, p.offset + static_cast<int64_t>(p.bytes.size()));
        }
        ReadSourceView view;
        view.physicalSize = io->size;
        view.size = logicalSize;
        view.current = [io, cancel = &abortIO_] {
            return io->openingViewActive.load(std::memory_order_acquire) && !cancel->load() && spLocalSourceUnchanged(*io);
        };
        view.read = [io, patches = overlay, logicalSize, current = view.current](int64_t pos, uint8_t* buf, size_t want) -> int64_t {
            if (!current()) return AVERROR_EXIT;
            if (pos < 0 || (!buf && want)) return AVERROR(EINVAL);
            if (pos >= logicalSize || want == 0) return current() ? 0 : AVERROR_EXIT;
            want = static_cast<size_t>(std::min<uint64_t>(want, static_cast<uint64_t>(logicalSize - pos)));
            size_t got = 0;
            if (pos < io->size) {
                const size_t physicalWant = static_cast<size_t>(std::min<uint64_t>(want, static_cast<uint64_t>(io->size - pos)));
                const ssize_t n = ::pread(io->fd, buf, physicalWant, static_cast<off_t>(pos));
                if (n < 0) return AVERROR(errno);
                got = static_cast<size_t>(n);
                if (got != physicalWant) return AVERROR(EIO);
            }
            if (got < want) std::memset(buf + got, 0, want - got);
            const int64_t end = pos + static_cast<int64_t>(want);
            for (const auto& p : patches) {
                const int64_t from = std::max(pos, p.offset);
                const int64_t to = std::min(end, p.offset + static_cast<int64_t>(p.bytes.size()));
                if (to > from) std::memcpy(buf + (from - pos), p.bytes.data() + (from - p.offset), static_cast<size_t>(to - from));
            }
            return current() ? static_cast<int64_t>(want) : AVERROR_EXIT;
        };
        return view.current() ? view : ReadSourceView{};
    } catch (const std::bad_alloc&) { return {}; }
}

void Demuxer::startVolumeKeepAliveIfNeeded() {
    if (!localIO_ || !remoteVolume_) return;
    if (!admitAuxWorker("keepalive")) return;
    AuxWorkerReservation rsv{auxWorkers_, true};
    if (keepAliveStarted_.exchange(true)) return;
    int fd = dup(localIO_->fd);
    if (fd < 0) return;
    const int64_t size = localIO_->size;
    auto cancel = std::make_shared<AuxIOCancelToken>();
    {

        std::lock_guard<std::mutex> lk(ioMtx_);
        if (abortIO_.load()) { ::close(fd); return; }
        keepAliveCancel_ = cancel;
    }
    int intervalSec = 45;
#if !SP_APP_STORE
    if (const char* e = getenv("SP_KEEPALIVE_SEC")) {
        int v = atoi(e);
        if (v >= 1 && v <= 600) intervalSec = v;
    }
#endif
    const bool debug = spDebug();
    rsv.handOff();
    std::thread([fd, size, cancel, intervalSec, debug, aux = auxWorkers_,
                 act = ioActivityUs_] {
        AuxWorkerScope scope(aux, /*adoptReservation=*/true);
        pthread_setname_np("sp.demux.keepalive");
        pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
        uint64_t lcg = 0x9E3779B97F4A7C15ULL ^ (uint64_t)fd;
        char buf[4096];
        if (debug) fprintf(stderr, "[DemuxIO] 保活启动（远端卷，每 %ds）\n", intervalSec);
        while (!cancel->cancel.load()) {

            {
                std::unique_lock<std::mutex> lk(cancel->waitMtx);
                cancel->waitCv.wait_for(lk, std::chrono::seconds(intervalSec),
                                        [&] { return cancel->cancel.load(); });
            }
            if (cancel->cancel.load()) break;

            if (act) {
                const int64_t last = act->load(std::memory_order_relaxed);
                if (last > 0 && spNowUs() - last < (int64_t)intervalSec * 1000000) {
                    continue;
                }
            }
            lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
            int64_t maxOff = size > (int64_t)sizeof(buf) ? size - (int64_t)sizeof(buf) : 0;
            int64_t off = maxOff > 0 ? (int64_t)(lcg % (uint64_t)maxOff) : 0;
            int64_t t0 = spNowUs();
            ssize_t n = spAuxPread(*cancel, fd, buf, sizeof(buf), off);
            if (debug) {
                fprintf(stderr, "[DemuxIO] 保活触达 off=%.1fGB %.0fms%s\n",
                        off / 1e9, (spNowUs() - t0) / 1000.0, n <= 0 ? "（读失败）" : "");
            }
        }
        ::close(fd);
    }).detach();
}

struct ScrubShared {
    std::mutex mtx;
    std::condition_variable cv;
    ScrubPrefetchRange ranges[2];
    int rangeCount = 0;
    int64_t timeTargetUs = -1;
    bool timeTargetForward = false;
    std::atomic<uint64_t> taskSeq{0};
    std::atomic<uint64_t> activeSeq{0};
    std::atomic<bool> stop{false};
    int fd = -1;
    std::string path;
    AVFormatContext* shadowCtx = nullptr;
    int shadowVideoStream = -1;

    std::shared_ptr<AuxIOCancelToken> ioTok[2] = {
        std::make_shared<AuxIOCancelToken>(), std::make_shared<AuxIOCancelToken>()
    };
};

static void spScrubStopAndInterrupt(const std::shared_ptr<ScrubShared>& st) {
    if (!st) return;
    {
        std::lock_guard<std::mutex> g(st->mtx);
        st->stop.store(true);
    }
    st->cv.notify_one();
    spAuxCancel(st->ioTok[0]);
    spAuxCancel(st->ioTok[1]);
}

static int spShadowInterruptCb(void* opaque) {
    auto* s = (ScrubShared*)opaque;
    return (s->stop.load() || s->taskSeq.load() != s->activeSeq.load()) ? 1 : 0;
}

static bool spShadowEnsureOpen(ScrubShared& sh) {
    if (sh.shadowCtx) return true;
    if (sh.path.empty()) return false;
    AVFormatContext* ctx = avformat_alloc_context();
    if (!ctx) return false;
    ctx->interrupt_callback = { spShadowInterruptCb, &sh };
    AVDictionary* opts = nullptr;
    av_dict_set(&opts, "scan_all_pmts", "0", 0);
    int64_t t0 = spNowUs();
    int ret = avformat_open_input(&ctx, sh.path.c_str(), nullptr, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        if (spDebug()) {
            fprintf(stderr, "[Shadow] open 失败 ret=%d\n", ret);
        }
        return false;
    }
    if (spDebug()) {
        fprintf(stderr, "[Shadow] open %.0fms\n", (spNowUs() - t0) / 1000.0);
    }

    int vs = -1;
    for (unsigned i = 0; i < ctx->nb_streams; ++i) {
        AVStream* s = ctx->streams[i];
        if (s->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && isRealVideoStream(s)) {
            vs = (int)i;
            break;
        }
    }
    if (vs < 0) { avformat_close_input(&ctx); return false; }
    sh.shadowCtx = ctx;
    sh.shadowVideoStream = vs;
    return true;
}

static void spShadowPrefetchAbsUs(ScrubShared& sh, int64_t absUs, uint64_t seq,
                                  bool forwardKeyframe) {
    if (!spShadowEnsureOpen(sh)) return;
    const bool debug = spDebug();
    int64_t t0 = spNowUs();
    AVStream* st = sh.shadowCtx->streams[sh.shadowVideoStream];
    int64_t ts = av_rescale_q(absUs, AV_TIME_BASE_Q, st->time_base);
    int sret = forwardKeyframe
        ? avformat_seek_file(sh.shadowCtx, sh.shadowVideoStream, ts, ts, INT64_MAX, 0)
        : avformat_seek_file(sh.shadowCtx, sh.shadowVideoStream, INT64_MIN, ts, ts, 0);
    if (sret < 0) {
        if (debug) fprintf(stderr, "[Shadow] seek(%.1fs) 失败 ret=%d\n", absUs / 1e6, sret);
        return;
    }
    AVPacket* pkt = av_packet_alloc();
    if (!pkt) return;

    int64_t bytes = 0;
    bool keySeen = false;
    for (int n = 0; n < 64 && bytes < 3 * 1024 * 1024; ++n) {
        if (sh.stop.load() || sh.taskSeq.load() != seq) break;
        if (av_read_frame(sh.shadowCtx, pkt) < 0) break;
        bytes += pkt->size;
        const bool isKey = pkt->stream_index == sh.shadowVideoStream &&
                           (pkt->flags & AV_PKT_FLAG_KEY) != 0;
        av_packet_unref(pkt);
        if (isKey && keySeen) break;
        if (isKey) keySeen = true;
        if (keySeen && n >= 16) break;
    }
    av_packet_free(&pkt);
    if (debug) {
        fprintf(stderr, "[Shadow] 预读 %.1fs: %.0fKB %.0fms key=%d\n",
                absUs / 1e6, bytes / 1024.0, (spNowUs() - t0) / 1000.0,
                (int)keySeen);
    }
}

void Demuxer::ensureScrubWorker() {
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        if (scrub_) return;
    }
    if (!localIO_) return;
    if (!admitAuxWorker("scrub")) return;
    AuxWorkerReservation rsv{auxWorkers_, true};
    int fd = dup(localIO_->fd);
    if (fd < 0) return;
    auto st = std::make_shared<ScrubShared>();
    st->fd = fd;
    st->path = path_;
    {

        std::lock_guard<std::mutex> lk(ioMtx_);
        if (abortIO_.load()) { ::close(fd); return; }
        scrub_ = st;
    }
    rsv.handOff();
    std::thread([st, aux = auxWorkers_] {
        AuxWorkerScope scope(aux, /*adoptReservation=*/true);
        pthread_setname_np("sp.demux.scrub-prefetch");
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);

        std::vector<uint8_t> scratchBuf[2];
        scratchBuf[0].resize(256 * 1024);
        scratchBuf[1].resize(256 * 1024);
        std::unique_lock<std::mutex> lk(st->mtx);
        while (true) {
            st->cv.wait(lk, [&] {
                return st->stop.load() || st->rangeCount > 0 ||
                       st->timeTargetUs >= 0;
            });
            if (st->stop.load()) break;

            const int64_t timeTarget = st->timeTargetUs;
            const bool timeTargetForward = st->timeTargetForward;
            st->timeTargetUs = -1;

            ScrubPrefetchRange jobs[4];
            int jobCount = 0;
            const int count = st->rangeCount;
            for (int i = 0; i < count && jobCount < 4; ++i) {
                const ScrubPrefetchRange& r = st->ranges[i];
                if (r.length > 512 * 1024) {
                    const int64_t half = r.length / 2;
                    jobs[jobCount++] = {r.offset, half};
                    jobs[jobCount++] = {r.offset + half, r.length - half};
                } else {
                    jobs[jobCount++] = r;
                }
            }
            const uint64_t seq = st->taskSeq.load();
            st->activeSeq.store(seq);
            st->rangeCount = 0;
            lk.unlock();

            if (timeTarget >= 0) {
                spShadowPrefetchAbsUs(*st, timeTarget, seq, timeTargetForward);
                lk.lock();
                continue;
            }

            std::atomic<int> nextJob{0};
            auto consume = [&](int tokSlot) {
                std::vector<uint8_t>& scratch = scratchBuf[tokSlot];
                for (int i = nextJob.fetch_add(1); i < jobCount;
                     i = nextJob.fetch_add(1)) {
                    for (int64_t p = jobs[i].offset;
                         p < jobs[i].offset + jobs[i].length;
                         p += (int64_t)scratch.size()) {
                        if (st->stop.load() || st->taskSeq.load() != seq) return;

                        if (spAuxPread(*st->ioTok[tokSlot], st->fd,
                                       scratch.data(), scratch.size(), p) <= 0)
                            break;
                    }
                }
            };
            if (jobCount > 1) {
                std::thread helper([&] {
                    AuxWorkerScope helperScope(aux);
                    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
                    consume(1);
                });
                consume(0);
                helper.join();
            } else {
                consume(0);
            }
            lk.lock();
        }
        lk.unlock();
        if (st->shadowCtx) avformat_close_input(&st->shadowCtx);
        ::close(st->fd);
    }).detach();
}

bool Demuxer::submitScrubTimeTarget(int64_t absUs, bool forwardKeyframe) {
    ensureScrubWorker();
    std::shared_ptr<ScrubShared> st;
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        st = scrub_;
    }
    if (!st) return false;
    {
        std::lock_guard<std::mutex> g(st->mtx);
        st->timeTargetUs = absUs;
        st->timeTargetForward = forwardKeyframe;
        st->rangeCount = 0;
        st->taskSeq++;
    }
    st->cv.notify_one();
    return true;
}

void Demuxer::preemptScrubTasks() {
    std::shared_ptr<ScrubShared> st;
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        st = scrub_;
    }
    if (!st) return;
    std::lock_guard<std::mutex> g(st->mtx);
    st->rangeCount = 0;
    st->timeTargetUs = -1;
    st->taskSeq++;

}

bool Demuxer::submitScrubRanges(const ScrubPrefetchRange* ranges, int count) {
    ensureScrubWorker();
    std::shared_ptr<ScrubShared> st;
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        st = scrub_;
    }
    if (!st) return false;
    {
        std::lock_guard<std::mutex> g(st->mtx);
        st->rangeCount = count > 2 ? 2 : count;
        for (int i = 0; i < st->rangeCount; ++i) st->ranges[i] = ranges[i];
        st->timeTargetUs = -1;
        st->taskSeq++;
    }
    st->cv.notify_one();
    return true;
}

void Demuxer::prefetchSequentialAhead(int64_t aheadBytes) {
    if (!localIO_ || !remoteVolume_ || aheadBytes <= 0) return;
#if !SP_APP_STORE

    static const bool relayOff = getenv("SP_IO_NORELAY") != nullptr;
    if (relayOff) return;
#endif
    const int64_t size = localIO_->size;

    const int64_t pos = localIO_->pos + 2 * 1024 * 1024;
    if (pos <= 0 || pos >= size) return;
    int64_t len = std::min(aheadBytes, size - pos);
    if (len < 1024 * 1024) return;

    ScrubPrefetchRange r[2] = {
        {pos, len / 2},
        {pos + len / 2, len - len / 2},
    };
    submitScrubRanges(r, 2);
}

int Demuxer::warmNextKeyframeClusters(int fromIdx, int64_t* lastUsInOut) {
    if (!localIO_ || !remoteVolume_ || !fmtCtx_ || videoStream_ < 0) return -1;
    AVStream* st = fmtCtx_->streams[videoStream_];
    const int nb = avformat_index_get_entries_count(st);
    if (nb < 16) return fromIdx;
    ScrubPrefetchRange r[2];
    int n = 0;
    int idx = fromIdx < 0 ? 0 : fromIdx;
    for (; idx < nb && n < 2; ++idx) {
        const AVIndexEntry* e = avformat_index_get_entry(st, idx);
        if (!e || e->pos <= 0) continue;
        const int64_t us = av_rescale_q(e->timestamp, st->time_base,
                                        AV_TIME_BASE_Q);
        if (*lastUsInOut >= 0 && us - *lastUsInOut < 15 * 1000000LL) continue;
        *lastUsInOut = us;
        r[n++] = {e->pos, 512 * 1024};
    }
    if (n > 0) submitScrubRanges(r, n);
    return idx >= nb ? -1 : idx;
}

bool Demuxer::prefetchSeekNeighborhood(int64_t predictedUs, int count,
                                       int64_t stepUs, bool forwardKeyframe) {
    if (!localIO_ || !fmtCtx_ || videoStream_ < 0) return false;
    AVStream* st = fmtCtx_->streams[videoStream_];
    const int nbEntries = avformat_index_get_entries_count(st);
    if (nbEntries <= 0) {

        if (predictedUs >= 0) {
            return submitScrubTimeTarget(predictedUs + timelineOriginUs_,
                                         forwardKeyframe);
        }
        return false;
    }
    ScrubPrefetchRange ranges[2];
    int rangeCount = 0;
    for (int k = 0; k < count && rangeCount < 2; ++k) {
        int64_t target = predictedUs + (int64_t)k * stepUs;
        if (target < 0) continue;
        int64_t absUs = target + timelineOriginUs_;
        int64_t ts = av_rescale_q(absUs, AV_TIME_BASE_Q, st->time_base);

        int idx = av_index_search_timestamp(
            st, ts, forwardKeyframe ? 0 : AVSEEK_FLAG_BACKWARD);
        if (idx < 0) {

            if (forwardKeyframe && k == 0) {
                return submitScrubTimeTarget(absUs, true);
            }
            continue;
        }
        const AVIndexEntry* e = avformat_index_get_entry(st, idx);
        if (!e || e->pos <= 0) continue;

        const int64_t entryUs = av_rescale_q(e->timestamp, st->time_base,
                                             AV_TIME_BASE_Q);
        if (absUs - entryUs > 15 * 1000000LL) {
            return submitScrubTimeTarget(predictedUs + timelineOriginUs_,
                                         forwardKeyframe);
        }

        int64_t length = 2 * 1024 * 1024;
        if (const AVIndexEntry* next = avformat_index_get_entry(st, idx + 1)) {
            if (next->pos > e->pos) length = next->pos - e->pos;
        }
        if (length > 2 * 1024 * 1024) length = 2 * 1024 * 1024;
        if (length < 128 * 1024) length = 128 * 1024;

        if (rangeCount > 0 && ranges[rangeCount - 1].offset == e->pos) continue;
        ranges[rangeCount++] = {e->pos, length};
    }
    return rangeCount > 0 && submitScrubRanges(ranges, rangeCount);
}

void Demuxer::prefetchIndexRegionAsync() {
    if (!localIO_) return;
    if (indexPrefetchBlocked_.load(std::memory_order_acquire)) return;
    const uint64_t deferSeqAtEntry =
        prefetchDeferSeq_.load(std::memory_order_acquire);
    const bool mkvLike = mkvLike_;

    const bool tsLike = tsLike_;
    const int64_t size = localIO_->size;
    if ((!mkvLike && !tsLike) || size < 32 * 1024 * 1024) {

        prefetchIssued_.store(true, std::memory_order_release);
        return;
    }
    if (!admitAuxWorker("index-prefetch")) return;
    AuxWorkerReservation rsv{auxWorkers_, true};

    int fd = dup(localIO_->fd);
    if (fd < 0) return;
    auto cancel = std::make_shared<AuxIOCancelToken>();
    auto completed = std::make_shared<std::atomic<bool>>(false);
    {

        std::lock_guard<std::mutex> lk(ioMtx_);
        if (abortIO_.load() ||
            indexPrefetchBlocked_.load(std::memory_order_acquire) ||
            prefetchDeferSeq_.load(std::memory_order_relaxed) != deferSeqAtEntry) {
            ::close(fd);
            return;
        }
        if (prefetchIssued_.exchange(true)) {
            ::close(fd);
            return;
        }
        prefetchCancel_ = cancel;
        prefetchCompleted_ = completed;
    }
    const bool debug = spDebug();
#if !SP_APP_STORE

    static const bool noCuesParse = getenv("SP_NO_CUESPARSE") != nullptr;
#else
    constexpr bool noCuesParse = false;
#endif
    rsv.handOff();
    std::thread([fd, size, cancel, completed, debug, tsLike,
                 noCuesParse = noCuesParse, aux = auxWorkers_] {
        AuxWorkerScope scope(aux, /*adoptReservation=*/true);
        pthread_setname_np("sp.demux.index-prefetch");

        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
        // QoS only influences CPU scheduling. The actual contention here is
        // disk/SMB I/O, so place this worker in Darwin's throttled disk tier as
        // well. This API has existed since macOS 10.5 (deployment target is
        // 14); failure merely leaves the existing utility-QoS behaviour.
        const int policyResult =
            setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE);
        if (policyResult != 0 && debug) {
            fprintf(stderr, "[DemuxIO] 索引预热 I/O 降优先级失败: %s\n",
                    strerror(errno));
        }
        int64_t t0 = spNowUs();
        constexpr int64_t kChunk = 1 * 1024 * 1024;
        constexpr int64_t kTail = 8 * 1024 * 1024;
        constexpr int64_t kHead = 1 * 1024 * 1024;
        std::vector<uint8_t> scratch((size_t)kChunk);
        uint64_t got = 0;
        auto warm = [&](int64_t off, int64_t len) {
            for (int64_t p = off; p < off + len && p < size; p += kChunk) {
                if (cancel->cancel.load()) return;
                ssize_t n = spAuxPread(*cancel, fd, scratch.data(), (size_t)kChunk, p);
                if (n <= 0) return;
                got += (uint64_t)n;
            }
        };

        int64_t cuesOff = -1, cuesLen = 0;
        if (!tsLike) {
            const size_t headWant = (size_t)(size < kHead ? size : kHead);
            ssize_t hn = spAuxPread(*cancel, fd, scratch.data(), headWant, 0);
            if (hn <= 0) { ::close(fd); return; }
            got += (uint64_t)hn;

            if (!noCuesParse) {
                SPMatroskaCuesScan scan =
                    spLocateMatroskaCues(scratch.data(), (size_t)hn, size);
                if (scan.status == SPMatroskaCuesScan::Status::NeedSeekHead &&
                    !cancel->cancel.load()) {

                    constexpr size_t kSeekHeadWant = 64 * 1024;
                    std::vector<uint8_t> sh(kSeekHeadWant);
                    ssize_t sn = spAuxPread(*cancel, fd, sh.data(), kSeekHeadWant,
                                            scan.seekHeadOffset);
                    if (sn > 0) {
                        got += (uint64_t)sn;
                        scan = spParseMatroskaSeekHead(sh.data(), (size_t)sn,
                                                       scan.segmentStart, size);
                    }
                }
                if (scan.status == SPMatroskaCuesScan::Status::Found &&
                    !cancel->cancel.load()) {

                    uint8_t hdr[32];
                    ssize_t cn = spAuxPread(*cancel, fd, hdr, sizeof(hdr), scan.cuesOffset);
                    if (cn > 0) {
                        got += (uint64_t)cn;
                        const int64_t len = spMatroskaCuesElementLength(hdr, (size_t)cn);

                        if (len > 0 && len <= kTail && scan.cuesOffset + len <= size) {
                            cuesOff = scan.cuesOffset;
                            cuesLen = len;
                        }
                    }
                }
            }
        }
        if (cuesOff >= 0) {
            warm(cuesOff, cuesLen);
        } else {
            const int64_t tail = tsLike ? kChunk : kTail;
            warm(size > tail ? size - tail : 0, tail);
        }

        if (!cancel->cancel.load()) {
            completed->store(true, std::memory_order_release);
        }
        if (debug) {
            if (cuesOff >= 0) {
                fprintf(stderr,
                        "[DemuxIO] 索引预热: 头1MB+Cues %lldKB@EOF-%lldKB 共 %.2fMB %.0fms%s\n",
                        (long long)((cuesLen + 1023) / 1024),
                        (long long)((size - cuesOff + 1023) / 1024), got / 1048576.0,
                        (spNowUs() - t0) / 1000.0, cancel->cancel.load() ? "（被中断）" : "");
            } else {
                fprintf(stderr, "[DemuxIO] 索引预热: 盲读尾%lldMB 共 %.2fMB %.0fms%s\n",
                        (long long)((tsLike ? kChunk : kTail) / 1048576), got / 1048576.0,
                        (spNowUs() - t0) / 1000.0, cancel->cancel.load() ? "（被中断）" : "");
            }
        }
        ::close(fd);
    }).detach();
}

void Demuxer::preemptIndexPrefetch() {
    // Publish first, then take the pointer lock. This closes both orderings:
    // ① prefetch has not published yet -> its lock-held recheck refuses spawn;
    // ② token is already published -> this snapshot cancels/interrupts pread.
    // Only the first seek in a session pays the pointer-lock/cancel work.
    if (indexPrefetchBlocked_.exchange(true, std::memory_order_acq_rel)) return;
    std::shared_ptr<AuxIOCancelToken> cancel;
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        cancel = prefetchCancel_;
    }
    spAuxCancel(cancel);
}

// Hover/preview I/O outranks the Cues warmer *now*, but unlike a real seek it
// loads nothing into the main context, so the warmer must stay available:
// permanently retiring it here meant one early mouse sweep across the timeline
// condemned the first real seek to the cold tail-of-file index read the warmer
// exists to eliminate. Cancel any in-flight read and re-open the one-shot
// gate; the demux admission loop (with its hover cooldown) restarts it later.
void Demuxer::deferIndexPrefetch() {
    std::shared_ptr<AuxIOCancelToken> cancel;
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        prefetchDeferSeq_.fetch_add(1, std::memory_order_acq_rel);

        if (prefetchCompleted_ &&
            prefetchCompleted_->load(std::memory_order_acquire)) {
            return;
        }
        cancel = std::move(prefetchCancel_);
        prefetchIssued_.store(false, std::memory_order_release);
    }
    spAuxCancel(cancel);
}

Demuxer::Demuxer() = default;
Demuxer::~Demuxer() { close(); }

static bool isRealVideoStream(const AVStream* s) {
    return (s->disposition & AV_DISPOSITION_ATTACHED_PIC) == 0;
}

static bool isTextSubtitleStream(const AVStream* s) {
    switch (s->codecpar->codec_id) {
        case AV_CODEC_ID_ASS:
        case AV_CODEC_ID_SSA:
        case AV_CODEC_ID_SUBRIP:
        case AV_CODEC_ID_TEXT:
        case AV_CODEC_ID_MOV_TEXT:
        case AV_CODEC_ID_WEBVTT:
            return true;
        default:
            return false;
    }
}

void Demuxer::close() {
    if (openingSource_) openingSource_->openingViewActive.store(false, std::memory_order_release);
    mkvContentCancelJob();

    if (cttsTrial_) cttsTrial_->abort.store(true);
    cttsTrial_.reset();

    std::shared_ptr<AuxIOCancelToken> pc, kc;
    std::shared_ptr<ScrubShared> sc;
    {
        std::lock_guard<std::mutex> lk(ioMtx_);
        pc = std::move(prefetchCancel_);
        prefetchCompleted_.reset();
        kc = std::move(keepAliveCancel_);
        sc = std::move(scrub_);
    }
    spAuxCancel(pc);
    prefetchIssued_.store(false);
    spAuxCancel(kc);
    keepAliveStarted_.store(false);
    if (sc) {

        spScrubStopAndInterrupt(sc);
    }
    if (fmtCtx_) {
        if (localIO_ && spDebug()) {
            const IOStats& s = localIO_->st;
            fprintf(stderr,
                    "[DemuxIO] 会话累计: reads=%llu bytes=%.1fMB io=%.0fms jumps=%llu\n",
                    (unsigned long long)s.reads, s.readBytes / 1048576.0, s.ioUs / 1000.0,
                    (unsigned long long)s.jumps);

            planLog("[DemuxPlan] 会话累计 规划器 reads=%llu %.1fKB io=%.1fms｜车道 reads=%llu %.1fKB io=%.1fms",
                    (unsigned long long)planIO_.reads.load(std::memory_order_relaxed), planIO_.bytes.load(std::memory_order_relaxed) / 1024.0,
                    planIO_.us.load(std::memory_order_relaxed) / 1000.0, (unsigned long long)laneIO_.reads.load(std::memory_order_relaxed),
                    laneIO_.bytes.load(std::memory_order_relaxed) / 1024.0, laneIO_.us.load(std::memory_order_relaxed) / 1000.0);
        }
        avformat_close_input(&fmtCtx_);
    }
    dropSeekPushback();
    for (AVFormatContext* c : retiredCtx_) { AVFormatContext* t = c; avformat_close_input(&t); }
    retiredCtx_.clear();
    detachLocalIO();
    tsLaneWin_ = TsLaneWindow{};
    std::vector<uint8_t>().swap(psLaneBlock_);
    fmtCtx_ = nullptr;
    streams_.clear();
    videoStream_ = -1;
    audioStream_ = -1;
    subtitleStream_ = -1;
    timelineOriginUs_ = 0;
    originOffsetCache_.clear();
    eof_ = false;
    durationUs_ = 0;
    container_.clear();
    streamInfoAttempted_ = false; streamInfoResult_ = 0;
    tsMpegTs_ = false;
    tsLike_ = false;
    mkvLike_ = false;
    discardEligible_ = false;
    tsGopUs_ = 0;
    tsLastKeyPtsUs_ = INT64_MIN;
    tsRapScanRetired_ = false;

    publishAltVideoCandidates();
    publishTsPcrIdentities(true);
}

static int spInterruptCb(void* opaque) {
    return ((std::atomic<bool>*)opaque)->load() ? 1 : 0;
}

// Temporary PGS dimensions during stream analysis (RAII).
// Matroska does not carry PGS dimensions, and the first subtitle packet may arrive
// well after playback begins. Treating every unsized PGS track as incomplete can
// make find_stream_info read all the way to probesize after other tracks are ready.
// Assign 1x1 placeholders before analysis and clear only placeholders that remain
// unchanged afterward; dimensions decoded from real subtitle packets are retained.
// Video dimensions are not a suitable placeholder because subtitle resolution can
// differ from the video. The placeholder never becomes a published stream size.
// Keep the normal probesize: reducing it can truncate video/audio analysis and
// lose channel layouts, codec properties, timestamps, or decoder reorder depth.
// This changes only PGS readiness; every other stream retains its normal criteria.
// Limit the optimization to Matroska/WebM. Headerless MPEG-TS has different stream
// discovery timing and must retain its existing analysis behavior.
// SP_NO_PGSPROBE disables the optimization for diagnostics outside AppStore builds.
namespace {
struct PgsAnalyzePlaceholder {
    AVFormatContext* ctx = nullptr;
    std::vector<unsigned> filled;

    explicit PgsAnalyzePlaceholder(AVFormatContext* c) {
#if !SP_APP_STORE

        static const bool disabled = getenv("SP_NO_PGSPROBE") != nullptr;
#else
        constexpr bool disabled = false;
#endif
        if (disabled || !c || !c->iformat || !c->iformat->name) return;
        const std::string name = c->iformat->name;
        if (name.find("matroska") == std::string::npos &&
            name.find("webm") == std::string::npos) {
            return;
        }
        ctx = c;
        for (unsigned i = 0; i < ctx->nb_streams; ++i) {
            AVCodecParameters* par = ctx->streams[i]->codecpar;
            if (!par) continue;
            if (par->codec_type == AVMEDIA_TYPE_SUBTITLE &&
                par->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE &&
                par->width == 0 && par->height == 0) {
                par->width = 1;
                par->height = 1;
                filled.push_back(i);
            }
        }
    }

    ~PgsAnalyzePlaceholder() {
        if (!ctx) return;
        for (unsigned i : filled) {
            if (i >= ctx->nb_streams) continue;
            AVCodecParameters* par = ctx->streams[i]->codecpar;

            if (par && par->width == 1 && par->height == 1) {
                par->width = 0;
                par->height = 0;
            }
        }
    }

    size_t count() const { return filled.size(); }

    PgsAnalyzePlaceholder(const PgsAnalyzePlaceholder&) = delete;
    PgsAnalyzePlaceholder& operator=(const PgsAnalyzePlaceholder&) = delete;
};
} // namespace

// FFmpeg releases its per-stream analysis state on return, including failure.
// Analysis therefore belongs to the current context and is never consumed as
// a one-shot hint: reopen/rollback must carry this result with that context.
int Demuxer::analyzeInputOnce(size_t* pgsFilled) {
    if (pgsFilled) *pgsFilled = 0;
    if (!fmtCtx_) return AVERROR(EINVAL);
    if (abortIO_.load()) return AVERROR_EXIT;
    if (streamInfoAttempted_) return streamInfoResult_;
    PgsAnalyzePlaceholder placeholder(fmtCtx_);
    if (pgsFilled) *pgsFilled = placeholder.count();
    streamInfoAttempted_ = true;
    streamInfoResult_ = avformat_find_stream_info(fmtCtx_, nullptr);
    if (abortIO_.load()) streamInfoResult_ = AVERROR_EXIT;
    return streamInfoResult_;
}

int Demuxer::open(const std::string& path, bool analyze) {
    close();
    abortIO_.store(false);
    openThread_.store(pthread_self(), std::memory_order_release);
    struct ClearOpenThread {
        std::atomic<pthread_t>& t;
        std::shared_ptr<LocalFileIO>& source;
        ~ClearOpenThread() {
            if (source) source->openingViewActive.store(false, std::memory_order_release);
            source.reset(); t.store(nullptr, std::memory_order_release);
        }
    } clearOpenThread{openThread_, openingSource_};
    indexPrefetchBlocked_.store(false, std::memory_order_release);
    path_ = path;
    openDiag_ = spresil::OpenDiagnosis{};
    openZeroHeadRetry_ = false;
    for (PlanIOCounters* c : {&planIO_, &laneIO_}) {
        c->reads.store(0, std::memory_order_relaxed);
        c->bytes.store(0, std::memory_order_relaxed);
        c->us.store(0, std::memory_order_relaxed);
    }
    planNote_.clear();
    openPlanSummary_.clear();

#if SP_APP_STORE
    resilientRecoveryEnabled_ = true;
#else
    static const bool recoveryOff = [] { const char* e = getenv("SP_RESILIENT"); return e && strcmp(e, "0") == 0; }();
    resilientRecoveryEnabled_ = !recoveryOff;
#endif
    analyzed_ = analyze;
    resetRecoverySessionState();

    int ret = openInputOnce(path, 0, 0);
    if (ret < 0) {

        if (ret != AVERROR_EXIT && !abortIO_.load()) {
            const int firstErr = ret;
            diagnoseOpenFailure(path);
            if (openFailureHint() == spresil::OpenFailureHint::LeadingZeros && !abortIO_.load()) {
                const int64_t skip = openDiag_.leadingZeroBytes;
                const int64_t probe = spresil::zeroHeadProbeSize(skip);
                const int64_t t1 = spNowUs();
                const int r2 = openInputOnce(path, skip, probe);
                if (spDebug()) {
                    fprintf(stderr, "[Demux] 零头重试 skip=%lld probe=%lld → %d (%.1fms)\n",
                            (long long)skip, (long long)probe, r2, (spNowUs() - t1) / 1000.0);
                }
                if (r2 == 0) {
                    openZeroHeadRetry_ = true;
                    ret = 0;
                }
            }

            if (ret < 0 && resilientRecoveryEnabled_ && !abortIO_.load()) {
                std::vector<spresil::Patch> acc;
                std::string kinds, details;
                for (int step = 0; step < 3 && ret < 0 && !abortIO_.load(); ++step) {
                    spresil::RecoveryPlan plan = planOpenRecovery(path, acc);
                    if (plan.empty()) break;
                    bool progress = false;
                    for (const spresil::Patch& np : plan.patches) {
                        bool dup = false;
                        for (const spresil::Patch& op : acc) if (op.offset == np.offset && op.bytes == np.bytes) dup = true;
                        if (!dup) { acc.push_back(np); progress = true; }
                    }
                    if (!progress) break;
                    kinds += (kinds.empty() ? "" : "+") + plan.kind;
                    details += (details.empty() ? "" : " → ") + plan.detail;
                    pendingPatches_ = acc;
                    const int64_t t1 = spNowUs();
                    const int r3 = openInputOnce(path, 0, 0);
                    if (spDebug()) {
                        fprintf(stderr, "[Demux] 候选恢复重试#%d %s（累计 %zu 补丁）→ %d (%.1fms) %s\n", step + 1, plan.kind.c_str(),
                                acc.size(), r3, (spNowUs() - t1) / 1000.0, plan.detail.c_str());
                    }
                    if (r3 == 0) {
                        openRecovery_ = kinds;
                        pushRecoveryEvent("打开阶段候选恢复 " + kinds + "：" + details, -1, -1);
                        ret = 0;
                    }
                }
                if (ret < 0) pendingPatches_.clear();
            }
            if (ret < 0) {
                close();
                return firstErr;
            }
        } else {
            close();
            return ret;
        }
    }

    if (resilientRecoveryEnabled_ && fmtCtx_->iformat && fmtCtx_->iformat->name &&
        spresil::isRawFormatName(fmtCtx_->iformat->name) && !abortIO_.load()) {
        tryFixedHeaderReopenAfterMisdetect(path);

        if (!fmtCtx_) { close(); return AVERROR(EIO); }
    }

    if (analyze) {

        ret = analyzeInputOnce();
        if (ret < 0) {
            close();
            return ret;
        }
    }

    container_ = fmtCtx_->iformat->name ? fmtCtx_->iformat->name : "";

    sampleEofRetryEligible_ = container_.find("mov") != std::string::npos ||
                              container_.find("mp4") != std::string::npos;
    sampleEofRetriesTotal_ = 0;
    sampleEofSkips_ = 0;
    sampleEofSkipsLogged_ = 0;
    demuxDamageEvidence_.store(false, std::memory_order_relaxed);
    mkvExtentChecked_ = false;
    mp3DeclChecked_ = false;
    zeroTailCheckedAnchor_ = -1;
    zeroTailChecks_ = 0;
    contentEndPos_ = -1;

    tsMpegTs_ = container_.find("mpegts") != std::string::npos;
    tsLike_ = tsMpegTs_ || container_ == "mpeg";
    mkvLike_ = container_.find("matroska") != std::string::npos || container_.find("webm") != std::string::npos;
    {
        const bool oggC = container_ == "ogg";
        gapRecoveryEligible_ = mkvLike_ || oggC;

        gapThresholdBytes_ = mkvLike_ ? 256 * 1024 : 27;
        recoveryRegions_.clear();

        gapTrackDecls_.clear();
        gapTrackDeclReads_ = 0;
        gapLegalLogged_ = 0;
    }
    discardEligible_ = tsMpegTs_ || mkvLike_;
    // Diagnostic override: disabling RAP scanning retains exponential backoff.
#if SP_APP_STORE
    constexpr bool rapScanOff = false;
#else
    static const bool rapScanOff = getenv("SP_TS_NORAPSCAN") != nullptr;
#endif
    tsRapScanDisabled_ = rapScanOff;
    rebuildStreamTable();
    resetContainerRecoveryState();
    flvLike_ = container_ == "flv" || container_ == "live_flv";
    aviLike_ = container_ == "avi";
    openStreamCount_ = fmtCtx_->nb_streams;
    psLike_ = container_ == "mpeg";

    int64_t planWallUs = 0;
    auto timed = [&](const char* name, const auto& fn) {
        if (!spDebug()) { fn(); return; }
        const PlanMark m = planMark();
        fn();
        planWallUs += spNowUs() - m.t0;
        if (planIO_.reads.load(std::memory_order_relaxed) != m.reads || !planNote_.empty())
            openPlanSummary_ += "｜" + planItem(m, name);
    };
    if (sampleEofRetryEligible_ && resilientRecoveryEnabled_) {

        timed("mp4-moof", [&] {
            withFileReader(path, [&](const spresil::Reader& read, int64_t size) {
                int64_t pos = 0;
                for (int hops = 0; hops < 8 && pos + 8 <= size; ++hops) {
                    spresil::Box b;
                    if (!spresil::readBox(read, pos, size, b)) break;
                    if (b.is("moof")) { fmp4Like_ = true; break; }
                    if (b.is("mdat") || b.sizeFieldZero || b.largeSizeZero || b.end() > size) break;
                    pos = b.end();
                }
            });
        });
    }
    rawAudioLike_ = container_ == "ac3" || container_ == "eac3" || container_ == "aac";
    rawAudioAdts_ = container_ == "aac";
    if (analyze && tsMpegTs_) timed("ts-pmt", [&] { tryTsPmtReopen(true); });
    if (analyze && tsMpegTs_) timed("ts-hdr", [&] { tryTsTransportReopen(true); });
    if (tsMpegTs_ && !analyze && resilientRecoveryEnabled_ && !abortIO_.load()) {

        timed("ts-psi", [&] { ensureTsRecoveryPids(); });
        timed("ts-hdr", [&] { tryTsTransportReopen(false); });
    }
    if (container_ == "avi" && resilientRecoveryEnabled_ && !abortIO_.load()) timed("avi-idx1", [&] { tryAviChunkSizeReopen(); });
    if (sampleEofRetryEligible_ && !fmp4Like_ && resilientRecoveryEnabled_ && !abortIO_.load()) timed("mp4-meta", [&] { tryMp4MetadataReopen(); });
    if (sampleEofRetryEligible_ && !fmp4Like_ && resilientRecoveryEnabled_ && !abortIO_.load()) {

        timed("mp4-ctts", [&] { tryMp4CttsRecovery(); });
    }

    asfLike_ = container_ == "asf";
    if (resilientRecoveryEnabled_ && !abortIO_.load()) {
        if (mkvLike_) timed("mkv-crc", [&] { tryMkvHeaderReopen(); });
        else if (asfLike_) timed("asf-geom", [&] { tryAsfGeometryReopen(); });
        else if (container_ == "rm") timed("rm-map", [&] { tryRmStreamMapReopen(); });
    }

    if (resilientRecoveryEnabled_ && !abortIO_.load()) {
        if (rawAudioLike_) timed("raw-audio", [&] { tryRawAudioFramesReopen(); });
        else if (flvLike_) timed("flv-avc", [&] { tryFlvAvcSubtypeReopen(); });
        else if (tsMpegTs_) timed("ts-adts", [&] { tryTsAdtsReopen(); });
        else if (mkvLike_) timed("mkv-flac", [&] { tryMkvFlacLacingReopen(); });
    }

    if (tsMpegTs_ && resilientRecoveryEnabled_ && !abortIO_.load()) timed("ts-pes", [&] { tryTsPesHeaderReopen(); });

    if (videoStream_ < 0 && audioStream_ < 0 && resilientRecoveryEnabled_ && !abortIO_.load() &&
        (container_.find("mov") != std::string::npos || container_.find("mp4") != std::string::npos)) {
        timed("mp4-noplay", [&] { tryNoPlayableTrackReopen(path, analyze); });
    }
    if (spDebug() && !openPlanSummary_.empty()) {
        planLog("[DemuxPlan] 打开期 %s 合计 reads=%llu %.1fKB io=%.2fms %.2fms%s", container_.c_str(),
                (unsigned long long)planIO_.reads.load(std::memory_order_relaxed), planIO_.bytes.load(std::memory_order_relaxed) / 1024.0,
                planIO_.us.load(std::memory_order_relaxed) / 1000.0, planWallUs / 1000.0, openPlanSummary_.c_str());
    }
    if (abortIO_.load()) { close(); return AVERROR_EXIT; }

    if (!fmtCtx_) { close(); return AVERROR(EIO); }
    return 0;
}

void Demuxer::releaseRetiredContexts() {
    retainRetiredCtx_ = false;
    for (AVFormatContext* c : retiredCtx_) { AVFormatContext* t = c; avformat_close_input(&t); }
    std::vector<AVFormatContext*>().swap(retiredCtx_);
}

void Demuxer::resetRecoverySessionState() {
    dropSeekPushback();
    growthResyncPending_ = false;
    pendingPatches_.clear();
    neutralProbeName_ = false;
    neutralProbeUrl_.clear();
    streamInfoAttempted_ = false; streamInfoResult_ = 0;
    pendingFlvIgnorePrevTag_ = false;
    openRecovery_.clear();
    pendingDurationUs_ = -1;
    resumeDiscardAbsUs_ = -1;
    lastRecoveryVideoPacket_ = {}; resumeVideoAnchor_ = {};
    resumeFrontierUs_.clear();
    resumeFrontierPos_.clear();
    lastGoodPos_ = 0;
    lastGoodAbsUs_ = -1;
    lastGoodAbsUsPerStream_.clear();
    lastGoodPosPerStream_.clear();
    earlyEofRecoveryPos_ = -1;
    readErrorRecoveries_ = 0;
    retainRetiredCtx_ = true;
    annexBTailRetryUsed_ = false;
    annexBTailSourceInvalid_ = false;
    discardApplied_ = false;
    {
        std::lock_guard<std::mutex> lk(recoveryMtx_);
        recoveryEvents_.clear();
        recoveryEventsPending_.store(false);
    }
}

void Demuxer::resetContainerRecoveryState() {
    aviChunkSizeTried_ = false;
    aviIdxCursor_.clear();
    flvExplosionTried_ = false;
    psLastCheckedPos_ = -1;
    psPesAttempts_ = 0;
    fmp4Like_ = false;
    fmp4LayoutReady_ = false;
    fmp4BrokenRun_ = 0;
    fmp4RealignAttempts_ = 0;
    mp4BrokenHistory_ = 0;
    mp4TableAttempts_ = 0;
    mp4WindowAttempts_ = mp4WindowReopens_ = 0;
    mp4WindowRegions_.clear();
    tsHdrPids_ = spresil::TsVideoPidMap{};
    tsHdrPidsScanned_ = false;
    tsPsiLocal_ = false; tsPsiMap_ = {}; tsPsiBudget_ = {};
    tsPsiProvisional_ = false;
    tsHdrOpenWindowClean_ = false; tsHdrOpenPatchCount_ = 0; tsHdrOpenViewRev_ = 0;
    tsHdrState_ = spresil::TsHeaderScanState{};
    tsHdrScannedUntil_ = 0;
    tsHdrAttempts_ = 0;
    mp4RapVerifiedPos_.clear();
    mp4RapFixes_ = 0;
    rawAudioScannedUntil_ = 0;
    rawAudioAttempts_ = 0;
    rawAudioDone_ = false;
    tsAdtsPid_ = -1;
    tsAdtsChecked_ = false;
    tsAdtsState_ = spresil::TsAdtsScanState{};
    tsAdtsScannedUntil_ = 0;
    tsAdtsAttempts_ = 0;
    mkvFlacTracks_.clear();
    mkvFlacTracksScanned_ = false;
    mkvFirstClusterPos_ = -1;
    mkvFlacLaceAttempts_ = 0;
    mkvFlacLaceRegions_.clear();
    mkvContentCancelJob();
    mkvContent_ = MkvContentState{};
    audioErrPosMailbox_.store(-1, std::memory_order_relaxed);
    videoIsolated_ = false;
    videoIsolationTried_ = false;
    flvAvcState_ = spresil::FlvAvcScanState{};
    flvAvcAttempts_ = 0;
    fmp4Cfgs_.clear();
    fmp4Anchors_ = spresil::Mp4FragAnchors{};
    fmp4CfgLoaded_ = false;
    fmp4FragCursor_ = 0;
    fmp4FragCheckedUntil_ = 0;
    fmp4CheckedMoofs_.clear();
    fmp4FragAttempts_ = 0;
    asfLastCheckedPacketPos_ = -1;
    asfLastDeliveredPos_ = -1;
    asfCountScannedUntil_ = -1;
    asfCountAttempts_ = 0;
    asfObjState_ = spresil::AsfObjectScanState{};
    asfObjScannedUntil_ = -1;
    asfObjAttempts_ = 0;
    tsPesState_ = spresil::TsPesScanState{};
    tsPesScannedUntil_ = 0;
    tsPesAttempts_ = 0;
    tsLaneWin_ = TsLaneWindow{};
    std::vector<uint8_t>().swap(psLaneBlock_);
    tsScanHoldUntilUs_ = spNowUs() + 300000;
    mpeg2SeqChecked_ = false;
    mpeg2VideoPktsSeen_ = 0;
    h264PpsChecked_ = false;
}

int Demuxer::openInputOnce(const std::string& path, int64_t skipInitialBytes, int64_t formatProbeSize,
                           const std::shared_ptr<LocalFileIO>& source,
                           std::unique_ptr<sptrial::SourceInput>* sourceBudget, int64_t deadlineUs) {
    streamInfoAttempted_ = false; streamInfoResult_ = 0;
    AVDictionary* opts = nullptr;

    av_dict_set(&opts, "scan_all_pmts", "0", 0);
    if (skipInitialBytes > 0) {
        av_dict_set_int(&opts, "skip_initial_bytes", skipInitialBytes, 0);
        av_dict_set_int(&opts, "formatprobesize", formatProbeSize, 0);
    }

    if (pendingFlvIgnorePrevTag_) av_dict_set(&opts, "flv_ignore_prevtag", "1", 0);
    int64_t t0 = spNowUs();

    fmtCtx_ = avformat_alloc_context();
    if (!fmtCtx_) { av_dict_free(&opts); return AVERROR(ENOMEM); }
    fmtCtx_->interrupt_callback = { spInterruptCb, &abortIO_ };
    const auto retainedSource = source ? source : openingSource_;
    const bool attached = attachLocalIO(path, retainedSource);
    if (attached && !openingSource_ && openThread_.load(std::memory_order_acquire)) {
        openingSource_ = localIO_;
        openingSource_->openingViewActive.store(true, std::memory_order_release);
    }
    if (retainedSource && !attached) {
        // A recovery candidate must never fall back to reopening a replaced path.
        av_dict_free(&opts);
        closeInputOnly();
        return AVERROR(EIO);
    }
    if (abortIO_.load()) {

        av_dict_free(&opts);
        closeInputOnly();
        return AVERROR_EXIT;
    }
    if (sourceBudget) {
        auto view = captureReadSourceView();
        if (!view) { av_dict_free(&opts); closeInputOnly(); return AVERROR(ESTALE); }
        sptrial::InterruptCtx interrupt;
        interrupt.cancel = &abortIO_;
        interrupt.deadlineUs = deadlineUs;
        try {
            *sourceBudget = std::make_unique<sptrial::SourceInput>(std::move(view), std::move(interrupt), 32ll * 1024 * 1024);
        } catch (const std::bad_alloc&) { av_dict_free(&opts); closeInputOnly(); return AVERROR(ENOMEM); }
        // Fault-only callback replacement leaves normal playback AVIO without
        // any budget checks. The caller restores normal callbacks at commit.
        avio_->opaque = sourceBudget->get();
        avio_->read_packet = [](void* p, uint8_t* b, int n) { return static_cast<sptrial::SourceInput*>(p)->read(b, n); };
        avio_->seek = [](void* p, int64_t off, int whence) { return static_cast<sptrial::SourceInput*>(p)->seek(off, whence); };
        fmtCtx_->interrupt_callback = {[](void* p) { return static_cast<sptrial::SourceInput*>(p)->usable() ? 0 : 1; }, sourceBudget->get()};
    }

    if (localIO_ && localIO_->size > 0) {
        av_dict_set_int(&opts, "resync_size",
                        std::min<int64_t>(localIO_->size, 64ll * 1024 * 1024), 0);
    }

    const std::string& probeUrl = (neutralProbeName_ && localIO_) ? neutralProbeUrl_ : path;
    int ret = avformat_open_input(&fmtCtx_, probeUrl.c_str(), nullptr, &opts);
    av_dict_free(&opts);
    if (spDebug()) {
        fprintf(stderr, "[Demux] open_input=%.1fms (format=%s score=%d%s)\n", (spNowUs() - t0) / 1000.0,
                fmtCtx_ && fmtCtx_->iformat ? fmtCtx_->iformat->name : "?", fmtCtx_ ? fmtCtx_->probe_score : -1,
                neutralProbeName_ ? " 中性名" : "");
        if (localIO_) {
            const IOStats& s = localIO_->st;
            fprintf(stderr, "[DemuxIO] open: reads=%llu bytes=%.1fKB io=%.1fms jumps=%llu\n",
                    (unsigned long long)s.reads, s.readBytes / 1024.0, s.ioUs / 1000.0,
                    (unsigned long long)s.jumps);
        }
    }
    if (ret < 0) {
        closeInputOnly();
        return ret;
    }
    // OpenIssued, weak extension matches only. Reprobe the existing AVIO without
    // destroying its demuxer or reopening the path: a downloader may rename it.
    if (!neutralProbeName_ && resilientRecoveryEnabled_ && localIO_ && fmtCtx_->iformat && fmtCtx_->iformat->extensions &&
        fmtCtx_->probe_score < AVPROBE_SCORE_RETRY && av_match_ext(path.c_str(), fmtCtx_->iformat->extensions) &&
        !abortIO_.load()) {
        const int r2 = recheckWeakProbe(path, skipInitialBytes, formatProbeSize);
        if (r2 < 0) closeInputOnly();
        return r2;
    }
    return 0;
}

int Demuxer::recheckWeakProbe(const std::string& path, int64_t skipInitialBytes, int64_t formatProbeSize) {
    AVIOContext* const pb = fmtCtx_->pb;
    const int64_t resume = avio_tell(pb);
    if (resume < 0) return 0; // Unable to restore the cursor: do not disturb this candidate.
    const int savedError = pb->error, savedEof = pb->eof_reached;
    const int savedSeekable = pb->seekable, savedDirect = pb->direct;
    auto restore = [&]() -> int64_t {
        pb->seekable = savedSeekable;
        pb->direct = savedDirect;
        const int64_t position = avio_seek(pb, resume, SEEK_SET);
        if (position >= 0) { pb->error = savedError; pb->eof_reached = savedEof; }
        return position;
    };
    const size_t slash = path.rfind('/');
    const std::string neutralUrl = (slash == std::string::npos ? std::string() : path.substr(0, slash + 1)) + "sp-neutral-probe";
    const AVInputFormat* neutral = nullptr;
    // Match the original format-probe window, including the existing zero-head retry.
    const unsigned int limit = (unsigned int)std::clamp<int64_t>(formatProbeSize > 0 ? formatProbeSize : fmtCtx_->format_probesize,
                                                               2048, 32ll * 1024 * 1024);
    int64_t seek = avio_seek(pb, 0, SEEK_SET);
    if (seek < 0) return (int)seek;
    const int score = av_probe_input_buffer2(pb, &neutral, neutralUrl.c_str(), nullptr, 0, limit);
    if (abortIO_.load() || score == AVERROR_EXIT) return AVERROR_EXIT;
    seek = restore();
    if (seek < 0) return (int)seek;
    if (spDebug()) fprintf(stderr, "[Demux] weak probe format=%s score=%d content=%s score=%d\n",
                           fmtCtx_->iformat->name, fmtCtx_->probe_score, neutral ? neutral->name : "-", score);
    if (score >= 0 && neutral == fmtCtx_->iformat) return 0;

    if (score >= 0 && neutral) {
        // One alternative, using the same descriptor, overlay and virtual size.
        // Both contexts use this AVIO sequentially; keep the old header state until
        // the alternative has opened successfully, and restore its cursor on failure.
        AVFormatContext* candidate = avformat_alloc_context();
        if (!candidate) return 0;
        candidate->pb = pb;
        candidate->flags |= AVFMT_FLAG_CUSTOM_IO;
        candidate->interrupt_callback = fmtCtx_->interrupt_callback;
        seek = avio_seek(pb, 0, SEEK_SET);
        if (seek < 0) { avformat_free_context(candidate); return (int)seek; }
        AVDictionary* opts = nullptr;
        av_dict_set(&opts, "scan_all_pmts", "0", 0);
        if (skipInitialBytes > 0) av_dict_set_int(&opts, "skip_initial_bytes", skipInitialBytes, 0);
        if (pendingFlvIgnorePrevTag_) av_dict_set(&opts, "flv_ignore_prevtag", "1", 0);
        if (localIO_->size > 0) av_dict_set_int(&opts, "resync_size", std::min<int64_t>(localIO_->size, 64ll * 1024 * 1024), 0);
        const int ret = avformat_open_input(&candidate, neutralUrl.c_str(), neutral, &opts);
        av_dict_free(&opts);
        if (ret == 0 && !abortIO_.load()) {
            const std::string oldName = fmtCtx_->iformat->name;
            fmtCtx_->pb = nullptr;
            avformat_close_input(&fmtCtx_);
            fmtCtx_ = candidate;
            streamInfoAttempted_ = false; streamInfoResult_ = 0;
            fmtCtx_->probe_score = score; // Forced demuxer selection otherwise reports no probe evidence.
            neutralProbeName_ = true;
            neutralProbeUrl_ = neutralUrl;
            pushRecoveryEvent("弱后缀提示纠正（" + oldName + " → " + neutral->name + "）", -1, -1);
            return 0;
        }
        if (candidate) avformat_close_input(&candidate);
        if (abortIO_.load() || ret == AVERROR_EXIT) return AVERROR_EXIT;
        seek = restore();
        if (seek < 0) return (int)seek;
    }

    // No neutral candidate is not proof of an empty file: useful frames can start
    // after the probe window. Run the normal stream analysis on the original
    // context; FFmpeg retains its parsed packets for playback. Cache that work so
    // open(analyze=true) and Core's later analyzeStreams() do not consume it twice.
    const int ret = analyzeInputOnce();
    if (abortIO_.load() || ret == AVERROR_EXIT) return AVERROR_EXIT;
    bool usable = false;
    for (unsigned int i = 0; i < fmtCtx_->nb_streams; ++i) {
        const AVCodecParameters* p = fmtCtx_->streams[i]->codecpar;
        usable |= (p->codec_type == AVMEDIA_TYPE_AUDIO && p->sample_rate > 0 && p->ch_layout.nb_channels > 0) ||
                  (p->codec_type == AVMEDIA_TYPE_VIDEO && p->width > 0 && p->height > 0);
    }
    if (ret >= 0 && usable) {
        analyzed_ = true;
        return 0;
    }
    // The normal prepare path cannot create a decoder with these missing fields.
    // Preserve neutral naming for the existing diagnosis/recovery ladder, which
    // must not rediscover the same unsupported extension-only hypothesis.
    neutralProbeName_ = true;
    neutralProbeUrl_ = neutralUrl;
    return ret < 0 ? ret : AVERROR_INVALIDDATA;
}

void Demuxer::closeInputOnly() {
    dropSeekPushback();
    if (fmtCtx_) avformat_close_input(&fmtCtx_);
    detachLocalIO();
    fmtCtx_ = nullptr;
    streamInfoAttempted_ = false; streamInfoResult_ = 0;
}

void Demuxer::diagnoseOpenFailure(const std::string& path) {
    const int64_t t0 = spNowUs();
    withFileReader(path, [&](const spresil::Reader& reader, int64_t size) {
        openDiag_ = spresil::diagnoseOpenFailure(reader, size, 16ll * 1024 * 1024, &abortFn_);
    }, /*tolerateAppend=*/true);
    if (spDebug()) {
        const spresil::OpenDiagnosis& d = openDiag_;
        fprintf(stderr,
                "[Demux] 打开失败诊断 %.1fms: size=%lld zeroHead=%lld%s mp4=%d ftyp=%d moov=%d moof=%d mdat=%d mdatToEnd=%d hint=%d\n",
                (spNowUs() - t0) / 1000.0, (long long)d.fileSize, (long long)d.leadingZeroBytes,
                d.zeroScanCapped ? "(capped)" : "", (int)d.mp4Family, (int)d.sawFtyp, (int)d.sawMoov,
                (int)d.sawMoof, (int)d.sawMdat, (int)d.mdatReachesEnd, (int)spresil::hintFor(d));
    }
}

void Demuxer::rebuildStreamTable() {
    streams_.clear();
    videoStream_ = -1;
    audioStream_ = -1;
    subtitleStream_ = -1;
    durationUs_ = (fmtCtx_->duration != AV_NOPTS_VALUE) ? fmtCtx_->duration : 0;
    if (durationUs_ < 0) durationUs_ = 0;

    computeTimelineOrigin();
    for (unsigned i = 0; i < fmtCtx_->nb_streams; ++i) {
        buildStreamInfo(fmtCtx_->streams[i]);
    }
    selectStreams();

    publishAltVideoCandidates();
    publishTsPcrIdentities(true);
}

void Demuxer::computeTimelineOrigin() {

    if (fmtCtx_->start_time != AV_NOPTS_VALUE) {
        timelineOriginUs_ = fmtCtx_->start_time;
        originOffsetCache_.clear();
        return;
    }
    int64_t mn = INT64_MAX;
    for (unsigned i = 0; i < fmtCtx_->nb_streams; ++i) {
        AVStream* s = fmtCtx_->streams[i];
        if (s->start_time == AV_NOPTS_VALUE) continue;
        int64_t us = av_rescale_q(s->start_time, s->time_base, AV_TIME_BASE_Q);
        if (us < mn) mn = us;
    }
    timelineOriginUs_ = (mn != INT64_MAX) ? mn : 0;
    originOffsetCache_.clear();
}

void Demuxer::selectStreams() {
    videoStream_ = -1;
    audioStream_ = -1;
    subtitleStream_ = -1;
    int defSub = -1;

    int defDecVideo = -1, decVideo = -1, defVideo = -1, firstVideo = -1;
    int defDecAudio = -1, decAudio = -1, defAudio = -1, firstAudio = -1;
    for (unsigned i = 0; i < fmtCtx_->nb_streams; ++i) {
        AVStream* s = fmtCtx_->streams[i];
        AVMediaType t = s->codecpar->codec_type;
        bool isDefault = (s->disposition & AV_DISPOSITION_DEFAULT) != 0;
        if (t == AVMEDIA_TYPE_VIDEO && isRealVideoStream(s)) {
            if (excludedVideo_.count((int)i)) continue;
            bool decodable = avcodec_find_decoder(s->codecpar->codec_id) != nullptr;
            if (firstVideo < 0) firstVideo = (int)i;
            if (defVideo < 0 && isDefault) defVideo = (int)i;
            if (decVideo < 0 && decodable) decVideo = (int)i;
            if (defDecVideo < 0 && isDefault && decodable) defDecVideo = (int)i;
        } else if (t == AVMEDIA_TYPE_AUDIO) {
            bool decodable = avcodec_find_decoder(s->codecpar->codec_id) != nullptr;
            if (firstAudio < 0) firstAudio = (int)i;
            if (defAudio < 0 && isDefault) defAudio = (int)i;
            if (decAudio < 0 && decodable) decAudio = (int)i;
            if (defDecAudio < 0 && isDefault && decodable) defDecAudio = (int)i;
        } else if (t == AVMEDIA_TYPE_SUBTITLE && isTextSubtitleStream(s)) {
            if (subtitleStream_ < 0) subtitleStream_ = (int)i;
            if (defSub < 0 && isDefault) defSub = (int)i;
        }
    }
    videoStream_ = defDecVideo >= 0 ? defDecVideo
                 : decVideo >= 0    ? decVideo
                 : defVideo >= 0    ? defVideo
                                    : firstVideo;
    audioStream_ = defDecAudio >= 0 ? defDecAudio
                 : decAudio >= 0    ? decAudio
                 : defAudio >= 0    ? defAudio
                                    : firstAudio;
    if (defSub >= 0) subtitleStream_ = defSub;
}

void Demuxer::publishAltVideoCandidates() {
    std::shared_ptr<std::vector<int>> cands;
    if (fmtCtx_) {
        try {
            cands = std::make_shared<std::vector<int>>();
            for (unsigned i = 0; i < fmtCtx_->nb_streams; ++i) {
                if (excludedVideo_.count((int)i)) continue;
                const AVStream* s = fmtCtx_->streams[i];
                if (s->codecpar->codec_type != AVMEDIA_TYPE_VIDEO || !isRealVideoStream(s)) continue;

                if (s->disposition & (AV_DISPOSITION_DEPENDENT | AV_DISPOSITION_STILL_IMAGE | AV_DISPOSITION_TIMED_THUMBNAILS)) continue;
                if (!avcodec_find_decoder(s->codecpar->codec_id)) continue;
                cands->push_back((int)i);
            }
        } catch (const std::bad_alloc&) { cands.reset(); }
    }
    altVideoStreamsSeen_ = fmtCtx_ ? fmtCtx_->nb_streams : 0;
    altVideoCodecSig_ = streamCodecSig();
    std::lock_guard<std::mutex> lk(altVideoMtx_);
    altVideoCands_ = std::move(cands);
    altVideoReopening_ = false;
}

uint64_t Demuxer::streamCodecSig() const {
    uint64_t sig = 1469598103934665603ull;
    if (!fmtCtx_) return sig;
    for (unsigned i = 0; i < fmtCtx_->nb_streams; ++i) {
        const AVCodecParameters* par = fmtCtx_->streams[i]->codecpar;
        sig = (sig ^ (((uint64_t)(uint32_t)par->codec_type << 32) | (uint32_t)par->codec_id)) * 1099511628211ull;
    }
    return sig;
}

void Demuxer::markAltVideoReopening() {
    std::lock_guard<std::mutex> lk(altVideoMtx_);
    altVideoCands_.reset();
    altVideoReopening_ = true;
}

int Demuxer::alternateVideoStream(int excluding) const {
    std::shared_ptr<const std::vector<int>> cands;
    {
        std::lock_guard<std::mutex> lk(altVideoMtx_);
        if (altVideoReopening_) return kAlternateVideoUnknown;
        cands = altVideoCands_;
    }
    if (!cands) return -1;
    for (int i : *cands) if (i != excluding) return i;
    return -1;
}

bool Demuxer::openSourceIdentity(uint64_t& dev, uint64_t& ino, int64_t& size, int64_t& mtimeNs) const {
    const auto io = ioSnapshot();
    if (!io) return false;
    dev = (uint64_t)io->sourceDev;
    ino = (uint64_t)io->sourceIno;
    size = io->size;
    mtimeNs = (int64_t)io->sourceMtime.tv_sec * 1000000000ll + io->sourceMtime.tv_nsec;
    return true;
}

bool Demuxer::publishTsPcrIdentities(bool force) {
    uint64_t sig = 1469598103934665603ull;
    auto mix = [&sig](uint64_t v) { sig = (sig ^ v) * 1099511628211ull; };
    const bool ts = tsMpegTs_ && fmtCtx_;
    if (ts) {
        mix(fmtCtx_->nb_programs);
        for (unsigned p = 0; p < fmtCtx_->nb_programs; ++p) {
            const AVProgram* prog = fmtCtx_->programs[p];
            if (!prog) { mix(0xFFFFFFFFull); continue; }
            mix((uint64_t)(uint32_t)prog->id); mix((uint64_t)(uint32_t)prog->pcr_pid); mix((uint64_t)(uint32_t)prog->pmt_pid);
            mix((uint64_t)(uint32_t)prog->pmt_version); mix(prog->nb_stream_indexes);
            for (unsigned k = 0; k < prog->nb_stream_indexes; ++k) mix(prog->stream_index[k]);
        }
    }
    if (!force && ts && sig == tsPcrSig_) return false;
    tsPcrSig_ = sig;
    std::shared_ptr<std::vector<TsPcrIdentity>> ids;
    if (ts) {
        try {
            ids = std::make_shared<std::vector<TsPcrIdentity>>();

            for (unsigned p = 0; p < fmtCtx_->nb_programs; ++p) {
                const AVProgram* prog = fmtCtx_->programs[p];
                if (!prog) continue;
                for (unsigned k = 0; k < prog->nb_stream_indexes; ++k) {
                    const int si = (int)prog->stream_index[k];
                    bool seen = false;
                    for (const TsPcrIdentity& e : *ids) if (e.stream == si) { seen = true; break; }
                    if (seen) continue;
                    TsPcrIdentity e;
                    e.stream = si;
                    e.query.pcrPid = prog->pcr_pid;
                    e.query.pmtPid = prog->pmt_pid;
                    e.query.pmtVersion = prog->pmt_version;
                    ids->push_back(e);
                }
            }
        } catch (const std::bad_alloc&) { ids.reset(); tsPcrSig_ = 0; }
    }
    std::lock_guard<std::mutex> lk(tsPcrMtx_);
    tsPcrIds_ = std::move(ids);
    return true;
}

void Demuxer::buildStreamInfo(AVStream* s) {
    StreamInfo info;
    info.index = (int)s->index;
    info.timeBase = s->time_base;
    info.durationUs = (s->duration != AV_NOPTS_VALUE)
                          ? av_rescale_q(s->duration, s->time_base, AV_TIME_BASE_Q)
                          : 0;

    info.startTimeUs = (s->start_time != AV_NOPTS_VALUE)
                           ? av_rescale_q(s->start_time, s->time_base, AV_TIME_BASE_Q) -
                                 timelineOriginUs_
                           : 0;

    const AVCodecParameters* par = s->codecpar;
    if (par) {
        info.type = par->codec_type;
        info.bitRate = par->bit_rate;
        info.width = par->width;
        info.height = par->height;
        if (info.type == AVMEDIA_TYPE_VIDEO) info.rotation = sp::spStreamClockwiseRotation(s);

        AVRational sar = s->sample_aspect_ratio;
        if (sar.num <= 0 || sar.den <= 0) sar = par->sample_aspect_ratio;
        if (sar.num > 0 && sar.den > 0) info.sampleAspect = sar;
        info.colorPrimaries = par->color_primaries;
        info.colorTrc = par->color_trc;
        info.colorSpace = par->color_space;
        info.colorRange = par->color_range;
        const AVCodec* c = avcodec_find_decoder(par->codec_id);
        if (c) {
            info.codecName = c->name ? c->name : "";
            info.codecLongName = c->long_name ? c->long_name : "";
        }
        if (info.type == AVMEDIA_TYPE_AUDIO) {
            info.channels = par->ch_layout.nb_channels;
            char buf[64] = {0};
            if (av_channel_layout_describe(&par->ch_layout, buf, sizeof(buf)) > 0) {
                info.channelLayout = buf;
            }
        }
    }

    if (info.type == AVMEDIA_TYPE_VIDEO) {

        info.colorBits = 0;
        if (par->format != AV_PIX_FMT_NONE) {
            if (const AVPixFmtDescriptor* pd = av_pix_fmt_desc_get((AVPixelFormat)par->format)) {
                info.colorBits = pd->comp[0].depth;
            }
        }
        if (info.colorBits <= 0 && par->bits_per_raw_sample > 0) info.colorBits = par->bits_per_raw_sample;

        if (info.colorBits <= 0 && par->codec_id == AV_CODEC_ID_HEVC &&
            (par->profile == AV_PROFILE_HEVC_MAIN_10 || par->profile == AV_PROFILE_HEVC_REXT)) {
            info.colorBits = 10;
        }
        if (info.colorBits <= 0 && par->codec_id == AV_CODEC_ID_H264 &&
            (par->profile == AV_PROFILE_H264_HIGH_10 || par->profile == AV_PROFILE_H264_HIGH_10_INTRA ||
             par->profile == AV_PROFILE_H264_HIGH_422 || par->profile == AV_PROFILE_H264_HIGH_422_INTRA)) {
            info.colorBits = 10;
        }
        if (info.colorBits <= 0 && par->bits_per_coded_sample > 0 && par->bits_per_coded_sample <= 16) {
            info.colorBits = par->bits_per_coded_sample;
        }
        if (info.colorBits <= 0) info.colorBits = 8;
        for (int i = 0; i < par->nb_coded_side_data; i++) {
            const AVPacketSideData* sd = &par->coded_side_data[i];
            if (sd->type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL && sd->size >= (int)sizeof(AVContentLightMetadata)) {
                const AVContentLightMetadata* clm = (const AVContentLightMetadata*)sd->data;
                info.maxCll = (int)clm->MaxCLL;
                info.maxFall = (int)clm->MaxFALL;
            } else if (sd->type == AV_PKT_DATA_DOVI_CONF && sd->size >= (int)sizeof(AVDOVIDecoderConfigurationRecord)) {
                const AVDOVIDecoderConfigurationRecord* dovi = (const AVDOVIDecoderConfigurationRecord*)sd->data;
                info.isDovi = true;
                info.doviProfile = dovi->dv_profile;
                info.doviBlCompatId = dovi->dv_bl_signal_compatibility_id;
            } else if (sd->type == AV_PKT_DATA_DYNAMIC_HDR10_PLUS) {
                info.hasHdr10Plus = true;
            }
        }
    }

    if (info.type == AVMEDIA_TYPE_VIDEO) {

        AVRational fr = s->avg_frame_rate;
        // Raw AV1 demuxers leave their default average (25) even when the
        // parser has explicit sequence timing. Packets already use that timing;
        // expose the same rate without overriding container timelines.
        const bool rawAv1 = par->codec_id == AV_CODEC_ID_AV1 && fmtCtx_ && fmtCtx_->iformat &&
            (!std::strcmp(fmtCtx_->iformat->name, "av1") || !std::strcmp(fmtCtx_->iformat->name, "obu"));
        if (rawAv1 && par->framerate.num > 0 && par->framerate.den > 0) fr = par->framerate;
        if (fr.num <= 0 || fr.den <= 0) fr = s->r_frame_rate;
        if (fr.num > 0 && fr.den > 0) {
            info.fps = av_q2d(fr);
        }
    }

    if (const AVDictionaryEntry* e = av_dict_get(s->metadata, "language", nullptr, 0)) {
        if (e->value) info.language = e->value;
    }
    if (const AVDictionaryEntry* e = av_dict_get(s->metadata, "title", nullptr, 0)) {
        if (e->value) info.title = e->value;
    }
    if (info.type == AVMEDIA_TYPE_SUBTITLE) {
        info.isTextSubtitle = isTextSubtitleStream(s);
    }
    streams_.push_back(std::move(info));
}

int Demuxer::analyzeStreams() {
    if (!fmtCtx_) return AVERROR(EINVAL);

    int64_t t0 = spNowUs();
    size_t pgsFilled = 0;
    const int ret = analyzeInputOnce(&pgsFilled);
    if (spDebug()) {
        fprintf(stderr, "[Demux] find_stream_info=%.1fms ret=%d pgsfill=%zu\n",
                (spNowUs() - t0) / 1000.0, ret, pgsFilled);
    }
    if (ret < 0) return ret;
    analyzed_ = true;

    rebuildStreamTable();
    if (!spDebug() || !tsMpegTs_) {
        tryTsPmtReopen(true);
        tryTsTransportReopen(true);
        return fmtCtx_ ? 0 : AVERROR(EIO);
    }

    std::string summary;
    const PlanMark all = planMark();
    for (int k = 0; k < 2; ++k) {
        const PlanMark m = planMark();
        if (k == 0) tryTsPmtReopen(true); else tryTsTransportReopen(true);
        if (planIO_.reads.load(std::memory_order_relaxed) != m.reads || !planNote_.empty())
            summary += "｜" + planItem(m, k == 0 ? "ts-pmt" : "ts-hdr");
    }
    if (!summary.empty()) {
        const PlanMark e = planMark();
        planLog("[DemuxPlan] 分析后 %s 合计 reads=%llu %.1fKB %.2fms%s", container_.c_str(), (unsigned long long)(e.reads - all.reads),
                (e.bytes - all.bytes) / 1024.0, (e.t0 - all.t0) / 1000.0, summary.c_str());
    }
    return fmtCtx_ ? 0 : AVERROR(EIO);
}

static void mergeExtension(spresil::RecoveryPlan& plan, const spresil::RecoveryPlan& more) {
    plan.patches.insert(plan.patches.end(), more.patches.begin(), more.patches.end());
    plan.damagedUntil = std::max(plan.damagedUntil, more.damagedUntil);
}

template <class PlanFn>
static void extendTsScan(spresil::RecoveryPlan& plan, int64_t& scannedTo, int64_t size, int stride, const std::atomic<bool>& abort, const PlanFn& planFn) {
    for (int ext = 0; ext < 8 && !plan.empty() && scannedTo < size && !abort.load(); ++ext) {
        const int64_t step = std::min<int64_t>(size - scannedTo, (1ll << 20) / stride * stride);
        if (step < stride) break;
        const spresil::RecoveryPlan more = planFn(scannedTo, step);
        scannedTo += step;
        if (more.empty()) break;
        mergeExtension(plan, more);
    }
}

bool Demuxer::tryTsPmtReopen(bool analyze) {
    if (!fmtCtx_ || !tsMpegTs_ || !resilientRecoveryEnabled_ || videoStream_ < 0 || abortIO_.load()) return false;
    if ((size_t)videoStream_ >= streams_.size() || streams_[videoStream_].width > 0) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withFileReader(path_, [&](const spresil::Reader& read, int64_t size) { plan = spresil::planTsPmtCrossCheck(read, size, &abortFn_); });
    if (spDebug()) {
        fprintf(stderr, "[Demux] TS 视频宽高为 0：PMT 交叉验证 %.1fms: %s %s\n", (spNowUs() - t0) / 1000.0,
                plan.empty() ? "无" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    if (!reopenCandidateOrFallBack(plan, analyze, true, "PMT ")) return false;
    noteOpenRecovery(plan.kind, "TS PMT 与实际 PES 矛盾，候选恢复 " + plan.kind + "：" + plan.detail);
    if (spDebug()) fprintf(stderr, "[Demux] PMT 候选 %s 生效：视频 %dx%d %s\n", plan.kind.c_str(), streams_[videoStream_].width, streams_[videoStream_].height, streams_[videoStream_].codecName.c_str());
    return true;
}

bool Demuxer::tryMp4MetadataReopen() {
    if (!fmtCtx_ || !localIO_) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();

    withPatchedFileReader([&](const spresil::Reader& read, int64_t size) { plan = spresil::planMp4MetadataSanity(read, size, &abortFn_); });
    const double ms = (spNowUs() - t0) / 1000.0;
    if (spDebug() && (!plan.empty() || ms > 2.0)) {
        fprintf(stderr, "[Demux] MP4 元数据一致性 %.2fms: %s %s\n", ms, plan.empty() ? "无矛盾" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;

    const bool paramChange = plan.kind.find("mp4-codec-tag") != std::string::npos || plan.kind.find("mp4-timescale") != std::string::npos ||
                             plan.kind.find("mp4-time-infer") != std::string::npos;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str(), false, paramChange)) return false;
    rebuildStreamTable();
    noteOpenRecovery(plan.kind, "MP4 元数据自相矛盾，候选恢复 " + plan.kind + "：" + plan.detail);
    return true;
}

bool Demuxer::tryMkvHeaderReopen() {
    if (!fmtCtx_ || !localIO_) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withFileReader(path_, [&](const spresil::Reader& read, int64_t size) { plan = spresil::planMkvHeaderCrc(read, size, &abortFn_); });
    const double ms = (spNowUs() - t0) / 1000.0;
    if (spDebug() && (!plan.empty() || !plan.detail.empty() || ms > 2.0)) {
        fprintf(stderr, "[Demux] MKV 头部 CRC 一致性 %.2fms: %s %s\n", ms, plan.empty() ? "无补丁" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str(), false, true)) return false;
    rebuildStreamTable();
    noteOpenRecovery(plan.kind, "Matroska 头部字段与原存 CRC 矛盾，候选恢复 " + plan.kind + "：" + plan.detail);
    return true;
}

bool Demuxer::tryAsfGeometryReopen() {
    if (!fmtCtx_ || !localIO_) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withFileReader(path_, [&](const spresil::Reader& read, int64_t size) { plan = spresil::planAsfPacketGeometry(read, size, &abortFn_); });
    if (spDebug() && (!plan.empty() || spNowUs() - t0 > 2000)) {
        fprintf(stderr, "[Demux] ASF 包几何 %.2fms: %s %s\n", (spNowUs() - t0) / 1000.0, plan.empty() ? "一致" : plan.kind.c_str(), plan.detail.c_str());
    }
    bool applied = false;
    if (!plan.empty() && reopenInPlace(plan.patches, false, plan.kind.c_str())) {
        rebuildStreamTable();
        noteOpenRecovery(plan.kind, "ASF 包长字段与 Data 范围矛盾，候选恢复 " + plan.kind + "：" + plan.detail);
        applied = true;
    }

    if (fmtCtx_ && fmtCtx_->packet_size > 0 && fmtCtx_->packet_size <= 65536) {
        spresil::RecoveryPlan cp;
        int64_t scanned = -1;
        const spresil::PatchOverlay overlay = localIO_ ? localIO_->patches : spresil::PatchOverlay{};
        const int64_t window = 64ll * fmtCtx_->packet_size;
        withFileReader(path_, [&](const spresil::Reader& base, int64_t size) {
            cp = spresil::planAsfPayloadCounts(spresil::patchedReader(base, overlay), size, 0, window, &abortFn_, &scanned);
        });
        if (scanned > 0) asfCountScannedUntil_ = scanned;
        if (!cp.empty()) {
            if (spDebug()) fprintf(stderr, "[Demux] ASF 打开时 payload 数量抽样: %s %s\n", cp.kind.c_str(), cp.detail.c_str());
            if (reopenInPlace(cp.patches, false, cp.kind.c_str())) {
                rebuildStreamTable();
                noteOpenRecovery(cp.kind, "ASF 包内 payload 数量与长度链矛盾（打开时抽样），候选恢复 " + cp.kind + "：" + cp.detail);
                applied = true;
            }
        }
    }

    if (fmtCtx_ && fmtCtx_->packet_size > 0 && fmtCtx_->packet_size <= 65536 && !abortIO_.load()) {
        spresil::RecoveryPlan op;
        int64_t scanned = -1;
        const spresil::PatchOverlay overlay = localIO_ ? localIO_->patches : spresil::PatchOverlay{};
        const int64_t t1 = spNowUs();
        withFileReader(path_, [&](const spresil::Reader& base, int64_t size) {
            const spresil::Reader rd = overlay.empty() ? base : spresil::patchedReader(base, overlay);
            op = spresil::planAsfObjectFragments(rd, size, 0, 64ll * fmtCtx_->packet_size, &abortFn_, asfObjState_, &scanned);
            for (int ext = 0; ext < 8 && !op.empty() && scanned >= 0 && scanned < size && !abortIO_.load(); ++ext) {
                int64_t more = -1;
                spresil::RecoveryPlan mp = spresil::planAsfObjectFragments(rd, size, scanned, 1ll << 20, &abortFn_, asfObjState_, &more);
                if (more <= scanned) break;
                scanned = more;
                if (mp.empty()) break;
                mergeExtension(op, mp);
            }
        });
        if (scanned > asfObjScannedUntil_) asfObjScannedUntil_ = scanned;
        if (spDebug() && (!op.empty() || spNowUs() - t1 > 2000)) {
            fprintf(stderr, "[Demux] ASF 打开时媒体对象片段核对（到 %lld）%.1fms: %s %s\n", (long long)scanned, (spNowUs() - t1) / 1000.0, op.empty() ? "无矛盾" : op.kind.c_str(), op.detail.c_str());
        }
        if (!op.empty()) {
            ++asfObjAttempts_;
            if (reopenInPlace(op.patches, false, op.kind.c_str())) {
                rebuildStreamTable();
                noteOpenRecovery(op.kind, "ASF 媒体对象的大小副本 / 片段偏移与其余片段矛盾（打开时核对），候选恢复 " + op.kind + "：" + op.detail);
                applied = true;
            }
        }
    }
    return applied;
}

bool Demuxer::tryRmStreamMapReopen() {
    if (!fmtCtx_ || !localIO_) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withFileReader(path_, [&](const spresil::Reader& read, int64_t size) { plan = spresil::planRmStreamMap(read, size, &abortFn_); });
    if (spDebug() && (!plan.empty() || spNowUs() - t0 > 2000)) {
        fprintf(stderr, "[Demux] RM 流映射 %.2fms: %s %s\n", (spNowUs() - t0) / 1000.0, plan.empty() ? "一致" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str())) return false;
    rebuildStreamTable();
    noteOpenRecovery(plan.kind, "RealMedia MDPR 流号与 DATA 分组矛盾，候选恢复 " + plan.kind + "：" + plan.detail);
    return true;
}

bool Demuxer::attemptAsfPayloadCountRecovery(int64_t fromPos) {
    if (!fmtCtx_ || !localIO_ || asfCountAttempts_ >= 8) return false;
    ++asfCountAttempts_;
    spresil::RecoveryPlan plan;
    int64_t scannedUntil = -1;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        plan = spresil::planAsfPayloadCounts(rd, size, fromPos, 32ll * 1024 * 1024, &abortFn_, &scannedUntil);
    });
    if (scannedUntil > asfCountScannedUntil_) asfCountScannedUntil_ = scannedUntil;
    if (spDebug()) {
        fprintf(stderr, "[Demux] ASF payload 数量裁决（从 %lld 起，扫到 %lld）%.1fms: %s %s\n", (long long)fromPos, (long long)scannedUntil,
                (spNowUs() - t0) / 1000.0, plan.empty() ? "无" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    if (!installPatches(plan.patches, true)) return false;
    const int64_t target = recoverySeekTargetUs();
    if (replayFromRecoveryTarget(target, "ASF 补丁 " + std::to_string(plan.patches.size()) + " 处已装入") != RecoveryOutcome::AppliedAndResumed) return false;
    pushRecoveryEvent("ASF 包内 payload 数量与长度链矛盾，候选恢复 " + plan.kind + "：" + plan.detail, byteToUsGuess(plan.damagedFrom), byteToUsGuess(plan.damagedUntil));
    return true;
}

bool Demuxer::attemptMpeg2SeqHeaderFix(AVPacket* pkt) {
    if (!fmtCtx_ || !localIO_ || !pkt || pkt->size < 12 || !pkt->data) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        plan = spresil::planMpeg2SeqHeader(rd, size, pkt->data, (size_t)pkt->size, 8ll * 1024 * 1024, &abortFn_);
    });
    if (spDebug()) {
        fprintf(stderr, "[Demux] MPEG-2 首序列头尺寸归零：重复头候选 %.1fms: %s %s\n", (spNowUs() - t0) / 1000.0, plan.empty() ? "无" : plan.kind.c_str(),
                plan.detail.c_str());
    }
    if (plan.empty() || plan.patches.size() != 1 || plan.patches[0].bytes.size() != 3) return false;
    if (av_packet_make_writable(pkt) < 0) return false;

    if (!installPatches(plan.patches, false)) return false;
    std::memcpy(pkt->data + 4, plan.patches[0].bytes.data(), 3);
    pushRecoveryEvent("MPEG-2 首序列头尺寸归零，候选恢复 " + plan.kind + "：" + plan.detail, 0, byteToUsGuess(plan.damagedUntil));
    return true;
}

static bool spH264TrialDecode(const std::string& path, int64_t patchAt, uint8_t patchByte, int maxPkts, int& frames, int& flagged, int& errors,
                              const std::atomic<bool>& abortFlag, const char** outcome) {
    sptrial::Budget b;
    b.maxTargetPkts = maxPkts; b.maxAnyPkts = 64 * maxPkts; b.maxBytes = 32ll << 20; b.maxWallUs = 1500000;
    sptrial::InterruptCtx ic;
    ic.abort = [&abortFlag] { return abortFlag.load(std::memory_order_acquire); };
    ic.deadlineUs = sptrial::monotonicNowUs() + b.maxWallUs;
    const sptrial::Stats st = sptrial::h264TrialDecode(path, patchAt, patchByte, b, ic);
    frames = st.frames; flagged = st.flaggedFrames; errors = st.sendErrors;
    if (outcome) *outcome = sptrial::outcomeName(st.outcome);
    switch (st.outcome) {
        case sptrial::Outcome::OpenFailed: case sptrial::Outcome::ReadFailed: case sptrial::Outcome::Cancelled: case sptrial::Outcome::BudgetExhausted:
            return false;
        default: return true;
    }
}

bool Demuxer::attemptH264PpsEntropyFix(AVPacket* pkt) {
    if (!fmtCtx_ || !localIO_ || !pkt || !pkt->data || pkt->size < 8 || pkt->pos < 0 || videoStream_ < 0) return false;
    const AVCodecParameters* par = fmtCtx_->streams[videoStream_]->codecpar;
    if (par->codec_id != AV_CODEC_ID_H264 || !par->extradata || par->extradata_size < 7 || par->extradata[0] != 1) return false;
    const int lenSize = (par->extradata[4] & 3) + 1;

    std::vector<std::pair<uint32_t, std::vector<uint8_t>>> avccPps;
    {
        const uint8_t* e = par->extradata; const int n = par->extradata_size;
        size_t off = 6;
        const int spsCount = e[5] & 0x1f;
        for (int i = 0; i < spsCount; ++i) { if (off + 2 > (size_t)n) return false; const size_t l = ((size_t)e[off] << 8) | e[off + 1]; off += 2 + l; }
        if (off >= (size_t)n) return false;
        const int ppsCount = e[off++];
        for (int i = 0; i < ppsCount; ++i) {
            if (off + 2 > (size_t)n) return false;
            const size_t l = ((size_t)e[off] << 8) | e[off + 1]; off += 2;
            if (l < 2 || off + l > (size_t)n) return false;
            spresil::detail::H264BitReader br(e + off + 1, l - 1, 8);
            const uint32_t id = br.ue();
            if (!br.bad) avccPps.push_back({id, std::vector<uint8_t>(e + off, e + off + l)});
            off += l;
        }
    }
    if (avccPps.empty()) return false;

    int64_t patchAt = -1; uint8_t patched = 0, original = 0; int matches = 0;
    size_t off = 0;
    while (off + (size_t)lenSize <= (size_t)pkt->size) {
        uint32_t len = 0;
        for (int i = 0; i < lenSize; ++i) len = (len << 8) | pkt->data[off + (size_t)i];
        off += (size_t)lenSize;
        if (len < 2 || off + len > (size_t)pkt->size) return false;
        const uint8_t* nal = pkt->data + off;
        if ((nal[0] & 0x1f) == 8) {
            spresil::detail::H264BitReader br(nal + 1, len - 1, 8);
            const uint32_t id = br.ue();
            size_t byteAt = 0; uint8_t mask = 0;
            if (!br.bad && spresil::h264PpsEntropyBit(nal, len, byteAt, mask)) {
                for (const auto& ap : avccPps) {
                    if (ap.first != id || ap.second.size() != len) continue;
                    bool onlyThatBit = true;
                    for (size_t k = 0; k < len && onlyThatBit; ++k) {
                        const uint8_t diff = ap.second[k] ^ nal[k];
                        if (diff != 0 && !(k == byteAt && diff == mask)) onlyThatBit = false;
                    }
                    if (onlyThatBit && (ap.second[byteAt] ^ nal[byteAt]) == mask) {
                        ++matches;
                        patchAt = pkt->pos + (int64_t)(off + byteAt);
                        patched = ap.second[byteAt];
                        original = nal[byteAt];
                    }
                }
            }
        }
        off += len;
    }
    if (matches != 1) return false;

    {
        uint8_t fb = 0; bool same = false;
        const spresil::PatchOverlay overlay = localIO_->patches;
        withFileReader(path_, [&](const spresil::Reader& base, int64_t) { same = spresil::patchedReader(base, overlay)(patchAt, &fb, 1) == 1 && fb == original; });
        if (!same) return false;
    }
    const int64_t t0 = spNowUs();

    struct PpsTrial { bool ok0 = false, ok1 = false; int f0 = 0, fl0 = 0, e0 = 0, f1 = 0, fl1 = 0, e1 = 0; const char* oc0 = "?"; const char* oc1 = "not-run"; };
    PpsTrial tr;
    const std::shared_ptr<LocalFileIO> trialIo = localIO_;
    const std::string trialPath = path_;

    const bool ran = spRunAbandonable(trialIo, "sp.pps-trial", [trialPath, patchAt, patched](const std::atomic<bool>& cancel) {
        PpsTrial t;
        t.ok0 = spH264TrialDecode(trialPath, -1, 0, 8, t.f0, t.fl0, t.e0, cancel, &t.oc0);
        t.ok1 = t.ok0 && !cancel.load(std::memory_order_acquire) &&
                spH264TrialDecode(trialPath, patchAt, patched, 8, t.f1, t.fl1, t.e1, cancel, &t.oc1);
        return t;
    }, tr);
    if (!ran) return false;
    const bool ok1 = tr.ok1;
    const int f0 = tr.f0, fl0 = tr.fl0, e0 = tr.e0, f1 = tr.f1, fl1 = tr.fl1, e1 = tr.e1;
    const char* oc0 = tr.oc0; const char* oc1 = tr.oc1;
    if (spDebug()) {
        fprintf(stderr, "[Demux] H.264 带内 PPS 与 avcC 副本只差 entropy 位：私有试解 %.1fms 原始 %d 帧/%d 坏/%d 错 (%s)，候选 %d 帧/%d 坏/%d 错 (%s)\n",
                (spNowUs() - t0) / 1000.0, f0, fl0, e0, oc0, f1, fl1, e1, oc1);
    }
    if (!ok1) return false;
    const bool origBad = fl0 > 0 || e0 > 0 || f0 < 4;
    const bool candClean = fl1 == 0 && e1 == 0 && f1 >= 7;
    if (!origBad || !candClean) return false;
    if (av_packet_make_writable(pkt) < 0) return false;
    spresil::Patch pt; pt.offset = patchAt; pt.bytes = {patched};
    if (!installPatches({pt}, false)) return false;
    pkt->data[patchAt - pkt->pos] = patched;
    pushRecoveryEvent("H.264 首个带内 PPS 的熵编码位与 avcC 副本矛盾，私有试解裁决后改回（原始前 8 包 " + std::to_string(fl0) + " 坏帧 / " +
                          std::to_string(e0) + " 错误，候选全干净）",
                      0, -1);
    return true;
}

bool Demuxer::tryAviChunkSizeReopen() {
    if (!fmtCtx_ || !localIO_) return false;
    spresil::RecoveryPlan plan;
    int mismatch = 0, tested = 0, rel = 0, absm = 0, idMismatch = 0;
    const int64_t t0 = spNowUs();
    const uint32_t samples = localIO_->remote ? 8 : 32;
    const bool sourceStable = withFileReader(path_, [&](const spresil::Reader& read, int64_t size) {
        spresil::AviLayout L;
        if (!spresil::aviLocate(read, size, L, &abortFn_)) return;
        tested = spresil::aviIdx1Sample(read, size, L, rel, absm, &mismatch, &idMismatch, samples, true);
        if (tested > 0 && mismatch > 0) plan = spresil::planAviChunkSizes(read, size, &abortFn_);

        if (plan.empty() && tested > 0 && idMismatch > 0) plan = spresil::planAviUnknownStreamIds(read, size, &abortFn_);
    });
    if (!sourceStable) plan = {};
    if (spDebug()) {
        char note[80];
        snprintf(note, sizeof note, "抽样 %d 条（相对 %d / 绝对 %d 命中）%s", tested, rel, absm, plan.empty() ? "无计划" : plan.kind.c_str());
        planNote_ = note;
    }
    if (spDebug() && (mismatch > 0 || idMismatch > 0 || spNowUs() - t0 > 2000)) {
        fprintf(stderr, "[Demux] AVI idx1 抽样 %d 条（相对 %d / 绝对 %d 命中，fourcc 相符长度不同 %d，长度相符 fourcc 不同 %d）%.1fms: %s %s\n", tested, rel, absm,
                mismatch, idMismatch, (spNowUs() - t0) / 1000.0, plan.empty() ? "无计划" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str())) return false;
    rebuildStreamTable();
    noteOpenRecovery(plan.kind, std::string(plan.kind == "avi-chunk-stream" ? "AVI 媒体 chunk 的流号未声明而 idx1 与媒体体互证" : "AVI 媒体 chunk 长度与 idx1 矛盾") +
                                    "，候选恢复 " + plan.kind + "：" + plan.detail);
    return true;
}

bool Demuxer::attemptAviChunkSizeRecovery(int64_t lostTsUs, const std::string& why) {
    if (!fmtCtx_ || !localIO_) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        plan = spresil::planAviChunkSizes(rd, size, &abortFn_);

        if (plan.empty()) plan = spresil::planAviUnknownStreamIds(rd, size, &abortFn_);
    });
    if (spDebug()) {
        fprintf(stderr, "[Demux] AVI 交付包与索引矛盾（%s）候选计划 %.1fms: %s %s\n", why.c_str(), (spNowUs() - t0) / 1000.0,
                plan.empty() ? "无" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    int64_t target = recoverySeekTargetUs();
    if (lostTsUs >= 0 && (target < 0 || lostTsUs < target)) target = lostTsUs;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str(), false, false, target)) return false;
    pushRecoveryEvent(std::string(plan.kind == "avi-chunk-stream" ? "AVI 媒体 chunk 的流号未声明而 idx1 与媒体体互证" : "AVI 媒体 chunk 长度与 idx1 矛盾") +
                          "，候选恢复 " + plan.kind + "：" + plan.detail, byteToUsGuess(plan.damagedFrom), byteToUsGuess(plan.damagedUntil));
    return true;
}

bool Demuxer::tsRangeHasZeroFill(int64_t posA, int64_t posB) {
    if (posA < 0 || posB <= posA) return false;
    const std::shared_ptr<LocalFileIO> io = ioSnapshot();
    if (!io || io->fd < 0 || abortIO_.load()) return false;
    const int64_t end = std::min<int64_t>(posB, posA + 64ll * 1024 * 1024);
    struct Scan { bool zero = false; };
    Scan scan;
    const bool ran = spRunAbandonable(io, "sp.ts-zero", [io, posA, end](const std::atomic<bool>& cancel) {
        Scan r;
        uint8_t buf[188];
        for (int64_t pos = posA; pos + 188 <= end; pos += 64 * 1024) {
            if (cancel.load(std::memory_order_acquire) || io->abortRequested.load()) break;
            ssize_t got;
            do { got = ::pread(io->fd, buf, sizeof(buf), (off_t)pos); } while (got < 0 && errno == EINTR && !io->abortRequested.load());
            if (got == (ssize_t)sizeof(buf) && spresil::allZero(buf, sizeof(buf))) { r.zero = true; break; }
        }
        return r;
    }, scan);
    if (ran && scan.zero && spDebug())
        fprintf(stderr, "[Demux] 字节区间 [%lld, %lld) 含整段填零：按空洞处理\n", (long long)posA, (long long)end);
    return ran && scan.zero;
}

int64_t Demuxer::tsPcrDeltaUs(int streamIndex, int64_t posA, int64_t posB) {
    if (!tsMpegTs_ || posA < 0 || posB < 0 || streamIndex < 0) return -1;

    std::shared_ptr<const std::vector<TsPcrIdentity>> ids;
    {
        std::lock_guard<std::mutex> lk(tsPcrMtx_);
        ids = tsPcrIds_;
    }
    spresil::TsPcrQuery q;
    if (ids) {
        for (const TsPcrIdentity& e : *ids) {
            if (e.stream == streamIndex) { q = e.query; break; }
        }
    }
    if (q.pcrPid <= 0 || q.pcrPid >= 0x1FFF) {
        if (spDebug()) fprintf(stderr, "[Demux] PCR 证据：流 #%d 无所属节目声明的 PCR_PID → 无证据\n", streamIndex);
        return -1;
    }

    const std::shared_ptr<LocalFileIO> io = ioSnapshot();
    if (!io || io->fd < 0 || io->size <= 0 || abortIO_.load()) return -1;
    if (posB > posA && posB - posA > (io->remote ? 16ll * 1024 * 1024 : 256ll * 1024 * 1024)) return -1;
    struct Scan { int64_t out = -1; uint64_t reads = 0, bytes = 0, us = 0; };
    const int64_t size = io->size;
    const bool count = spDebug();
    Scan scan;
    const bool ran = spRunAbandonable(io, "sp.ts-pcr", [io, size, posA, posB, q, count](const std::atomic<bool>& cancel) {
        Scan r;

        const spresil::Reader read = [&io, &r, count](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
            if (pos < 0 || io->abortRequested.load()) return AVERROR_EXIT;
            const int64_t t0 = count ? spNowUs() : 0;
            ssize_t got;
            do { got = ::pread(io->fd, buf, n, (off_t)pos); } while (got < 0 && errno == EINTR && !io->abortRequested.load());
            const int64_t result = got < 0 ? (int64_t)AVERROR(errno) : (int64_t)got;
            if (count) { ++r.reads; if (got > 0) r.bytes += (uint64_t)got; r.us += (uint64_t)(spNowUs() - t0); }
            return result;
        };
        const spresil::AbortFn abort = [&cancel, &io] { return cancel.load(std::memory_order_acquire) || io->abortRequested.load(); };
        r.out = spresil::tsPcrDeltaUs(read, size, posA, posB, q, &abort);
        return r;
    }, scan);
    if (!ran) return -1;
    if (count) {
        planIO_.reads.fetch_add(scan.reads, std::memory_order_relaxed);
        planIO_.bytes.fetch_add(scan.bytes, std::memory_order_relaxed);
        planIO_.us.fetch_add(scan.us, std::memory_order_relaxed);
        fprintf(stderr, "[Demux] PCR 证据：流 #%d 节目 PCR_PID 0x%x PMT 0x%x v%d，[%lld, %lld] ΔPCR=%.3fs\n", streamIndex, q.pcrPid,
                q.pmtPid, q.pmtVersion, (long long)posA, (long long)posB, scan.out / 1e6);
    }
    return scan.out;
}

bool Demuxer::attemptFmp4RealignRecovery(int64_t samplePos) {
    if (!fmtCtx_ || !localIO_ || videoStream_ < 0 || fmp4RealignAttempts_ >= 16) return false;
    ++fmp4RealignAttempts_;
    const uint32_t trackId = (uint32_t)fmtCtx_->streams[videoStream_]->id;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        const spresil::Reader& read = rd;
        plan = spresil::planFmp4Realign(read, size, samplePos, trackId, fmp4VideoLayout_.nalLengthSize, fmp4VideoLayout_.hevc, &abortFn_);
    });
    if (spDebug()) {
        fprintf(stderr, "[Demux] fMP4 视频包链连续不闭合（样本 @%lld，轨 %u）重锚定计划 %.1fms: %s %s\n", (long long)samplePos, trackId,
                (spNowUs() - t0) / 1000.0, plan.empty() ? "无" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    const int64_t evFrom = byteToUsGuess(plan.damagedFrom), evUntil = byteToUsGuess(plan.damagedUntil);
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str())) return false;
    pushRecoveryEvent("fMP4 样本错位候选恢复 " + plan.kind + "：" + plan.detail, evFrom, evUntil);
    return true;
}

bool Demuxer::attemptMp4SampleTableRecovery(int64_t faultPosition) {
    if (!fmtCtx_ || !localIO_ || mp4WindowReopens_ >= 2 || mp4WindowAttempts_ >= 8) return false;
    ++mp4WindowAttempts_; // one shared check: legacy plan followed by a bounded window
    spresil::RecoveryPlan plan;
    bool windowCandidate = false;
    bool linearPresentationTimeline = false;
    const int64_t t0 = spNowUs();
    if (mp4TableAttempts_ < 2) {
        ++mp4TableAttempts_;
        withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
            plan = spresil::planMp4SampleTables(rd, size, &abortFn_);
        });
    }
    if (plan.empty() && mp4WindowReopens_ < 2 && faultPosition >= 0 &&
        videoStream_ >= 0 && static_cast<unsigned>(videoStream_) < fmtCtx_->nb_streams) {
        for (const auto& region : mp4WindowRegions_)
            if (faultPosition >= region.first && faultPosition <= region.second) return false;
        auto view = captureReadSourceView();
        if (!view) return false;
        const int64_t lo = std::max<int64_t>(0, faultPosition - (4ll << 20));
        const int64_t hi = faultPosition <= INT64_MAX - (4ll << 20) ? faultPosition + (4ll << 20) : INT64_MAX;
        try {
            mp4WindowRegions_.push_back({lo, hi});
            const int64_t plannerDeadline = sptrial::monotonicNowUs() + 250000;
            spresil::AbortFn current = [&] { return abortIO_.load() || !view.current() || sptrial::monotonicNowUs() >= plannerDeadline; };
            auto result = spresil::planMp4SampleTableWindow(view.read, view.physicalSize,
                static_cast<uint32_t>(fmtCtx_->streams[videoStream_]->id), faultPosition, &current);
            uint64_t metadataBytes = result.metadataBytes;
            spresil::Reader confirm = [&](int64_t pos, uint8_t* bytes, size_t n) -> int64_t {
                if (current() || metadataBytes > (16u << 20) || n > (16u << 20) - metadataBytes) return AVERROR_EXIT;
                const int64_t got = view.read(pos, bytes, n);
                if (got > 0) metadataBytes += static_cast<uint64_t>(got);
                return current() ? AVERROR_EXIT : got;
            };
            if (result.status == spresil::Mp4WindowStatus::Ready && !current() &&
                spresil::mp4WindowOriginalFieldsMatch(confirm, result, &current)) {
                plan = std::move(result.plan);
                windowCandidate = true;
                linearPresentationTimeline = result.linearPresentationTimeline;
            }
        } catch (const std::bad_alloc&) { return false; }
    }
    if (spDebug()) fprintf(stderr, "[Demux] MP4 样本表恢复计划 %.1fms: %s %s\n",
        (spNowUs() - t0) / 1000.0, plan.empty() ? "无" : plan.kind.c_str(), plan.detail.c_str());
    if (plan.empty()) return false;
    const int64_t target = recoverySeekTargetUs();
    const int64_t resume = target >= 0 && target < 1000000 ? 0 : target;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str(), false, false, resume, windowCandidate,
                       linearPresentationTimeline)) return false;
    ++mp4WindowReopens_; // shared cap: old whole-track and new window successes
    pushRecoveryEvent("MP4 样本表表项与媒体字节矛盾，候选恢复 " + plan.kind + "：" + plan.detail,
                      windowCandidate ? -1 : byteToUsGuess(plan.damagedFrom),
                      windowCandidate ? -1 : byteToUsGuess(plan.damagedUntil));
    return true;
}

bool Demuxer::attemptPsPesRecovery(int64_t pesPos) {
    if (!fmtCtx_ || !localIO_ || psPesAttempts_ >= 16) return false;
    ++psPesAttempts_;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        plan = spresil::planMpegPsPesLengths(rd, size, pesPos, &abortFn_);
    });
    if (spDebug()) {
        fprintf(stderr, "[Demux] PS PES 长度与后继矛盾（@%lld）候选计划 %.1fms: %s %s\n", (long long)pesPos, (spNowUs() - t0) / 1000.0,
                plan.empty() ? "无" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    const int64_t evFrom = byteToUsGuess(plan.damagedFrom), evUntil = byteToUsGuess(plan.damagedUntil);
    if (!installPatches(plan.patches, true)) return false;
    const int64_t target = recoverySeekTargetUs();

    const auto savedAbs = lastGoodAbsUsPerStream_;
    const auto savedPos = lastGoodPosPerStream_;
    const int64_t savedLast = lastGoodAbsUs_;
    const int sret = target >= 0 ? seekToUs(target - timelineOriginUs_) : -1;
    lastGoodAbsUsPerStream_ = savedAbs;
    lastGoodPosPerStream_ = savedPos;
    lastGoodAbsUs_ = savedLast;
    if (spDebug()) {
        fprintf(stderr, "[Demux] PS 补丁 %zu 处已装入，回 seek %.2fs → %d（各流最近交付：", plan.patches.size(), target / 1e6, sret);
        for (size_t i = 0; i < lastGoodAbsUsPerStream_.size(); ++i) fprintf(stderr, "#%zu %.3fs ", i, lastGoodAbsUsPerStream_[i] / 1e6);
        fprintf(stderr, "）\n");
    }
    if (sret < 0) return false;
    eof_ = false;
    lastGoodPos_ = -1;
    armResumeDiscard(target);
    pushRecoveryEvent("PS PES 长度候选恢复 " + plan.kind + "：" + plan.detail, evFrom, evUntil);
    return true;
}

void Demuxer::applyStreamDiscard(int audioIndex, int subtitleIndex) {
    lastDiscardAudio_ = audioIndex;
    lastDiscardSub_ = subtitleIndex;
    discardApplied_ = true;
    if (!fmtCtx_ || !discardEligible_) return;
    for (unsigned i = 0; i < fmtCtx_->nb_streams; ++i) {
        AVStream* s = fmtCtx_->streams[i];
        const bool keep = ((int)i == videoStream_ && !videoIsolated_) || (int)i == audioIndex || (int)i == subtitleIndex;
        s->discard = keep ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    }
}

void Demuxer::resetAnnexBTailPermission() {
    annexBTailRetryUsed_ = false;
    if (fmtCtx_ && fmtCtx_->iformat && fmtCtx_->iformat->name &&
        strcmp(fmtCtx_->iformat->name, "av1") == 0 && fmtCtx_->priv_data)
        (void)av_opt_set_int(fmtCtx_->priv_data, "sp_annexb_tail_control", -1, 0);
}

void Demuxer::attemptAnnexBTailDrain(AVPacket* packet, int& readResult) {
    // This path is reached only after an actual raw-Annex-B error/EOF. The
    // read-only latch was set inside FFmpeg by a short payload read, never by
    // a filename, a generic INVALIDDATA, or a guessed private struct layout.
    if (annexBTailRetryUsed_ || !resilientRecoveryEnabled_ || !fmtCtx_ ||
        !fmtCtx_->iformat || !fmtCtx_->iformat->name ||
        strcmp(fmtCtx_->iformat->name, "av1") != 0 || !fmtCtx_->priv_data ||
        !fmtCtx_->pb || !localIO_ || !localIO_->localFilesystem || localIO_->remote ||
        !localIO_->patches.empty() || localIO_->virtualSize != localIO_->size ||
        videoStream_ < 0 || fmtCtx_->streams[videoStream_]->codecpar->codec_id != AV_CODEC_ID_AV1 ||
        lastGoodPos_ <= 0 || abortIO_.load() || fmtCtx_->pb->error || !fmtCtx_->pb->eof_reached)
        return;
    int64_t pending = 0, position = -1, requested = 0, received = 0;
    void* options = fmtCtx_->priv_data;
    if (av_opt_get_int(options, "sp_annexb_tail_pending", 0, &pending) < 0 || pending != 1 ||
        av_opt_get_int(options, "sp_annexb_tail_position", 0, &position) < 0 ||
        av_opt_get_int(options, "sp_annexb_tail_requested", 0, &requested) < 0 ||
        av_opt_get_int(options, "sp_annexb_tail_received", 0, &received) < 0 ||
        requested <= 0 || requested > INT_MAX ||
        !((received >= 0 && received < requested) || received == AVERROR_EOF) ||
        position != localIO_->size || avio_tell(fmtCtx_->pb) != position)
        return;
    const ReadSourceView source = captureReadSourceView();
    if (!source || source.size != source.physicalSize || source.size != position) return;
    auto rejectInvalidSource = [&](bool acknowledged) {
        const bool current = source.current();
        const bool aborted = abortIO_.load();
        const bool changed = !current && !aborted;
        if (!aborted && !changed) return false;
        (void)av_opt_set_int(options, "sp_annexb_tail_control", -1, 0);
        if (changed && !acknowledged) {

            return true;
        }
        // A consumed BSF drain cannot be made current again by an ordinary seek.
        // Remember only a proven identity failure; cancellation is not poison.
        if (changed) annexBTailSourceInvalid_ = true;
        readResult = aborted ? AVERROR_EXIT : AVERROR(ESTALE);
        av_packet_unref(packet);
        return true;
    };
    if (rejectInvalidSource(false)) return;
    annexBTailRetryUsed_ = true;
    if (av_opt_set_int(options, "sp_annexb_tail_control", 1, 0) < 0) return;
    if (rejectInvalidSource(true)) return;
    av_packet_unref(packet);
    readResult = av_read_frame(fmtCtx_, packet); // Exactly one acknowledgement retry.
    (void)av_opt_set_int(options, "sp_annexb_tail_control", 0, 0);
    if (rejectInvalidSource(true)) return; // Never publish from an invalid source view.
    if (readResult >= 0 || readResult == AVERROR_EOF)
        pushRecoveryEvent("AV1 Annex-B 尾 OBU 截断：静态物理 EOF，排空完整前缀", lastGoodAbsUs_, -1);
}

bool Demuxer::growthActive() const {
    const LocalFileIO* io = localIO_.get();
    if (!io) return false;
    const uint8_t m = io->growthMode.load(std::memory_order_relaxed);
    return m == (uint8_t)spgrow::Mode::Growing || m == (uint8_t)spgrow::Mode::Final;
}

int Demuxer::readFrameGrowthAware(AVPacket* pkt) {

    if (!seekPushback_.empty()) {
        AVPacket* p = seekPushback_.front();
        seekPushback_.pop_front();
        av_packet_unref(pkt);
        av_packet_move_ref(pkt, p);
        av_packet_free(&p);
        return 0;
    }
    LocalFileIO* io = localIO_.get();
    if (!io) return av_read_frame(fmtCtx_, pkt);
    if (io->growth.zeroEofOutsidePlay) {
        io->growth.zeroEofOutsidePlay = false;
        growthResyncPending_ = true;
    }
    if (growthResyncPending_) {

        growthResyncPending_ = false;
        if (fmtCtx_->pb) avio_seek(fmtCtx_->pb, avio_tell(fmtCtx_->pb), SEEK_SET);
    }
    if (!byteTimeMapCaptured_ && growthActive()) captureByteTimeMap();
    io->growthWaitAllowed.store(true, std::memory_order_relaxed);
    int ret = av_read_frame(fmtCtx_, pkt);
    io->growthWaitAllowed.store(false, std::memory_order_relaxed);
    if (io->growthInterrupted) {
        io->growthInterrupted = false;
        growthResyncPending_ = true;
        if (ret >= 0) av_packet_unref(pkt);
        return AVERROR_EXIT;
    }
    return ret;
}

int Demuxer::growthRefreshOnStructuralEof() {
    std::shared_ptr<LocalFileIO> io = localIO_;
    if (!io || !fmtCtx_ || !fmtCtx_->pb || abortIO_.load()) return 0;
    constexpr int64_t kRefreshSlack = 64 * 1024;
    auto aborted = [&] { return abortIO_.load() || io->abortRequested.load(); };
    int64_t waitStartUs = 0;
    SourceGrowthPub* pub = growthPub_.get();
    auto leaveWait = [&] { if (waitStartUs) pub->waitingSinceUs.store(0, std::memory_order_relaxed); };
    for (;;) {
        if (aborted()) { leaveWait(); return AVERROR_EXIT; }
        if (io->growthYield && *io->growthYield && (*io->growthYield)()) { leaveWait(); return AVERROR_EXIT; }
        struct stat sb {};
        int statErrno = 0;
        std::string path;
        bool aria2 = false;
        const int64_t mono = spNowUs();
        const bool wantPath = spGrowthWantPath(io.get(), mono);
        if (!spLocalIOStat(io.get(), wantPath, &sb, &statErrno, &path, &aria2)) { leaveWait(); return AVERROR_EXIT; }
        if (statErrno) { leaveWait(); return 0; }
        const spgrow::FileStamp now = spStampOf(sb);
        auto mode = (spgrow::Mode)io->growthMode.load(std::memory_order_relaxed);
        if ((mode == spgrow::Mode::Static || mode == spgrow::Mode::Probing) && now == io->growth.atOpen) { leaveWait(); return 0; }
        spGrowthObserve(io.get(), sb, mono, wantPath, path, aria2);
        const int64_t consumed = avio_tell(fmtCtx_->pb);
        if (mode == spgrow::Mode::Static || mode == spgrow::Mode::Probing) {
            mode = spgrow::Mode::Growing;
            spSetGrowthMode(io.get(), pub, mode);
            io->growth.lastUs = mono;
        }
        spGrowthAdoptSize(io.get(), sb);

        const bool inPlace = io->growth.inPlaceFill || now.size == io->growth.atOpen.size;
        bool pendingAtStop = false;
        bool worthReopen = now.size - consumed > kRefreshSlack;
        if (worthReopen && inPlace) {
            const int still = spPendingZeroStill(io.get(), consumed, 16);
            if (still < 0) { leaveWait(); return AVERROR_EXIT; }
            pendingAtStop = still == 1;
            worthReopen = !pendingAtStop && !(refreshTriedAt_ == consumed && refreshTriedSize_ == now.size &&
                                              refreshTriedMtimeNs_ == now.mtimeNs);
        }
        if (worthReopen) {
            leaveWait();
            refreshTriedAt_ = consumed;
            refreshTriedSize_ = now.size;
            refreshTriedMtimeNs_ = now.mtimeNs;
            const bool ok = reopenInPlace({}, false, "增长文件：刷新容器结构");
            if (spDebug())
                fprintf(stderr, "[Grow] 容器结构性 EOF @%lld，文件已到 %lld：原地重开%s\n", (long long)consumed,
                        (long long)now.size, ok ? "续上" : inPlace ? "失败，等下一次写入再试" : "失败，按结束处理");
            if (ok) return 1;
            if (!inPlace) return 0;
            pendingAtStop = true;
        } else if (inPlace && !pendingAtStop) {
            pendingAtStop = true;
        }
        spgrow::Inputs in;
        in.mode = mode;
        in.atOpen = io->growth.atOpen;
        in.now = now;
        in.readPos = now.size;
        in.inPlaceFill = io->growth.inPlaceFill;
        in.openWallNs = io->growth.openWallNs;
        in.pendingZero = pendingAtStop;
        in.downloadHint = io->growth.hint;
        in.hadDownloadHint = io->growth.hadHint;
        in.monoNowUs = mono;
        in.lastGrowthUs = io->growth.lastUs;
        if (mode == spgrow::Mode::Growing) in.writerOpen = spGrowthWriterOpen(io.get(), mono);
        const spgrow::Decision d = spgrow::decide(in);
        spSetGrowthMode(io.get(), pub, d.mode);
        if (d.action != spgrow::Action::Wait) { leaveWait(); return 0; }
        if (!waitStartUs) {
            waitStartUs = mono;
            pub->waitingSinceUs.store(mono, std::memory_order_relaxed);
            if (spDebug()) fprintf(stderr, "[Grow] 容器结构性 EOF @%lld：等待写入方\n", (long long)consumed);
        }
        std::unique_lock<std::mutex> lk(io->growthMtx);
        io->growthCv.wait_for(lk, std::chrono::microseconds(spgrow::kPollUs), [&] { return aborted(); });
    }
}

bool Demuxer::rereadAfterRecovery(AVPacket* pkt, int& ret) {
    av_packet_unref(pkt);
    lastGoodPos_ = -1;
    ret = readFrameGrowthAware(pkt);
    if (ret == AVERROR_EOF) { ret = markEof(); return true; }
    if (ret < 0) {
        lastReadPos_ = fmtCtx_->pb ? avio_tell(fmtCtx_->pb) : 0;
        lastReadAdvanced_ = false;
        return true;
    }
    return false;
}

int Demuxer::reopenForOpenPlanner(const std::string& path, const std::vector<spresil::Patch>& patches, bool analyze) {
    closeInputOnly();
    pendingPatches_ = patches;
    int r = openInputOnce(path, 0, 0);
    if (r == 0 && analyze) r = analyzeInputOnce();
    if (r == 0) rebuildStreamTable();
    return r;
}

bool Demuxer::reopenCandidateOrFallBack(const spresil::RecoveryPlan& plan, bool analyze, bool needDims, const char* what) {
    const std::vector<spresil::Patch> oldPatches = pendingPatches_;
    std::vector<spresil::Patch> withPlan = oldPatches;
    withPlan.insert(withPlan.end(), plan.patches.begin(), plan.patches.end());
    const int r = reopenForOpenPlanner(path_, withPlan, analyze);
    if (r == 0 && videoStream_ >= 0 && (size_t)videoStream_ < streams_.size() && (!needDims || streams_[videoStream_].width > 0)) return true;
    if (spDebug()) fprintf(stderr, "[Demux] %s候选 %s 未生效（%d）：回落原上下文\n", what, plan.kind.c_str(), r);
    const int back = reopenForOpenPlanner(path_, oldPatches, analyze);
    if (back < 0 && spDebug()) fprintf(stderr, "[Demux] %s回落重开失败（%d）\n", what, back);
    return false;
}

int Demuxer::readPacket(AVPacket* pkt) {
    if (!fmtCtx_) return AVERROR(EINVAL);
    lastPacketReplay_ = false;
    lastPacketAllZero_ = false;
    lastPacketGarbage_ = false;
    readFaultsAtRead_ = localIO_ ? localIO_->readFaults : 0;
    if (annexBTailSourceInvalid_) {
        av_packet_unref(pkt);
        return AVERROR(ESTALE); // No fresh fstat; only the fault-time check sets this latch.
    }

    const int64_t posBefore = fmtCtx_->pb ? avio_tell(fmtCtx_->pb) : 0;
    if (localIO_ && mkvLike_ && resilientRecoveryEnabled_ && !localIO_->contentSuspectEnabled && !mkvContent_.prepareFailed &&
        localIO_->contentGaps.empty() && !growthActive() && mkvContent_.jumps == 0 && !mkvContent_.prepared) {
        localIO_->contentSuspectEnabled = true;
    }
    if (mkvContent_.job) mkvContentMergeJob();
    int ret;
    if (mkvLandingCutAt_ >= 0 && localIO_) {

        localIO_->contentCutAt = mkvLandingCutAt_;
        mkvLandingCutAt_ = -1;
        mkvCutFromSeekLanding_ = true;
        ret = AVERROR_EOF;
    } else {
        ret = readFrameGrowthAware(pkt);

        if (ret >= 0 && sampleEofRetryEligible_ && !fmp4Like_ && localIO_ && resilientRecoveryEnabled_ && pkt->stream_index == videoStream_ &&
            !mkvContent_.prepareFailed && !growthActive() && (mkvContent_.prepared || mkvContentPrepare()) && mkvContent_.kind == ContentKind::Mp4) {
            if (mp4PacketGarbage(pkt)) {
                lastPacketGarbage_ = true;

                const bool beforeLanding = mkvContent_.lastJumpPos >= 0 && pkt->pos >= 0 && pkt->pos < mkvContent_.lastJumpPos;
                if (!beforeLanding && ++mkvContent_.mp4GarbageRun >= 3 && pkt->pos >= 0 && localIO_->growthMode.load(std::memory_order_relaxed) == (uint8_t)spgrow::Mode::Static) {
                    if (spDebug()) fprintf(stderr, "[Demux] 内容地图（MP4）：连续 %d 个噪声视频包（@%lld）→ 按读截断找下一孤岛\n", mkvContent_.mp4GarbageRun, (long long)pkt->pos);
                    mkvContent_.mp4GarbageRun = 0;
                    localIO_->contentCutAt = pkt->pos;
                    av_packet_unref(pkt);
                    ret = AVERROR_EOF;
                }
            } else mkvContent_.mp4GarbageRun = 0;
        }

        if (ret == AVERROR_INVALIDDATA && tsMpegTs_ && localIO_ && resilientRecoveryEnabled_ && !growthActive() && fmtCtx_->pb &&
            localIO_->growthMode.load(std::memory_order_relaxed) == (uint8_t)spgrow::Mode::Static) {
            const int64_t at = avio_tell(fmtCtx_->pb);
            if (at >= 0 && !tsSyncAtPos(at)) {
                mkvContent_.evidence = true;
                localIO_->contentCutAt = at;
                if (spDebug()) fprintf(stderr, "[Demux] 内容地图（TS）：读错误处 @%lld 没有同步串（噪声区）→ 按读截断找下一孤岛\n", (long long)at);
                ret = AVERROR_EOF;
            }
        }
    }
    if (localIO_) {
        if (ret >= 0) localIO_->bytesSinceDeliver = 0;
        else {

            for (int hops = 0; hops < 4 && ret == AVERROR_EOF && (localIO_->contentCutAt >= 0 || localIO_->contentSuspectAt >= 0) &&
                               !abortIO_.load(); ++hops) {
                if (!mkvContentJumpAfterCut(pkt, ret)) break;
            }
            if (ret >= 0) localIO_->bytesSinceDeliver = 0;
        }
    }

    const bool growthTail = growthActive();
    if ((ret == AVERROR_INVALIDDATA || ret == AVERROR_EOF) && !growthTail)
        attemptAnnexBTailDrain(pkt, ret);
    if (ret == AVERROR_EOF && sampleEofRetryEligible_) {

        int consecutive = 0;
        int budget = 8;
        while (ret == AVERROR_EOF && consecutive < budget && sampleEofRetriesTotal_ < 65536 && !abortIO_.load()) {
            ++consecutive;
            ++sampleEofRetriesTotal_;
            ret = readFrameGrowthAware(pkt);

            if (ret == AVERROR_EOF && consecutive == 8 && budget == 8 && resilientRecoveryEnabled_ && localIO_ && lastGoodPos_ >= 0) {

                const int64_t fsz = localIO_->size;
                int64_t later = 0, beyond = 0;
                for (unsigned si = 0; si < fmtCtx_->nb_streams && later < 200000; ++si) {
                    const AVStream* st = fmtCtx_->streams[si];
                    if (st->discard == AVDISCARD_ALL) continue;
                    const int cnt = avformat_index_get_entries_count(st);
                    for (int k = 0; k < cnt && later < 200000; ++k) {
                        const AVIndexEntry* e = avformat_index_get_entry(const_cast<AVStream*>(st), k);
                        if (!e || e->pos < lastGoodPos_) continue;
                        if (e->pos + e->size <= fsz) ++later;
                        else ++beyond;
                    }
                }
                if (beyond > 0 && !growthActive()) demuxDamageEvidence_.store(true, std::memory_order_relaxed);
                if (later > 0) {
                    budget = 8 + (int)std::min<int64_t>(later, 8192);
                    if (spDebug()) fprintf(stderr, "[Demux] 样本级 EOF 连续 8 次：索引里最近交付位置之后仍有 %lld 个在文件内的样本 → 继续重试（预算 %d）\n", (long long)later, budget);
                }
            }
        }
        if (ret >= 0) {
            sampleEofSkips_ += consecutive;
            if (sampleEofSkipsLogged_ < 3) {
                ++sampleEofSkipsLogged_;
                fprintf(stderr, "[Demux] 样本级 EOF 越过 %d 个越界样本后继续（累计 %d）\n", consecutive, sampleEofSkips_);
            }
        }
    }

    if (ret == AVERROR_EOF && resilientRecoveryEnabled_ && !abortIO_.load() && !growthActive() && attemptEarlyEofRecovery()) {
        ret = readFrameGrowthAware(pkt);
    }

    if (ret == AVERROR_EOF && resilientRecoveryEnabled_ && lastGoodAbsUs_ < 0 && !abortIO_.load() && !growthActive() &&
        attemptVideoTrackIsolation()) {
        ret = readFrameGrowthAware(pkt);
    }

    if (ret == AVERROR_EOF && resilientRecoveryEnabled_ && localIO_ && localIO_->size > 0 && !abortIO_.load() && !growthActive() &&
        ((tsMpegTs_ && (attemptTsTransportRecovery(localIO_->size, true) || attemptTsAdtsRecovery(localIO_->size, true) || attemptTsPesHeaderRecovery(localIO_->size, true))) ||
         (asfLike_ && attemptAsfObjectRecovery(localIO_->size, true)))) {
        ret = readFrameGrowthAware(pkt);
    }
    if (ret == AVERROR_EOF) {

        const int g = growthRefreshOnStructuralEof();
        if (g == AVERROR_EXIT) return AVERROR_EXIT;
        if (g > 0) ret = readFrameGrowthAware(pkt);
        if (ret == AVERROR_EOF) return markEof();
    }
    if (ret < 0) {

        if (ret == AVERROR_EXIT) return ret;
        const int64_t posAfter = fmtCtx_->pb ? avio_tell(fmtCtx_->pb) : posBefore;
        lastReadAdvanced_ = posAfter > posBefore;
        lastReadPos_ = posAfter;

        if (resilientRecoveryEnabled_ && !abortIO_.load() &&
            (attemptReadErrorRecovery(ret, posBefore, posAfter) || (lastGoodAbsUs_ < 0 && attemptVideoTrackIsolation()))) {
            ret = readFrameGrowthAware(pkt);
            if (ret == AVERROR_EOF) return markEof();
            if (ret < 0) {
                lastReadPos_ = fmtCtx_->pb ? avio_tell(fmtCtx_->pb) : posAfter;
                lastReadAdvanced_ = lastReadPos_ > posAfter;
                return ret;
            }
        } else {
            return ret;
        }
    }

    if (resilientRecoveryEnabled_ && gapRecoveryEligible_ && lastGoodPos_ > 0 && pkt->pos > 0 &&
        pkt->pos - lastGoodPos_ >= gapThresholdBytes_ && !abortIO_.load()) {
        const int64_t gapFrom = lastGoodPos_, gapTo = pkt->pos;

        if (!gapIsLegalSkippedData(gapFrom, gapTo) && recoverRegion(gapFrom, gapTo, "交付跳跃")) {
            if (rereadAfterRecovery(pkt, ret)) return ret;
        }
    }

    if ((fmp4Like_ || (mp4WindowReopens_ < 2 && mp4WindowAttempts_ < 8)) && sampleEofRetryEligible_ && resilientRecoveryEnabled_ && pkt->stream_index == videoStream_ &&
        pkt->size > 0 && pkt->data && (fmp4Like_ ? fmp4RealignAttempts_ < 16 : true) && !abortIO_.load()) {
        if (!fmp4LayoutReady_) {
            const AVCodecParameters* vp = fmtCtx_->streams[videoStream_]->codecpar;
            fmp4VideoLayout_ = spresil::classifyLayout(vp->codec_id == AV_CODEC_ID_H264, vp->codec_id == AV_CODEC_ID_HEVC,
                                                       vp->codec_id == AV_CODEC_ID_AV1, false, vp->extradata, vp->extradata_size);
            fmp4LayoutReady_ = true;
        }
        if (fmp4VideoLayout_.kind == spresil::Bitstream::LengthPrefixed) {
            const spresil::PacketInspection pi =
                spresil::inspectLengthPrefixed(pkt->data, (size_t)pkt->size, fmp4VideoLayout_.nalLengthSize, fmp4VideoLayout_.hevc);
            const bool intact = pi.structure == spresil::PacketStructure::Intact;
            if (intact) fmp4BrokenRun_ = 0; else ++fmp4BrokenRun_;
            mp4BrokenHistory_ = (uint8_t)((mp4BrokenHistory_ << 1) | (intact ? 0 : 1));

            const bool fire = fmp4Like_ ? fmp4BrokenRun_ == 3 : __builtin_popcount(mp4BrokenHistory_) >= 1;
            if (fire) {
                fmp4BrokenRun_ = 0;
                mp4BrokenHistory_ = 0;
                if (fmp4Like_ ? attemptFmp4RealignRecovery(pkt->pos) : attemptMp4SampleTableRecovery(pkt->pos)) {
                    if (rereadAfterRecovery(pkt, ret)) return ret;
                }
            }
        }
    }

    if (psLike_ && resilientRecoveryEnabled_ && localIO_ && localIO_->fd >= 0 && pkt->stream_index == videoStream_ && pkt->pos >= 0 &&
        psPesAttempts_ < 16 && !abortIO_.load()) {
        const int64_t fsz = localIO_->size;
        const spresil::Reader raw = localRawReader();
        const spresil::Reader rd = localIO_->patches.empty() ? raw : spresil::patchedReader(raw, localIO_->patches);
        const int64_t q = (psLastCheckedPos_ >= 0 && psLastCheckedPos_ < pkt->pos) ? psLastCheckedPos_ : pkt->pos;

        const int64_t bad = spresil::psChainFirstInconsistentPes(rd, q, pkt->pos, fsz, 256, psLaneBlock_);
        psLastCheckedPos_ = pkt->pos;
        if (bad >= 0 && attemptPsPesRecovery(bad)) {
            psLastCheckedPos_ = -1;
            if (rereadAfterRecovery(pkt, ret)) return ret;
        }
    }

    if (aviLike_ && resilientRecoveryEnabled_ && !aviChunkSizeTried_ && pkt->pos > 8 && pkt->stream_index >= 0 &&
        pkt->stream_index < (int)fmtCtx_->nb_streams && !abortIO_.load()) {
        AVStream* st = fmtCtx_->streams[pkt->stream_index];
        const int n = avformat_index_get_entries_count(st);
        if ((size_t)pkt->stream_index >= aviIdxCursor_.size()) aviIdxCursor_.resize(fmtCtx_->nb_streams, -1);
        int& cur = aviIdxCursor_[pkt->stream_index];
        const int64_t hdrPos = pkt->pos - 8;
        if (cur < 0 && n > 0) {

            const int64_t ts = pkt->dts != AV_NOPTS_VALUE ? pkt->dts : pkt->pts;
            int i = ts != AV_NOPTS_VALUE ? av_index_search_timestamp(st, ts, AVSEEK_FLAG_ANY) : 0;
            if (i < 0) i = 0;
            for (int k = std::max(0, i - 64); k < std::min(n, i + 64); ++k) {
                const AVIndexEntry* e = avformat_index_get_entry(st, k);
                if (e && (e->pos == hdrPos || e->pos == pkt->pos)) { cur = k; break; }
            }
        }
        bool contradiction = false; int64_t lostTsUs = -1; std::string why;
        if (cur >= 0 && cur < n) {
            const AVIndexEntry* e = avformat_index_get_entry(st, cur);
            if (e && (e->pos == hdrPos || e->pos == pkt->pos)) {
                if (e->size > 0 && e->size != pkt->size) { contradiction = true; why = "同位置长度不同（索引 " + std::to_string(e->size) + " vs 包 " + std::to_string(pkt->size) + "）"; }
                ++cur;
            } else if (e && e->pos < hdrPos) {
                contradiction = true;
                lostTsUs = av_rescale_q(e->timestamp, st->time_base, AV_TIME_BASE_Q);
                why = "索引条目@" + std::to_string(e->pos) + " 未交付（本包@" + std::to_string(hdrPos) + "）";
                cur = -1;
            }
        }
        if (contradiction) {
            aviChunkSizeTried_ = true;
            demuxDamageEvidence_.store(true, std::memory_order_relaxed);
            if (attemptAviChunkSizeRecovery(lostTsUs, why)) {
                if (rereadAfterRecovery(pkt, ret)) return ret;
            }
        }
    }

    if (asfLike_ && resilientRecoveryEnabled_ && localIO_ && localIO_->fd >= 0 && pkt->pos >= 0 && pkt->pos != asfLastCheckedPacketPos_ &&
        pkt->pos >= asfCountScannedUntil_ && fmtCtx_->packet_size > 0 && fmtCtx_->packet_size <= 65536 && !abortIO_.load()) {
        const int64_t psz = fmtCtx_->packet_size;

        int64_t contradictionAt = -1;
        const int64_t gapFrom = std::max(asfLastCheckedPacketPos_ >= 0 ? asfLastCheckedPacketPos_ + psz : -1, asfCountScannedUntil_);

        if (gapFrom >= 0 && pkt->pos > gapFrom && pkt->pos - gapFrom <= scanCap(64ll * 1024 * 1024)) {
            spresil::RecoveryPlan gap;
            const int64_t from = gapFrom;
            withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
                gap = spresil::planAsfPayloadCounts(rd, size, from, pkt->pos - from, &abortFn_, nullptr);
            });
            if (!gap.empty()) contradictionAt = gap.damagedFrom;
        }
        asfLastCheckedPacketPos_ = pkt->pos;
        asfLastDeliveredPos_ = std::max(asfLastDeliveredPos_, pkt->pos);
        std::set<int> sids;
        for (unsigned i = 0; i < fmtCtx_->nb_streams; ++i) sids.insert(fmtCtx_->streams[i]->id & 0x7f);
        std::vector<uint8_t> buf((size_t)psz);
        const spresil::Reader raw = localRawReader();
        const spresil::Reader rd = localIO_->patches.empty() ? raw : spresil::patchedReader(raw, localIO_->patches);
        if (contradictionAt < 0 && rd(pkt->pos, buf.data(), buf.size()) == (int64_t)buf.size()) {
            const spresil::AsfPacketInfo pi = spresil::asfParsePacket(buf.data(), buf.size(), sids);
            if (pi.ok && pi.countPos >= 0 && pi.actual != pi.declared) contradictionAt = pkt->pos;
        }
        if (contradictionAt >= 0) {
            if (attemptAsfPayloadCountRecovery(contradictionAt)) {
                if (rereadAfterRecovery(pkt, ret)) return ret;
            }
        }
    }

    if (tsMpegTs_ && resilientRecoveryEnabled_ && localIO_ && localIO_->fd >= 0 && pkt->pos >= 0 && tsHdrAttempts_ < 8 && !abortIO_.load() &&
        (videoStream_ < 0 || pkt->stream_index == videoStream_) && attemptTsTransportRecovery(pkt->pos)) {
        if (rereadAfterRecovery(pkt, ret)) return ret;
    }

    if (resilientRecoveryEnabled_ && localIO_ && localIO_->fd >= 0 && !abortIO_.load()) {
        bool recovered = false;
        const int64_t errPos = audioErrPosMailbox_.exchange(-1, std::memory_order_relaxed);
        if (errPos >= 0 && attemptMkvFlacLacingRecovery(errPos)) recovered = true;
        else if (rawAudioLike_ && pkt->pos >= 0 && attemptRawAudioFrameRecovery(pkt->pos)) recovered = true;
        else if (tsMpegTs_ && pkt->pos >= 0 && (videoStream_ < 0 || pkt->stream_index == videoStream_) && attemptTsAdtsRecovery(pkt->pos)) recovered = true;
        else if (flvLike_ && pkt->pos >= 0 && attemptFlvAvcSubtypeRecovery(pkt->pos)) recovered = true;
        else if (fmp4Like_ && sampleEofRetryEligible_ && pkt->pos >= 0 && attemptFmp4FragmentCheck(pkt->pos)) recovered = true;

        else if (asfLike_ && pkt->pos >= 0 && attemptAsfObjectRecovery(pkt->pos)) recovered = true;
        else if (tsMpegTs_ && pkt->pos >= 0 && (videoStream_ < 0 || pkt->stream_index == videoStream_) && attemptTsPesHeaderRecovery(pkt->pos)) recovered = true;
        if (recovered) {
            if (rereadAfterRecovery(pkt, ret)) return ret;
        }
    }

    if (cttsTrial_ && cttsTrial_->done.load(std::memory_order_acquire) && applyMp4CttsTrial()) {
        if (rereadAfterRecovery(pkt, ret)) return ret;
    }

    if ((psLike_ || container_ == "mpegvideo") && resilientRecoveryEnabled_ && !mpeg2SeqChecked_ && pkt->stream_index == videoStream_ &&
        pkt->size >= 12 && pkt->data && !abortIO_.load()) {
        const AVCodecID cid = fmtCtx_->streams[videoStream_]->codecpar->codec_id;
        if (cid == AV_CODEC_ID_MPEG1VIDEO || cid == AV_CODEC_ID_MPEG2VIDEO) {
            const uint8_t* d = pkt->data;
            if (d[0] == 0 && d[1] == 0 && d[2] == 1 && d[3] == 0xB3) {
                mpeg2SeqChecked_ = true;
                const uint32_t w = ((uint32_t)d[4] << 4) | (d[5] >> 4), h = ((uint32_t)(d[5] & 0x0F) << 8) | d[6];
                if (w == 0 || h == 0) attemptMpeg2SeqHeaderFix(pkt);
            } else if (++mpeg2VideoPktsSeen_ >= 8) {
                mpeg2SeqChecked_ = true;
            }
        } else {
            mpeg2SeqChecked_ = true;
        }
    }

    if (sampleEofRetryEligible_ && resilientRecoveryEnabled_ && !h264PpsChecked_ && pkt->stream_index == videoStream_ && (pkt->flags & AV_PKT_FLAG_KEY) &&
        pkt->size > 0 && pkt->data && !abortIO_.load()) {
        h264PpsChecked_ = true;
        attemptH264PpsEntropyFix(pkt);
    }

    if (flvLike_ && resilientRecoveryEnabled_ && !flvExplosionTried_ && fmtCtx_->nb_streams >= openStreamCount_ + 8 && !abortIO_.load()) {
        flvExplosionTried_ = true;
        if (attemptFlvStreamExplosionRecovery()) {
            if (rereadAfterRecovery(pkt, ret)) return ret;
        }
    }

    if (resumeVideoAnchor_.valid() && pkt->stream_index == resumeVideoAnchor_.stream) {
        // Only a proven linear MP4 timeline can use the exact already-delivered
        // anchor. Never apply a PTS <= frontier rule to reordered video.
        if (resumeVideoAnchor_.matches(pkt)) {
            pkt->flags |= AV_PKT_FLAG_DISCARD;
            lastPacketReplay_ = true;
            resumeVideoAnchor_ = {};
        } else if (pkt->pos > resumeVideoAnchor_.pos) resumeVideoAnchor_ = {};
    }
    if (sampleEofRetryEligible_ && pkt->stream_index == videoStream_)
        lastRecoveryVideoPacket_ = {pkt->pts, pkt->dts, pkt->pos, pkt->size, pkt->stream_index};
    lastGoodPos_ = fmtCtx_->pb ? avio_tell(fmtCtx_->pb) : lastGoodPos_;

    lastPacketAllZero_ = pkt->size > 0 && pkt->data && spresil::allZero(pkt->data, (size_t)pkt->size);
    if (pkt->size > 0 && pkt->data && !lastPacketAllZero_) {
        const int64_t end = pkt->pos >= 0 ? pkt->pos + pkt->size : lastGoodPos_;
        if (end > contentEndPos_) contentEndPos_ = end;
    }
    if (pkt->stream_index >= 0 && pkt->stream_index < (int)fmtCtx_->nb_streams) {
        const int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
        if (ts != AV_NOPTS_VALUE) {
            lastGoodAbsUs_ = av_rescale_q(ts, fmtCtx_->streams[pkt->stream_index]->time_base, AV_TIME_BASE_Q);
            if ((size_t)pkt->stream_index >= lastGoodAbsUsPerStream_.size())
                lastGoodAbsUsPerStream_.resize(fmtCtx_->nb_streams, -1);
            lastGoodAbsUsPerStream_[pkt->stream_index] = lastGoodAbsUs_;

            if (resumeDiscardAbsUs_ >= 0) {
                if (lastGoodAbsUs_ < resumeDiscardAbsUs_) { pkt->flags |= AV_PKT_FLAG_DISCARD; lastPacketReplay_ = true; }
                else if (lastGoodAbsUs_ >= resumeDiscardAbsUs_ + 2000000) resumeDiscardAbsUs_ = -1;
            }

            const size_t si = (size_t)pkt->stream_index;
            if (si < resumeFrontierUs_.size() && resumeFrontierUs_[si] >= 0 &&
                fmtCtx_->streams[si]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                const int64_t fr = resumeFrontierUs_[si];
                if (lastGoodAbsUs_ < fr || (lastGoodAbsUs_ == fr && pkt->pos <= resumeFrontierPos_[si])) {
                    pkt->flags |= AV_PKT_FLAG_DISCARD;
                    lastPacketReplay_ = true;
                } else if (lastGoodAbsUs_ >= fr + 2000000) {
                    resumeFrontierUs_[si] = -1;
                }
            }
        }
        if ((size_t)pkt->stream_index >= lastGoodPosPerStream_.size()) lastGoodPosPerStream_.resize(fmtCtx_->nb_streams, -1);
        lastGoodPosPerStream_[pkt->stream_index] = pkt->pos;
    }

    if (timelineOriginUs_ != 0 && pkt->stream_index >= 0 &&
        pkt->stream_index < (int)fmtCtx_->nb_streams) {

        if ((size_t)pkt->stream_index >= originOffsetCache_.size())
            originOffsetCache_.resize(fmtCtx_->nb_streams, INT64_MIN);
        int64_t& off = originOffsetCache_[pkt->stream_index];
        if (off == INT64_MIN)
            off = av_rescale_q(timelineOriginUs_, AV_TIME_BASE_Q,
                               fmtCtx_->streams[pkt->stream_index]->time_base);
        if (pkt->pts != AV_NOPTS_VALUE) pkt->pts -= off;
        if (pkt->dts != AV_NOPTS_VALUE) pkt->dts -= off;
    }

    if (tsMpegTs_ && pkt->stream_index == videoStream_ &&
        (pkt->flags & AV_PKT_FLAG_KEY) && pkt->pts != AV_NOPTS_VALUE) {
        noteTsKeyframePtsUs(av_rescale_q(pkt->pts,
                                         fmtCtx_->streams[videoStream_]->time_base,
                                         AV_TIME_BASE_Q));
    }

    const bool programsChanged = tsMpegTs_ && publishTsPcrIdentities(false);
    if (programsChanged || fmtCtx_->nb_streams != altVideoStreamsSeen_ ||
        ((tsMpegTs_ || psLike_) && streamCodecSig() != altVideoCodecSig_)) publishAltVideoCandidates();
    return 1;
}

void Demuxer::noteOpenRecovery(const std::string& kind, const std::string& text) {
    openRecovery_ = openRecovery_.empty() ? kind : openRecovery_ + "+" + kind;
    pushRecoveryEvent(text, -1, -1);
}

void Demuxer::pushRecoveryEvent(const std::string& text, int64_t fromUs, int64_t untilUs, int64_t newDurationUs) {
    if (spDebug()) fprintf(stderr, "[Demux] 恢复：%s\n", text.c_str());
    if (newDurationUs < 0 && pendingDurationUs_ >= 0) { newDurationUs = pendingDurationUs_; pendingDurationUs_ = -1; }
    std::lock_guard<std::mutex> lk(recoveryMtx_);
    if (recoveryEvents_.size() < 64) recoveryEvents_.push_back({text, fromUs, untilUs, newDurationUs});
    recoveryEventsPending_.store(true, std::memory_order_relaxed);
}

std::vector<Demuxer::RecoveryEvent> Demuxer::takeRecoveryEvents() {
    std::lock_guard<std::mutex> lk(recoveryMtx_);
    std::vector<RecoveryEvent> out;
    out.swap(recoveryEvents_);
    recoveryEventsPending_.store(false, std::memory_order_relaxed);
    return out;
}

static bool spLocalSourceAppendOnly(const LocalFileIO& io) {
    struct stat sb {};
    return io.fd >= 0 && fstat(io.fd, &sb) == 0 && S_ISREG(sb.st_mode) && sb.st_dev == io.sourceDev &&
           sb.st_ino == io.sourceIno && sb.st_size >= io.size;
}

static spresil::Reader spOpenPlanCachedReader(spresil::Reader base) {
    struct Cache {
        std::vector<uint8_t> bytes[2];
        int64_t pos[2] = {-1, -1};
        size_t len[2] = {0, 0};
        uint64_t used[2] = {0, 0}, tick = 0;
    };
    constexpr size_t kBlock = 64 * 1024;
    auto c = std::make_shared<Cache>();
    return [base = std::move(base), c](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
        if (n == 0 || n > kBlock / 2 || pos < 0) return base(pos, buf, n);
        for (int i = 0; i < 2; ++i) {
            if (c->pos[i] >= 0 && pos >= c->pos[i] && pos + (int64_t)n <= c->pos[i] + (int64_t)c->len[i]) {
                memcpy(buf, c->bytes[i].data() + (pos - c->pos[i]), n);
                c->used[i] = ++c->tick;
                return (int64_t)n;
            }
        }
        const int i = c->used[0] <= c->used[1] ? 0 : 1;
        if (c->bytes[i].size() < kBlock) c->bytes[i].resize(kBlock);
        c->pos[i] = -1;
        const int64_t got = base(pos, c->bytes[i].data(), kBlock);
        if (got < 0) return got;
        c->pos[i] = pos;
        c->len[i] = (size_t)got;
        c->used[i] = ++c->tick;
        const size_t k = std::min(n, (size_t)got);
        memcpy(buf, c->bytes[i].data(), k);
        return (int64_t)k;
    };
}

bool Demuxer::withFileReader(const std::string& path, const std::function<void(const spresil::Reader&, int64_t)>& fn,
                             bool tolerateAppend) {
    // A pathname can be replaced or renamed while recovery is running. Read the
    // inode that the playback/open transaction actually acquired, with a cursor
    // independent of both AVIO and its worker. Do not adopt changed file data.
    const bool count = spDebug();
    const auto live = localIO_;
    if (live && live->fd >= 0 && !onOpenThread()) {

        if (abortIO_.load()) return false;
        fn(abandonableReader(live, count ? &planIO_ : nullptr), live->size);
        return !abortIO_.load();
    }
    const auto source = live ? live : openingSource_;
    if (source) {

        auto sourceOk = [&] { return spLocalSourceUnchanged(*source) || (tolerateAppend && spLocalSourceAppendOnly(*source)); };
        if (abortIO_.load() || !sourceOk()) return false;
        spresil::Reader reader = [this, source, count](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
            if (abortIO_.load()) return AVERROR_EXIT;
            if (pos < 0 || n > static_cast<uint64_t>(INT64_MAX - pos)) return AVERROR(EINVAL);
            const int64_t t0 = count ? spNowUs() : 0;
            const ssize_t got = ::pread(source->fd, buf, n, static_cast<off_t>(pos));
            if (count) notePlanRead(got, spNowUs() - t0);
            return got < 0 ? static_cast<int64_t>(AVERROR(errno)) : static_cast<int64_t>(got);
        };
        fn(spOpenPlanCachedReader(std::move(reader)), source->size);
        return !abortIO_.load() && sourceOk();
    }
    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat sb {};
    if (fstat(fd, &sb) != 0 || !S_ISREG(sb.st_mode)) { ::close(fd); return false; }
    spresil::Reader reader = [this, fd, count](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
        const int64_t t0 = count ? spNowUs() : 0;
        const ssize_t got = ::pread(fd, buf, n, (off_t)pos);
        if (count) notePlanRead(got, spNowUs() - t0);
        return got < 0 ? (int64_t)AVERROR(errno) : (int64_t)got;
    };
    fn(spOpenPlanCachedReader(std::move(reader)), (int64_t)sb.st_size);
    ::close(fd);
    return true;
}

void Demuxer::noteIORead(PlanIOCounters& c, int64_t got, int64_t us) {
    c.reads.fetch_add(1, std::memory_order_relaxed);
    if (got > 0) c.bytes.fetch_add((uint64_t)got, std::memory_order_relaxed);
    if (us > 0) c.us.fetch_add((uint64_t)us, std::memory_order_relaxed);
}

Demuxer::PlanMark Demuxer::planMark() const {
    PlanMark m;
    m.reads = planIO_.reads.load(std::memory_order_relaxed);
    m.bytes = planIO_.bytes.load(std::memory_order_relaxed);
    m.us = planIO_.us.load(std::memory_order_relaxed);
    m.t0 = spNowUs();
    return m;
}

std::string Demuxer::planItem(const PlanMark& m, const char* name) {
    const PlanMark e = planMark();
    char buf[192];
    snprintf(buf, sizeof buf, "%s reads=%llu %.1fKB io=%.2fms %.2fms", name, (unsigned long long)(e.reads - m.reads),
             (e.bytes - m.bytes) / 1024.0, (e.us - m.us) / 1000.0, (e.t0 - m.t0) / 1000.0);
    std::string s = buf;
    if (!planNote_.empty()) { s += " " + planNote_; planNote_.clear(); }
    return s;
}

void Demuxer::planLog(const char* fmt, ...) const {
    char stackBuf[512];
    va_list ap;
    va_start(ap, fmt);
    const int n = vsnprintf(stackBuf, sizeof stackBuf, fmt, ap);
    va_end(ap);
    std::string line;
    if (n >= (int)sizeof stackBuf) {
        line.resize((size_t)n + 1);
        va_start(ap, fmt);
        vsnprintf(&line[0], line.size(), fmt, ap);
        va_end(ap);
        line.resize((size_t)n);
    } else if (n > 0) {
        line.assign(stackBuf, (size_t)n);
    }
    if (debugLogSink_) debugLogSink_(line.c_str());
    else fprintf(stderr, "%s\n", line.c_str());
}

int64_t Demuxer::recoverySeekTargetUs() const {
    int64_t t = -1;

    for (int idx : {videoStream_, audioStream_}) {
        if (idx < 0 || (size_t)idx >= lastGoodAbsUsPerStream_.size()) continue;
        const int64_t v = lastGoodAbsUsPerStream_[(size_t)idx];
        if (v < 0) continue;
        if (fmtCtx_ && (unsigned)idx < fmtCtx_->nb_streams && fmtCtx_->streams[idx]->discard == AVDISCARD_ALL) continue;
        if (t < 0 || v < t) t = v;
    }
    if (t >= 0) return t;
    for (size_t i = 0; i < lastGoodAbsUsPerStream_.size(); ++i) {
        const int64_t v = lastGoodAbsUsPerStream_[i];
        if (v < 0) continue;
        if (fmtCtx_ && i < fmtCtx_->nb_streams && fmtCtx_->streams[i]->discard == AVDISCARD_ALL) continue;
        if (t < 0 || v < t) t = v;
    }
    return t >= 0 ? t : lastGoodAbsUs_;
}

void Demuxer::armResumeDiscard(int64_t target) {
    resumeVideoAnchor_ = {};
    resumeDiscardAbsUs_ = target;
    resumeFrontierUs_ = lastGoodAbsUsPerStream_;
    resumeFrontierPos_ = lastGoodPosPerStream_;
    resumeFrontierPos_.resize(resumeFrontierUs_.size(), -1);
}

int64_t Demuxer::byteToUsGuess(int64_t bytePos) const {
    const int64_t size = localIO_ ? localIO_->size : 0;
    if (bytePos < 0 || size <= 0 || durationUs_ <= 0) return -1;
    return (int64_t)((double)durationUs_ * (double)std::min(bytePos, size) / (double)size);
}

spresil::RecoveryPlan Demuxer::planOpenRecovery(const std::string& path, const std::vector<spresil::Patch>& overlay) {
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withFileReader(path, [&](const spresil::Reader& base, int64_t size) {
        const spresil::Reader read = spresil::patchedReader(base, overlay);
        if (openDiag_.mp4Family) {
            plan = spresil::planMp4MdatTailMoov(read, size, &abortFn_);
            if (plan.empty()) plan = spresil::planMp4TableCounts(read, size, &abortFn_);
            if (plan.empty()) plan = spresil::planMp4IsolateBadTrak(read, size, &abortFn_);
            if (plan.empty()) plan = spresil::planFmp4Chain(read, size, &abortFn_);
            if (plan.empty() && !openDiag_.sawMoof) plan = spresil::planMp4CarveFrames(read, size, &abortFn_);
            if (plan.empty() && !openDiag_.sawMoof) {
                const auto view = captureOpeningReadSourceView(overlay);
                if (view) {
                    auto inferred = sptrial::planMp4InferredRecovery(view, &abortFn_);
                    if (inferred.status == sptrial::Mp4InferredStatus::Ready && view.current() && !abortFn_())
                        plan = std::move(inferred.plan);
                }
            }
            if (!plan.empty()) return;
        }

        plan = spresil::planMp4ZeroHeadTailMoov(read, size, &abortFn_);
        if (!plan.empty()) return;
        uint8_t head[16] = {0};
        if (read(0, head, 16) == 4 + 12 && memcmp(head, "OggS", 4) == 0) {
            plan = spresil::planOggCrc(read, size, 0, 4ll * 1024 * 1024, &abortFn_);
            if (!plan.empty()) return;
        }
        // The weak-probe gate can reject damaged raw audio before the ordinary
        // post-open recovery pass. Reuse only the stored-CRC-proven AC3/EAC3
        // planner here; a signature or suffix alone never authorizes admission.
        if (head[0] == 0x0b && head[1] == 0x77) {
            plan = spresil::planRawAudioFrames(read, size, 0, 1ll << 20, false, &abortFn_, nullptr);
            if (!plan.empty()) return;
        }
        if (memcmp(head, spresil::kAsfHeaderGuid.data(), 16) == 0) {
            plan = spresil::planAsfPacketGeometry(read, size, &abortFn_);
            if (!plan.empty()) return;
        }
        plan = spresil::planFixedHeader(read, size);
    });
    if (spDebug()) {
        fprintf(stderr, "[Demux] 打开失败候选计划 %.1fms: %s\n", (spNowUs() - t0) / 1000.0,
                plan.empty() ? "无" : plan.kind.c_str());
    }
    return plan;
}

bool Demuxer::tryFixedHeaderReopenAfterMisdetect(const std::string& path) {
    spresil::RecoveryPlan plan;
    withFileReader(path, [&](const spresil::Reader& read, int64_t size) { plan = spresil::planFixedHeader(read, size); });
    if (plan.empty()) return false;
    const std::string rawName = fmtCtx_ && fmtCtx_->iformat && fmtCtx_->iformat->name ? fmtCtx_->iformat->name : "?";
    closeInputOnly();
    pendingPatches_ = plan.patches;
    const int64_t t0 = spNowUs();
    int r = openInputOnce(path, 0, 0);
    const bool stillRaw = r == 0 && fmtCtx_->iformat && fmtCtx_->iformat->name && spresil::isRawFormatName(fmtCtx_->iformat->name);
    if (r < 0 || stillRaw) {
        if (spDebug()) fprintf(stderr, "[Demux] 误识别纠正 %s 未生效（%d，仍裸流=%d）：回落 %s\n", plan.kind.c_str(), r, (int)stillRaw, rawName.c_str());
        closeInputOnly();
        pendingPatches_.clear();
        const int back = openInputOnce(path, 0, 0);
        if (back < 0 && spDebug()) fprintf(stderr, "[Demux] 误识别纠正回落重开失败（%d）\n", back);
        return false;
    }
    openRecovery_ = plan.kind;
    pushRecoveryEvent("裸流误识别纠正（" + rawName + " → " + std::string(fmtCtx_->iformat->name) + "）" + plan.kind + "：" +
                          plan.detail + "（" + std::to_string((spNowUs() - t0) / 1000) + "ms）",
                      -1, -1);
    return true;
}

bool Demuxer::tryNoPlayableTrackReopen(const std::string& path, bool analyze) {
    diagnoseOpenFailure(path);
    if (!openDiag_.mp4Family) return false;
    const std::vector<spresil::Patch> none;
    spresil::RecoveryPlan plan = planOpenRecovery(path, none);
    if (plan.empty()) return false;
    auto reopen = [&](bool withPatches) -> int {
        return reopenForOpenPlanner(path, withPatches ? plan.patches : std::vector<spresil::Patch>{}, analyze);
    };
    const int64_t t0 = spNowUs();
    const int r = reopen(true);
    if (r < 0 || (videoStream_ < 0 && audioStream_ < 0)) {
        if (spDebug()) fprintf(stderr, "[Demux] 无可播轨候选 %s 未生效（%d，轨 v=%d a=%d）：回落原上下文\n", plan.kind.c_str(), r, videoStream_, audioStream_);
        const int back = reopen(false);
        if (back < 0 && spDebug()) fprintf(stderr, "[Demux] 无可播轨回落重开失败（%d）\n", back);
        return false;
    }
    openRecovery_ = plan.kind;
    pushRecoveryEvent("打开成功但无可播轨，候选恢复 " + plan.kind + "：" + plan.detail + "（" + std::to_string((spNowUs() - t0) / 1000) + "ms）", -1, -1);
    if (spDebug()) fprintf(stderr, "[Demux] 无可播轨候选 %s 生效 %.1fms：v=%d a=%d %s\n", plan.kind.c_str(), (spNowUs() - t0) / 1000.0, videoStream_, audioStream_, plan.detail.c_str());
    return true;
}

bool Demuxer::attemptFlvStreamExplosionRecovery() {
    if (!fmtCtx_ || !localIO_) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) { plan = spresil::planFlvDataSize(read, fsz, &abortFn_); });
    if (spDebug()) {
        fprintf(stderr, "[Demux] FLV 流数 %u（打开时 %u）伪轨污染候选计划 %.1fms: %s %s\n", fmtCtx_->nb_streams, openStreamCount_,
                (spNowUs() - t0) / 1000.0, plan.empty() ? "无" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    const int64_t evFrom = byteToUsGuess(plan.damagedFrom), evUntil = byteToUsGuess(plan.damagedUntil);
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str(), true)) return false;
    pushRecoveryEvent("FLV 伪轨污染候选恢复 " + plan.kind + "：" + plan.detail, evFrom, evUntil);
    return true;
}

void Demuxer::invalidateAvioBuffer() {
    if (fmtCtx_ && fmtCtx_->pb) avio_flush(fmtCtx_->pb);
}

bool Demuxer::reopenInPlace(const std::vector<spresil::Patch>& patches, bool flvIgnorePrevTag, const char* why, bool allowFewerStreams,
                            bool allowParamChange, int64_t targetOverrideUs, bool boundedCandidate,
                            bool linearPresentationTimeline) {
    resumeVideoAnchor_ = {};
    if (!fmtCtx_) return false;
    dropSeekPushback();
    RecoveryVideoPacket candidateAnchor;
    if (boundedCandidate && linearPresentationTimeline && lastRecoveryVideoPacket_.valid()) {
        candidateAnchor = lastRecoveryVideoPacket_;
        for (const auto& patch : patches) {
            if (patch.offset < 0 || patch.bytes.size() > static_cast<uint64_t>(INT64_MAX - patch.offset) ||
                (patch.offset < candidateAnchor.pos + candidateAnchor.size &&
                 patch.offset + static_cast<int64_t>(patch.bytes.size()) > candidateAnchor.pos)) {
                candidateAnchor = {}; break;
            }
        }
    }
    const int64_t target = targetOverrideUs >= 0 ? targetOverrideUs : recoverySeekTargetUs();
    AVFormatContext* oldCtx = fmtCtx_;
    AVIOContext* oldAvio = avio_;
    const bool oldStreamInfoAttempted = streamInfoAttempted_;
    const int oldStreamInfoResult = streamInfoResult_;
    auto oldIo = ioSnapshot();
    std::vector<spresil::Patch> oldPatches, candidatePatches;
    std::vector<int64_t> nextFrontierUs, nextFrontierPos;
    try {
        if (oldIo) oldPatches = oldIo->patches.list();
        candidatePatches = oldPatches;
        candidatePatches.insert(candidatePatches.end(), patches.begin(), patches.end());
        retiredCtx_.reserve(retiredCtx_.size() + 1);
        if (target >= 0) {
            nextFrontierUs = lastGoodAbsUsPerStream_;
            nextFrontierPos = lastGoodPosPerStream_;
            nextFrontierPos.resize(nextFrontierUs.size(), -1);
        }
    } catch (const std::bad_alloc&) { return false; }
    const bool oldFlv = pendingFlvIgnorePrevTag_;
    const bool oldAnalyzed = analyzed_, oldRemote = remoteVolume_;
    std::unique_ptr<sptrial::SourceInput> sourceBudget; // must outlive rollback close
    bool committed = false;
    auto rollback = [&] {
        if (committed) return;
        closeInputOnly();
        fmtCtx_ = oldCtx; avio_ = oldAvio;
        streamInfoAttempted_ = oldStreamInfoAttempted; streamInfoResult_ = oldStreamInfoResult;
        analyzed_ = oldAnalyzed; remoteVolume_ = oldRemote;
        { std::lock_guard<std::mutex> lk(ioMtx_); localIO_ = oldIo; }
        pendingPatches_ = std::move(oldPatches);
        pendingFlvIgnorePrevTag_ = oldFlv;
        publishAltVideoCandidates();
    };
    struct Rollback { decltype(rollback)& action; ~Rollback() { action(); } } guard{rollback};

    markAltVideoReopening();
    { std::lock_guard<std::mutex> lk(ioMtx_); localIO_.reset(); }
    fmtCtx_ = nullptr; avio_ = nullptr;
    pendingPatches_ = std::move(candidatePatches);
    pendingFlvIgnorePrevTag_ = oldFlv || flvIgnorePrevTag;
    const int64_t t0 = spNowUs();
    try {
    int r = openInputOnce(path_, 0, 0, oldIo, boundedCandidate ? &sourceBudget : nullptr,
                          boundedCandidate ? sptrial::monotonicNowUs() + 500000 : 0);
    if (r == 0 && analyzed_) {
        r = analyzeInputOnce();
    }
    bool ok = r == 0 && fmtCtx_ && (!oldIo || spLocalSourceUnchanged(*oldIo)) &&
        (allowFewerStreams || fmtCtx_->nb_streams >= oldCtx->nb_streams);
    std::string mismatch;
    for (unsigned i = 0; ok && i < oldCtx->nb_streams; ++i) {
        if (allowFewerStreams) {

            const bool selected = (int)i == videoStream_ || (int)i == audioStream_ || (int)i == subtitleStream_;
            if (!selected) continue;
            if (i >= fmtCtx_->nb_streams) { ok = false; mismatch = "已选流#" + std::to_string(i) + " 不在候选里"; break; }
        }
        const AVCodecParameters* a = oldCtx->streams[i]->codecpar;
        const AVCodecParameters* b = fmtCtx_->streams[i]->codecpar;

        if ((a->codec_type != b->codec_type || a->codec_id != b->codec_id) && !allowParamChange) {
            ok = false;
            mismatch = "流#" + std::to_string(i) + " 类型/编码 " + std::to_string(a->codec_type) + "/" + std::to_string(a->codec_id) +
                       " vs " + std::to_string(b->codec_type) + "/" + std::to_string(b->codec_id);
        }
        if (!allowParamChange && (oldCtx->streams[i]->time_base.num != fmtCtx_->streams[i]->time_base.num ||
                                  oldCtx->streams[i]->time_base.den != fmtCtx_->streams[i]->time_base.den)) {
            ok = false;
            mismatch = "流#" + std::to_string(i) + " 时基不同";
        }
    }
    // Replay is part of the candidate transaction. A candidate that cannot
    // resume at the delivery frontier must not retire the working context.
    int sret = -1;
    if (ok && target >= 0) {
        sret = avformat_seek_file(fmtCtx_, -1, INT64_MIN, target, target, 0);
        if (sret < 0) { ok = false; mismatch = "候选无法回到交付前沿"; }
    }
    if (ok && (abortIO_.load() || (oldIo && !spLocalSourceUnchanged(*oldIo)))) ok = false;
    if (ok && sourceBudget && !sourceBudget->usable()) ok = false;
    if (!ok) {
        if (spDebug()) {
            fprintf(stderr, "[Demux] 原地重开（%s）候选不合格 r=%d streams=%u/%u %s：保留原上下文\n", why, r,
                    fmtCtx_ ? fmtCtx_->nb_streams : 0u, oldCtx->nb_streams, mismatch.c_str());
        }
        return false;
    }
    if (sourceBudget) {
        // SourceInput's cursor is the AVIO buffer end, not avio_tell's consumed
        // position. Keep the buffered data and continue normal I/O at its end.
        localIO_->pos = sourceBudget->seek(0, SEEK_CUR);
        if (localIO_->pos < 0) return false;
        avio_->opaque = localIO_.get();
        avio_->read_packet = spLocalIORead;
        avio_->seek = spLocalIOSeek;
        fmtCtx_->interrupt_callback = {spInterruptCb, &abortIO_};
        sourceBudget.reset();
    }

    committed = true;
    oldCtx->pb = nullptr;
    if (retainRetiredCtx_) retiredCtx_.push_back(oldCtx);
    else avformat_close_input(&oldCtx);
    if (oldAvio) {
        av_freep(&oldAvio->buffer);
        avio_context_free(&oldAvio);
    }
    if (oldIo) {
        oldIo->viewAttached.store(false, std::memory_order_release);
        oldIo->abortRequested.store(true);
        {
            std::lock_guard<std::mutex> lk(oldIo->jobMtx);
            oldIo->quit = true;
            oldIo->jobPending = false;
        }
        oldIo->jobCv.notify_all();
    }
    eof_ = false;
    sampleEofRetriesTotal_ = 0;

    {
        int64_t newDur = fmtCtx_->duration != AV_NOPTS_VALUE ? fmtCtx_->duration : -1;
        if (newDur < 0) {
            for (unsigned i = 0; i < fmtCtx_->nb_streams; ++i) {
                const AVStream* st = fmtCtx_->streams[i];
                if (st->duration == AV_NOPTS_VALUE) continue;
                newDur = std::max(newDur, av_rescale_q(st->duration, st->time_base, AV_TIME_BASE_Q));
            }
        }
        if (newDur > 0 && newDur > durationUs_ + 500000) {
            durationUs_ = newDur;
            pendingDurationUs_ = newDur;
        }
    }
    if (discardApplied_) applyStreamDiscard(lastDiscardAudio_, lastDiscardSub_);
    if (videoIsolated_ && videoStream_ >= 0 && (unsigned)videoStream_ < fmtCtx_->nb_streams) fmtCtx_->streams[videoStream_]->discard = AVDISCARD_ALL;
    publishAltVideoCandidates();
    publishTsPcrIdentities(true);
    lastGoodPos_ = -1;
    if (sret >= 0) {
        resumeDiscardAbsUs_ = target;
        resumeVideoAnchor_ = candidateAnchor;
        resumeFrontierUs_.swap(nextFrontierUs);
        resumeFrontierPos_.swap(nextFrontierPos);
    }
    if (spDebug()) {
        int64_t stDur = -1;
        if (fmtCtx_->nb_streams > 0) {
            const AVStream* s0 = fmtCtx_->streams[videoStream_ >= 0 ? videoStream_ : 0];
            if (s0->duration != AV_NOPTS_VALUE) stDur = av_rescale_q(s0->duration, s0->time_base, AV_TIME_BASE_Q);
        }
        fprintf(stderr, "[Demux] 原地重开（%s）成功 %.1fms，回 seek %.2fs → %d；时长 ctx=%.2fs 流=%.2fs（原 %.2fs）\n", why,
                (spNowUs() - t0) / 1000.0, target / 1e6, sret,
                fmtCtx_->duration != AV_NOPTS_VALUE ? fmtCtx_->duration / 1e6 : -1.0, stDur / 1e6, durationUs_ / 1e6);
    }
    return true;
    } catch (const std::bad_alloc&) { return false; }
}

bool Demuxer::attemptEarlyEofRecovery() {
    if (!fmtCtx_ || !localIO_ || localIO_->size <= 0) return false;
    const int64_t size = localIO_->size;

    const int64_t anchor = asfLike_ ? std::max(asfLastDeliveredPos_, asfCountScannedUntil_) : lastGoodPos_;
    if (anchor < 0) return false;
    const int64_t remaining = size - anchor;
    if (remaining < std::max<int64_t>(64 * 1024, size / 20)) return false;
    if (earlyEofRecoveryPos_ == anchor) return false;
    earlyEofRecoveryPos_ = anchor;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    const bool flv = container_ == "flv" || container_ == "live_flv";
    const bool avi = container_ == "avi";
    const bool mov = container_.find("mov") != std::string::npos || container_.find("mp4") != std::string::npos;
    const bool ogg = container_ == "ogg";
    const bool mkv = mkvLike_;
    const bool asf = asfLike_;
    if (!flv && !avi && !mov && !ogg && !mkv && !asf) return false;
    const int64_t from = anchor;
    int64_t asfScanned = -1;
    withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
        if (asf) {

            const spresil::PatchOverlay overlay = localIO_->patches;
            plan = spresil::planAsfPayloadCounts(spresil::patchedReader(read, overlay), fsz, std::max(from, asfCountScannedUntil_), 32ll * 1024 * 1024, &abortFn_, &asfScanned);
        }
        else if (flv) {
            plan = spresil::planFlvPrevTag(read, fsz, from, &abortFn_);
            if (plan.empty()) plan = spresil::planFlvDataSize(read, fsz, &abortFn_);
        }
        else if (avi) {
            plan = spresil::planAviChunkSizes(read, fsz, &abortFn_);
            if (plan.empty()) plan = spresil::planAviIdx1(read, fsz, &abortFn_);
            if (plan.empty()) plan = spresil::planAviOdml(read, fsz, &abortFn_);
        }
        else if (mov) plan = spresil::planFmp4Chain(read, fsz, &abortFn_);
        else if (ogg) plan = spresil::planOggCrc(read, fsz, from, 16ll * 1024 * 1024, &abortFn_);
        else if (mkv) { plan.kind = "mkv-region"; }
    });
    if (mkv) {
        if (plan.kind == "mkv-region" && recoverRegion(from, size, "异常 EOF")) return true;
        return false;
    }
    if (spDebug()) {
        fprintf(stderr, "[Demux] 异常 EOF（交付到 %lld / %lld，容器 %s）候选计划 %.1fms: %s %s\n", (long long)from,
                (long long)size, container_.c_str(), (spNowUs() - t0) / 1000.0, plan.empty() ? "无" : plan.kind.c_str(),
                plan.detail.c_str());
    }
    if (asf && asfScanned > asfCountScannedUntil_) asfCountScannedUntil_ = asfScanned;
    if (plan.empty()) return false;
    const int64_t evFrom = byteToUsGuess(plan.damagedFrom), evUntil = byteToUsGuess(plan.damagedUntil);
    bool applied = false;
    if (ogg || mkv || asf) {

        if (!installPatches(plan.patches, true)) return false;
        const int64_t target = recoverySeekTargetUs();
        dropSeekPushback();
        const int sret = target >= 0 ? avformat_seek_file(fmtCtx_, -1, INT64_MIN, target, target, 0) : -1;
        applied = sret >= 0;
        if (spDebug()) fprintf(stderr, "[Demux] 补丁 %zu 处已装入，回 seek %.2fs → %d\n", plan.patches.size(), target / 1e6, sret);
        if (applied) { eof_ = false; lastGoodPos_ = -1; armResumeDiscard(target); }
    } else {
        applied = reopenInPlace(plan.patches, plan.flvIgnorePrevTag, plan.kind.c_str());
    }
    if (applied) {
        pushRecoveryEvent("异常 EOF 候选恢复 " + plan.kind + "：" + plan.detail, evFrom, evUntil);
    }
    return applied;
}

bool Demuxer::attemptReadErrorRecovery(int err, int64_t posBefore, int64_t posAfter) {
    if (!fmtCtx_ || !localIO_ || (err != AVERROR_INVALIDDATA && err != AVERROR(EAGAIN))) return false;
    if (!gapRecoveryEligible_ || lastGoodAbsUs_ < 0) return false;
    const int64_t size = localIO_->size;
    const int64_t from = std::max<int64_t>(0, std::min(posBefore, lastGoodPos_ > 0 ? lastGoodPos_ : posBefore));
    const int64_t to = posAfter > from ? posAfter : std::min(size, from + 8ll * 1024 * 1024);
    if (to <= from) return false;
    return recoverRegion(from, to, "读错误");
}

namespace {
struct MkvContentYieldScope {
    MkvContentScanJob* job;
    explicit MkvContentYieldScope(MkvContentScanJob* j) : job(j) { if (job) job->yield.fetch_add(1, std::memory_order_relaxed); }
    ~MkvContentYieldScope() { if (job) job->yield.fetch_sub(1, std::memory_order_relaxed); }
};

struct ContentSearchScope {
    std::atomic<int64_t>& since;
    bool owner;
    explicit ContentSearchScope(std::atomic<int64_t>& s) : since(s), owner(s.load(std::memory_order_relaxed) == 0) {
        if (owner) since.store(spNowUs(), std::memory_order_relaxed);
    }
    ~ContentSearchScope() { if (owner) since.store(0, std::memory_order_relaxed); }
};
} // namespace

std::shared_ptr<MkvContentScanJob> Demuxer::takeMkvContentScanJob() {
    std::lock_guard<std::mutex> lk(mkvContentJobMtx_);
    mkvContentJobPending_.store(false, std::memory_order_relaxed);
    return std::move(mkvContentJobHandoff_);
}

void Demuxer::mkvContentStartJob() {
    if (mkvContent_.job || !mkvContent_.prepared || !localIO_ || growthActive()) return;
    auto job = std::make_shared<MkvContentScanJob>();
    job->path = sourceCurrentPath();
    if (job->path.empty()) job->path = path_;
    job->dev = localIO_->sourceDev;
    job->ino = localIO_->sourceIno;
    job->size = localIO_->size;
    job->remote = remoteVolume_.load(std::memory_order_relaxed);
    job->kind = (uint8_t)mkvContent_.kind;
    job->tracks = mkvContent_.tracks;
    job->videoTrack = mkvContent_.videoTrack;
    job->tsVideoPid = mkvContent_.tsVideoPid;
    job->mp4Entries = mkvContent_.mp4Entries;
    job->mp4NalLen = mkvContent_.mp4NalLen;
    job->mp4Hevc = mkvContent_.mp4Hevc;
    job->timestampScale = mkvContent_.map->timestampScale;
    job->durationUs = durationUs_.load(std::memory_order_relaxed);
    job->timelineOriginUs = timelineOriginUs_;
    job->map = std::make_shared<spresil::MkvContentMap>(*mkvContent_.map);
    mkvContent_.job = job;
    mkvContent_.mergedVersion = 0;
    {
        std::lock_guard<std::mutex> lk(mkvContentJobMtx_);
        mkvContentJobHandoff_ = job;
    }
    mkvContentJobPending_.store(true, std::memory_order_release);
    if (spDebug()) fprintf(stderr, "[Demux] 内容地图：确认无内容区，放出后台预扫任务（种子孤岛 %zu）\n", mkvContent_.map->islands.size());
}

void Demuxer::mkvContentMergeJob() {
    MkvContentScanJob* job = mkvContent_.job.get();
    if (!job || !mkvContent_.map) return;
    const uint64_t v = job->version.load(std::memory_order_acquire);
    if (v == mkvContent_.mergedVersion) return;
    spresil::MkvContentMap snap;
    {
        std::lock_guard<std::mutex> lk(job->mapMtx);
        if (job->map) snap = *job->map;
    }
    mkvContent_.mergedVersion = v;
    spresil::MkvContentMap& map = *mkvContent_.map;

    for (spresil::MkvIsland& is : snap.islands) {
        for (spresil::MkvIslandCluster& c : is.clusters) {
            if (c.keyTimecode >= 0) continue;
            const int at = map.islandAtPos(c.pos);
            if (at < 0) continue;
            for (const spresil::MkvIslandCluster& x : map.islands[(size_t)at].clusters) if (x.pos == c.pos) { c.keyTimecode = x.keyTimecode; break; }
        }
        map.insertIsland(std::move(is));
    }
    for (const auto& r : snap.scanned) map.addScanned(r.first, r.second);
    map.bytesRead = std::max(map.bytesRead, snap.bytesRead);
    if (spDebug()) fprintf(stderr, "[Demux] 内容地图：合并后台预扫第 %llu 批 → 孤岛 %zu 已扫段 %zu%s\n", (unsigned long long)v, map.islands.size(),
                           map.scanned.size(), job->done.load(std::memory_order_relaxed) ? "（预扫完成）" : "");
    mkvContentPublish();
}

void Demuxer::mkvContentCancelJob() {
    if (mkvContent_.job) mkvContent_.job->cancelled.store(true, std::memory_order_relaxed);
    mkvContent_.job.reset();
    std::lock_guard<std::mutex> lk(mkvContentJobMtx_);
    mkvContentJobHandoff_.reset();
    mkvContentJobPending_.store(false, std::memory_order_relaxed);
    contentSearchSinceUs_.store(0, std::memory_order_relaxed);
}

void spRunMkvContentScan(MkvContentScanJob& job, const std::function<void(std::vector<std::pair<int64_t, int64_t>>)>& progress) {
    if (job.cancelled.load() || !job.map) return;
    const int fd = ::open(job.path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    struct stat sb {};
    if (fstat(fd, &sb) != 0 || !S_ISREG(sb.st_mode) || sb.st_dev != job.dev || sb.st_ino != job.ino || sb.st_size != job.size) {
        ::close(fd);
        return;
    }
    const int64_t fsz = job.size;
    int64_t bytes = 0;
    const spresil::Reader read = [&](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
        for (int spins = 0; job.yield.load(std::memory_order_relaxed) > 0 && !job.cancelled.load() && spins < 3000; ++spins) usleep(10000);
        if (job.cancelled.load()) return AVERROR_EXIT;
        if (pos < 0 || n > static_cast<uint64_t>(INT64_MAX - pos)) return AVERROR(EINVAL);
        const ssize_t got = ::pread(fd, buf, n, (off_t)pos);
        if (got > 0) bytes += got;

        if (job.remote && got > 0) usleep((useconds_t)std::min<int64_t>(200000, got * 1000000 / (32ll * 1024 * 1024)));
        return got < 0 ? (int64_t)AVERROR(errno) : (int64_t)got;
    };
    spresil::MkvContentMap local;
    {
        std::lock_guard<std::mutex> lk(job.mapMtx);
        local = *job.map;
    }
    spresil::MkvContentScanParams p;
    p.videoTrack = job.videoTrack;
    const int64_t stride = std::clamp<int64_t>(fsz / 64, 256 * 1024, (job.remote ? 16ll : 8ll) * 1024 * 1024);
    p.stride = stride;
    p.probe = std::min<int64_t>(p.probe, stride / 2);
    p.clusterPrefix = 256 * 1024;
    spresil::TsContentScanParams tp;
    tp.videoPid = job.tsVideoPid;
    tp.stride = stride;
    spresil::Mp4ContentScanParams mp;
    mp.nalLen = job.mp4NalLen; mp.hevc = job.mp4Hevc;
    const spresil::AbortFn abort = [&] { return job.cancelled.load(); };
    const int64_t scale = std::max<int64_t>(1, local.timestampScale);
    const int64_t durationTc = job.durationUs > 0 ? av_rescale(job.durationUs + job.timelineOriginUs, 1000, scale) : 0;
    auto spansUs = [&]() {
        std::vector<std::pair<int64_t, int64_t>> out;
        for (const auto& sp : spresil::mkvNoContentSpans(local, fsz, durationTc)) {
            int64_t a = av_rescale(sp.first, scale, 1000) - job.timelineOriginUs;
            int64_t b = av_rescale(sp.second, scale, 1000) - job.timelineOriginUs;
            if (job.durationUs > 0) b = std::min(b, job.durationUs);
            a = std::max<int64_t>(0, a);
            if (b - a < 500000) continue;
            out.push_back({a, b});
        }
        return out;
    };
    const int64_t t0 = spNowUs();
    const int64_t kSlice = 512ll * 1024 * 1024;
    bool ok = true;
    for (int64_t pos = 0; pos < fsz && ok;) {
        if (job.cancelled.load()) { ok = false; break; }
        const int64_t to = std::min(fsz, pos + kSlice);
        switch (job.kind) {
        case 1: ok = spresil::mkvScanContent(read, fsz, pos, to, job.tracks, p, &abort, false, local); break;
        case 2: ok = spresil::tsScanContent(read, fsz, pos, to, tp, &abort, false, local); break;
        case 3: ok = job.mp4Entries && spresil::mp4ScanContent(read, fsz, pos, to, *job.mp4Entries, mp, &abort, false, local); break;
        default: ok = false; break;
        }
        pos = to;
        {
            std::lock_guard<std::mutex> lk(job.mapMtx);
            *job.map = local;
            job.bytesRead = bytes;
            job.elapsedUs = spNowUs() - t0;
        }
        if (pos >= fsz && ok) job.done.store(true, std::memory_order_release);
        job.version.fetch_add(1, std::memory_order_release);
        progress(spansUs());
    }
    ::close(fd);
    if (spDebug()) {
        fprintf(stderr, "[Demux] 内容地图：后台预扫%s %.1fs 读 %.1fMB 探测 %d 次 → 孤岛 %zu\n", ok ? "完成" : "中止", (spNowUs() - t0) / 1e6,
                bytes / 1048576.0, local.probes, local.islands.size());
    }
}

bool Demuxer::mp4PacketGarbage(const AVPacket* pkt) const {
    if (!pkt || !pkt->data || pkt->size <= 0) return false;
    if (spresil::mp4SamplePrefixValid(pkt->data, std::min<size_t>((size_t)pkt->size, 4096), pkt->size, mkvContent_.mp4NalLen, mkvContent_.mp4Hevc)) return false;

    spresil::BitstreamLayout layout;
    layout.kind = spresil::Bitstream::LengthPrefixed;
    layout.nalLengthSize = mkvContent_.mp4NalLen;
    layout.hevc = mkvContent_.mp4Hevc;
    return !spresil::deliverable(spresil::inspect(pkt->data, (size_t)pkt->size, layout));
}

bool Demuxer::tsSyncAtPos(int64_t pos) {
    bool sync = false;
    withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
        if (pos < 0 || pos >= fsz) return;
        auto w = spresil::readSpan(read, pos, (size_t)std::min<int64_t>(4096, fsz - pos));
        sync = !w.empty() && spresil::tsProbeSync(w.data(), w.size(), 16, nullptr, nullptr);
    });
    return sync;
}

int64_t Demuxer::tsIslandBisect(int64_t absUs, int64_t from, int64_t to, int streamIndex) {
    if (!fmtCtx_ || streamIndex < 0 || to <= from) return -1;
    AVStream* st = fmtCtx_->streams[streamIndex];
    AVPacket* probe = av_packet_alloc();
    if (!probe) return -1;
    auto dtsAt = [&](int64_t pos, int64_t* posOut) -> int64_t {
        if (av_seek_frame(fmtCtx_, streamIndex, pos, AVSEEK_FLAG_BYTE) < 0) return AV_NOPTS_VALUE;
        for (int n = 0; n < 64; ++n) {
            if (av_read_frame(fmtCtx_, probe) < 0) break;
            const bool ours = probe->stream_index == streamIndex;
            const int64_t d = probe->dts != AV_NOPTS_VALUE ? probe->dts : probe->pts;
            const int64_t p = probe->pos;
            av_packet_unref(probe);
            if (ours && d != AV_NOPTS_VALUE) { if (posOut) *posOut = p; return av_rescale_q(d, st->time_base, AV_TIME_BASE_Q); }
        }
        return AV_NOPTS_VALUE;
    };
    int64_t lo = from, hi = to;
    int64_t best = -1;
    int64_t loPos = -1;
    const int64_t loDts = dtsAt(lo, &loPos);
    if (loDts == AV_NOPTS_VALUE) { av_packet_free(&probe); return -1; }
    if (loDts >= absUs) { av_packet_free(&probe); return loPos >= 0 ? loPos : lo; }
    best = loPos >= 0 ? loPos : lo;
    for (int it = 0; it < 40 && hi - lo > 256 * 1024 && !abortIO_.load(); ++it) {
        const int64_t mid = lo + (hi - lo) / 2;
        int64_t mp = -1;
        const int64_t d = dtsAt(mid, &mp);
        if (d == AV_NOPTS_VALUE) { hi = mid; continue; }
        if (d <= absUs) { lo = mid; best = mp >= 0 ? mp : mid; } else hi = mid;
    }
    av_packet_free(&probe);
    return best;
}

bool Demuxer::mkvContentPrepare() {
    if (mkvContent_.prepared) return true;
    if (mkvContent_.prepareFailed || !localIO_ || !resilientRecoveryEnabled_) return false;

    mkvContent_.kind = (mkvLike_ && !tsLike_) ? ContentKind::Mkv : tsMpegTs_ ? ContentKind::Ts
                     : (sampleEofRetryEligible_ && !fmp4Like_) ? ContentKind::Mp4 : ContentKind::None;
    if (mkvContent_.kind == ContentKind::None) { mkvContent_.prepareFailed = true; return false; }
    if (mkvContent_.kind == ContentKind::Ts) {
        mkvContent_.tsVideoPid = (videoStream_ >= 0 && fmtCtx_ && (unsigned)videoStream_ < fmtCtx_->nb_streams) ? fmtCtx_->streams[videoStream_]->id : -1;
        mkvContent_.headerEnd = 0;
        if (!mkvContent_.map) mkvContent_.map = std::make_shared<spresil::MkvContentMap>();
        mkvContent_.map->timestampScale = 1000;
        mkvContent_.prepared = true;
        return true;
    }
    if (mkvContent_.kind == ContentKind::Mp4) {
        if (videoStream_ < 0 || !fmtCtx_ || (unsigned)videoStream_ >= fmtCtx_->nb_streams) { mkvContent_.prepareFailed = true; return false; }
        AVStream* st = fmtCtx_->streams[videoStream_];
        const AVCodecParameters* par = st->codecpar;
        const bool hevc = par->codec_id == AV_CODEC_ID_HEVC;
        if ((par->codec_id != AV_CODEC_ID_H264 && !hevc) || !par->extradata || par->extradata_size < 7 || par->extradata[0] != 1) {
            mkvContent_.prepareFailed = true;
            return false;
        }
        mkvContent_.mp4NalLen = hevc ? (par->extradata_size >= 23 ? (par->extradata[21] & 3) + 1 : 4) : (par->extradata[4] & 3) + 1;
        mkvContent_.mp4Hevc = hevc;
        auto entries = std::make_shared<std::vector<spresil::Mp4KeyEntry>>();
        const int n = avformat_index_get_entries_count(st);
        entries->reserve((size_t)std::max(0, n / 8));
        for (int i = 0; i < n; ++i) {
            const AVIndexEntry* e = avformat_index_get_entry(st, i);
            if (!e || !(e->flags & AVINDEX_KEYFRAME) || e->pos < 0 || e->size <= 0) continue;
            spresil::Mp4KeyEntry k;
            k.pos = e->pos; k.size = e->size; k.tsUs = av_rescale_q(e->timestamp, st->time_base, AV_TIME_BASE_Q);
            if (!entries->empty() && k.pos < entries->back().pos) { entries->clear(); break; }
            entries->push_back(k);
        }
        if (entries->size() < 2) { mkvContent_.prepareFailed = true; return false; }
        mkvContent_.headerEnd = entries->front().pos;
        mkvContent_.mp4Entries = entries;
        if (!mkvContent_.map) mkvContent_.map = std::make_shared<spresil::MkvContentMap>();
        mkvContent_.map->timestampScale = 1000;
        mkvContent_.prepared = true;
        if (spDebug()) fprintf(stderr, "[Demux] 内容地图（MP4）：关键帧样本 %zu 条\n", entries->size());
        return true;
    }
    std::vector<int> tracks;
    int videoTrack = 0;
    int64_t scale = 1000000;
    withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
        tracks = spresil::mkvReadTrackNumbers(read, fsz, &abortFn_);
        const auto decls = spresil::mkvReadTrackDecls(read, fsz, &abortFn_, nullptr);
        for (const auto& d : decls) if (d.type == 1 && d.number > 0 && videoTrack == 0) videoTrack = (int)d.number;
        scale = spresil::mkvReadTimestampScale(read, fsz);
    });
    if (tracks.empty()) { mkvContent_.prepareFailed = true; return false; }

    int64_t headerEnd = -1;
    withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
        headerEnd = spresil::mkvFindNextClusterHead(read, 0, fsz, 4ll * 1024 * 1024, &abortFn_);
    });
    mkvContent_.headerEnd = headerEnd;
    mkvContent_.tracks = tracks;
    mkvContent_.videoTrack = videoTrack;
    if (!mkvContent_.map) mkvContent_.map = std::make_shared<spresil::MkvContentMap>();
    mkvContent_.map->timestampScale = scale;
    mkvContent_.prepared = true;
    return true;
}

bool Demuxer::mkvCuesUsable() {
    if (mkvContent_.cuesChecked) return mkvContent_.cuesUsable;
    mkvContent_.cuesChecked = true;
    mkvContent_.cuesUsable = false;
    if (!localIO_) return false;
    withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
        auto head = spresil::readSpan(read, 0, (size_t)std::min<int64_t>(fsz, 256 * 1024));
        if (head.empty()) return;
        SPMatroskaCuesScan scan = spLocateMatroskaCues(head.data(), head.size(), fsz);
        if (scan.status == SPMatroskaCuesScan::Status::NeedSeekHead) {
            auto sh = spresil::readSpan(read, scan.seekHeadOffset, 64 * 1024);
            if (!sh.empty()) scan = spParseMatroskaSeekHead(sh.data(), sh.size(), scan.segmentStart, fsz);
        }
        if (scan.status != SPMatroskaCuesScan::Status::Found) return;
        auto hdr = spresil::readSpan(read, scan.cuesOffset, 32);
        const int64_t len = hdr.empty() ? -1 : spMatroskaCuesElementLength(hdr.data(), hdr.size());
        if (len > 0 && scan.cuesOffset + len <= fsz) {
            mkvContent_.cuesUsable = true;
            mkvContent_.cuesFrom = scan.cuesOffset;
            mkvContent_.cuesTo = scan.cuesOffset + len;
        }
    });
    if (spDebug()) fprintf(stderr, "[Demux] MKV Cues %s\n", mkvContent_.cuesUsable ? "可用" : "不可用（在文件外 / 无 SeekHead）：seek 前先建内容地图");
    return mkvContent_.cuesUsable;
}

bool Demuxer::mkvContentScan(int64_t from, int64_t limit, bool stopAfterIsland, const std::function<bool()>* abortFn, const char* why) {
    if (!mkvContentPrepare()) return false;
    spresil::MkvContentMap& map = *mkvContent_.map;
    spresil::MkvContentScanParams p;
    p.videoTrack = mkvContent_.videoTrack;

    const int64_t fileSize = localIO_ ? localIO_->size : 0;
    const int64_t stride = std::clamp<int64_t>(fileSize / 64, 256 * 1024, (remoteVolume_ ? 16ll : 8ll) * 1024 * 1024);
    p.stride = stride;
    p.probe = std::min<int64_t>(p.probe, stride / 2);

    p.maxIslandBytes = 64ll * 1024 * 1024;
    spresil::TsContentScanParams tp;
    tp.videoPid = mkvContent_.tsVideoPid;
    tp.stride = stride;
    spresil::Mp4ContentScanParams mp;
    mp.nalLen = mkvContent_.mp4NalLen; mp.hevc = mkvContent_.mp4Hevc;
    const spresil::AbortFn abort = [this, abortFn] { return abortIO_.load() || (abortFn && (*abortFn)()); };
    MkvContentYieldScope yield(mkvContent_.job.get());
    const int64_t t0 = spNowUs();
    const int64_t bytes0 = map.bytesRead;
    const size_t islands0 = map.islands.size();
    bool ok = false;
    withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
        switch (mkvContent_.kind) {
        case ContentKind::Mkv: ok = spresil::mkvScanContent(read, fsz, from, limit, mkvContent_.tracks, p, &abort, stopAfterIsland, map); break;
        case ContentKind::Ts: ok = spresil::tsScanContent(read, fsz, from, limit, tp, &abort, stopAfterIsland, map); break;
        case ContentKind::Mp4: ok = mkvContent_.mp4Entries && spresil::mp4ScanContent(read, fsz, from, limit, *mkvContent_.mp4Entries, mp, &abort, stopAfterIsland, map); break;
        default: break;
        }
    });
    if (spDebug() && (mkvContent_.scansLogged < 40 || !ok)) {
        ++mkvContent_.scansLogged;
        fprintf(stderr, "[Demux] 内容地图 %s：扫 [%lld, %lld)%s %.1fms 读 %.1fMB → 孤岛 %zu（+%zu）%s\n", why, (long long)from,
                (long long)limit, stopAfterIsland ? " 找到首个孤岛即停" : "", (spNowUs() - t0) / 1000.0,
                (map.bytesRead - bytes0) / 1048576.0, map.islands.size(), map.islands.size() - islands0, ok ? "" : "（中止）");
    }
    return ok;
}

void Demuxer::mkvContentPublish() {
    if (!mkvContent_.prepared || !fmtCtx_ || !localIO_) return;
    spresil::MkvContentMap& map = *mkvContent_.map;
    int si = videoStream_ >= 0 ? videoStream_ : audioStream_;
    if (si < 0 || (unsigned)si >= fmtCtx_->nb_streams) return;
    AVStream* st = fmtCtx_->streams[si];
    if (mkvContent_.indexCtx != fmtCtx_) { mkvContent_.indexCtx = fmtCtx_; mkvContent_.indexedClusters.clear(); }
    const AVRational tcq = {(int)std::min<int64_t>(map.timestampScale, INT32_MAX), 1000000000};
    auto tcToTs = [&](int64_t tc) { return av_rescale_q(tc, tcq, st->time_base); };
    int added = 0;

    if (mkvContent_.kind == ContentKind::Mkv) for (const spresil::MkvIsland& is : map.islands) {
        bool any = false;
        for (const spresil::MkvIslandCluster& c : is.clusters) {
            if (c.keyTimecode < 0) continue;
            any = true;
            auto it = std::lower_bound(mkvContent_.indexedClusters.begin(), mkvContent_.indexedClusters.end(), c.pos);
            if (it != mkvContent_.indexedClusters.end() && *it == c.pos) continue;
            mkvContent_.indexedClusters.insert(it, c.pos);
            av_add_index_entry(st, c.pos, tcToTs(c.keyTimecode), 0, 0, AVINDEX_KEYFRAME);
            ++added;
        }
        if (!any && !is.clusters.empty()) {
            const spresil::MkvIslandCluster& c = is.clusters.front();
            auto it = std::lower_bound(mkvContent_.indexedClusters.begin(), mkvContent_.indexedClusters.end(), c.pos);
            if (it == mkvContent_.indexedClusters.end() || *it != c.pos) {
                mkvContent_.indexedClusters.insert(it, c.pos);
                av_add_index_entry(st, c.pos, tcToTs(c.timecode), 0, 0, AVINDEX_KEYFRAME);
                ++added;
            }
        }
    }

    const int64_t fsz = localIO_->size;
    if (mkvContent_.kind == ContentKind::Mkv) for (const spresil::MkvIsland& is : map.islands) {
        if (is.to <= 0 || is.to >= fsz) continue;
        auto it = std::lower_bound(mkvContent_.indexedClusters.begin(), mkvContent_.indexedClusters.end(), is.to);
        if (it != mkvContent_.indexedClusters.end() && *it == is.to) continue;
        mkvContent_.indexedClusters.insert(it, is.to);
        av_add_index_entry(st, is.to, tcToTs(map.islandEndTimecode(is)), 0, 0, AVINDEX_KEYFRAME);
        ++added;
    }
    std::vector<std::pair<int64_t, int64_t>> exclude;
    if (mkvContent_.cuesUsable && mkvContent_.cuesFrom >= 0) exclude.push_back({mkvContent_.cuesFrom, mkvContent_.cuesTo});

    const auto gaps = spresil::mkvContentGaps(map, fsz, exclude, mkvContent_.headerEnd);
    localIO_->contentGaps = mkvContent_.kind == ContentKind::Mp4 ? std::vector<std::pair<int64_t, int64_t>>{} : gaps;
    if (!mkvContent_.job && !gaps.empty()) mkvContentStartJob();
    if (spDebug() && added) {
        int64_t gapBytes = 0;
        for (const auto& g : localIO_->contentGaps) gapBytes += g.second - g.first;
        fprintf(stderr, "[Demux] 内容地图发布：索引条目 +%d（共 %zu 簇）截断区间 %zu 段 %.1fMB\n", added, mkvContent_.indexedClusters.size(),
                localIO_->contentGaps.size(), gapBytes / 1048576.0);
    }
}

bool Demuxer::mkvContentSnapSeek(int64_t& absUs, const std::function<bool()>* abortFn) {
    if (!contentMapEligible() || !localIO_ || !resilientRecoveryEnabled_ || growthActive() || abortIO_.load()) return false;
    const bool haveMap = mkvContent_.map && !mkvContent_.map->islands.empty();
    if (!haveMap && (tsMpegTs_ ? !mkvContent_.evidence : !(mkvLike_ && !tsLike_))) {

        return false;
    }
    if (!mkvContentPrepare()) return false;

    const bool cues = mkvContent_.kind == ContentKind::Mkv ? mkvCuesUsable() : mkvContent_.kind == ContentKind::Mp4;
    if (!haveMap && cues) return false;
    ContentSearchScope searching(contentSearchSinceUs_);
    mkvContentMergeJob();
    spresil::MkvContentMap& map = *mkvContent_.map;
    const int64_t fsz = localIO_->size;
    const int64_t scale = std::max<int64_t>(1, map.timestampScale);
    const int64_t tc = av_rescale(std::max<int64_t>(0, absUs), 1000, scale);

    auto landingIsland = [&](int idx, bool forwardSearch) -> int {
        if (idx < 0) return -1;
        if (forwardSearch) { for (size_t i = (size_t)idx; i < map.islands.size(); ++i) if (map.islands[i].hasKey()) return (int)i; }
        else { for (int i = idx; i >= 0; --i) if (map.islands[(size_t)i].hasKey()) return i; }
        return idx;
    };
    if (cues) {

        if (map.islandAtTimecode(tc) >= 0) return false;
        const int prev = map.lastIslandBeforeTimecode(tc), next = map.firstIslandAfterTimecode(tc);
        const int64_t low = prev >= 0 ? map.islands[(size_t)prev].to : 0;
        const int64_t high = next >= 0 ? map.islands[(size_t)next].from : fsz;
        if (next < 0 && prev < 0) return false;
        for (int64_t p2 = low; p2 < high;) {
            bool in = false;
            for (const auto& r : map.scanned) if (p2 >= r.first && p2 < r.second) { p2 = r.second; in = true; break; }
            if (!in) return false;
        }
        int idx = landingIsland(next, true);
        if (idx < 0) idx = landingIsland(prev, false);
        if (idx < 0) return false;
        const spresil::MkvIsland& is = map.islands[(size_t)idx];
        const spresil::MkvIslandCluster& c = is.entryCluster();
        const int64_t targetTc = c.keyTimecode >= 0 ? c.keyTimecode : c.timecode;
        const int64_t newAbsUs = av_rescale(targetTc, scale, 1000);
        if (spDebug()) fprintf(stderr, "[Demux] 内容地图：seek 目标 %.2fs 落在已知无内容区 → %.2fs（簇@%lld）\n", (absUs - timelineOriginUs_) / 1e6, (newAbsUs - timelineOriginUs_) / 1e6, (long long)c.pos);
        mkvContent_.lastSnapUs = newAbsUs - timelineOriginUs_;
        absUs = newAbsUs;
        return true;
    }

    auto estimateBytePos = [&](int64_t t) -> int64_t {
        if (mkvContent_.kind == ContentKind::Mp4 && mkvContent_.mp4Entries) return spresil::mp4EstimatePos(*mkvContent_.mp4Entries, t);
        int64_t aByte = 0, aTc = 0, bByte = fsz;
        int64_t bTc = av_rescale(std::max<int64_t>(durationUs_.load(), 1), 1000, scale);
        for (const spresil::MkvIsland& is : map.islands) {
            if (is.lastTimecode <= t && is.to > aByte) { aByte = is.to; aTc = is.lastTimecode; }
            if (is.firstTimecode > t && is.from < bByte) { bByte = is.from; bTc = is.firstTimecode; }
        }
        if (bTc <= aTc || bByte <= aByte) return aByte;
        return aByte + (int64_t)((double)(bByte - aByte) * (double)(t - aTc) / (double)(bTc - aTc));
    };
    const int64_t kWindow = 64ll * 1024 * 1024;
    int64_t fwd = -1, bwd = -1;
    for (int rounds = 0; rounds < 100000 && map.islandAtTimecode(tc) < 0; ++rounds) {
        const int prev = map.lastIslandBeforeTimecode(tc);
        const int next = map.firstIslandAfterTimecode(tc);
        const int64_t low = prev >= 0 ? map.islands[(size_t)prev].to : 0;
        const int64_t high = next >= 0 ? map.islands[(size_t)next].from : fsz;
        if (fwd < 0) { fwd = bwd = std::clamp<int64_t>(estimateBytePos(tc), low, high); }
        fwd = std::clamp<int64_t>(fwd, low, high);
        bwd = std::clamp<int64_t>(bwd, low, high);

        auto skipScanned = [&](int64_t& pos, bool forward) {
            for (bool moved = true; moved;) {
                moved = false;
                for (const auto& r : map.scanned) {
                    if (forward && pos >= r.first && pos < r.second) { pos = r.second; moved = true; }
                    if (!forward && pos > r.first && pos <= r.second) { pos = r.first; moved = true; }
                }
            }
        };
        skipScanned(fwd, true);
        skipScanned(bwd, false);
        const bool canFwd = fwd < high, canBwd = bwd > low;
        if (!canFwd && !canBwd) break;
        const size_t before = map.islands.size();
        const int64_t bytesBefore = map.bytesRead;

        const bool goFwd = canFwd && (!canBwd || fwd - estimateBytePos(tc) <= estimateBytePos(tc) - bwd);
        if (goFwd) {
            const int64_t to = std::min(high, fwd + kWindow);
            if (!mkvContentScan(fwd, to, false, abortFn, "seek→")) { mkvContentPublish(); return false; }
            fwd = to;
        } else {
            const int64_t from = std::max(low, bwd - kWindow);
            if (!mkvContentScan(from, bwd, false, abortFn, "seek←")) { mkvContentPublish(); return false; }
            bwd = from;
        }
        if (map.islands.size() == before && map.bytesRead == bytesBefore) break;
    }
    mkvContentPublish();
    if (map.islands.empty()) return false;
    const int at = map.islandAtTimecode(tc);
    if (at >= 0) return false;
    int idx = landingIsland(map.firstIslandAfterTimecode(tc), true);
    if (idx < 0) idx = landingIsland(map.lastIslandBeforeTimecode(tc), false);
    if (idx < 0) return false;
    const spresil::MkvIsland& is = map.islands[(size_t)idx];
    const spresil::MkvIslandCluster& c = is.entryCluster();
    const int64_t targetTc = c.keyTimecode >= 0 ? c.keyTimecode : c.timecode;
    const int64_t newAbsUs = av_rescale(targetTc, scale, 1000);
    if (spDebug()) {
        fprintf(stderr, "[Demux] 内容地图：seek 目标 %.2fs 落在无内容区 → %s孤岛 %.2fs（簇@%lld%s）\n", (absUs - timelineOriginUs_) / 1e6,
                idx == map.firstIslandAfterTimecode(tc) ? "下一" : "前一", (newAbsUs - timelineOriginUs_) / 1e6, (long long)c.pos,
                c.keyTimecode >= 0 ? "" : "，无关键帧：只有声音");
    }
    pushRecoveryEvent(std::string("无内容区 seek：") + std::to_string((absUs - timelineOriginUs_) / 1000000) + "s → " +
                      std::to_string((newAbsUs - timelineOriginUs_) / 1000000) + "s", -1, -1);
    mkvContent_.lastSnapUs = newAbsUs - timelineOriginUs_;
    absUs = newAbsUs;
    return true;
}

bool Demuxer::mkvContentSeekToCluster(int64_t clusterPos, int64_t timecode) {
    int si = videoStream_ >= 0 ? videoStream_ : audioStream_;
    if (si < 0 || !fmtCtx_) return false;
    if (mkvContent_.kind == ContentKind::Ts) {

        dropSeekPushback();

        int64_t target = clusterPos + 4096;
        withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
            if (target >= fsz) { target = clusterPos; return; }
            auto w = spresil::readSpan(read, target, (size_t)std::min<int64_t>(8192, fsz - target));
            int st = 0; size_t off = 0;
            if (!w.empty() && spresil::tsProbeSync(w.data(), w.size(), 16, &st, &off)) target += (int64_t)off;
        });
        const int r = av_seek_frame(fmtCtx_, si, target, AVSEEK_FLAG_BYTE);
        if (spDebug()) fprintf(stderr, "[Demux] 内容地图：TS 字节定位到 %lld（%.2fs）→ %d\n", (long long)target, (timecode - timelineOriginUs_) / 1e6, r);
        return r >= 0;
    }
    AVStream* st = fmtCtx_->streams[si];
    const AVRational tcq = {(int)std::min<int64_t>(mkvContent_.map->timestampScale, INT32_MAX), 1000000000};
    int64_t seekTc = timecode;
    if (mkvContent_.kind == ContentKind::Mp4) {

        seekTc = timecode + 250000;
        const int at = mkvContent_.map->islandAtPos(clusterPos);
        if (at >= 0) for (const spresil::MkvIslandCluster& x : mkvContent_.map->islands[(size_t)at].clusters)
            if (x.pos > clusterPos) { seekTc = std::min(seekTc, x.timecode - 1000); break; }
    }
    const int64_t ts = av_rescale_q(seekTc, tcq, st->time_base);
    dropSeekPushback();
    if (spDebug()) {
        const int nb = avformat_index_get_entries_count(st);
        const int idx = av_index_search_timestamp(st, ts, AVSEEK_FLAG_BACKWARD);
        fprintf(stderr, "[Demux] 内容地图：索引 %d 条，目标 ts=%lld → 条目 %d", nb, (long long)ts, idx);
        for (int k = std::max(0, idx - 2); k < std::min(nb, idx + 3); ++k) {
            const AVIndexEntry* e = avformat_index_get_entry(st, k);
            if (e) fprintf(stderr, " [%d: pos=%lld ts=%lld]", k, (long long)e->pos, (long long)e->timestamp);
        }
        const AVIndexEntry* last = nb ? avformat_index_get_entry(st, nb - 1) : nullptr;
        if (last) fprintf(stderr, " 末条 pos=%lld ts=%lld", (long long)last->pos, (long long)last->timestamp);
        fprintf(stderr, "\n");
    }
    const int r = avformat_seek_file(fmtCtx_, si, INT64_MIN, ts, ts, 0);
    if (spDebug()) fprintf(stderr, "[Demux] 内容地图：定位到簇@%lld ts=%lld → %d（pb@%lld）\n", (long long)clusterPos, (long long)ts, r, fmtCtx_->pb ? (long long)avio_tell(fmtCtx_->pb) : -1LL);
    return r >= 0;
}

bool Demuxer::mkvContentJumpAfterCut(AVPacket* pkt, int& ret) {
    LocalFileIO* io = localIO_.get();
    const bool suspect = io->contentCutAt < 0;
    int64_t cutAt = suspect ? io->contentSuspectAt : io->contentCutAt;
    io->contentCutAt = -1;
    io->contentSuspectAt = -1;
    io->bytesSinceDeliver = 0;
    if (!contentMapEligible() || !resilientRecoveryEnabled_ || abortIO_.load() || cutAt < 0) { mkvCutFromSeekLanding_ = false; return false; }
    if (growthActive()) {
        io->contentGaps.clear();
        io->contentSuspectEnabled = false;
        if (fmtCtx_->pb) avio_seek(fmtCtx_->pb, cutAt, SEEK_SET);
        ret = readFrameGrowthAware(pkt);
        return true;
    }
    if (!mkvContentPrepare()) return false;
    ContentSearchScope searching(contentSearchSinceUs_);
    mkvContentMergeJob();
    spresil::MkvContentMap& map = *mkvContent_.map;
    const int64_t fsz = io->size;
    if (suspect) {

        int64_t from = lastGoodPos_ >= 0 ? lastGoodPos_ : std::max<int64_t>(0, cutAt - LocalFileIO::kContentSuspectBytes);
        if (lastGoodPos_ >= 0) {
            withFileReader(path_, [&](const spresil::Reader& read, int64_t) {
                int64_t tcOut = -1;
                const int64_t enclosing = spresil::mkvFindEnclosingCluster(read, lastGoodPos_ + 1, 64ll * 1024 * 1024, &tcOut, &abortFn_);
                if (enclosing >= 0) from = enclosing;
            });
        }
        if (!mkvContentScan(from, cutAt, false, nullptr, "读截断嫌疑")) return false;
        const int at = map.islandAtPos(cutAt);
        if (at >= 0) {

            mkvContentPublish();
            const spresil::MkvIsland& is = map.islands[(size_t)at];
            const spresil::MkvIslandCluster* c = &is.clusters.front();
            for (const auto& x : is.clusters) if (x.pos <= cutAt) c = &x;
            if (spDebug()) fprintf(stderr, "[Demux] 内容地图：64 MiB 未交付但截断点仍有内容（簇@%lld）：继续\n", (long long)c->pos);
            io->contentSuspectEnabled = false;
            if (!mkvContentSeekToCluster(c->pos, c->keyTimecode >= 0 ? c->keyTimecode : c->timecode)) return false;
            io->bytesSinceDeliver = 0;
            ret = readFrameGrowthAware(pkt);
            return true;
        }
    }

    int next = -1;
    for (int rounds = 0; rounds < 100000; ++rounds) {
        next = map.firstIslandAtOrAfterPos(cutAt);
        if (next >= 0 && map.islands[(size_t)next].from < cutAt) {

            if (mkvContent_.kind == ContentKind::Mkv) { next = -1; break; }
            if (mkvContent_.kind == ContentKind::Ts) {
                spresil::MkvIsland& is = map.islands[(size_t)next];
                const int64_t oldTo = is.to;
                is.to = cutAt;
                is.endTimecode = -1;
                map.removeScanned(cutAt, oldTo);
                if (spDebug()) fprintf(stderr, "[Demux] 内容地图（TS）：孤岛 [%lld, %lld) 在 %lld 处撞到噪声：截到撞点，之后重探\n", (long long)is.from, (long long)oldTo, (long long)cutAt);
                continue;
            }
            cutAt = map.islands[(size_t)next].to;
            continue;
        }
        const int64_t limit = next >= 0 ? map.islands[(size_t)next].from : fsz;
        int64_t from = cutAt;
        for (bool moved = true; moved && from < limit;) {
            moved = false;
            for (const auto& r : map.scanned) if (from >= r.first && from < r.second) { from = r.second; moved = true; }
        }
        if (from >= limit) break;
        const size_t before = map.islands.size();
        const int64_t bytesBefore = map.bytesRead;
        if (!mkvContentScan(from, limit, true, nullptr, "读截断")) { mkvContentPublish(); return false; }
        if (map.islands.size() == before && map.bytesRead == bytesBefore) break;
    }
    mkvContentPublish();
    const int64_t scale = std::max<int64_t>(1, map.timestampScale);
    const int64_t fromUs = lastGoodAbsUs_ >= 0 ? lastGoodAbsUs_ - timelineOriginUs_ : byteToUsGuess(cutAt);

    if (next >= 0 && mkvCutFromSeekLanding_) {
        int keyed = -1;
        for (int hops = 0; hops < 8 && keyed < 0; ++hops) {
            for (size_t i = (size_t)next; i < map.islands.size(); ++i) if (map.islands[i].hasKey()) { keyed = (int)i; break; }
            if (keyed >= 0) break;
            const int64_t from0 = map.islands.back().to;
            int64_t from = from0;
            for (const auto& r : map.scanned) if (from >= r.first && from < r.second) from = r.second;
            if (from >= fsz) break;
            const size_t before = map.islands.size();
            if (!mkvContentScan(from, fsz, true, nullptr, "读截断（找关键帧）")) break;
            if (map.islands.size() == before) break;
        }
        if (keyed >= 0) next = keyed;
        mkvContentPublish();
    }
    mkvCutFromSeekLanding_ = false;
    if (next < 0) {

        if (!io->contentGaps.empty()) demuxDamageEvidence_.store(true, std::memory_order_relaxed);
        if (spDebug()) fprintf(stderr, "[Demux] 内容地图：截断点 %lld 之后没有内容 → 结束\n", (long long)cutAt);
        pushRecoveryEvent("之后的内容无法播放（未下载区域）", -1, -1);
        return false;
    }
    const spresil::MkvIsland& is = map.islands[(size_t)next];
    const spresil::MkvIslandCluster& c = is.entryCluster();
    const int64_t targetTc = c.keyTimecode >= 0 ? c.keyTimecode : c.timecode;
    const int64_t toUs = av_rescale(targetTc, scale, 1000) - timelineOriginUs_;
    ++mkvContent_.jumps;
    if (spDebug()) {
        fprintf(stderr, "[Demux] 内容地图：越过无内容区 [%lld, %lld) %.2fs → %.2fs（第 %d 次跳跃%s）\n", (long long)cutAt, (long long)is.from,
                fromUs / 1e6, toUs / 1e6, mkvContent_.jumps, c.keyTimecode >= 0 ? "" : "，无关键帧：只有声音");
    }
    pushRecoveryEvent("跳过无内容区 " + std::to_string(fromUs / 1000000) + "s → " + std::to_string(toUs / 1000000) + "s", -1, -1);
    if (!mkvContentSeekToCluster(c.pos, targetTc)) return false;
    mkvContent_.lastJumpPos = c.pos;
    mkvContent_.mp4GarbageRun = 0;

    lastGoodPos_ = -1;
    std::fill(lastGoodPosPerStream_.begin(), lastGoodPosPerStream_.end(), -1);
    eof_ = false;
    io->bytesSinceDeliver = 0;
    ret = readFrameGrowthAware(pkt);
    return true;
}

bool Demuxer::gapIsLegalSkippedData(int64_t from, int64_t to) {
    if (!fmtCtx_ || !localIO_ || to <= from || abortIO_.load()) return false;
    const bool ogg = container_ == "ogg";
    const int64_t t0 = spNowUs();
    bool legal = false;
    withPatchedFileReader([&](const spresil::Reader& read, int64_t fsz) {
        if (to > fsz) return;
        if (ogg) {
            legal = spresil::oggGapIsValidPages(read, from, to, 1024 * 1024, &abortFn_);
            return;
        }
        if (gapTrackDecls_.empty() && gapTrackDeclReads_ < 2) {
            ++gapTrackDeclReads_;
            gapTrackDecls_ = spresil::mkvReadTrackDecls(read, fsz, &abortFn_, nullptr);
        }
        std::string kinds;
        std::vector<bool> discarded;
        for (unsigned i = 0; i < fmtCtx_->nb_streams; ++i) {
            const AVStream* st = fmtCtx_->streams[i];
            const AVMediaType t = st->codecpar->codec_type;
            kinds.push_back(t == AVMEDIA_TYPE_VIDEO ? 'v' : t == AVMEDIA_TYPE_AUDIO ? 'a' : t == AVMEDIA_TYPE_SUBTITLE ? 's'
                            : t == AVMEDIA_TYPE_DATA ? 'd' : '?');
            discarded.push_back(st->discard >= AVDISCARD_ALL);
        }
        std::vector<uint64_t> skippable;
        if (!spresil::mkvSkippableTrackNumbers(gapTrackDecls_, kinds, discarded, skippable)) return;
        legal = spresil::mkvGapIsSkippedTrackData(read, from, to, skippable, &abortFn_);
    });
    if (legal && spDebug() && gapLegalLogged_ < 3) {
        ++gapLegalLogged_;
        fprintf(stderr, "[Demux] 交付跳跃 区间 [%lld, %lld) 是未选中轨 / 链边界的合法数据（%.2fms）：不做区间恢复\n",
                (long long)from, (long long)to, (spNowUs() - t0) / 1000.0);
    }
    return legal;
}

bool Demuxer::lastReadErrorIsContent(int err) const {
    if (err >= 0 || err == AVERROR_EXIT || err == AVERROR(ENOMEM) || annexBTailSourceInvalid_) return false;
    if (localIO_) return localIO_->readFaults == readFaultsAtRead_;
    return err == AVERROR_INVALIDDATA || (err == AVERROR(EAGAIN) && lastReadAdvanced_);
}

int Demuxer::markEof() {
    noteTruncationEvidenceAtEof();
    releaseLaneScratch();
    eof_ = true;
    return 0;
}

void Demuxer::releaseLaneScratch() {
    std::vector<uint8_t>().swap(tsLaneWin_.buf);
    tsLaneWin_.pos = -1;
    tsLaneWin_.len = 0;
    std::vector<uint8_t>().swap(psLaneBlock_);
    const std::shared_ptr<LocalFileIO> io = localIO_;
    if (!io || io->abortRequested.load() || (io->abortFlag && io->abortFlag->load())) return;
    std::vector<uint8_t>().swap(io->auxLanding);
    for (LocalFileIO::LaneCacheBlock& b : io->laneCache) {
        std::vector<uint8_t>().swap(b.bytes);
        b.pos = -1;
        b.len = 0;
    }
}

bool Demuxer::evidenceSourceUnchanged() {
    const std::shared_ptr<LocalFileIO> io = localIO_;
    if (!io || io->fd < 0) return false;
    if (onOpenThread()) return spLocalSourceUnchanged(*io);
    bool unchanged = false;
    const bool ran = spRunAbandonable(io, "sp.src-ident", [io](const std::atomic<bool>&) { return spLocalSourceUnchanged(*io); }, unchanged);
    return ran && unchanged;
}

void Demuxer::noteTruncationEvidenceAtEof() {
    if (!localIO_ || localIO_->size <= 0 || abortIO_.load() || demuxDamageEvidence_.load(std::memory_order_relaxed)) return;
    if (growthActive()) return;
    if (mkvLike_ && !mkvExtentChecked_) noteMkvSegmentExtentAtEof();
    if (container_ == "mp3" && !mp3DeclChecked_) {
        mp3DeclChecked_ = true;
        bool truncated = false;
        withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
            truncated = spresil::mp3DeclaredBytesExceedFile(spresil::mp3ReadDeclaredBytes(read, fsz), fsz);
        });
        if (truncated && evidenceSourceUnchanged()) {
            demuxDamageEvidence_.store(true, std::memory_order_relaxed);
            if (spDebug()) fprintf(stderr, "[Demux] EOF：Xing/VBRI 声明的流字节数比物理文件多出 1/16 以上（文件被截断）\n");
        }
    }
    if (demuxDamageEvidence_.load(std::memory_order_relaxed)) return;

    int64_t anchor = contentEndPos_;
    if (asfLike_ && asfLastDeliveredPos_ >= 0 && fmtCtx_ && fmtCtx_->packet_size > 0)
        anchor = std::max(anchor, asfLastDeliveredPos_ + (int64_t)fmtCtx_->packet_size);
    if (anchor < 0 || anchor == zeroTailCheckedAnchor_ || zeroTailChecks_ >= 4) return;
    zeroTailCheckedAnchor_ = anchor;
    ++zeroTailChecks_;
    bool zeroTail = false;
    int64_t size = 0;
    withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
        size = fsz;
        zeroTail = spresil::zeroFilledTail(read, anchor, fsz, &abortFn_);
    });
    if (spDebug()) {
        fprintf(stderr, "[Demux] EOF：内容交付到 %lld / %lld，%s\n", (long long)anchor, (long long)size,
                zeroTail ? "之后的尾段是零填充（预分配未写完的签名，记为截断证据）" : "之后的尾段不是零填充");
    }
    if (zeroTail && evidenceSourceUnchanged()) demuxDamageEvidence_.store(true, std::memory_order_relaxed);
}

void Demuxer::noteMkvSegmentExtentAtEof() {
    mkvExtentChecked_ = true;
    if (!localIO_ || abortIO_.load()) return;
    bool truncated = false;
    withPatchedFileReader([&](const spresil::Reader& read, int64_t fsz) {
        const auto head = spresil::readSpan(read, 0, 64);
        if (head.size() < 16 || !(head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3)) return;
        uint64_t hsz = 0; bool hun = false;
        const int hsl = spresil::ebmlReadSize(head.data() + 4, head.size() - 4, hsz, hun);
        if (hsl == 0 || hun || hsz > 4096) return;
        const int64_t segPos = 4 + hsl + (int64_t)hsz;
        const auto sh = spresil::readSpan(read, segPos, 16);
        if (sh.size() < 8 || !(sh[0] == 0x18 && sh[1] == 0x53 && sh[2] == 0x80 && sh[3] == 0x67)) return;
        uint64_t ssz = 0; bool sun = false;
        const int ssl = spresil::ebmlReadSize(sh.data() + 4, sh.size() - 4, ssz, sun);
        if (ssl == 0 || sun) return;
        const int64_t segData = segPos + 4 + ssl;
        truncated = ssz > (uint64_t)std::max<int64_t>(fsz - segData, 0);
    });
    if (!truncated || !evidenceSourceUnchanged()) return;
    demuxDamageEvidence_.store(true, std::memory_order_relaxed);
    if (spDebug()) fprintf(stderr, "[Demux] EOF：Segment 声明的范围越出物理文件尾（文件被截断）\n");
}

bool Demuxer::recoverRegion(int64_t from, int64_t to, const char* why) {
    if (!fmtCtx_ || !localIO_ || to <= from || lastGoodAbsUs_ < 0) return false;
    if (readErrorRecoveries_ >= 64) return false;
    for (const auto& r : recoveryRegions_) {
        if (from < r.second && to > r.first) return false;
    }
    if (recoveryRegions_.size() < 256) recoveryRegions_.push_back({from, to});
    ++readErrorRecoveries_;
    const bool ogg = container_ == "ogg";
    spresil::RecoveryPlan plan;
    std::string note;
    const int64_t t0 = spNowUs();
    withFileReader(path_, [&](const spresil::Reader& read, int64_t fsz) {
        to = std::min(to, fsz);
        if (ogg) {
            plan = spresil::planOggCrc(read, fsz, from, std::min<int64_t>(to - from + 256 * 1024, 32ll * 1024 * 1024), &abortFn_);
            return;
        }

        std::vector<int> tracks = spresil::mkvReadTrackNumbers(read, fsz, &abortFn_);
        if (tracks.empty()) { note = "Tracks 轨号不可读"; return; }
        const AVStream* st = fmtCtx_->streams[videoStream_ >= 0 ? videoStream_ : 0];

        int64_t enclosingTc = -1;
        int64_t enclosingPos = spresil::mkvFindEnclosingCluster(read, from, 64ll * 1024 * 1024, &enclosingTc, &abortFn_);
        const int n = avformat_index_get_entries_count(st);
        std::vector<spresil::MkvCluster> inGap;
        for (int i = 0; i < n; ++i) {
            const AVIndexEntry* e = avformat_index_get_entry(const_cast<AVStream*>(st), i);
            if (!e) continue;
            if (e->pos > from && e->pos < to) {

                bool dup = false;
                for (auto& c : inGap) if (c.pos == e->pos) dup = true;
                if (!dup) inGap.push_back({e->pos, e->timestamp});
            }
        }
        std::vector<spresil::MkvCluster> clusters;
        if (enclosingPos >= 0 && enclosingTc >= 0) clusters.push_back({enclosingPos, enclosingTc});
        clusters.insert(clusters.end(), inGap.begin(), inGap.end());
        int64_t minRel = INT64_MIN;
        if (enclosingTc >= 0) minRel = av_rescale_q(lastGoodAbsUs_, AV_TIME_BASE_Q, st->time_base) - enclosingTc - 200;
        note = "轨号 " + std::to_string(tracks.size()) + " 包围簇@" + std::to_string(enclosingPos) + " tc=" +
               std::to_string(enclosingTc) + " 区内索引簇 " + std::to_string(inGap.size());

        plan = spresil::planMkvCrcSizeFix(read, fsz, from, tracks, &abortFn_);
        if (plan.empty()) plan = spresil::planMkvClusterChains(read, from, to, tracks, clusters, &abortFn_, minRel);
    });
    if (spDebug()) {
        fprintf(stderr, "[Demux] %s 区间 [%lld, %lld) 候选计划 %.1fms: %s %s %s\n", why, (long long)from, (long long)to,
                (spNowUs() - t0) / 1000.0, plan.empty() ? "无" : plan.kind.c_str(), plan.detail.c_str(), note.c_str());
    }
    if (plan.empty()) return false;
    if (!installPatches(plan.patches, true)) return false;
    const int64_t target = recoverySeekTargetUs();
    dropSeekPushback();
    const int sret = avformat_seek_file(fmtCtx_, -1, INT64_MIN, target, target, 0);
    if (spDebug()) fprintf(stderr, "[Demux] 补丁 %zu 处已装入，回 seek %.2fs → %d\n", plan.patches.size(), target / 1e6, sret);
    if (sret < 0) return false;
    eof_ = false;
    lastGoodPos_ = -1;
    armResumeDiscard(target);
    pushRecoveryEvent(std::string(why) + "区间恢复 " + plan.kind + "：" + plan.detail, byteToUsGuess(plan.damagedFrom),
                      byteToUsGuess(plan.damagedUntil));
    return true;
}

void Demuxer::dropSeekPushback() {
    for (AVPacket* p : seekPushback_) { AVPacket* t = p; av_packet_free(&t); }
    seekPushback_.clear();
}

int Demuxer::rawSeekToAbsUs(int64_t absUs, int streamIndex, bool forwardKeyframe) {
    dropSeekPushback();
    AVStream* st = fmtCtx_->streams[streamIndex];
    int64_t ts = av_rescale_q(absUs, AV_TIME_BASE_Q, st->time_base);
    int ret;

    if (mkvContent_.kind == ContentKind::Ts && mkvContent_.map && streamIndex == videoStream_) {
        const int at = mkvContent_.map->islandAtTimecode(absUs);
        if (at >= 0) {
            const spresil::MkvIsland& is = mkvContent_.map->islands[(size_t)at];
            const int64_t pos = tsIslandBisect(absUs, is.from, is.to, streamIndex);
            if (pos >= 0) {
                ret = av_seek_frame(fmtCtx_, streamIndex, pos, AVSEEK_FLAG_BYTE);
                if (spDebug()) fprintf(stderr, "[Demux] 内容地图：TS 孤岛内二分 %.2fs → 字节 %lld（%d）\n", (absUs - timelineOriginUs_) / 1e6, (long long)pos, ret);
                if (ret >= 0) return ret;
            }
        }
    }
    if (forwardKeyframe) {

        ret = avformat_seek_file(fmtCtx_, streamIndex, ts, ts, INT64_MAX, 0);
        if (ret >= 0) return ret;
        if (spDebug()) {
            fprintf(stderr, "[Demux] 前向 seek 失败 ret=%d target=%.2fs → 回落后向\n",
                    ret, absUs / 1e6);
        }
    }

    return avformat_seek_file(fmtCtx_, streamIndex, INT64_MIN, ts, ts, 0);
}

void Demuxer::noteTsKeyframePtsUs(int64_t relPtsUs) {
    if (tsLastKeyPtsUs_ != INT64_MIN)
        tsGopUs_ = spTsRapBlendGopUs(tsGopUs_, relPtsUs - tsLastKeyPtsUs_);
    tsLastKeyPtsUs_ = relPtsUs;
}

int64_t Demuxer::findTsRapPos(int64_t absUs, int streamIndex, bool forward,
                              int64_t floorAbsUs,
                              const std::function<bool()>* abortFn,
                              int64_t* outPtsUs, bool* cappedOut) {
    *cappedOut = false;
    AVStream* st = fmtCtx_->streams[videoStream_];
    const AVRational tb = st->time_base;
    const SPTsRapLimits lim;
    const int64_t bytes0 = localIO_ ? (int64_t)localIO_->st.readBytes : 0;
    auto bytesRead = [&]() -> int64_t {
        return localIO_ ? (int64_t)localIO_->st.readBytes - bytes0 : 0;
    };
    AVPacket* probe = av_packet_alloc();
    if (!probe) return -1;
    struct PacketGuard {
        AVPacket** p;
        ~PacketGuard() { av_packet_free(p); }
    } guard{&probe};

    int64_t bestPos = -1, bestPts = AV_NOPTS_VALUE;
    int64_t vpkts = 0;

    int64_t prevKeyPts = AV_NOPTS_VALUE;
    int64_t gopSample = 0;

    int64_t hiUs = absUs;
    int64_t loUs = forward ? absUs : absUs - spTsRapWindowUs(tsGopUs_, 0);
    for (int attempt = 0;; ++attempt) {

        if (abortFn && (*abortFn)()) return -1;
        if (!forward) {
            if (loUs < floorAbsUs) loUs = floorAbsUs;
            if (rawSeekToAbsUs(loUs, streamIndex) < 0) break;
        }
        int64_t prevDts = INT64_MIN;
        bool discontinuity = false;
        for (;;) {

            if (abortFn && (*abortFn)()) return -1;
            if (spTsRapExhausted(lim, absUs - loUs, bytesRead(), vpkts)) {
                *cappedOut = true;
                return -1;
            }
            if (av_read_frame(fmtCtx_, probe) < 0) break;
            if (probe->stream_index != videoStream_) {
                av_packet_unref(probe);
                continue;
            }
            ++vpkts;
            const int64_t pts = probe->pts != AV_NOPTS_VALUE
                                    ? av_rescale_q(probe->pts, tb, AV_TIME_BASE_Q)
                                    : AV_NOPTS_VALUE;
            const int64_t dts = probe->dts != AV_NOPTS_VALUE
                                    ? av_rescale_q(probe->dts, tb, AV_TIME_BASE_Q)
                                    : pts;
            const bool key = (probe->flags & AV_PKT_FLAG_KEY) != 0;
            const int64_t pos = probe->pos;
            av_packet_unref(probe);

            if (dts != AV_NOPTS_VALUE) {
                if (prevDts != INT64_MIN && dts < prevDts) { discontinuity = true; break; }
                prevDts = dts;
            }
            if (key && pos >= 0 && pts != AV_NOPTS_VALUE) {
                if (prevKeyPts != AV_NOPTS_VALUE && pts > prevKeyPts)
                    gopSample = pts - prevKeyPts;
                prevKeyPts = pts;
                if (forward) {
                    if (pts >= absUs) { bestPos = pos; bestPts = pts; break; }
                } else if (pts <= absUs) {

                    bestPos = pos;
                    bestPts = pts;
                }
            }

            if (!forward && dts != AV_NOPTS_VALUE && dts > hiUs) break;
        }
        if (bestPos >= 0 || forward || discontinuity) break;
        if (loUs == floorAbsUs) break;
        hiUs = loUs;
        loUs = absUs - spTsRapWindowUs(tsGopUs_, attempt + 1);
        if (spTsRapExhausted(lim, absUs - loUs, bytesRead(), vpkts)) {
            *cappedOut = true;
            return -1;
        }
    }
    if (bestPos >= 0) {

        tsGopUs_ = spTsRapBlendGopUs(tsGopUs_, gopSample);
        *outPtsUs = bestPts;
    }
    return bestPos;
}

int Demuxer::seekToUs(int64_t us, bool forwardKeyframe,
                      int64_t forwardMinExclusiveUs,
                      const std::function<bool()>* abortFn,
                      int64_t alignToleranceUs) {
    if (!fmtCtx_) return AVERROR(EINVAL);
    growthResyncPending_ = false;
    psLastCheckedPos_ = -1;
    tsScanHoldUntilUs_ = spNowUs() + 300000;
    fmp4BrokenRun_ = 0;
    mp4BrokenHistory_ = 0;
    for (int& c : aviIdxCursor_) c = -1;

    if (forwardKeyframe && forwardMinExclusiveUs >= 0 &&
        us < forwardMinExclusiveUs + 20000) {
        if (spDebug()) {
            fprintf(stderr, "[Demux] 前向进度下界生效 %.2fs → %.2fs\n",
                    us / 1e6, (forwardMinExclusiveUs + 20000) / 1e6);
        }
        us = forwardMinExclusiveUs + 20000;
    }
    resetAnnexBTailPermission();
    eof_ = false;
    lastGoodPos_ = -1;
    lastRecoveryVideoPacket_ = {}; resumeVideoAnchor_ = {};
    clearTsRecoveryCarry();
    resumeDiscardAbsUs_ = -1;
    resumeFrontierUs_.clear();
    resumeFrontierPos_.clear();

    std::fill(lastGoodAbsUsPerStream_.begin(), lastGoodAbsUsPerStream_.end(), -1);
    std::fill(lastGoodPosPerStream_.begin(), lastGoodPosPerStream_.end(), -1);
    if (lastGoodAbsUs_ >= 0) lastGoodAbsUs_ = us + timelineOriginUs_;

    {
        std::shared_ptr<AuxIOCancelToken> pc;
        {
            std::lock_guard<std::mutex> lk(ioMtx_);
            pc = prefetchCancel_;
        }
        spAuxCancel(pc);
    }
    preemptScrubTasks();

    const IOStats seekBase = localIO_ ? localIO_->st : IOStats{};
    const int64_t seekT0 = spNowUs();

    int64_t absUs = us + timelineOriginUs_;

    const int64_t gridTolUs =
        (!forwardKeyframe && alignToleranceUs > 0) ? alignToleranceUs : 0;

    const int videoDelay = (videoStream_ >= 0 && fmtCtx_->streams[videoStream_]->codecpar)
        ? fmtCtx_->streams[videoStream_]->codecpar->video_delay : 0;
    if (!tsLike_ && spSeekTsIsPtsDomain(container_, videoDelay)) absUs += gridTolUs;

    int streamIndex = videoStream_ >= 0 ? videoStream_
                     : (audioStream_ >= 0 ? audioStream_ : 0);

    tsLastKeyPtsUs_ = INT64_MIN;
    if (localIO_) localIO_->bytesSinceDeliver = 0;
    mkvLandingCutAt_ = -1;
    mkvContent_.lastJumpPos = -1;
    mkvContent_.mp4GarbageRun = 0;

    if (tsMpegTs_ && !mkvContent_.tsProbed && localIO_ && resilientRecoveryEnabled_ && !growthActive() && !abortIO_.load()) {
        mkvContent_.tsProbed = true;
        const int64_t fsz = localIO_->size;
        const int64_t dur = std::max<int64_t>(durationUs_.load(), 1);
        const int64_t est = std::clamp<int64_t>((int64_t)((double)fsz * (double)std::max<int64_t>(absUs - timelineOriginUs_, 0) / (double)dur), 0, std::max<int64_t>(fsz - 4096, 0));
        const int64_t spots[3] = {est, fsz / 2, std::max<int64_t>(fsz - 65536, 0)};
        for (int64_t sp : spots) if (!tsSyncAtPos(sp)) { mkvContent_.evidence = true; break; }
        if (spDebug()) fprintf(stderr, "[Demux] 内容地图（TS）：快探 %s\n", mkvContent_.evidence ? "见到无同步区 → 之后 seek 走内容地图" : "三处都有同步（不建图）");
    }

    if (contentMapEligible() && mkvContentSnapSeek(absUs, abortFn)) forwardKeyframe = false;
    int ret = rawSeekToAbsUs(absUs, streamIndex, forwardKeyframe);

    if (ret >= 0 && sampleEofRetryEligible_ && !fmp4Like_ && localIO_ && resilientRecoveryEnabled_ && !growthActive() && videoStream_ >= 0 &&
        !mkvContent_.prepareFailed && (mkvContent_.prepared || mkvContentPrepare()) && mkvContent_.kind == ContentKind::Mp4) {
        AVStream* vst = fmtCtx_->streams[videoStream_];
        const int idx = av_index_search_timestamp(vst, av_rescale_q(absUs, AV_TIME_BASE_Q, vst->time_base), forwardKeyframe ? 0 : AVSEEK_FLAG_BACKWARD);
        const AVIndexEntry* e = idx >= 0 ? avformat_index_get_entry(vst, idx) : nullptr;
        if (e && e->pos >= 0 && e->size > 0) {
            bool valid = true;
            withFileReader(path_, [&](const spresil::Reader& read, int64_t) {
                auto w = spresil::readSpan(read, e->pos, std::min<size_t>(4096, (size_t)e->size));
                valid = !w.empty() && spresil::mp4SamplePrefixValid(w.data(), w.size(), e->size, mkvContent_.mp4NalLen, mkvContent_.mp4Hevc);
            });
            if (!valid && !abortIO_.load()) {
                mkvLandingCutAt_ = e->pos;
                if (spDebug()) fprintf(stderr, "[Demux] 内容地图（MP4）：seek 落点样本 @%lld 是噪声 → 按读截断找下一孤岛\n", (long long)e->pos);
            }
        }
    }

    if (ret >= 0 && tsMpegTs_ && localIO_ && resilientRecoveryEnabled_ && !growthActive() && fmtCtx_->pb && mkvLandingCutAt_ < 0) {
        const int64_t landing = avio_tell(fmtCtx_->pb);
        if (!tsSyncAtPos(landing) && !abortIO_.load()) {
            mkvContent_.evidence = true;
            mkvLandingCutAt_ = landing;
            if (spDebug()) fprintf(stderr, "[Demux] 内容地图（TS）：seek 落点 @%lld 没有同步串（噪声区）→ 按读截断找下一孤岛\n", (long long)landing);
        }
    }

    if (ret >= 0 && mkvLike_ && !tsLike_ && localIO_ && resilientRecoveryEnabled_ && !growthActive() && fmtCtx_->pb &&
        mkvContent_.cuesChecked && mkvContent_.cuesUsable) {
        const int64_t landing = avio_tell(fmtCtx_->pb);
        bool head = true;
        withFileReader(path_, [&](const spresil::Reader& read, int64_t) { head = spresil::mkvReadClusterTimecode(read, landing) >= 0; });
        if (!head && !abortIO_.load()) {
            mkvLandingCutAt_ = landing;
            if (spDebug()) fprintf(stderr, "[Demux] 内容地图：seek 落点 @%lld 不是簇头（未下载区）→ 按读截断找下一孤岛\n", (long long)landing);
        }
    }

    if (ret >= 0 && sampleEofRetryEligible_ && !fmp4Like_ && videoStream_ >= 0 && resilientRecoveryEnabled_) verifyMp4SeekRap(absUs, streamIndex, forwardKeyframe, ret);

    if (ret >= 0 && tsLike_ && videoStream_ >= 0 && mkvLandingCutAt_ < 0) {

        const int64_t floorAbsUs = std::min<int64_t>(timelineOriginUs_, absUs);
        int64_t back = 0;
        for (int attempt = 0;; ++attempt) {

            if (attempt > 0 && abortFn && (*abortFn)()) break;
            int64_t tryUs = absUs - back;
            if (tryUs < floorAbsUs) tryUs = floorAbsUs;
            back = back == 0 ? 2000000 : back * 2 + 2000000;

            const bool atHead = attempt > 0 && tryUs == floorAbsUs;
            auto seekAttempt = [&]() -> int {
                if (atHead) {
                    const int r = av_seek_frame(fmtCtx_, streamIndex, 0, AVSEEK_FLAG_BYTE);
                    if (r >= 0) return r;
                }
                return rawSeekToAbsUs(tryUs, streamIndex,
                                      attempt == 0 ? forwardKeyframe : false);
            };
            if (attempt > 0 && seekAttempt() < 0) break;

            bool foundKey = false, foundVideo = false;
            AVPacket* probe = av_packet_alloc();
            if (!probe) { ret = AVERROR(ENOMEM); break; }
            for (int n = 0; n < 400; ++n) {
                if (av_read_frame(fmtCtx_, probe) < 0) break;
                if (probe->stream_index == videoStream_) {
                    foundVideo = true;
                    foundKey = (probe->flags & AV_PKT_FLAG_KEY) != 0;
                    av_packet_unref(probe);
                    break;
                }
                av_packet_unref(probe);
            }
            av_packet_free(&probe);
            if (foundKey || !foundVideo || tryUs == floorAbsUs) {

                int rret = seekAttempt();
                if (rret < 0) ret = rret;
                if (spDebug() && attempt > 0) {
                    int64_t relUs = tryUs - timelineOriginUs_;
                    if (relUs < 0) relUs = 0;
                    fprintf(stderr, "[Demux] TS RAP 回退 %.2fs → %.2fs (key=%d)\n",
                            us / 1e6, relUs / 1e6, (int)foundKey);
                }
                break;
            }

            if (attempt == 0 && tsMpegTs_ && !tsRapScanRetired_ &&
                !tsRapScanDisabled_) {
                int64_t rapPts = AV_NOPTS_VALUE;
                bool capped = false;
                const int64_t scanT0 = spNowUs();
                const int64_t rapPos =
                    findTsRapPos(absUs + gridTolUs, streamIndex, forwardKeyframe,
                                 floorAbsUs, abortFn, &rapPts, &capped);
                if (capped) {
                    tsRapScanRetired_ = true;
                    if (spDebug()) {
                        fprintf(stderr,
                                "[Demux] TS RAP 扫描触上界 → 本会话退役"
                                "（%.2fs, %.1fms）\n",
                                us / 1e6, (spNowUs() - scanT0) / 1000.0);
                    }
                }
                if (rapPos >= 0) {

                    int bret = av_seek_frame(fmtCtx_, streamIndex, rapPos,
                                             AVSEEK_FLAG_BYTE);
                    if (bret >= 0) {
                        if (spDebug()) {
                            int64_t relUs = rapPts - timelineOriginUs_;
                            if (relUs < 0) relUs = 0;
                            fprintf(stderr,
                                    "[Demux] TS RAP 扫描 %.2fs → %.2fs "
                                    "(%s, %.1fms, gop≈%.2fs)\n",
                                    us / 1e6, relUs / 1e6,
                                    forwardKeyframe ? "前向" : "后向",
                                    (spNowUs() - scanT0) / 1000.0, tsGopUs_ / 1e6);
                        }
                        break;
                    }

                } else if (abortFn && (*abortFn)()) {

                    break;
                }
            }
        }
        eof_ = false;
    }
    if (spDebug()) {
        fprintf(stderr, "[Demux] seekToUs(%.2fs) ret=%d\n", us / 1e6, ret);
        if (localIO_) {
            const IOStats& s = localIO_->st;
            fprintf(stderr,
                    "[DemuxIO] seek: %.0fms (io=%.0fms) reads=%llu bytes=%.0fKB jumps=%llu\n",
                    (spNowUs() - seekT0) / 1000.0, (s.ioUs - seekBase.ioUs) / 1000.0,
                    (unsigned long long)(s.reads - seekBase.reads),
                    (s.readBytes - seekBase.readBytes) / 1024.0,
                    (unsigned long long)(s.jumps - seekBase.jumps));
        }
    }
    return ret;
}

void Demuxer::scanTsRecoveryPids(const spresil::Reader& read, int64_t size, const spresil::AbortFn* abort, bool full) {
    tsPsiLocal_ = localIO_ && localIO_->localFilesystem && !localIO_->remote;
    constexpr int64_t kFullWindow = 8ll << 20, kRemoteProvisionalWindow = 2ll << 20;
    int64_t scanned = 0;
    try {
        if (tsPsiLocal_) {
            tsPsiMap_ = spresil::tsScanStablePsi(read, size, kFullWindow, abort, &scanned, !full);
            tsHdrPids_ = tsPsiMap_.pids;
        } else {
            tsHdrPids_ = spresil::tsScanDeclaredVideoPids(read, size, full ? kFullWindow : kRemoteProvisionalWindow, abort, &scanned, !full);
        }
    } catch (const std::bad_alloc&) { tsPsiMap_ = {}; tsHdrPids_ = {}; }

    tsPsiProvisional_ = !full && tsHdrPids_.programTrusted && scanned < std::min(size, kFullWindow);
    if (spDebug()) {
        char note[96];
        snprintf(note, sizeof note, "%s@%lldKiB", full ? (tsHdrPids_.programTrusted ? "补完" : "补完（不可信）")
                 : !tsHdrPids_.programTrusted ? "不可信" : (tsPsiProvisional_ ? "早停" : "读满"), (long long)(scanned / 1024));
        planNote_ = note;
    }
}

void Demuxer::ensureTsRecoveryPids() {
    if (tsHdrPidsScanned_ || !localIO_) return;
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        scanTsRecoveryPids(rd, size, &abortFn_);
    });
    tsHdrPidsScanned_ = true;
}

bool Demuxer::completeTsPsiScan(spresil::TsRecoveryLane lane, int audioPid) {
    if (!tsPsiProvisional_) return true;
    const spresil::TsVideoPidMap provisional = tsHdrPids_;
    const PlanMark m = spDebug() ? planMark() : PlanMark{};
    const bool scannedOk = withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        scanTsRecoveryPids(rd, size, &abortFn_, true);
    });
    tsPsiProvisional_ = false;
    const bool same = scannedOk && tsHdrPids_.programTrusted && tsHdrPids_.pids == provisional.pids && tsHdrPids_.audioPids == provisional.audioPids;
    bool laneOk = same;
    if (lane == spresil::TsRecoveryLane::Adts) {
        const auto it = tsHdrPids_.audioPids.find(audioPid);
        laneOk = laneOk && it != tsHdrPids_.audioPids.end() && it->second == 0x0f;
    } else {
        laneOk = laneOk && tsHdrPids_.trusted;
    }

    if (!same) { tsHdrPids_ = spresil::TsVideoPidMap{}; tsPsiMap_ = {}; tsAdtsPid_ = -1; tsAdtsChecked_ = true; }
    if (spDebug()) {
        const std::string item = planItem(m, "ts-psi");
        planLog("[DemuxPlan] 候选触发 %s %s", item.c_str(), laneOk ? "与临时结论一致"
                : !scannedOk ? "补完未完成（中止/源已变）：拒绝候选、车道关闭" : "与临时结论不符：拒绝候选、车道关闭");
    }
    return laneOk;
}

void Demuxer::clearTsRecoveryCarry() {
    tsHdrState_ = {};
    tsAdtsState_ = {};
    tsPesState_ = {};

    tsHdrOpenWindowClean_ = false;
}

bool Demuxer::validateTsRecoveryCandidate(spresil::RecoveryPlan& plan, spresil::TsRecoveryLane lane,
                                         int64_t scannedUntil, int audioPid, int64_t* earliestPts90k) {

    if (!completeTsPsiScan(lane, audioPid)) { clearTsRecoveryCarry(); plan = {}; return false; }
    if (!tsPsiLocal_) return true; // old remote subset never gets the new PSI map
    try {
        const auto view = captureReadSourceView();
        if (view) {
            auto proof = spresil::tsRevalidateTsPlan(view.read, view.size, view.current,
                [this] { return abortIO_.load(); }, tsPsiMap_, plan, lane, scannedUntil, audioPid, tsPsiBudget_);
            if (!proof.plan.empty() && proof.confirm()) {
                plan = std::move(proof.plan);
                if (earliestPts90k) *earliestPts90k = proof.earliestPts90k;
                clearTsRecoveryCarry();
                return true;
            }
        }
    } catch (const std::bad_alloc&) {}
    clearTsRecoveryCarry();
    plan = {};
    return false;
}

bool Demuxer::tryTsTransportReopen(bool analyze) {
    if (!fmtCtx_ || !tsMpegTs_ || !resilientRecoveryEnabled_ || !localIO_ || abortIO_.load() || tsHdrAttempts_ >= 8) return false;

    const bool zeroDims = analyze && videoStream_ >= 0 && (size_t)videoStream_ < streams_.size() && streams_[videoStream_].width == 0;
    const int64_t window = zeroDims ? 8ll * 1024 * 1024 : 512ll * 1024;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    int64_t scanned = 0;
    ensureTsRecoveryPids();
    if (!zeroDims && tsHdrOpenWindowClean_ && tsHdrPids_.trusted && localIO_->patches.size() == tsHdrOpenPatchCount_ &&
        localIO_->viewRevision.load(std::memory_order_acquire) == tsHdrOpenViewRev_) {

        if (spDebug()) planNote_ = "打开期同窗口已核对";
        return false;
    }
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        if (!tsHdrPids_.trusted) return;
        spresil::TsHeaderScanState st;
        plan = spresil::planTsTransportHeaders(rd, size, 0, window, tsHdrPids_, st, &abortFn_);
        scanned = std::min(size, window);
        if (plan.empty()) tsHdrState_ = st;
    });
    if (!tsHdrPids_.trusted) { tsHdrAttempts_ = 8; return false; }
    if (spDebug() && (zeroDims || !plan.empty())) {
        fprintf(stderr, "[Demux] TS 传输头核对（%s，前 %lld KiB）%.1fms: %s %s\n", zeroDims ? "视频无尺寸" : "打开", (long long)(window / 1024),
                (spNowUs() - t0) / 1000.0, plan.empty() ? "无矛盾" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) {
        tsHdrScannedUntil_ = std::max(tsHdrScannedUntil_, scanned);
        if (!zeroDims && window == scanned) {
            tsHdrOpenWindowClean_ = true;
            tsHdrOpenPatchCount_ = localIO_->patches.size();
            tsHdrOpenViewRev_ = localIO_->viewRevision.load(std::memory_order_acquire);
        }
        return false;
    }
    if (!validateTsRecoveryCandidate(plan, spresil::TsRecoveryLane::Header, scanned)) return false;
    ++tsHdrAttempts_;
    if (!reopenCandidateOrFallBack(plan, analyze, zeroDims, "TS 传输头")) return false;
    tsHdrScannedUntil_ = scanned;
    tsHdrState_ = spresil::TsHeaderScanState{};
    noteOpenRecovery(plan.kind, "TS 传输头与载荷结构矛盾，候选恢复 " + plan.kind + "：" + plan.detail + "（" + std::to_string(plan.patches.size()) + " 字节）");
    if (spDebug()) fprintf(stderr, "[Demux] TS 传输头候选生效：%zu 字节，视频 %dx%d\n", plan.patches.size(), streams_[videoStream_].width, streams_[videoStream_].height);
    return true;
}

bool Demuxer::attemptTsTransportRecovery(int64_t untilPos, bool flush) {
    if (!fmtCtx_ || !localIO_ || tsHdrAttempts_ >= 8) return false;
    if (!flush && spNowUs() < tsScanHoldUntilUs_) return false;
    ensureTsRecoveryPids();
    if (!tsHdrPids_.trusted) { tsHdrAttempts_ = 8; return false; }
    const int stride = fmtCtx_->packet_size > 0 ? fmtCtx_->packet_size : 188;
    if (stride != 188 && stride != 192 && stride != 204) { tsHdrAttempts_ = 8; return false; }
    const int64_t aligned = flush ? untilPos : (untilPos / stride) * stride;
    if (aligned <= tsHdrScannedUntil_) return false;
    const int64_t window = aligned - tsHdrScannedUntil_;
    if (window > 2ll * 1024 * 1024) {
        tsHdrScannedUntil_ = aligned;
        tsHdrState_ = spresil::TsHeaderScanState{};
        return false;
    }
    spresil::RecoveryPlan plan;
    const int64_t from = tsHdrScannedUntil_;
    withPatchedLocalReader([&](const spresil::Reader& rd, int64_t size) {
        spresil::TsGeometry geom;
        spresil::TsByteSource src = tsLaneSource(rd, size, from, std::min(size, from + window), aligned + 40ll * stride, geom);
        plan = spresil::planTsTransportHeaders(src, geom, size, from, window, tsHdrPids_, tsHdrState_, &abortFn_);
    });
    tsHdrScannedUntil_ = aligned;
    if (plan.empty()) return false;
    if (!validateTsRecoveryCandidate(plan, spresil::TsRecoveryLane::Header, aligned)) return false;
    ++tsHdrAttempts_;
    if (!installPatches(plan.patches, true)) return false;
    const int64_t target = recoverySeekTargetUs();
    if (replayFromRecoveryTarget(target, "TS 传输头补丁 " + std::to_string(plan.patches.size()) + " 字节已装入（" + std::to_string(from) + "–" + std::to_string(aligned) + "）：" + plan.detail) != RecoveryOutcome::AppliedAndResumed) return false;
    pushRecoveryEvent("TS 传输头与载荷结构矛盾，候选恢复 " + plan.kind + "：" + plan.detail, byteToUsGuess(plan.damagedFrom), byteToUsGuess(plan.damagedUntil));
    return true;
}

void Demuxer::verifyMp4SeekRap(int64_t absUs, int streamIndex, bool forwardKeyframe, int& ret) {
    if (ret < 0 || !resilientRecoveryEnabled_ || !localIO_ || localIO_->fd < 0 || videoStream_ < 0 || fmp4Like_ || !sampleEofRetryEligible_ || abortIO_.load()) return;
    AVStream* st = fmtCtx_->streams[videoStream_];
    const AVCodecParameters* par = st->codecpar;
    const bool hevc = par->codec_id == AV_CODEC_ID_HEVC;
    if ((par->codec_id != AV_CODEC_ID_H264 && !hevc) || !par->extradata || par->extradata_size < 7 || par->extradata[0] != 1) return;
    const int nalLen = hevc ? (par->extradata_size >= 23 ? (par->extradata[21] & 3) + 1 : 4) : (par->extradata[4] & 3) + 1;
    const std::vector<std::pair<uint32_t, int>> ppsExtra = hevc ? spresil::hvccPpsSliceFields(par->extradata, par->extradata_size) : std::vector<std::pair<uint32_t, int>>{};
    const int64_t t0 = spNowUs();
    dropSeekPushback();
    int64_t landedPos = -1;
    const uint8_t* data = nullptr;
    size_t size = 0;
    for (int n = 0; n < 64; ++n) {
        AVPacket* probe = av_packet_alloc();
        if (!probe) break;
        if (av_read_frame(fmtCtx_, probe) < 0) { av_packet_free(&probe); break; }
        seekPushback_.push_back(probe);
        if (probe->stream_index == videoStream_) {
            landedPos = probe->pos;
            if (probe->data && probe->size > 0) { data = probe->data; size = (size_t)probe->size; }
            break;
        }
    }
    auto reseek = [&] { dropSeekPushback(); ret = rawSeekToAbsUs(absUs, streamIndex, forwardKeyframe); };
    if (landedPos < 0) { reseek(); return; }
    if (mp4RapVerifiedPos_.count(landedPos)) return;
    const spresil::RapClass cls = spresil::avcSampleRapClass(data, size, nalLen, hevc, hevc ? &ppsExtra : nullptr);
    if (cls != spresil::RapClass::Predicted) {
        if (cls != spresil::RapClass::Unknown) mp4RapVerifiedPos_.insert(landedPos);
        return;
    }
    const int cnt = avformat_index_get_entries_count(st);
    int idx = -1;
    for (int k = 0; k < cnt; ++k) { const AVIndexEntry* e = avformat_index_get_entry(st, k); if (e && e->pos == landedPos) { idx = k; break; } }
    if (idx < 0) { reseek(); return; }
    const spresil::Reader raw = localRawReader();
    const spresil::Reader rd = localIO_->patches.empty() ? raw : spresil::patchedReader(raw, localIO_->patches);
    const int dir = forwardKeyframe ? 1 : -1;
    struct Entry { int64_t pos; int64_t ts; int size; int dist; };
    std::vector<Entry> fakeKeys;
    { const AVIndexEntry* e = avformat_index_get_entry(st, idx); fakeKeys.push_back({e->pos, e->timestamp, e->size, e->min_distance}); }
    Entry real{-1, 0, 0, 0};
    int64_t bytes = 0;

    int64_t walkCap = 32ll * 1024 * 1024;
    if (remoteVolume_) {
        int64_t gopBytes = 0;
        int keys = 0;
        for (int k = idx + dir, steps = 0; k >= 0 && k < cnt && steps < 600 && keys < 2 && gopBytes < walkCap; k += dir, ++steps) {
            const AVIndexEntry* e = avformat_index_get_entry(st, k);
            if (!e) break;
            if (e->size > 0) gopBytes += e->size;
            if (e->flags & AVINDEX_KEYFRAME) ++keys;
        }
        walkCap = std::clamp<int64_t>(gopBytes, 8ll * 1024 * 1024, walkCap);
    }
    for (int k = idx + dir, steps = 0; k >= 0 && k < cnt && steps < 600 && bytes < walkCap && !abortIO_.load(); k += dir, ++steps) {
        const AVIndexEntry* e = avformat_index_get_entry(st, k);
        if (!e || e->size <= 0 || e->size > 8 * 1024 * 1024) break;
        std::vector<uint8_t> s((size_t)e->size);
        if (rd(e->pos, s.data(), s.size()) != (int64_t)s.size()) break;
        bytes += e->size;
        const spresil::RapClass c = spresil::avcSampleRapClass(s.data(), s.size(), nalLen, hevc, hevc ? &ppsExtra : nullptr);
        if (c == spresil::RapClass::Idr || c == spresil::RapClass::IntraOrRecovery) { real = {e->pos, e->timestamp, e->size, e->min_distance}; break; }
        if (c == spresil::RapClass::Predicted && (e->flags & AVINDEX_KEYFRAME)) fakeKeys.push_back({e->pos, e->timestamp, e->size, e->min_distance});
    }
    if (real.pos < 0) {
        if (spDebug()) fprintf(stderr, "[Demux] seek 落点样本 @%lld 声明为同步样本却是 P/B 图，%s向 600 条内未找到独立图：保持原落点\n", (long long)landedPos, dir > 0 ? "前" : "后");
        mp4RapVerifiedPos_.insert(landedPos);
        return;
    }
    for (const Entry& f : fakeKeys) av_add_index_entry(st, f.pos, f.ts, f.size, f.dist, 0);
    av_add_index_entry(st, real.pos, real.ts, real.size, real.dist, AVINDEX_KEYFRAME);
    mp4RapVerifiedPos_.insert(real.pos);
    ++mp4RapFixes_;
    const int64_t landedUs = av_rescale_q(fakeKeys.front().ts, st->time_base, AV_TIME_BASE_Q), realUs = av_rescale_q(real.ts, st->time_base, AV_TIME_BASE_Q);
    if (mp4RapFixes_ <= 3) {
        pushRecoveryEvent("stss 声明的同步样本（" + std::to_string(landedUs / 1e6).substr(0, 5) + "s）不是独立图，seek 改落到经 AU 语法核实的随机访问点（" +
                          std::to_string(realUs / 1e6).substr(0, 5) + "s，" + std::to_string(fakeKeys.size()) + " 个假同步点去标）", -1, -1);
    }
    if (spDebug()) fprintf(stderr, "[Demux] seek 落点 %.3fs 是 P/B 图（stss 错指）→ 真随机访问点 %.3fs（%zu 个假同步点去标，%.1fms）\n",
                           landedUs / 1e6, realUs / 1e6, fakeKeys.size(), (spNowUs() - t0) / 1000.0);
    reseek();
}

void Demuxer::tryMp4CttsRecovery() {
    if (!fmtCtx_ || !localIO_ || !resilientRecoveryEnabled_ || fmp4Like_ || videoStream_ < 0 || abortIO_.load()) return;
    const AVCodecParameters* par = fmtCtx_->streams[videoStream_]->codecpar;
    if (par->codec_id != AV_CODEC_ID_H264 && par->codec_id != AV_CODEC_ID_HEVC) return;
    const int64_t t0 = spNowUs();
    auto plan = std::make_shared<spresil::Mp4CttsPlan>();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        *plan = spresil::planMp4CttsReorder(rd, size, &abortFn_);
    });
    const double ms = (spNowUs() - t0) / 1000.0;
    if (spDebug()) {
        static const char* const kScreen[] = {"不适用", "粗筛放行", "预筛放行", "全量无矛盾"};
        planNote_ = plan->candidate ? "候选" : kScreen[std::clamp(plan->screen, 0, 3)];
    }
    if (spDebug() && (plan->candidate || ms > 2.0)) fprintf(stderr, "[Demux] MP4 ctts 结构判据 %.2fms: %s\n", ms, plan->candidate ? plan->detail.c_str() : "无矛盾");
    if (!plan->candidate) return;

    const size_t N = plan->samples.size();
    size_t first = plan->c.runFirst > 64 ? plan->c.runFirst - 64 : 0, last = std::min(N - 1, plan->c.runLast + 64);
    if (!plan->keyframe.empty()) {
        while (first > 0 && !plan->keyframe[first]) --first;
        while (last + 1 < N && !plan->keyframe[last + 1]) ++last;
    }
    if (last - first + 1 > 512) { if (spDebug()) fprintf(stderr, "[Demux] ctts 试解窗口 %zu 个样本超预算：不试\n", last - first + 1); return; }
    auto trial = std::make_shared<Mp4CttsTrial>();
    cttsTrial_ = trial;
    const std::string path = path_;
    const int vi = videoStream_;
    const AVCodecID cid = par->codec_id;
    const int64_t patchOffset = plan->patchOffset;
    const uint32_t newValue = plan->c.newValue;
    const std::string detail = plan->detail;

    auto launch = [&](auto&& body) {
        try { std::thread(std::forward<decltype(body)>(body)).detach(); }
        catch (...) { cttsTrial_.reset(); if (spDebug()) fprintf(stderr, "[Demux] ctts 私有试解线程启动失败：不试\n"); }
    };
    launch([trial, plan, path, vi, cid, first, last, patchOffset, newValue, detail] {
        pthread_setname_np("sp.ctts-trial");
        struct Finish { std::shared_ptr<Mp4CttsTrial> t; ~Finish() { t->done.store(true, std::memory_order_release); } } finish{trial};
        if (const int64_t stallUs = spAuxStallUs()) spSleepUninterruptible(stallUs);

        sptrial::InterruptCtx ic;
        ic.abort = [trial] { return trial->abort.load(std::memory_order_acquire); };
        ic.deadlineUs = sptrial::monotonicNowUs() + 5000000;
        int anyPkts = 0; int64_t anyBytes = 0;
        auto overBudget = [&] { return anyPkts >= 16384 || anyBytes >= (128ll << 20) || ic.cancelled(); };
        AVFormatContext* fc = sptrial::openInput(path, &ic);
        if (!fc) return;
        const AVCodec* dec = avcodec_find_decoder(cid);
        AVCodecContext* ctx = ((unsigned)vi < fc->nb_streams && dec) ? avcodec_alloc_context3(dec) : nullptr;
        std::vector<size_t> order; int errors = 0, flagged = 0;
        if (ctx) {
            avcodec_parameters_to_context(ctx, fc->streams[vi]->codecpar);
            ctx->thread_count = 1;
            ctx->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
            if (avcodec_open2(ctx, dec, nullptr) == 0) {
                std::map<int64_t, size_t> byPos;
                for (size_t i = first; i <= last; ++i) byPos[plan->samples[i].first] = i;
                const AVStream* st = fc->streams[vi];
                const int64_t ts = av_rescale_q(plan->dts[first], AVRational{1, (int)std::max<uint32_t>(1, plan->timescale)}, st->time_base);
                if (plan->timescale == 0 || avformat_seek_file(fc, vi, INT64_MIN, ts, ts, 0) < 0) avformat_seek_file(fc, vi, INT64_MIN, 0, 0, 0);
                AVPacket* pkt = av_packet_alloc(); AVFrame* fr = av_frame_alloc();
                auto receive = [&] {
                    while (avcodec_receive_frame(ctx, fr) == 0) {
                        if (fr->decode_error_flags || (fr->flags & AV_FRAME_FLAG_CORRUPT)) ++flagged;
                        if (fr->opaque) order.push_back((size_t)(uintptr_t)fr->opaque - 1);
                        av_frame_unref(fr);
                    }
                };
                int sent = 0; bool reached = false;
                while (sent < 1024 && !overBudget() && av_read_frame(fc, pkt) >= 0) {
                    ++anyPkts; anyBytes += pkt->size;
                    if (pkt->stream_index == vi) {
                        auto it = byPos.find(pkt->pos);
                        if (it == byPos.end()) { if (reached && pkt->pos > plan->samples[last].first) { av_packet_unref(pkt); break; } av_packet_unref(pkt); continue; }
                        reached = true;
                        pkt->opaque = (void*)(uintptr_t)(it->second + 1);
                        int r = avcodec_send_packet(ctx, pkt);
                        if (r == AVERROR(EAGAIN)) { receive(); r = avcodec_send_packet(ctx, pkt); }
                        if (r < 0) ++errors;
                        receive();
                        ++sent;
                        if (it->second == last) { av_packet_unref(pkt); break; }
                    }
                    av_packet_unref(pkt);
                }
                avcodec_send_packet(ctx, nullptr);
                receive();
                av_frame_free(&fr); av_packet_free(&pkt);
            }
            avcodec_free_context(&ctx);
        }
        avformat_close_input(&fc);
        if (overBudget()) { if (spDebug()) fprintf(stderr, "[Demux] ctts 私有试解：取消/超预算（%d 包 %lld 字节）：不裁决\n", anyPkts, (long long)anyBytes); return; }
        if (errors || flagged || order.size() < 2) return;
        bool coversRun = true;
        { std::vector<uint8_t> seen(last - first + 1, 0); for (size_t i : order) if (i >= first && i <= last) seen[i - first] = 1; for (size_t i = plan->c.runFirst; i <= plan->c.runLast; ++i) if (!seen[i - first]) coversRun = false; }
        bool origIncreasing = true, candIncreasing = true;
        for (size_t k = 1; k < order.size(); ++k) {
            if (plan->cts[order[k]] <= plan->cts[order[k - 1]]) origIncreasing = false;
            if (plan->ctsNew[order[k]] <= plan->ctsNew[order[k - 1]]) candIncreasing = false;
        }
        if (spDebug()) fprintf(stderr, "[Demux] ctts 私有试解：%zu 帧出图，原组合时间%s递增，候选%s递增，覆盖涉事 run=%d\n", order.size(),
                               origIncreasing ? "" : "不", candIncreasing ? "" : "不", (int)coversRun);
        if (!coversRun || origIncreasing || !candIncreasing) return;
        spresil::Patch p; p.offset = patchOffset;
        p.bytes = {(uint8_t)(newValue >> 24), (uint8_t)(newValue >> 16), (uint8_t)(newValue >> 8), (uint8_t)newValue};
        trial->patches.push_back(p);
        trial->detail = detail + "，私有试解按真实出图顺序验证 " + std::to_string(order.size()) + " 帧";
        trial->ok = true;
    });
}

bool Demuxer::applyMp4CttsTrial() {
    if (!cttsTrial_ || !cttsTrial_->done.load(std::memory_order_acquire)) return false;
    auto trial = cttsTrial_;
    cttsTrial_.reset();
    if (!trial->ok || abortIO_.load()) return false;
    if (!reopenInPlace(trial->patches, false, "mp4-ctts")) return false;
    noteOpenRecovery("mp4-ctts", "MP4 ctts 组合时间偏移与出图顺序矛盾，候选恢复 mp4-ctts：" + trial->detail);
    return true;
}

bool Demuxer::tryRawAudioFramesReopen() {
    if (!fmtCtx_ || !rawAudioLike_ || !localIO_ || abortIO_.load()) return false;
    spresil::RecoveryPlan plan;
    int64_t consumed = 0;
    const int64_t t0 = spNowUs();
    withFileReader(path_, [&](const spresil::Reader& read, int64_t size) {
        plan = spresil::planRawAudioFrames(read, size, 0, 1ll << 20, rawAudioAdts_, &abortFn_, &consumed);
    });
    rawAudioScannedUntil_ = std::max<int64_t>(consumed, 0);
    if (consumed <= 0) rawAudioDone_ = true;
    if (spDebug() && (!plan.empty() || spNowUs() - t0 > 2000)) {
        fprintf(stderr, "[Demux] 裸音频帧链核对（前 1 MiB，续点 %lld）%.1fms: %s %s\n", (long long)consumed, (spNowUs() - t0) / 1000.0,
                plan.empty() ? "无矛盾" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    ++rawAudioAttempts_;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str(), false, true)) return false;
    rebuildStreamTable();
    noteOpenRecovery(plan.kind, "裸音频帧头与后继矛盾，候选恢复 " + plan.kind + "：" + plan.detail);
    return true;
}

bool Demuxer::attemptRawAudioFrameRecovery(int64_t untilPos) {
    if (!fmtCtx_ || !localIO_ || rawAudioDone_ || rawAudioAttempts_ >= 8 || untilPos <= rawAudioScannedUntil_) return false;
    const int64_t from = rawAudioScannedUntil_;
    const int64_t window = untilPos - from;
    spresil::RecoveryPlan plan;
    int64_t consumed = from;
    bool realigned = false;
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        if (window > scanCap(16ll * 1024 * 1024)) {
            const int64_t s = spresil::rawAudioSyncAt(rd, size, untilPos, rawAudioAdts_);
            consumed = s >= 0 ? s : untilPos;
            realigned = true;
            return;
        }
        plan = spresil::planRawAudioFrames(rd, size, from, window, rawAudioAdts_, &abortFn_, &consumed);

        for (int ext = 0; ext < 8 && !plan.empty() && consumed < size && !abortIO_.load(); ++ext) {
            int64_t c2 = consumed;
            spresil::RecoveryPlan more = spresil::planRawAudioFrames(rd, size, consumed, 1ll << 20, rawAudioAdts_, &abortFn_, &c2);
            if (c2 <= consumed) break;
            consumed = c2;
            if (more.empty()) break;
            mergeExtension(plan, more);
        }
    });
    if (realigned) { rawAudioScannedUntil_ = consumed; return false; }
    if (consumed <= from && window >= 64 * 1024 && plan.empty()) { rawAudioDone_ = true; return false; }
    rawAudioScannedUntil_ = std::max(rawAudioScannedUntil_, consumed);
    if (plan.empty()) return false;
    ++rawAudioAttempts_;
    if (!installPatches(plan.patches, true)) return false;
    const int64_t target = recoverySeekTargetUs();
    if (replayFromRecoveryTarget(target, "裸音频补丁 " + std::to_string(plan.patches.size()) + " 字节已装入（" + std::to_string(from) + "–" + std::to_string(consumed) + "）：" + plan.detail) != RecoveryOutcome::AppliedAndResumed) return false;
    pushRecoveryEvent("裸音频帧头与后继矛盾，候选恢复 " + plan.kind + "：" + plan.detail + "（累计 " + std::to_string(plan.patches.size()) + " 帧）",
                      byteToUsGuess(plan.damagedFrom), byteToUsGuess(plan.damagedUntil));
    return true;
}

int Demuxer::resolveTsAdtsPid() {
    if (tsAdtsChecked_) return tsAdtsPid_;
    tsAdtsChecked_ = true;
    if (!fmtCtx_ || !localIO_ || audioStream_ < 0 || (unsigned)audioStream_ >= fmtCtx_->nb_streams) return -1;
    ensureTsRecoveryPids();
    const AVStream* as = fmtCtx_->streams[audioStream_];
    const auto it = tsHdrPids_.audioPids.find(as->id);
    if (tsHdrPids_.programTrusted && it != tsHdrPids_.audioPids.end() && it->second == 0x0f && as->codecpar->codec_id == AV_CODEC_ID_AAC) tsAdtsPid_ = as->id;
    const int stride = fmtCtx_->packet_size > 0 ? fmtCtx_->packet_size : 188;
    if (stride != 188 && stride != 192 && stride != 204) tsAdtsPid_ = -1;
    return tsAdtsPid_;
}

bool Demuxer::tryTsAdtsReopen() {
    if (!fmtCtx_ || !tsMpegTs_ || !localIO_ || abortIO_.load() || resolveTsAdtsPid() < 0) return false;
    const int stride = fmtCtx_->packet_size > 0 ? fmtCtx_->packet_size : 188;
    spresil::RecoveryPlan plan;
    int64_t scannedTo = 0;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        const int64_t first = std::min<int64_t>(size, (1ll << 20) / stride * stride);
        plan = spresil::planTsAdtsFrames(rd, size, 0, first, tsAdtsPid_, tsAdtsState_, &abortFn_);
        scannedTo = first;
        extendTsScan(plan, scannedTo, size, stride, abortIO_, [&](int64_t at, int64_t step) { return spresil::planTsAdtsFrames(rd, size, at, step, tsAdtsPid_, tsAdtsState_, &abortFn_); });
    });
    tsAdtsScannedUntil_ = scannedTo;
    if (spDebug() && (!plan.empty() || spNowUs() - t0 > 2000)) {
        fprintf(stderr, "[Demux] TS ADTS 帧链核对（PID 0x%x，前 %lld KiB）%.1fms: %s %s\n", tsAdtsPid_, (long long)(scannedTo / 1024), (spNowUs() - t0) / 1000.0,
                plan.empty() ? "无矛盾" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    if (!validateTsRecoveryCandidate(plan, spresil::TsRecoveryLane::Adts, scannedTo, tsAdtsPid_)) return false;
    ++tsAdtsAttempts_;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str())) return false;
    noteOpenRecovery(plan.kind, "TS 音频 ADTS 帧长与后继帧头矛盾，候选恢复 " + plan.kind + "：" + plan.detail + "（累计 " + std::to_string(plan.patches.size()) + " 帧）");
    return true;
}

bool Demuxer::attemptTsAdtsRecovery(int64_t untilPos, bool flush) {
    if (!fmtCtx_ || !localIO_ || tsAdtsAttempts_ >= 8 || resolveTsAdtsPid() < 0) return false;
    if (!flush && spNowUs() < tsScanHoldUntilUs_) return false;
    const int stride = fmtCtx_->packet_size > 0 ? fmtCtx_->packet_size : 188;
    const int64_t aligned = flush ? untilPos : (untilPos / stride) * stride;
    if (aligned <= tsAdtsScannedUntil_) return false;
    const int64_t window = aligned - tsAdtsScannedUntil_;
    if (window > 2ll * 1024 * 1024) {
        tsAdtsScannedUntil_ = aligned;
        tsAdtsState_ = spresil::TsAdtsScanState{};
        return false;
    }
    spresil::RecoveryPlan plan;
    const int64_t from = tsAdtsScannedUntil_;
    int64_t scannedTo = aligned;
    withPatchedLocalReader([&](const spresil::Reader& rd, int64_t size) {
        spresil::TsGeometry geom;
        spresil::TsByteSource src = tsLaneSource(rd, size, from, std::min(size, from + window), aligned + 40ll * stride, geom);
        plan = spresil::planTsAdtsFrames(src, geom, size, from, window, tsAdtsPid_, tsAdtsState_, &abortFn_);

        extendTsScan(plan, scannedTo, size, stride, abortIO_, [&](int64_t at, int64_t step) { return spresil::planTsAdtsFrames(rd, size, at, step, tsAdtsPid_, tsAdtsState_, &abortFn_); });
    });
    tsAdtsScannedUntil_ = scannedTo;
    if (plan.empty()) return false;
    if (!validateTsRecoveryCandidate(plan, spresil::TsRecoveryLane::Adts, scannedTo, tsAdtsPid_)) return false;
    ++tsAdtsAttempts_;
    if (!installPatches(plan.patches, true)) return false;
    const int64_t target = recoverySeekTargetUs();
    if (replayFromRecoveryTarget(target, "TS ADTS 补丁 " + std::to_string(plan.patches.size()) + " 字节已装入（" + std::to_string(from) + "–" + std::to_string(aligned) + "）：" + plan.detail) != RecoveryOutcome::AppliedAndResumed) return false;
    pushRecoveryEvent("TS 音频 ADTS 帧长与后继帧头矛盾，候选恢复 " + plan.kind + "：" + plan.detail + "（累计 " + std::to_string(plan.patches.size()) + " 帧）",
                      byteToUsGuess(plan.damagedFrom), byteToUsGuess(plan.damagedUntil));
    return true;
}

bool Demuxer::loadMkvFlacTracks() {
    if (mkvFlacTracksScanned_) return !mkvFlacTracks_.empty();
    mkvFlacTracksScanned_ = true;
    if (!localIO_ || !mkvLike_) return false;
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        int64_t first = -1;
        const std::vector<spresil::MkvTrackDecl> decls = spresil::mkvReadTrackDecls(rd, size, &abortFn_, &first);
        mkvFirstClusterPos_ = first;
        for (const spresil::MkvTrackDecl& d : decls) if (d.type == 2 && d.codecId == "A_FLAC" && d.number > 0) mkvFlacTracks_.push_back((int)d.number);
    });
    return !mkvFlacTracks_.empty();
}

bool Demuxer::tryMkvFlacLacingReopen() {
    if (!fmtCtx_ || !resilientRecoveryEnabled_ || abortIO_.load() || !loadMkvFlacTracks() || mkvFirstClusterPos_ < 0) return false;
    spresil::RecoveryPlan plan;
    spresil::MkvFlacLaceResult res;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        plan = spresil::planMkvFlacLacing(rd, size, mkvFirstClusterPos_, 4ll * 1024 * 1024, mkvFlacTracks_, 16, &abortFn_, &res);
    });
    if (spDebug() && (!plan.empty() || res.unfixable > 0 || spNowUs() - t0 > 2000)) {
        fprintf(stderr, "[Demux] MKV FLAC lacing 核对（首簇起 %d 块：%d 通过 / %d 无法裁决）%.1fms: %s %s\n", res.blocks, res.verified, res.unfixable,
                (spNowUs() - t0) / 1000.0, plan.empty() ? "无补丁" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    ++mkvFlacLaceAttempts_;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str())) return false;
    noteOpenRecovery(plan.kind, "Matroska FLAC 块的 lacing 表与帧链矛盾，候选恢复 " + plan.kind + "：" + plan.detail);
    return true;
}

bool Demuxer::attemptMkvFlacLacingRecovery(int64_t pos) {
    if (!fmtCtx_ || !localIO_ || mkvFlacLaceAttempts_ >= 8 || pos < 0 || !loadMkvFlacTracks()) return false;
    spresil::RecoveryPlan plan;
    spresil::MkvFlacLaceResult res;
    int64_t clusterPos = -1;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        int64_t tc = -1;
        clusterPos = spresil::mkvFindEnclosingCluster(rd, pos + 1, 64ll * 1024 * 1024, &tc, &abortFn_);
        if (clusterPos < 0) return;
        const int64_t winTo = clusterPos + 8ll * 1024 * 1024;
        for (const auto& r : mkvFlacLaceRegions_) if (clusterPos < r.second && winTo > r.first) { clusterPos = -2; return; }
        if (mkvFlacLaceRegions_.size() < 256) mkvFlacLaceRegions_.push_back({clusterPos, winTo});
        plan = spresil::planMkvFlacLacing(rd, size, clusterPos, 8ll * 1024 * 1024, mkvFlacTracks_, 512, &abortFn_, &res);
    });
    if (clusterPos == -2) return false;
    if (spDebug()) {
        fprintf(stderr, "[Demux] 音频解码错误 @%lld → MKV FLAC lacing 核对（簇@%lld 起 %d 块：%d 通过 / %d 无法裁决）%.1fms: %s %s\n", (long long)pos,
                (long long)clusterPos, res.blocks, res.verified, res.unfixable, (spNowUs() - t0) / 1000.0, plan.empty() ? "无补丁" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    ++mkvFlacLaceAttempts_;
    if (!installPatches(plan.patches, true)) return false;
    const int64_t target = recoverySeekTargetUs();
    if (replayFromRecoveryTarget(target, "MKV FLAC lacing 补丁 " + std::to_string(plan.patches.size()) + " 处已装入") != RecoveryOutcome::AppliedAndResumed) return false;
    pushRecoveryEvent("Matroska FLAC 块的 lacing 表与帧链矛盾，候选恢复 " + plan.kind + "：" + plan.detail, byteToUsGuess(plan.damagedFrom), byteToUsGuess(plan.damagedUntil));
    return true;
}

bool Demuxer::attemptVideoTrackIsolation() {
    if (!fmtCtx_ || videoIsolationTried_ || videoIsolated_ || !discardEligible_ || videoStream_ < 0 || audioStream_ < 0 || lastGoodAbsUs_ >= 0 || abortIO_.load()) return false;
    if (!mkvLike_) return false;
    if ((unsigned)videoStream_ >= fmtCtx_->nb_streams || (unsigned)audioStream_ >= fmtCtx_->nb_streams) return false;
    videoIsolationTried_ = true;
    AVStream* vs = fmtCtx_->streams[videoStream_];
    const AVDiscard oldDiscard = vs->discard;
    vs->discard = AVDISCARD_ALL;
    int audioPkts = 0, reads = 0, errs = 0;
    const int64_t t0 = spNowUs();
    dropSeekPushback();
    if (avformat_seek_file(fmtCtx_, -1, INT64_MIN, 0, 0, 0) >= 0) {
        AVPacket* pkt = av_packet_alloc();
        while (pkt && reads < 64 && audioPkts < 8 && !abortIO_.load()) {
            const int r = av_read_frame(fmtCtx_, pkt);
            ++reads;
            if (r == AVERROR_EOF) break;
            if (r < 0) { ++errs; continue; }
            if (pkt->stream_index == audioStream_) ++audioPkts;
            av_packet_unref(pkt);
        }
        av_packet_free(&pkt);
    }
    const bool ok = audioPkts >= 4;
    if (!ok) vs->discard = oldDiscard;
    const int sret = avformat_seek_file(fmtCtx_, -1, INT64_MIN, 0, 0, 0);
    if (spDebug()) {
        fprintf(stderr, "[Demux] 视频轨 流#%d 隔离验证 %.1fms：读 %d 包 / 音频 %d / 错误 %d → %s（回 seek %d）\n", videoStream_, (spNowUs() - t0) / 1000.0, reads,
                audioPkts, errs, ok ? "接管纯音频" : "不成立，原样恢复", sret);
    }
    if (!ok || sret < 0) return false;
    videoIsolated_ = true;
    eof_ = false;
    lastGoodPos_ = -1;
    pushRecoveryEvent("视频轨 流#" + std::to_string(videoStream_) + " 在 demux 层解包失败且无唯一候选，隔离该轨后音轨可交付（" + std::to_string(audioPkts) +
                      " 包验证）：只播放音频", -1, -1);
    return true;
}

bool Demuxer::tryFlvAvcSubtypeReopen() {
    if (!fmtCtx_ || !flvLike_ || !localIO_ || abortIO_.load()) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withFileReader(path_, [&](const spresil::Reader& read, int64_t size) { plan = spresil::planFlvAvcSubtype(read, size, 13, 1ll << 20, flvAvcState_, &abortFn_); });
    if (spDebug() && (!plan.empty() || spNowUs() - t0 > 2000)) {
        fprintf(stderr, "[Demux] FLV AVC 标签类型核对（前 1 MiB，%d 个标签）%.1fms: %s %s\n", flvAvcState_.tags, (spNowUs() - t0) / 1000.0,
                plan.empty() ? "无矛盾" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    ++flvAvcAttempts_;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str(), false, true)) return false;
    rebuildStreamTable();
    noteOpenRecovery(plan.kind, "FLV AVC 标签的 AVCPacketType 与体语法矛盾，候选恢复 " + plan.kind + "：" + plan.detail);
    return true;
}

bool Demuxer::attemptFlvAvcSubtypeRecovery(int64_t untilPos) {
    if (!fmtCtx_ || !localIO_ || flvAvcAttempts_ >= 8 || untilPos < 13 || untilPos <= flvAvcState_.scannedUntil) return false;
    const int64_t from = flvAvcState_.scannedUntil;
    const int64_t window = untilPos - from;
    if (window > scanCap(16ll * 1024 * 1024)) { flvAvcState_.scannedUntil = untilPos; return false; }
    spresil::RecoveryPlan plan;
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        plan = spresil::planFlvAvcSubtype(rd, size, from, window, flvAvcState_, &abortFn_);

        for (int ext = 0; ext < 8 && !plan.empty() && flvAvcState_.scannedUntil < size && !abortIO_.load(); ++ext) {
            const int64_t at = flvAvcState_.scannedUntil;
            spresil::RecoveryPlan more = spresil::planFlvAvcSubtype(rd, size, at, 1ll << 20, flvAvcState_, &abortFn_);
            if (flvAvcState_.scannedUntil <= at) break;
            if (more.empty()) break;
            mergeExtension(plan, more);
        }
    });
    if (plan.empty()) return false;
    ++flvAvcAttempts_;
    const int64_t evFrom = byteToUsGuess(plan.damagedFrom), evUntil = byteToUsGuess(plan.damagedUntil);
    if (spDebug()) fprintf(stderr, "[Demux] FLV AVC 标签类型矛盾（%lld–%lld）：%s → 原地重开\n", (long long)from, (long long)untilPos, plan.detail.c_str());
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str())) return false;
    pushRecoveryEvent("FLV AVC 标签的 AVCPacketType 与体语法矛盾，候选恢复 " + plan.kind + "：" + plan.detail, evFrom, evUntil);
    return true;
}

bool Demuxer::attemptFmp4FragmentCheck(int64_t pktPos) {
    if (!fmtCtx_ || !localIO_ || !fmp4Like_ || fmp4FragAttempts_ >= 8 || pktPos < 0 || pktPos < fmp4FragCheckedUntil_) return false;
    spresil::RecoveryPlan plan;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        if (!fmp4CfgLoaded_) {
            fmp4CfgLoaded_ = true;
            fmp4Cfgs_ = spresil::mp4ReadTrackConfigs(rd, size, &abortFn_);
            uint32_t vid = 0; int nv = 0;
            for (const spresil::Mp4TrackCfg& c : fmp4Cfgs_) if (c.video) { vid = c.id; ++nv; }
            if (nv == 1) fmp4Anchors_ = spresil::mp4ReadFragAnchors(rd, size, vid, &abortFn_);
            if (spDebug()) fprintf(stderr, "[Demux] fMP4 轨配置 %zu 条（视频 %d）、sidx %zu / tfra %zu 条锚\n", fmp4Cfgs_.size(), nv, fmp4Anchors_.sidx.size(), fmp4Anchors_.tfra.size());
        }
        if (fmp4Cfgs_.empty()) { fmp4FragCheckedUntil_ = INT64_MAX; return; }
        int64_t pos = fmp4FragCursor_;
        spresil::Box moof;
        bool haveMoof = false;
        for (int hops = 0; hops < 256 && pos + 8 <= size; ++hops) {
            if (spresil::aborted(&abortFn_)) return;
            spresil::Box b;
            if (!spresil::readBox(rd, pos, size, b) || b.sizeFieldZero || b.largeSizeZero || b.end() > size) { fmp4FragCheckedUntil_ = INT64_MAX; return; }
            if (b.is("moof")) { moof = b; haveMoof = true; }
            else if (b.is("mdat") && haveMoof) {
                if (!fmp4CheckedMoofs_.count(moof.pos)) {
                    fmp4CheckedMoofs_.insert(moof.pos);
                    plan = spresil::planFmp4FragmentCheck(rd, size, moof, b, fmp4Cfgs_, fmp4Anchors_, &abortFn_);
                }
                haveMoof = false;
                fmp4FragCursor_ = b.end();
                fmp4FragCheckedUntil_ = b.end();
                if (!plan.empty() || pktPos < b.end()) return;
                pos = b.end();
                continue;
            }
            pos = b.end();
            fmp4FragCursor_ = pos;
        }
    });
    if (plan.empty()) return false;
    ++fmp4FragAttempts_;
    if (spDebug()) fprintf(stderr, "[Demux] fMP4 片检查（包 @%lld）%.1fms: %s %s\n", (long long)pktPos, (spNowUs() - t0) / 1000.0, plan.kind.c_str(), plan.detail.c_str());

    const int64_t evFrom = byteToUsGuess(plan.damagedFrom), evUntil = byteToUsGuess(plan.damagedUntil);
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str())) return false;
    pushRecoveryEvent("fMP4 片内声明与载荷/索引矛盾，候选恢复 " + plan.kind + "：" + plan.detail, evFrom, evUntil);
    return true;
}

bool Demuxer::withPatchedFileReader(const std::function<void(const spresil::Reader&, int64_t)>& fn) {
    const spresil::PatchOverlay overlay = localIO_ ? localIO_->patches : spresil::PatchOverlay{};
    return withFileReader(path_, [&](const spresil::Reader& base, int64_t size) {
        if (overlay.empty()) fn(base, size); else fn(spresil::patchedReader(base, overlay), size);
    });
}

bool Demuxer::withPatchedLocalReader(const std::function<void(const spresil::Reader&, int64_t)>& fn) {
    const spresil::PatchOverlay overlay = localIO_ ? localIO_->patches : spresil::PatchOverlay{};
    return withLocalReader([&](const spresil::Reader& base, int64_t size) {
        if (overlay.empty()) fn(base, size); else fn(spresil::patchedReader(base, overlay), size);
    });
}

bool Demuxer::installPatches(const std::vector<spresil::Patch>& patches, bool invalidateAvio) {
    if (!localIO_ || abortIO_.load() || !spLocalSourceUnchanged(*localIO_)) return false;
    try {
        std::lock_guard<std::mutex> lk(localIO_->viewMutex);
        std::vector<spresil::Patch> combined = localIO_->patches.list();
        combined.insert(combined.end(), patches.begin(), patches.end());
        spresil::PatchOverlay next(std::move(combined));
        if (abortIO_.load() || !spLocalSourceUnchanged(*localIO_)) return false;
        localIO_->patches = std::move(next);
        for (const auto& p : patches) {
            if (p.offset >= 0 && p.bytes.size() <= (uint64_t)(INT64_MAX - p.offset))
                localIO_->virtualSize = std::max(localIO_->virtualSize, p.offset + (int64_t)p.bytes.size());
        }
        localIO_->viewRevision.fetch_add(1, std::memory_order_release);
    } catch (const std::bad_alloc&) { return false; }
    if (invalidateAvio) invalidateAvioBuffer();
    return true;
}

Demuxer::RecoveryOutcome Demuxer::replayFromRecoveryTarget(int64_t targetUs, const std::string& what) {
    const int64_t t = targetUs >= 0 ? targetUs : 0;
    dropSeekPushback();
    const int sret = avformat_seek_file(fmtCtx_, -1, INT64_MIN, t, t, 0);
    if (spDebug()) fprintf(stderr, "[Demux] %s，回 seek %.2fs → %d\n", what.c_str(), t / 1e6, sret);
    if (sret < 0) return RecoveryOutcome::AppliedButReplayFailed;
    eof_ = false;
    lastGoodPos_ = -1;
    if (targetUs >= 0) armResumeDiscard(targetUs);
    return RecoveryOutcome::AppliedAndResumed;
}

spresil::TsByteSource Demuxer::tsLaneSource(const spresil::Reader& rd, int64_t size, int64_t from, int64_t needTo, int64_t fillTo,
                                             spresil::TsGeometry& geom) {
    spresil::TsByteSource src;
    src.read = &rd;
    TsLaneWindow& w = tsLaneWin_;
    const std::shared_ptr<LocalFileIO> io = localIO_;
    const uint64_t rev = io ? io->viewRevision.load(std::memory_order_acquire) : 0;
    if (!(io && w.geomValid && w.geomIo.lock() == io && w.geomRev == rev)) {
        w.geom = spresil::tsGeometryAt(rd, 0, size);

        w.geomValid = io != nullptr && w.geom.valid(); w.geomIo = io; w.geomRev = rev;
    }
    geom = w.geom;

    if (!io || !geom.valid() || from < 0 || needTo <= from) return src;
    const bool covered = w.pos >= 0 && w.io.lock() == io && w.viewRev == rev && from >= w.pos && needTo <= w.pos + (int64_t)w.len;
    if (!covered) {
        const int64_t to = std::max(needTo, std::min(size, fillTo));
        const size_t need = (size_t)(to - from);
        w.pos = -1; w.len = 0;

        if (w.buf.capacity() > 512u * 1024 && need < w.buf.capacity() / 4) std::vector<uint8_t>().swap(w.buf);
        int64_t got;
        if (need > LocalFileIO::kLaneCacheBlock / 2 && io->patches.empty() && !onOpenThread()) {

            const int64_t t0 = spDebug() ? spNowUs() : 0;
            got = spLocalIOReadSwap(io.get(), from, need, w.buf);
            if (spDebug()) noteIORead(laneIO_, got, spNowUs() - t0);
        } else {
            try { w.buf.resize(need); } catch (const std::bad_alloc&) { std::vector<uint8_t>().swap(w.buf); return src; }
            got = rd(from, w.buf.data(), w.buf.size());
        }
        w.pos = from; w.len = got > 0 ? (size_t)std::min<int64_t>(got, (int64_t)need) : 0;
        w.io = io; w.viewRev = rev;
    }
    src.data = w.buf.data(); src.pos = w.pos; src.len = w.len;
    return src;
}

bool Demuxer::flacLastFrameEndSample(const uint8_t* streamInfo, size_t n, uint64_t& endSample) {
    spresil::FlacStreamInfo info;
    const std::shared_ptr<LocalFileIO> io = localIO_;
    if (!fmtCtx_ || !io || io->fd < 0 || io->size <= 0 || container_ != "flac" || abortIO_.load() ||
        !spresil::flacParseStreamInfo(streamInfo, n, info)) return false;

    const int64_t size = io->size;
    const int64_t len = std::min(size, std::min<int64_t>(2ll << 20, (int64_t)spresil::flacTailSearchSpan(info) + 16 * 1024));
    if (len <= 0) return false;

    const bool count = spDebug();
    const spresil::Reader base = [this, io, count](int64_t pos, uint8_t* buf, size_t want) -> int64_t {
        const int64_t t0 = count ? spNowUs() : 0;
        const int64_t got = spLocalIOReadOutsideAvio(io.get(), pos, buf, want, /*retainLanding=*/false);
        if (count) noteIORead(laneIO_, got, spNowUs() - t0);
        return got;
    };
    const spresil::PatchOverlay overlay = io->patches;
    const spresil::Reader rd = overlay.empty() ? base : spresil::patchedReader(base, overlay);
    std::vector<uint8_t> tail((size_t)len);
    if (rd(size - len, tail.data(), tail.size()) != len) return false;
    return spresil::flacTailLastFrameEnd(tail.data(), tail.size(), info, endSample, &abortFn_);
}

bool Demuxer::withLocalReader(const std::function<void(const spresil::Reader&, int64_t)>& fn) {
    if (!localIO_ || localIO_->fd < 0 || localIO_->size <= 0) return withFileReader(path_, fn);
    const bool count = spDebug();
    if (!onOpenThread()) {

        if (abortIO_.load()) return false;
        const std::shared_ptr<LocalFileIO> io = localIO_;
        fn(abandonableReader(io, count ? &laneIO_ : nullptr), io->size);
        return !abortIO_.load();
    }
    const int fd = localIO_->fd;
    const spresil::Reader reader = [this, fd, count](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
        const int64_t t0 = count ? spNowUs() : 0;
        const ssize_t got = ::pread(fd, buf, n, (off_t)pos);
        if (count) noteIORead(laneIO_, got, spNowUs() - t0);
        return got < 0 ? (int64_t)AVERROR(errno) : (int64_t)got;
    };
    fn(reader, localIO_->size);
    return true;
}

spresil::Reader Demuxer::localRawReader() {
    const std::shared_ptr<LocalFileIO> io = localIO_;
    if (!onOpenThread()) return abandonableReader(io, nullptr);
    const int fd = io->fd;
    return [fd](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
        const ssize_t got = ::pread(fd, buf, n, (off_t)pos);
        return got < 0 ? (int64_t)AVERROR(errno) : (int64_t)got;
    };
}

spresil::Reader Demuxer::abandonableReader(const std::shared_ptr<LocalFileIO>& io, PlanIOCounters* counters) {
    return [io, counters](int64_t pos, uint8_t* buf, size_t n) -> int64_t {
        if (pos < 0 || n > static_cast<uint64_t>(INT64_MAX - pos)) return AVERROR(EINVAL);
        if (n == 0) return 0;
        LocalFileIO& c = *io;

        if (n <= LocalFileIO::kLaneCacheBlock / 2) {
            for (LocalFileIO::LaneCacheBlock& b : c.laneCache) {
                if (b.pos >= 0 && pos >= b.pos && pos + (int64_t)n <= b.pos + (int64_t)b.len) {
                    memcpy(buf, b.bytes.data() + (pos - b.pos), n);
                    b.used = ++c.laneCacheTick;
                    return (int64_t)n;
                }
            }
            LocalFileIO::LaneCacheBlock& b = c.laneCache[0].used <= c.laneCache[1].used ? c.laneCache[0] : c.laneCache[1];
            bool cacheOk = b.bytes.size() >= LocalFileIO::kLaneCacheBlock;
            if (!cacheOk) {
                try { b.bytes.resize(LocalFileIO::kLaneCacheBlock); cacheOk = true; } catch (const std::bad_alloc&) {}
            }
            if (cacheOk) {
                b.pos = -1;
                b.len = 0;
                const int64_t t0 = counters ? spNowUs() : 0;

                const int64_t got = spLocalIOReadIntoOwned(io.get(), pos, b.bytes.data(), LocalFileIO::kLaneCacheBlock);
                if (counters) noteIORead(*counters, got, spNowUs() - t0);
                if (got < 0) return got;
                b.pos = pos;
                b.len = (size_t)got;
                b.used = ++c.laneCacheTick;
                const size_t k = std::min(n, (size_t)got);
                memcpy(buf, b.bytes.data(), k);
                return (int64_t)k;
            }
        }
        const int64_t t0 = counters ? spNowUs() : 0;
        const int64_t got = spLocalIOReadOutsideAvio(io.get(), pos, buf, n);
        if (counters) noteIORead(*counters, got, spNowUs() - t0);
        return got;
    };
}

bool Demuxer::attemptAsfObjectRecovery(int64_t untilPos, bool flush) {
    if (!fmtCtx_ || !localIO_ || asfObjAttempts_ >= 8 || fmtCtx_->packet_size <= 0 || fmtCtx_->packet_size > 65536) return false;
    const int64_t psz = fmtCtx_->packet_size;
    const int64_t until = flush ? untilPos : untilPos + psz;
    if (until <= asfObjScannedUntil_) return false;
    const int64_t from = asfObjScannedUntil_ < 0 ? 0 : asfObjScannedUntil_;
    if (until - from > 4ll * 1024 * 1024) {
        asfObjScannedUntil_ = until;
        asfObjState_ = spresil::AsfObjectScanState{};
        return false;
    }
    if (!flush && until - from < 64ll * 1024) return false;
    spresil::RecoveryPlan plan;
    int64_t scannedTo = from, earliestMs = -1;
    const int64_t t0 = spNowUs();
    withPatchedLocalReader([&](const spresil::Reader& rd, int64_t size) {
        plan = spresil::planAsfObjectFragments(rd, size, from, until - from, &abortFn_, asfObjState_, &scannedTo, &earliestMs);
        for (int ext = 0; ext < 8 && !plan.empty() && scannedTo < size && !abortIO_.load(); ++ext) {
            int64_t more = -1, ms = -1;
            spresil::RecoveryPlan mp = spresil::planAsfObjectFragments(rd, size, scannedTo, 1ll << 20, &abortFn_, asfObjState_, &more, &ms);
            if (more <= scannedTo) break;
            scannedTo = more;
            if (mp.empty()) break;
            mergeExtension(plan, mp);
            if (ms >= 0 && (earliestMs < 0 || ms < earliestMs)) earliestMs = ms;
        }
    });
    if (scannedTo > asfObjScannedUntil_) asfObjScannedUntil_ = scannedTo;
    if (plan.empty()) return false;
    ++asfObjAttempts_;
    if (!installPatches(plan.patches, true)) return false;
    int64_t target = recoverySeekTargetUs();
    if (earliestMs >= 0 && (target < 0 || earliestMs * 1000 - 1000 < target)) target = std::max<int64_t>(0, earliestMs * 1000 - 1000);
    if (replayFromRecoveryTarget(target, "ASF 媒体对象补丁 " + std::to_string(plan.patches.size()) + " 处已装入（" + std::to_string(from) + "–" + std::to_string(scannedTo) + "）" +
                                 std::to_string((spNowUs() - t0) / 1000) + "ms：" + plan.detail) != RecoveryOutcome::AppliedAndResumed) return false;
    pushRecoveryEvent("ASF 媒体对象的大小副本 / 片段偏移与其余片段矛盾，候选恢复 " + plan.kind + "：" + plan.detail, byteToUsGuess(plan.damagedFrom), byteToUsGuess(plan.damagedUntil));
    return true;
}

bool Demuxer::loadTsVideoPids() {
    ensureTsRecoveryPids();

    return tsHdrPids_.trusted;
}

bool Demuxer::tryTsPesHeaderReopen() {
    if (!fmtCtx_ || !tsMpegTs_ || !localIO_ || abortIO_.load() || !loadTsVideoPids()) return false;
    const int stride = fmtCtx_->packet_size > 0 ? fmtCtx_->packet_size : 188;
    if (stride != 188 && stride != 192 && stride != 204) return false;
    spresil::RecoveryPlan plan;
    int64_t scannedTo = 0;
    const int64_t t0 = spNowUs();
    withPatchedFileReader([&](const spresil::Reader& rd, int64_t size) {
        const int64_t first = std::min<int64_t>(size, (1ll << 20) / stride * stride);
        plan = spresil::planTsPesHeaderLengths(rd, size, 0, first, tsHdrPids_, tsPesState_, &abortFn_);
        scannedTo = first;
        extendTsScan(plan, scannedTo, size, stride, abortIO_, [&](int64_t at, int64_t step) { return spresil::planTsPesHeaderLengths(rd, size, at, step, tsHdrPids_, tsPesState_, &abortFn_); });
    });
    tsPesScannedUntil_ = scannedTo;
    if (spDebug() && (!plan.empty() || spNowUs() - t0 > 2000)) {
        fprintf(stderr, "[Demux] TS 视频 PES 头长核对（前 %lld KiB）%.1fms: %s %s\n", (long long)(scannedTo / 1024), (spNowUs() - t0) / 1000.0,
                plan.empty() ? "无矛盾" : plan.kind.c_str(), plan.detail.c_str());
    }
    if (plan.empty()) return false;
    if (!validateTsRecoveryCandidate(plan, spresil::TsRecoveryLane::Pes, scannedTo)) return false;
    ++tsPesAttempts_;
    if (!reopenInPlace(plan.patches, false, plan.kind.c_str(), false, true)) return false;
    rebuildStreamTable();
    noteOpenRecovery(plan.kind, "TS 视频 PES 可选头长度与时间字段 / 填充 / 起始码矛盾，候选恢复 " + plan.kind + "：" + plan.detail);
    return true;
}

bool Demuxer::attemptTsPesHeaderRecovery(int64_t untilPos, bool flush) {
    if (!fmtCtx_ || !localIO_ || tsPesAttempts_ >= 8 || !loadTsVideoPids()) return false;
    if (!flush && spNowUs() < tsScanHoldUntilUs_) return false;
    const int stride = fmtCtx_->packet_size > 0 ? fmtCtx_->packet_size : 188;
    if (stride != 188 && stride != 192 && stride != 204) { tsPesAttempts_ = 8; return false; }
    const int64_t aligned = flush ? untilPos : (untilPos / stride) * stride;
    if (aligned <= tsPesScannedUntil_) return false;
    const int64_t window = aligned - tsPesScannedUntil_;
    if (window > 2ll * 1024 * 1024) {
        tsPesScannedUntil_ = aligned;
        tsPesState_ = spresil::TsPesScanState{};
        return false;
    }
    spresil::RecoveryPlan plan;
    const int64_t from = tsPesScannedUntil_;
    int64_t scannedTo = aligned, earliest90k = -1;
    withPatchedLocalReader([&](const spresil::Reader& rd, int64_t size) {
        spresil::TsGeometry geom;
        const int64_t needTo = std::min(size, std::min(size, from + window) + 40ll * stride);
        spresil::TsByteSource src = tsLaneSource(rd, size, from, needTo, aligned + 40ll * stride, geom);
        plan = spresil::planTsPesHeaderLengths(src, geom, size, from, window, tsHdrPids_, tsPesState_, &abortFn_, &earliest90k);
        extendTsScan(plan, scannedTo, size, stride, abortIO_, [&](int64_t at, int64_t step) {
            int64_t e = -1;
            spresil::RecoveryPlan more = spresil::planTsPesHeaderLengths(rd, size, at, step, tsHdrPids_, tsPesState_, &abortFn_, &e);
            if (!more.empty() && e >= 0 && (earliest90k < 0 || e < earliest90k)) earliest90k = e;
            return more;
        });
    });
    tsPesScannedUntil_ = scannedTo;
    if (plan.empty()) return false;
    if (!validateTsRecoveryCandidate(plan, spresil::TsRecoveryLane::Pes, scannedTo, -1, &earliest90k)) return false;
    ++tsPesAttempts_;
    if (!installPatches(plan.patches, true)) return false;
    int64_t target = recoverySeekTargetUs();
    if (earliest90k >= 0) {
        const int64_t ptsUs = av_rescale_q(earliest90k, AVRational{1, 90000}, AV_TIME_BASE_Q) - 1000;
        if (target < 0 || ptsUs < target) target = std::max<int64_t>(0, ptsUs);
    }
    if (replayFromRecoveryTarget(target, "TS 视频 PES 头长补丁 " + std::to_string(plan.patches.size()) + " 处已装入（" + std::to_string(from) + "–" + std::to_string(scannedTo) + "）：" + plan.detail) != RecoveryOutcome::AppliedAndResumed) return false;
    pushRecoveryEvent("TS 视频 PES 可选头长度与时间字段 / 填充 / 起始码矛盾，候选恢复 " + plan.kind + "：" + plan.detail, byteToUsGuess(plan.damagedFrom), byteToUsGuess(plan.damagedUntil));
    return true;
}

} // namespace sp
