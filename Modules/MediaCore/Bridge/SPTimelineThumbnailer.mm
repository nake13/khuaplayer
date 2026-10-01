#import "SPTimelineThumbnailer.h"
#import "SPVideoDecoder.h"
#import "SPFFmpegDecoder.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

#include <cstring>
#include <pthread.h>
#include <sys/resource.h>

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
}

#include "SPThumbSchedulingPolicy.hpp"
#include "SPThumbKeyPolicy.hpp"
#include "SPThumbBlackBorder.hpp"
#include "TsRapScan.hpp"
#include "SPDoviRPU.hpp"
#include "SPDisplayRotation.hpp"

using spthumb::SPThumbClaim;
using spthumb::SPThumbHoldVerdict;
using spthumb::SPThumbOpenResult;
using spthumb::SPThumbTaskKind;
using spthumb::kImmuneBase;

#include "SPRuntimeGates.hpp"

#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_spLogId, ##__VA_ARGS__)

struct SPThumbShared {
    unsigned logId = 0;

    AVCodecParameters *videoPar = nullptr;
    int videoStreamIndex = -1;
    int videoStreamId = 0;
    bool doviIPT = false;
    int doviNalLengthSize = 4;
    ~SPThumbShared() { if (videoPar) avcodec_parameters_free(&videoPar); }
    std::mutex mtx;
    std::condition_variable cv;
    std::atomic<bool> stop{false};

    std::atomic<uint64_t> yieldSeq{0};
    std::atomic<int64_t> lastYieldWallUs{0};

    std::atomic<bool> everInteracted{false};

    int64_t hoverTargetUs = -1;

    int64_t activeHoverTargetUs = INT64_MIN;

    uint64_t activeHoverBase = 0;
    std::atomic<uint64_t> hoverSeq{0};

    std::atomic<uint64_t> cancelSeq{0};
    bool sweepArmed = false;

    std::atomic<uint64_t> cbYieldBase{0};
    std::atomic<uint64_t> cbHoverBase{0};
    std::atomic<uint64_t> cbCancelBase{kImmuneBase};
    std::string path;
    int64_t durationUs = 0;
    int64_t originUs = 0;
    bool remote = false;

    int colorPrimaries = 2, colorTrc = 2, colorSpace = 2, colorRange = 0;

    std::vector<int64_t> evictedKeys;
};

static int spThumbInterruptCb(void *opaque) {
    auto *s = (SPThumbShared *)opaque;
    return spthumb::taskInterrupted(s->stop.load(),
                                    s->yieldSeq.load(), s->cbYieldBase.load(),
                                    s->hoverSeq.load(), s->cbHoverBase.load(),
                                    s->cancelSeq.load(), s->cbCancelBase.load())
               ? 1 : 0;
}

static void spThumbFitSize(int w, int h, AVRational sar, int *ow, int *oh) {
    double dw = w > 0 ? w : 2, dh = h > 0 ? h : 2;
    if (sar.num > 0 && sar.den > 0) dw = dw * sar.num / sar.den;
    double s = std::min(384.0 / dw, 216.0 / dh);
    if (s > 1.0) s = 1.0;
    *ow = std::max((int)llround(dw * s) & ~1, 2);
    *oh = std::max((int)llround(dh * s) & ~1, 2);
}

static NSData *spThumbEncodeImage(CGImageRef cg, CFStringRef uti, double quality) {
    NSMutableData *md = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)md, uti, 1, NULL);
    if (!dst) return nil;
    NSDictionary *props = @{
        (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality),
    };
    CGImageDestinationAddImage(dst, cg, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok ? md : nil;
}

static bool spThumbBlackBorders(CVPixelBufferRef buf, bool fullRangeOverride, int fullRangeValue,
                                size_t *top, size_t *bot, size_t *left, size_t *right) {
    const OSType fmt = CVPixelBufferGetPixelFormatType(buf);
    const bool tenBit =
        fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    bool fullRange =
        fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    if (fullRangeOverride) fullRange = fullRangeValue != 0;
    if (CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return false;
    }
    const size_t W = CVPixelBufferGetWidthOfPlane(buf, 0);
    const size_t H = CVPixelBufferGetHeightOfPlane(buf, 0);
    const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 0);
    if (!base || W < 16 || H < 16) {
        CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
        return false;
    }

    const unsigned thresh = (fullRange ? 0 : 16) + 4;
    const auto edges = tenBit
        ? spthumb::findBlackBorders<true>(base, W, H, stride, thresh)
        : spthumb::findBlackBorders<false>(base, W, H, stride, thresh);
    CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    *top = edges.top; *bot = edges.bottom; *left = edges.left; *right = edges.right;
    if (*top + *bot + *left + *right == 0) return false;

    if (*top == H / 4 && *bot == H / 4 && *left == W / 4 && *right == W / 4) return false;
    if (W - *left - *right < W / 2 || H - *top - *bot < H / 2) return false;
    return true;
}

static CIImage *spThumbCropLetterbox(CIImage *ci, CVPixelBufferRef buf) {
    size_t top = 0, bot = 0, left = 0, right = 0;
    if (!spThumbBlackBorders(buf, false, 0, &top, &bot, &left, &right)) return ci;
    const size_t W = CVPixelBufferGetWidthOfPlane(buf, 0);
    const size_t H = CVPixelBufferGetHeightOfPlane(buf, 0);

    const CGRect r = CGRectMake((CGFloat)left, (CGFloat)bot,
                                (CGFloat)(W - left - right),
                                (CGFloat)(H - top - bot));
    return [[ci imageByCroppingToRect:r]
        imageByApplyingTransform:CGAffineTransformMakeTranslation(-r.origin.x,
                                                                  -r.origin.y)];
}

static CIImage *spThumbFitCI(CIImage *ci) {
    CGFloat w = ci.extent.size.width, h = ci.extent.size.height;
    double s = std::min(384.0 / w, 216.0 / h);
    if (s >= 1.0) return ci;
    CIFilter *f = [CIFilter filterWithName:@"CILanczosScaleTransform"];
    [f setValue:ci forKey:kCIInputImageKey];
    [f setValue:@(s) forKey:kCIInputScaleKey];
    CIImage *out = f.outputImage;
    return out ?: ci;
}

static CGImageRef spThumbRenderCG(CIContext *ciCtx, CGColorSpaceRef srgb,
                                  CVPixelBufferRef buf, int hdrTrc,
                                  bool *outHDR, unsigned logId)
    CF_RETURNS_RETAINED {
    *outHDR = false;
    if (hdrTrc == 16 /*PQ*/ || hdrTrc == 18 /*HLG*/) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:buf];
        if (ci) ci = spThumbFitCI(spThumbCropLetterbox(ci, buf));
        CGColorSpaceRef hdrSpace = CGColorSpaceCreateWithName(
            hdrTrc == 16 ? kCGColorSpaceITUR_2100_PQ : kCGColorSpaceITUR_2100_HLG);
        if (ci && hdrSpace) {

            CGImageRef cg = [ciCtx createCGImage:ci
                                        fromRect:ci.extent
                                          format:kCIFormatRGBA16
                                      colorSpace:hdrSpace];
            CGColorSpaceRelease(hdrSpace);
            if (cg) {
                *outHDR = true;
                return cg;
            }
            if (spDebug()) {
                NSLog(@"[c%u][Thumb] CI RGBA16/PQ 渲染失败，跌落 SDR", logId);
            }
        } else if (hdrSpace) {
            CGColorSpaceRelease(hdrSpace);
        }

    }
    CIImage *ci = [CIImage imageWithCVPixelBuffer:buf
                                          options:@{kCIImageToneMapHDRtoSDR : @YES}];
    if (!ci) return NULL;
    ci = spThumbFitCI(spThumbCropLetterbox(ci, buf));
    return [ciCtx createCGImage:ci
                       fromRect:ci.extent
                         format:kCIFormatRGBA8
                     colorSpace:srgb];
}

// Consumes `cg` and returns it turned upright for a stream whose display
// matrix rotates it, so hover previews match the playing picture. The result
// is refitted to the 384x216 preview box, so a rotated portrait thumbnail is
// no larger than a native one. Keeps the source color space (sRGB or PQ/HLG)
// and falls back to the unrotated image.
static CGImageRef spThumbRotateCG(CGImageRef cg, int clockwise) CF_RETURNS_RETAINED {
    if (!cg || clockwise == 0) return cg;
    const size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    const bool swap = sp::spRotationSwapsAxes(clockwise);
    const double fit = std::min(1.0, std::min(384.0 / (swap ? h : w), 216.0 / (swap ? w : h)));
    const double dw = w * fit, dh = h * fit;   // Drawn size before rotation.
    const size_t ow = std::max<size_t>(2, (size_t)llround(swap ? dh : dw));
    const size_t oh = std::max<size_t>(2, (size_t)llround(swap ? dw : dh));
    const bool deep = CGImageGetBitsPerComponent(cg) > 8;
    CGColorSpaceRef cs = CGImageGetColorSpace(cg);
    CGContextRef bmp = CGBitmapContextCreate(
        NULL, ow, oh, deep ? 16 : 8, 0, cs,
        deep ? (CGBitmapInfo)kCGImageAlphaPremultipliedLast
             : (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    if (!bmp) return cg;
    // Core Graphics is y-up, so a negative angle turns the picture clockwise.
    CGContextTranslateCTM(bmp, ow / 2.0, oh / 2.0);
    CGContextRotateCTM(bmp, -clockwise * M_PI / 180.0);
    CGContextSetInterpolationQuality(bmp, kCGInterpolationHigh);
    CGContextDrawImage(bmp, CGRectMake(-dw / 2, -dh / 2, dw, dh), cg);
    CGImageRef out = CGBitmapContextCreateImage(bmp);
    CGContextRelease(bmp);
    if (!out) return cg;
    CGImageRelease(cg);
    return out;
}

// HEIC quality 0.8 and JPEG quality 0.72 balance artifacting and size at
// 384x216. SDR remains an sRGB JPEG path.
static NSData *spThumbEncodeCG(CGImageRef cg, bool isHDR) {
    return spThumbEncodeImage(cg, isHDR ? CFSTR("public.heic") : CFSTR("public.jpeg"),
                              isHDR ? 0.8 : 0.72);
}

struct SPThumbDoviGpu {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pso;
    CVMetalTextureCacheRef texCache = NULL;
    id<MTLBuffer> outBuf;
    bool triedSetup = false;
    bool ready() const { return pso != nil && queue != nil && texCache != NULL; }
    void teardown() {
        if (texCache) { CFRelease(texCache); texCache = NULL; }
        pso = nil; queue = nil; outBuf = nil; device = nil; triedSetup = false;
    }
};

static bool spThumbDoviGpuSetup(SPThumbDoviGpu &g, unsigned logId) {
    if (g.triedSetup) return g.ready();
    g.triedSetup = true;
    g.device = MTLCreateSystemDefaultDevice();
    if (!g.device) return false;
    NSError *error = nil;

    id<MTLLibrary> lib = [g.device newDefaultLibraryWithBundle:
                              [NSBundle bundleForClass:SPTimelineThumbnailer.class]
                                                       error:&error];
    id<MTLFunction> fn = [lib newFunctionWithName:@"doviThumbConvert"];
    if (!fn) {
        NSLog(@"[c%u][Thumb] DoVi 转换核加载失败: %@", logId, error);
        return false;
    }
    g.pso = [g.device newComputePipelineStateWithFunction:fn error:&error];
    g.queue = [g.device newCommandQueue];
    CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, g.device, NULL, &g.texCache);
    if (!g.ready()) NSLog(@"[c%u][Thumb] DoVi 转换核建管线失败: %@", logId, error);
    return g.ready();
}

static void spThumbDoviFloatsFromPacket(const AVPacket *pkt, int nalLengthSize, float *out) {
    sp::DoviReshape rp;
    bool ok = false;
    if (pkt && pkt->data && pkt->size > 8) {
        const bool annexB = pkt->data[0] == 0 && pkt->data[1] == 0 &&
                            (pkt->data[2] == 1 || (pkt->data[2] == 0 && pkt->data[3] == 1));
        ok = sp::doviParseRPUFromPacket(pkt->data, (size_t)pkt->size, annexB, rp, nalLengthSize) &&
             rp.valid && !rp.usePrev;
    }
    if (!ok) rp = sp::DoviReshape{};
    sp::doviToGpuFloats(rp, out);
}

static CGImageRef spThumbRenderDoviCG(SPThumbDoviGpu &g, CVPixelBufferRef buf,
                                      const float *dovi, unsigned logId)
    CF_RETURNS_RETAINED {
    const OSType fmt = CVPixelBufferGetPixelFormatType(buf);
    const bool is10 = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                      fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    const bool is8 = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                     fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if ((!is10 && !is8) || CVPixelBufferGetPlaneCount(buf) < 2) return NULL;
    const size_t W = CVPixelBufferGetWidthOfPlane(buf, 0), H = CVPixelBufferGetHeightOfPlane(buf, 0);
    const size_t W1 = CVPixelBufferGetWidthOfPlane(buf, 1), H1 = CVPixelBufferGetHeightOfPlane(buf, 1);
    if (W == 0 || H == 0 || W1 == 0 || H1 == 0) return NULL;
    CVMetalTextureRef yRef = NULL, uvRef = NULL;
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, g.texCache, buf, NULL,
                                              is10 ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm,
                                              W, H, 0, &yRef);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, g.texCache, buf, NULL,
                                              is10 ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm,
                                              W1, H1, 1, &uvRef);
    if (!yRef || !uvRef) {
        if (yRef) CFRelease(yRef);
        if (uvRef) CFRelease(uvRef);
        return NULL;
    }
    const size_t bytes = W * H * 8;
    if (!g.outBuf || g.outBuf.length < bytes) {
        g.outBuf = [g.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    }
    CGImageRef cg = NULL;
    if (g.outBuf) {
        id<MTLCommandBuffer> cmd = [g.queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:g.pso];
        [enc setTexture:CVMetalTextureGetTexture(yRef) atIndex:0];
        [enc setTexture:CVMetalTextureGetTexture(uvRef) atIndex:1];
        [enc setBytes:dovi length:sp::kDoviGpuFloats * sizeof(float) atIndex:0];
        const int32_t meta[4] = {is10 ? 10 : 8, (int32_t)W, (int32_t)H, 0};
        [enc setBytes:meta length:sizeof(meta) atIndex:1];
        [enc setBuffer:g.outBuf offset:0 atIndex:2];
        const MTLSize tg = MTLSizeMake(16, 16, 1);
        const MTLSize groups = MTLSizeMake((W + 15) / 16, (H + 15) / 16, 1);
        [enc dispatchThreadgroups:groups threadsPerThreadgroup:tg];
        [enc endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        if (cmd.error) {
            NSLog(@"[c%u][Thumb] DoVi 转换核执行失败: %@", logId, cmd.error);
        } else {
            NSData *data = [NSData dataWithBytes:g.outBuf.contents length:bytes];
            CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
            if (prov && cs) {
                cg = CGImageCreate(W, H, 16, 64, W * 8, cs,
                                   (CGBitmapInfo)kCGImageAlphaNoneSkipLast |
                                       (CGBitmapInfo)kCGBitmapByteOrder16Little,
                                   prov, NULL, false, kCGRenderingIntentDefault);
            }
            if (cs) CGColorSpaceRelease(cs);
            if (prov) CGDataProviderRelease(prov);
        }
    }
    CFRelease(yRef);
    CFRelease(uvRef);
    if (!cg) return NULL;

    size_t top = 0, bot = 0, left = 0, right = 0;
    if (spThumbBlackBorders(buf, true, dovi[23] > 0.5f ? 1 : 0, &top, &bot, &left, &right)) {
        CGImageRef cropped = CGImageCreateWithImageInRect(
            cg, CGRectMake((CGFloat)left, (CGFloat)top,
                           (CGFloat)(W - left - right), (CGFloat)(H - top - bot)));
        if (cropped) {
            CGImageRelease(cg);
            cg = cropped;
        }
    }
    return cg;
}

// Only HEVC setup's parameter-set fallback reads this hint. Keep its existing
// owning snapshot semantics: NSData's copy property may materialize borrowed
// no-copy data anyway. Other codecs need no whole-keyframe allocation at all.
static NSData *spThumbFirstPacketHint(const AVCodecParameters *par,
                                      const AVPacket *pkt) {
    if (!par || par->codec_id != AV_CODEC_ID_HEVC || !pkt ||
        !pkt->data || pkt->size <= 0) return nil;
    return [NSData dataWithBytes:pkt->data length:(NSUInteger)pkt->size];
}

@interface SPTimelineThumbnailer ()
- (void)_mainStoreJPEG:(NSData *)jpeg
              forKeyUs:(int64_t)keyUs
      resolvedTargetUs:(int64_t)resolvedTargetUs
           previewImage:(nullable id)previewImage
              dustValid:(BOOL)dustValid dustHue:(float)dustHue dustSat:(float)dustSat dustLuma:(float)dustLuma;
- (void)_mainStoreDustKeys:(NSData *)keys sweepSpacingUs:(int64_t)spacing;
- (void)_mainStorePreviewImage:(id)image
                      forKeyUs:(int64_t)keyUs
              resolvedTargetUs:(int64_t)resolvedTargetUs;
- (void)_mainNoteResolvedTargetUs:(int64_t)targetUs forKeyUs:(int64_t)keyUs;
- (void)_lruInsert:(id)image forKeyUs:(int64_t)keyUs;
@end

static bool spThumbDustColor(CGImageRef cg, float *hue, float *sat, float *luma);

static void spThumbPublishImage(__weak SPTimelineThumbnailer *target,
                                CGImageRef cg, int64_t keyUs,
                                int64_t resolvedTargetUs) {
    if (!cg) return;
    id boxed = CFBridgingRelease(CGImageRetain(cg));
    dispatch_async(dispatch_get_main_queue(), ^{
        SPTimelineThumbnailer *s = target;
        if (s) [s _mainStorePreviewImage:boxed
                                forKeyUs:keyUs
                        resolvedTargetUs:resolvedTargetUs];
    });
}

// Optional diagnostic override for hover I/O priority. Background sweeps remain
// throttled. Parse once; a negative value leaves the normal policy unchanged.
static int spThumbHoverIOPolicyOverride() {
#if SP_APP_STORE
    return -1;
#else
    static const int policy = [] {
        const char *e = getenv("SP_THUMB_IOPOL");
        if (!e) return -1;
        if (strcmp(e, "throttle") == 0) return IOPOL_THROTTLE;
        if (strcmp(e, "utility") == 0) return IOPOL_UTILITY;
        if (strcmp(e, "standard") == 0) return IOPOL_STANDARD;
        return -1;
    }();
    return policy;
#endif
}

static void spThumbApplyIOTier(spthumb::SPThumbIOTier tier, bool hoverTask) {
    int policy = IOPOL_THROTTLE;
    switch (tier) {
        case spthumb::SPThumbIOTier::Standard: policy = IOPOL_STANDARD; break;
        case spthumb::SPThumbIOTier::Utility:  policy = IOPOL_UTILITY;  break;
        case spthumb::SPThumbIOTier::Throttle: policy = IOPOL_THROTTLE; break;
    }
    if (hoverTask) {
        const int override_ = spThumbHoverIOPolicyOverride();
        if (override_ >= 0) policy = override_;
    }
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, policy);
}

static void spThumbWorkerMain(std::shared_ptr<SPThumbShared> sh,
                              SPThumbIdleProbe probe,
                              SPThumbSeekBusyProbe seekBusy,
                              __weak SPTimelineThumbnailer *weakSelf) {
    pthread_setname_np("sp.thumbs");

    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);

    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE);

    AVFormatContext *ctx = nullptr;
    id<SPVideoDecoding> dec = nil;
    CIContext *ciCtx = nil;
    SPThumbDoviGpu doviGpu;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    int vs = -1;
    int hdrTrc = 0;
    int rotation = 0;
    bool opened = false, openFailed = false, decoderFailed = false;
    bool planBuilt = false;
    std::vector<int64_t> keyAbsUs;
    std::vector<int64_t> plan;
    size_t planIdx = 0;
    int planFail = 0;
    bool sweepLogged = false;
    std::set<int64_t> done;
    int generated = 0;
    int64_t sweepT0 = 0;

    bool indexTrusted = true;

    int64_t keyPtsOffsetUs = 0;
    bool keyPtsCalibrated = false;
    int64_t tsGopUs = 0;

    sp::SPTsRapLimits tsLim = sp::spThumbTsRapLimits();
    std::vector<spthumb::SPThumbFailNote> failNotes;
    int decoderSetupFails = 0;
    double lastCostMs = 0;

    spthumb::SPThumbKeyMap tsKeys;

    auto ensureOpen = [&](const SPThumbClaim &claim) -> SPThumbOpenResult {
        if (opened) return SPThumbOpenResult::Ready;
        if (openFailed) return SPThumbOpenResult::Failed;
        sh->cbYieldBase.store(claim.yieldBase);
        sh->cbHoverBase.store(kImmuneBase);
        sh->cbCancelBase.store(claim.cancelBase);

        auto interrupted = [&] {
            return spthumb::taskInterrupted(sh->stop.load(),
                sh->yieldSeq.load(), claim.yieldBase,
                sh->hoverSeq.load(), kImmuneBase,
                sh->cancelSeq.load(), claim.cancelBase);
        };
        AVFormatContext *c = avformat_alloc_context();
        if (!c) { openFailed = true; return SPThumbOpenResult::Failed; }
        c->interrupt_callback = { spThumbInterruptCb, sh.get() };
        AVDictionary *opts = nullptr;
        av_dict_set(&opts, "scan_all_pmts", "0", 0);
        int64_t t0 = spNowUs();
        int ret = avformat_open_input(&c, sh->path.c_str(), nullptr, &opts);
        av_dict_free(&opts);
        if (ret < 0) {
            if (interrupted()) return SPThumbOpenResult::Preempted;
            openFailed = true;
            if (spDebug()) NSLog(@"[c%u][Thumb] open 失败 ret=%d，本会话停用", sh->logId, ret);
            return SPThumbOpenResult::Failed;
        }

        if (c->nb_streams == 0) {
            AVPacket *warm = av_packet_alloc();
            for (int k = 0; warm && k < 32 && c->nb_streams == 0; ++k) {
                if (av_read_frame(c, warm) < 0) break;
                av_packet_unref(warm);
            }
            av_packet_free(&warm);
            if (interrupted()) {
                avformat_close_input(&c);
                return SPThumbOpenResult::Preempted;
            }
        }

        bool matched = false;
        auto isVideoStream = [&](unsigned i) {
            return c->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO;
        };
        if (sh->videoStreamIndex >= 0) {
            const int want = sh->videoStreamIndex;
            if ((unsigned)want < c->nb_streams && isVideoStream((unsigned)want) &&
                (sh->videoStreamId == 0 || c->streams[want]->id == sh->videoStreamId)) {
                vs = want;
                matched = true;
            } else if (sh->videoStreamId != 0) {
                for (unsigned i = 0; i < c->nb_streams; ++i) {
                    if (isVideoStream(i) && c->streams[i]->id == sh->videoStreamId) {
                        vs = (int)i;
                        matched = true;
                        break;
                    }
                }
            }
            if (!matched) {
                avformat_close_input(&c);
                openFailed = true;
                if (spDebug()) NSLog(@"[c%u][Thumb] 影子上下文无主视频流（索引 %d id %d），本会话停用",
                                     sh->logId, want, sh->videoStreamId);
                return SPThumbOpenResult::Failed;
            }
        }
        for (unsigned i = 0; vs < 0 && i < c->nb_streams; ++i) {
            AVStream *s = c->streams[i];
            if (s->codecpar->codec_type == AVMEDIA_TYPE_VIDEO &&
                !(s->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
                vs = (int)i;
                break;
            }
        }
        if (vs < 0) {
            avformat_close_input(&c);
            openFailed = true;
            if (spDebug()) NSLog(@"[c%u][Thumb] 无可用视频流，本会话停用", sh->logId);
            return SPThumbOpenResult::Failed;
        }
        ctx = c;
        rotation = sp::spStreamClockwiseRotation(c->streams[vs]);

        {
            AVCodecParameters *par = c->streams[vs]->codecpar;

            if (matched && sh->videoPar && (par->extradata_size == 0 || par->width <= 0)) {
                avcodec_parameters_copy(par, sh->videoPar);
            }

            if (par->color_primaries == AVCOL_PRI_UNSPECIFIED &&
                sh->colorPrimaries != 0 && sh->colorPrimaries != 2)
                par->color_primaries = (AVColorPrimaries)sh->colorPrimaries;
            if (par->color_trc == AVCOL_TRC_UNSPECIFIED &&
                sh->colorTrc != 0 && sh->colorTrc != 2)
                par->color_trc = (AVColorTransferCharacteristic)sh->colorTrc;
            if (par->color_space == AVCOL_SPC_UNSPECIFIED && sh->colorSpace != 2)
                par->color_space = (AVColorSpace)sh->colorSpace;
            if (par->color_range == AVCOL_RANGE_UNSPECIFIED && sh->colorRange > 0)
                par->color_range = (AVColorRange)sh->colorRange;
            hdrTrc = par->color_trc;
        }
        AVStream *st = ctx->streams[vs];
        indexTrusted = spthumb::spThumbIndexTrustworthy(c->iformat ? c->iformat->name : nullptr);

        if (indexTrusted && keyAbsUs.empty()) {
            if (avformat_index_get_entries_count(st) < 16 && sh->durationUs > 0) {
                int64_t midTs = av_rescale_q(sh->originUs + sh->durationUs / 2,
                                             AV_TIME_BASE_Q, st->time_base);
                (void)avformat_seek_file(ctx, vs, INT64_MIN, midTs, midTs, 0);
            }
            const int nb = avformat_index_get_entries_count(st);
            for (int i = 0; i < nb; ++i) {
                const AVIndexEntry *e = avformat_index_get_entry(st, i);
                if (!e || !(e->flags & AVINDEX_KEYFRAME)) continue;
                keyAbsUs.push_back(av_rescale_q(e->timestamp, st->time_base,
                                                AV_TIME_BASE_Q));
            }
            std::sort(keyAbsUs.begin(), keyAbsUs.end());
            keyAbsUs.erase(std::unique(keyAbsUs.begin(), keyAbsUs.end()),
                           keyAbsUs.end());

            if (interrupted()) {
                avformat_close_input(&ctx);
                ctx = nullptr;
                vs = -1;
                keyAbsUs.clear();
                return SPThumbOpenResult::Preempted;
            }
        }

        int64_t dur = sh->durationUs;
        if (dur <= 0 && ctx->duration > 0) dur = ctx->duration;
        if (!indexTrusted) {
            const int64_t size = ctx->pb ? avio_size(ctx->pb) : 0;
            tsLim = sp::spThumbTsRapLimits(size > 0 && dur > 0 ? size * 1000000 / dur : 0);
        }
        int maxSweep = sh->remote ? 60 : 120;
#if !SP_APP_STORE
        if (const char *e = getenv("SP_THUMBS_MAX")) {
            int v = atoi(e);
            if (v >= 0 && v <= 1000) maxSweep = v;
        }
#endif
        if (!planBuilt && dur > 2 * 1000000LL && maxSweep > 0) {
            int n = (int)std::min((int64_t)maxSweep, dur / 5000000LL);
            n = std::min(n, keyAbsUs.size() >= 8 ? (int)keyAbsUs.size() : 16);
            std::vector<int64_t> targets;
            for (int i = 0; i < n; ++i) {
                targets.push_back(sh->originUs +
                                  dur * (2 * (int64_t)i + 1) / (2 * n));
            }

            int bits = 0;
            while ((1 << bits) < (int)targets.size()) bits++;
            std::vector<std::pair<uint32_t, int64_t>> order;
            order.reserve(targets.size());
            for (size_t i = 0; i < targets.size(); ++i) {
                uint32_t r = 0;
                for (int b = 0; b < bits; ++b)
                    if (i & (1u << b)) r |= 1u << (bits - 1 - b);
                order.push_back({r, targets[i]});
            }
            std::stable_sort(order.begin(), order.end(),
                             [](const auto &a, const auto &b) {
                                 return a.first < b.first;
                             });
            for (auto &p : order) plan.push_back(p.second);
        }
        planBuilt = true;
        opened = true;

        {
            NSMutableData *keys = [NSMutableData data];
            const int nbk = (indexTrusted && st) ? avformat_index_get_entries_count(st) : 0;
            for (int i = 0; i < nbk; ++i) {
                const AVIndexEntry *e = avformat_index_get_entry(st, i);
                if (!e || !(e->flags & AVINDEX_KEYFRAME) || e->pos < 0) continue;
                SPDustKey k;
                k.tsUs = av_rescale_q(e->timestamp, st->time_base, AV_TIME_BASE_Q) - sh->originUs;
                k.pos = e->pos;
                [keys appendBytes:&k length:sizeof k];
            }
            const int64_t spacing = plan.empty() ? 0 : dur / (int64_t)plan.size();
            __weak SPTimelineThumbnailer *dustTarget = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                [dustTarget _mainStoreDustKeys:keys sweepSpacingUs:spacing];
            });
        }
        if (spDebug()) {
            NSLog(@"[c%u][Thumb] open %.0fms 索引关键帧=%zu%@ 扫描计划=%zu%s",
                  sh->logId, (spNowUs() - t0) / 1000.0, keyAbsUs.size(),
                  indexTrusted ? @"" : [NSString stringWithFormat:@"（索引不可信，向后 RAP 扫描，单点预算 %lldMiB）",
                                        (long long)(tsLim.maxBytes >> 20)],
                  plan.size(), sh->remote ? "（远程卷）" : "");
        }
        return SPThumbOpenResult::Ready;
    };

    auto genThumb = [&](const SPThumbClaim &claim) -> int {
      // The detached worker has no outer autorelease pool. Drain each thumbnail
      // independently so CIImage, CVPixelBuffer, CGImage and NSData intermediates
      // cannot accumulate for the lifetime of the thread. Full-size software
      // fallback surfaces can otherwise retain roughly 154 MB across 48 images.
      @autoreleasepool {
        const int64_t absTargetUs = claim.targetAbsUs;
        sh->cbYieldBase.store(claim.yieldBase);
        sh->cbHoverBase.store(claim.hoverBase);
        sh->cbCancelBase.store(claim.cancelBase);
        auto interrupted = [&] {
            return spthumb::taskInterrupted(sh->stop.load(),
                sh->yieldSeq.load(), claim.yieldBase,
                sh->hoverSeq.load(), claim.hoverBase,
                sh->cancelSeq.load(), claim.cancelBase);
        };
        AVStream *st = ctx->streams[vs];

        auto noteResolved = [&](int64_t keyUs) {
            const int64_t noteKeyUs = keyUs;
            const int64_t noteTargetUs =
                std::max<int64_t>(absTargetUs - sh->originUs, 0);

            __weak SPTimelineThumbnailer *noteObj = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                SPTimelineThumbnailer *s = noteObj;
                if (s) [s _mainNoteResolvedTargetUs:noteTargetUs
                                           forKeyUs:noteKeyUs];
            });
        };
        int64_t mappedKey = -1;
        {

            const int64_t k = spthumb::spThumbMapTargetToIndexKeyAbsUs(
                keyAbsUs, absTargetUs, keyPtsOffsetUs);
            if (k != INT64_MIN) {
                mappedKey = std::max<int64_t>(k - sh->originUs, 0);
                if (done.count(mappedKey)) {
                    noteResolved(mappedKey);
                    return 1;
                }
            }
        }

        spthumb::SPThumbKeyHit tsHit;
        if (!indexTrusted) {
            tsHit = tsKeys.resolve(absTargetUs);
            if (tsHit.known) {
                mappedKey = std::max<int64_t>(tsHit.ptsAbsUs - sh->originUs, 0);
                if (done.count(mappedKey)) {
                    noteResolved(mappedKey);
                    return 1;
                }
            }
        }

        if (spthumb::spThumbFailSuppressed(failNotes, absTargetUs, spNowUs())) return 0;

        if (interrupted()) return -1;
        int64_t t0 = spNowUs();
        bool tsFromTable = false;

        bool scanComplete = true;
        auto noteFail = [&] {
            spthumb::spThumbFailNoteAdd(failNotes, absTargetUs, tsGopUs, spNowUs());
        };
        SPDecodedVideoOutput out = SPDecodedVideoOutputEmpty();
        int fed = 0;
        float doviFloats[sp::kDoviGpuFloats];

        auto feedPacket = [&](AVPacket *pkt) -> bool {
            if (sh->doviIPT && fed == 0) {
                spThumbDoviFloatsFromPacket(pkt, sh->doviNalLengthSize, doviFloats);
            }
            if (!dec) {
                if (decoderFailed) return false;
                SPVideoDecoder *vt = [SPVideoDecoder new];
                vt.spLogId = sh->logId;
                // Non-HEVC codecs never consume a first-packet hint.
                vt.firstPacketHint = spThumbFirstPacketHint(st->codecpar, pkt);
                int ow = 0, oh = 0;
                spThumbFitSize(st->codecpar->width, st->codecpar->height,
                               st->codecpar->sample_aspect_ratio, &ow, &oh);
                vt.outputWidthHint = ow;
                vt.outputHeightHint = oh;
                int r = [vt setupWithCodecParameters:st->codecpar
                                   timeBaseNumerator:st->time_base.num
                                 timeBaseDenominator:st->time_base.den];
                vt.firstPacketHint = nil;
                if (r == 0) {
                    dec = vt;
                } else {
                    [vt shutdown];
                    // Fall back to FFmpeg when VideoToolbox cannot decode the
                    // codec, including unsupported AV1, VC-1 and RV variants.
                    // Single-frame slice mode avoids frame-pipeline startup cost
                    // for an isolated keyframe.
                    SPFFmpegDecoder *sw = [SPFFmpegDecoder new];
                    sw.spLogId = sh->logId;
                    sw.singleFrameMode = YES;

                    sw.outputWidthHint = ow;
                    sw.outputHeightHint = oh;
                    int r2 = [sw setupWithCodecParameters:st->codecpar
                                        timeBaseNumerator:st->time_base.num
                                      timeBaseDenominator:st->time_base.den];
                    if (r2 != 0) {
                        [sw shutdown];
                        if (++decoderSetupFails >= 2) decoderFailed = true;
                        if (spDebug()) NSLog(@"[c%u][Thumb] 解码器创建失败 VT r=%d 软解 r=%d（第 %d 次）%s", sh->logId, r, r2, decoderSetupFails, decoderFailed ? "，缩略图停用" : "");
                        return false;
                    }
                    dec = sw;
                    if (spDebug()) NSLog(@"[c%u][Thumb] VT 不支持(r=%d)，FFmpeg 软解兜底", sh->logId, r);
                }
                decoderSetupFails = 0;
            }
            out = [dec decodePacketOutput:pkt];
            fed++;
            return true;
        };

        auto readAndFeed = [&]() -> bool {
            AVPacket *pkt = av_packet_alloc();
            if (!pkt) return true;
            bool keyFed = fed > 0;
            int64_t videoPkts = 0, bytes = 0;
            while (!spthumb::spThumbReadBudgetExhausted(videoPkts, bytes)) {
                if (interrupted()) { av_packet_free(&pkt); return false; }
                if (av_read_frame(ctx, pkt) < 0) break;
                bytes += pkt->size;
                if (pkt->stream_index != vs) { av_packet_unref(pkt); continue; }
                videoPkts++;
                if (!keyFed && !(pkt->flags & AV_PKT_FLAG_KEY)) {
                    av_packet_unref(pkt);
                    continue;
                }
                const bool ok = feedPacket(pkt);
                av_packet_unref(pkt);
                if (!ok) break;
                keyFed = true;
                if (out.pixelBuffer) break;

                if (dec.lastError != 0 || fed >= 8) break;
            }
            av_packet_free(&pkt);
            return true;
        };

        auto feedKnownKey = [&](const spthumb::SPThumbKeyHit &hit) -> int {
            if (av_seek_frame(ctx, vs, hit.pos, AVSEEK_FLAG_BYTE) < 0) return 0;
            AVPacket *pkt = av_packet_alloc();
            if (!pkt) return 0;
            int r = 0;
            for (int n = 0; n < 256; ++n) {
                if (interrupted()) { r = -1; break; }
                if (av_read_frame(ctx, pkt) < 0) break;
                if (pkt->stream_index != vs) { av_packet_unref(pkt); continue; }
                const int64_t pts = pkt->pts != AV_NOPTS_VALUE
                    ? av_rescale_q(pkt->pts, st->time_base, AV_TIME_BASE_Q) : INT64_MIN;
                const bool match = (pkt->flags & AV_PKT_FLAG_KEY) && pts != INT64_MIN &&
                                   llabs(pts - hit.ptsAbsUs) <= 1000;
                if (match && feedPacket(pkt)) r = 1;
                av_packet_unref(pkt);
                break;
            }
            av_packet_free(&pkt);
            return r;
        };
        if (indexTrusted) {

            int64_t ts = av_rescale_q(absTargetUs, AV_TIME_BASE_Q, st->time_base);
            if (avformat_seek_file(ctx, vs, INT64_MIN, ts, ts, 0) < 0) {
                if (interrupted()) return -1;
                noteFail();
                return 0;
            }
            if (!readAndFeed()) { if (dec) [dec flush]; return -1; }
        } else {

            int64_t replayPos = -1;
            bool tsFed = false;
            tsFromTable = false;
            if (tsHit.known) {
                const int r = feedKnownKey(tsHit);
                if (r < 0) return -1;
                tsFed = r == 1;
                tsFromTable = tsFed;
                replayPos = tsHit.pos;
                if (spDebug()) NSLog(@"[c%u][Thumb] 关键帧表命中 %.1fs → %.1fs%@", sh->logId,
                                     (absTargetUs - sh->originUs) / 1e6,
                                     (tsHit.ptsAbsUs - sh->originUs) / 1e6,
                                     tsFed ? @"（按字节回放）" : @"（回放落不到，改扫描）");
            }
            if (!tsFed) {
                const std::function<bool()> abortFn = [&] { return interrupted(); };
                sp::SPTsRapScanResult rap = sp::spTsRapScanBackward(
                    ctx, vs, absTargetUs, sh->originUs, tsLim, &tsGopUs, &abortFn);

                tsKeys.noteReorder(rap.reorderMaxUs);
                for (const auto &k : rap.keys) tsKeys.noteKey(k.first, k.second);
                for (const auto &o : rap.observed)
                    tsKeys.noteSpan(o.fromDtsUs, o.untilDtsUs, o.fromHead, o.untilEof);
                if (rap.aborted || interrupted()) return -1;
                if (rap.pos < 0 || !rap.keyPkt) {
                    if (spDebug()) NSLog(@"[c%u][Thumb] RAP 扫描未找到关键帧 %.1fs（capped=%d 读 %lldKB）",
                                         sh->logId, (absTargetUs - sh->originUs) / 1e6,
                                         (int)rap.capped, (long long)(rap.bytes / 1024));
                    noteFail();
                    return 0;
                }

                if (rap.fromHead && !rap.reachedFloor && !rap.spanExhausted) {
                    if (spDebug()) NSLog(@"[c%u][Thumb] RAP 扫描触上界（读 %lldKB）退到片头，不作 %.1fs 的答案",
                                         sh->logId, (long long)(rap.bytes / 1024),
                                         (absTargetUs - sh->originUs) / 1e6);
                    noteFail();
                    return 0;
                }
                mappedKey = std::max<int64_t>(rap.ptsUs - sh->originUs, 0);
                scanComplete = !rap.capped;
                if (!scanComplete && spDebug())
                    NSLog(@"[c%u][Thumb] RAP 扫描不完整（读 %lldKB）：%.1fs 取邻近图 %.1fs，不登记精确覆盖",
                          sh->logId, (long long)(rap.bytes / 1024),
                          (absTargetUs - sh->originUs) / 1e6, (rap.ptsUs - sh->originUs) / 1e6);
                if (!feedPacket(rap.keyPkt)) { noteFail(); return 0; }
                replayPos = rap.pos;
            }
            if (!out.pixelBuffer && dec.lastError == 0) {

                [dec flush];
                fed = 0;
                if (av_seek_frame(ctx, vs, replayPos, AVSEEK_FLAG_BYTE) >= 0) {
                    if (!readAndFeed()) { [dec flush]; return -1; }
                }
            }
        }
        if (!out.pixelBuffer) {
            if (dec) [dec flush];
            if (interrupted()) return -1;
            noteFail();
            return 0;
        }
        int64_t keyUs = out.ptsUs - sh->originUs;
        if (keyUs < 0) keyUs = 0;
        const int64_t resolvedTargetUs = spthumb::spThumbCoverageTargetUs(
            scanComplete, keyUs, std::max<int64_t>(absTargetUs - sh->originUs, 0));

        if (spthumb::discardDecodedFrame(sh->stop.load(), sh->yieldSeq.load(),
                                         claim.yieldBase, sh->cancelSeq.load(),
                                         claim.cancelBase)) {
            CVPixelBufferRelease(out.pixelBuffer);
            [dec flush];
            return -1;
        }
        const bool supersededByHover =
            claim.hoverBase != kImmuneBase && sh->hoverSeq.load() != claim.hoverBase;
        if (!ciCtx) {
            ciCtx = [CIContext contextWithOptions:@{
                kCIContextCacheIntermediates : @NO }];
        }
        bool isHEIC = false;

        CGImageRef cg = NULL;
        if (sh->doviIPT) {

            if (spThumbDoviGpuSetup(doviGpu, sh->logId)) {
                cg = spThumbRenderDoviCG(doviGpu, out.pixelBuffer, doviFloats, sh->logId);
            }
            isHEIC = cg != NULL;
        } else {
            cg = spThumbRenderCG(ciCtx, srgb, out.pixelBuffer, hdrTrc, &isHEIC, sh->logId);
        }
        cg = spThumbRotateCG(cg, rotation);

        int64_t tPublishUs = 0;
        if (cg && isHEIC) {
            spThumbPublishImage(weakSelf, cg, keyUs, resolvedTargetUs);
            tPublishUs = spNowUs();
        }
        NSData *jpeg = cg ? spThumbEncodeCG(cg, isHEIC) : nil;
        if (!jpeg && isHEIC && !sh->doviIPT) {

            if (spDebug()) NSLog(@"[c%u][Thumb] HEIC 编码失败，跌落 SDR", sh->logId);
            CGImageRelease(cg);
            isHEIC = false;
            cg = spThumbRenderCG(ciCtx, srgb, out.pixelBuffer, /*hdrTrc=*/0,
                                 &isHEIC, sh->logId);
            cg = spThumbRotateCG(cg, rotation);
            jpeg = cg ? spThumbEncodeCG(cg, false) : nil;
            if (jpeg) spThumbPublishImage(weakSelf, cg, keyUs, resolvedTargetUs);
        }
        CVPixelBufferRelease(out.pixelBuffer);
        [dec flush];
        if (!jpeg) {
            if (cg) CGImageRelease(cg);
            noteFail();
            return 0;
        }
        failNotes.clear();

        if (indexTrusted && !keyAbsUs.empty() && !keyPtsCalibrated) {
            keyPtsCalibrated = true;
            keyPtsOffsetUs = spthumb::spThumbIndexPtsOffsetUs(keyAbsUs, out.ptsUs);
            if (keyPtsOffsetUs > 0) {

                const int64_t k = spthumb::spThumbMapTargetToIndexKeyAbsUs(
                    keyAbsUs, absTargetUs, keyPtsOffsetUs);
                mappedKey = k == INT64_MIN ? -1 : std::max<int64_t>(k - sh->originUs, 0);
                if (spDebug()) NSLog(@"[c%u][Thumb] 索引 dts→pts 偏移校准 %.1fms", sh->logId, keyPtsOffsetUs / 1000.0);
            }
        }
        done.insert(keyUs);

        if (mappedKey >= 0 && spthumb::spThumbIndexKeyAliasesDecoded(mappedKey, keyUs))
            done.insert(mappedKey);
        generated++;
#if !SP_APP_STORE

        if (const char *dumpDir = getenv("SP_THUMBS_DUMP")) {
            NSString *p = [NSString stringWithFormat:@"%s/thumb_%07.1fs.%s",
                                                     dumpDir, keyUs / 1e6,
                                                     isHEIC ? "heic" : "jpg"];
            [jpeg writeToFile:p atomically:NO];

            if (isHEIC && cg) {
                NSData *png = spThumbEncodeImage(cg, CFSTR("public.png"), 1.0);
                if (png) {
                    [png writeToFile:[NSString stringWithFormat:
                                         @"%s/thumb_%07.1fs.pre.png",
                                         dumpDir, keyUs / 1e6]
                          atomically:NO];
                }
            }
        }
#endif
        lastCostMs = (spNowUs() - t0) / 1000.0;
        if (spDebug() && (generated <= 3 || generated % 20 == 0 || supersededByHover)) {

            NSLog(@"[c%u][Thumb] #%d key=%.1fs %.0fms%@ %luKB%@%@", sh->logId, generated,
                  keyUs / 1e6, lastCostMs,
                  tPublishUs ? [NSString stringWithFormat:@" 图=%.0fms",
                                   (tPublishUs - t0) / 1000.0] : @"",
                  (unsigned long)(jpeg.length / 1024),
                  tsFromTable ? @"（关键帧表命中）" : @"",
                  supersededByHover ? @"（已被新 hover 顶替，作邻近图发布）" : @"");
        }

        float dustH = 0, dustS = 0, dustL = 0;
        const bool dustOK = spThumbDustColor(cg, &dustH, &dustS, &dustL);
        id previewImage = nil;
        if (claim.kind == SPThumbTaskKind::Hover && !isHEIC) {
            previewImage = CFBridgingRelease(cg);
        } else {
            CGImageRelease(cg);
        }
        // Materialize a local weak reference before creating the Objective-C
        // block. Capturing the worker's weakSelf parameter through a [&] lambda
        // would retain a reference to stack storage after the worker exits;
        // value capture registers the weak reference correctly.
        __weak SPTimelineThumbnailer *publishTarget = weakSelf;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPTimelineThumbnailer *s = publishTarget;
            if (s) [s _mainStoreJPEG:jpeg
                            forKeyUs:keyUs
                    resolvedTargetUs:resolvedTargetUs
                         previewImage:previewImage
                            dustValid:dustOK dustHue:dustH dustSat:dustS dustLuma:dustL];
        });
        return 1;
      } // @autoreleasepool
    };

    int probeBlockedStreak = 0;

    int64_t gateSettleUs = -1;
    uint64_t gateSettleYield = 0;
    for (;;) {
        if (sh->stop.load()) break;

        spThumbApplyIOTier(spthumb::SPThumbIOTier::Throttle, /*hoverTask=*/false);
        SPThumbClaim claim;
        {
            std::unique_lock<std::mutex> lk(sh->mtx);

            if (!sh->evictedKeys.empty()) {
                for (int64_t k : sh->evictedKeys) {

                    done.erase(k - 1);
                    done.erase(k);
                    done.erase(k + 1);
                }
                sh->evictedKeys.clear();
                failNotes.clear();
            }
            auto workLeft = [&] {

                return sh->sweepArmed && !openFailed && !decoderFailed &&
                       (!planBuilt || planIdx < plan.size());
            };
            if (sh->hoverTargetUs < 0 && !workLeft()) {
                if (openFailed || decoderFailed) {

                    sh->cv.wait(lk, [&] {
                        return sh->stop.load() || sh->hoverTargetUs >= 0;
                    });
                } else {

                    const bool signaled =
                        sh->cv.wait_for(lk, std::chrono::seconds(30), [&] {
                            return sh->stop.load() || sh->hoverTargetUs >= 0 ||
                                   workLeft();
                        });

                    if (!signaled && (dec || ciCtx || doviGpu.ready())) {
                        lk.unlock();
                        if (dec) { [dec shutdown]; dec = nil; }
                        ciCtx = nil;
                        doviGpu.teardown();
                        if (spDebug()) NSLog(@"[c%u][Thumb] 空闲拆除解码器/CIContext（上下文保留）", sh->logId);
                        lk.lock();
                    }
                }
            }
            if (sh->stop.load()) break;
            if (sh->hoverTargetUs >= 0) {

                const uint64_t curYield = sh->yieldSeq.load();
                if (curYield != gateSettleYield) {
                    gateSettleYield = curYield;
                    gateSettleUs = -1;
                }
                const int64_t sinceYieldUs =
                    spNowUs() - sh->lastYieldWallUs.load();
                const bool seekBusyNow = seekBusy && seekBusy();

                if (!seekBusyNow && gateSettleUs < 0) gateSettleUs = sinceYieldUs;
                const int64_t waitUs = spthumb::hoverGateWaitUs(
                    sh->everInteracted.load(), sh->remote, sinceYieldUs,
                    seekBusyNow, gateSettleUs);
                if (waitUs > 0) {
                    sh->cv.wait_for(lk, std::chrono::microseconds(waitUs + 1000));
                    continue;
                }

                claim.kind = SPThumbTaskKind::Hover;
                claim.targetAbsUs = sh->hoverTargetUs + sh->originUs;
                sh->activeHoverTargetUs = sh->hoverTargetUs;
                sh->hoverTargetUs = -1;
                claim.hoverBase = sh->hoverSeq.load();
                sh->activeHoverBase = claim.hoverBase;
                claim.yieldBase = sh->yieldSeq.load();
                claim.cancelBase = sh->cancelSeq.load();
            } else if (workLeft()) {

                claim.kind = SPThumbTaskKind::Sweep;
                claim.hoverBase = sh->hoverSeq.load();
                claim.yieldBase = sh->yieldSeq.load();

            }
        }

        spThumbApplyIOTier(spthumb::ioTierForClaim(claim.kind, sh->remote),
                           claim.kind == SPThumbTaskKind::Hover);

        if (claim.kind == SPThumbTaskKind::Hover) {

            const SPThumbOpenResult o = ensureOpen(claim);
            int r = 0;
            if (o == SPThumbOpenResult::Preempted) {

                r = -1;
            } else if (o == SPThumbOpenResult::Ready && !decoderFailed) {
                r = genThumb(claim);
            }
            if (r == -1) {

                std::unique_lock<std::mutex> lk(sh->mtx);
                for (;;) {
                    const auto d = spthumb::holdDecision(
                        sh->stop.load(), sh->hoverTargetUs >= 0,
                        sh->hoverSeq.load() != claim.hoverBase ||
                            sh->cancelSeq.load() != claim.cancelBase,
                        sh->remote,
                        spNowUs() - sh->lastYieldWallUs.load());
                    if (d.verdict == SPThumbHoldVerdict::Requeue) {
                        sh->hoverTargetUs = claim.targetAbsUs - sh->originUs;
                        break;
                    }
                    if (d.verdict == SPThumbHoldVerdict::Drop) break;
                    sh->cv.wait_for(lk,
                        std::chrono::microseconds(d.waitUs + 1000));
                }
                sh->activeHoverTargetUs = INT64_MIN;
            } else {
                std::lock_guard<std::mutex> g(sh->mtx);
                sh->activeHoverTargetUs = INT64_MIN;
            }
            continue;
        }
        if (claim.kind != SPThumbTaskKind::Sweep) continue;

        const bool quiet = spthumb::sweepQuietSatisfied(
            sh->remote, spNowUs() - sh->lastYieldWallUs.load());
        if (!quiet || (probe && !probe())) {
            // Report sustained admission blocking so a permanently false idle
            // predicate, such as a low packet watermark on TrueHD, is observable.
            if (++probeBlockedStreak % 120 == 0 && spDebug()) {
                NSLog(@"[c%u][Thumb] 闲判据连续拦截 ~%ds（quiet=%d probe=%d）",
                      sh->logId, probeBlockedStreak / 4, (int)quiet,
                      probe ? (int)probe() : -1);
            }
            std::unique_lock<std::mutex> lk(sh->mtx);
            sh->cv.wait_for(lk, std::chrono::milliseconds(250), [&] {
                return sh->stop.load() || sh->hoverTargetUs >= 0;
            });
            continue;
        }
        probeBlockedStreak = 0;

        if (ensureOpen(claim) != SPThumbOpenResult::Ready) continue;
        if (planIdx >= plan.size()) continue;
        if (sweepT0 == 0) sweepT0 = spNowUs();
        claim.targetAbsUs = plan[planIdx];
        const int r = genThumb(claim);
        if (r == 1) {
            planIdx++;
            planFail = 0;
        } else if (r == 0) {

            if (++planFail >= 2) { planIdx++; planFail = 0; }
        }
        if (planIdx >= plan.size() && !sweepLogged) {
            sweepLogged = true;
            if (spDebug()) {
                NSLog(@"[c%u][Thumb] 扫描完成：%d 张 / %.1fs", sh->logId, generated,
                      (spNowUs() - sweepT0) / 1e6);
            }
        }

        std::unique_lock<std::mutex> lk(sh->mtx);
        sh->cv.wait_for(lk, std::chrono::milliseconds(
                                spthumb::sweepWaitMs(r == 1 ? lastCostMs : 0.0, sh->remote)),
                        [&] {
                            return sh->stop.load() || sh->hoverTargetUs >= 0;
                        });
    }

    if (dec) [dec shutdown];
    doviGpu.teardown();
    if (ctx) avformat_close_input(&ctx);
    CGColorSpaceRelease(srgb);
}

static bool spThumbDustColor(CGImageRef cg, float *hue, float *sat, float *luma) {
    if (!cg) return false;
    const size_t bpc = CGImageGetBitsPerComponent(cg);
    const size_t bpp = CGImageGetBitsPerPixel(cg);
    if (!((bpc == 8 && bpp == 32) || (bpc == 16 && bpp == 64))) return false;
    CGDataProviderRef prov = CGImageGetDataProvider(cg);
    CFDataRef data = prov ? CGDataProviderCopyData(prov) : NULL;
    if (!data) return false;
    const size_t W = CGImageGetWidth(cg), H = CGImageGetHeight(cg);
    const size_t stride = CGImageGetBytesPerRow(cg);
    const uint8_t *base = CFDataGetBytePtr(data);
    const size_t len = (size_t)CFDataGetLength(data);
    float hist[24] = {0};
    float binSat[24] = {0}, binLum[24] = {0};
    double lumaSum = 0; size_t n = 0;
    for (size_t y = 0; y < H; y += 2) {
        const uint8_t *row = base + y * stride;
        if ((size_t)(row - base) + W * (bpp / 8) > len) break;
        for (size_t x = 0; x < W; x += 2) {
            float r, g, b;
            if (bpc == 8) {
                const uint8_t *p = row + x * 4;
                r = p[0] / 255.f; g = p[1] / 255.f; b = p[2] / 255.f;
            } else {
                const uint16_t *p = (const uint16_t *)(row + x * 8);
                r = p[0] / 65535.f; g = p[1] / 65535.f; b = p[2] / 65535.f;
            }
            const float mx = fmaxf(r, fmaxf(g, b)), mn = fminf(r, fminf(g, b));
            const float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            const float sa = mx > 0 ? (mx - mn) / mx : 0;
            lumaSum += l; n++;
            if (mx - mn > 0.03f) {
                float hh;
                if (mx == r) hh = (g - b) / (mx - mn);
                else if (mx == g) hh = 2 + (b - r) / (mx - mn);
                else hh = 4 + (r - g) / (mx - mn);
                if (hh < 0) hh += 6;
                int bin = (int)(hh * 4); if (bin > 23) bin = 23; if (bin < 0) bin = 0;
                hist[bin] += sa * l;
                binSat[bin] += sa * l;
                binLum[bin] += l;
            }
        }
    }
    CFRelease(data);
    if (n == 0) return false;

    float sm[24];
    for (int k = 0; k < 24; ++k)
        sm[k] = 0.5f * hist[k] + 0.25f * (hist[(k + 23) % 24] + hist[(k + 1) % 24]);
    int best = 0;
    for (int k = 1; k < 24; ++k) if (sm[k] > sm[best]) best = k;

    float satW = 0, lumW = 0;
    for (int d = -1; d <= 1; ++d) { int k = (best + d + 24) % 24; satW += binSat[k]; lumW += binLum[k]; }

    float hAcc = 0, wAcc = 0;
    for (int d = -1; d <= 1; ++d) { int k = (best + d + 24) % 24; hAcc += (best + d + 0.5f) * hist[k]; wAcc += hist[k]; }
    float hh = wAcc > 0 ? hAcc / wAcc : best + 0.5f;
    if (hh < 0) hh += 24; if (hh >= 24) hh -= 24;
    *hue = hh / 24.f;
    *sat = lumW > 0 ? satW / lumW : 0;
    *luma = (float)(lumaSum / n);
    return true;
}

@implementation SPThumbDustSnapshot
- (instancetype)initWithGeneration:(uint64_t)gen keys:(NSData *)keys covers:(NSData *)covers
                     sweepSpacingUs:(int64_t)spacing {
    if ((self = [super init])) {
        _generation = gen; _keys = keys; _covers = covers; _sweepSpacingUs = spacing;
    }
    return self;
}
@end

@implementation SPTimelineThumbnailer {
    std::shared_ptr<SPThumbShared> _shared;
    SPThumbIdleProbe _idleProbe;
    SPThumbSeekBusyProbe _seekBusyProbe;
    void (^_onUpdate)(void);
    BOOL _workerStarted;

    std::map<int64_t, NSData *> _encodedByKeyUs;
    size_t _encodedBytes;
    int64_t _lastQueryKeyUs;

    std::map<int64_t, std::pair<int64_t, int64_t>> _coveredByKeyUs;

    BOOL _sawHDR;
    std::list<std::pair<int64_t, id>> _lru;
    std::map<int64_t, std::list<std::pair<int64_t, id>>::iterator> _lruIdx;

    NSData *_dustKeys;
    int64_t _dustSweepSpacingUs;
    std::map<int64_t, std::array<float, 3>> _dustColorByKeyUs;
    uint64_t _dustGen;
    SPThumbDustSnapshot *_dustSnapCache;
    uint64_t _dustSnapCacheGen;
}

- (void)setSpLogId:(unsigned)spLogId {
    _spLogId = spLogId;
    if (_shared) _shared->logId = spLogId;
}

- (instancetype)initWithPath:(NSString *)path
                  durationUs:(int64_t)durationUs
            timelineOriginUs:(int64_t)originUs
                remoteVolume:(BOOL)remoteVolume
              colorPrimaries:(int)colorPrimaries
                    colorTrc:(int)colorTrc
                  colorSpace:(int)colorSpace
                  colorRange:(int)colorRange
                 videoParams:(nullable const AVCodecParameters *)videoParams
            videoStreamIndex:(int)videoStreamIndex
               videoStreamId:(int)videoStreamId
                     doviIPT:(BOOL)doviIPT
           doviNalLengthSize:(int)doviNalLengthSize
                   idleProbe:(SPThumbIdleProbe)idleProbe
               seekBusyProbe:(nullable SPThumbSeekBusyProbe)seekBusyProbe
                    onUpdate:(void (^)(void))onUpdate {
    if ((self = [super init])) {
        _shared = std::make_shared<SPThumbShared>();
        _shared->path = path.fileSystemRepresentation;
        _shared->durationUs = durationUs;
        _shared->originUs = originUs;
        _shared->remote = remoteVolume;
        _shared->colorPrimaries = colorPrimaries;
        _shared->colorTrc = colorTrc;
        _shared->colorSpace = colorSpace;
        _shared->colorRange = colorRange;
        _shared->videoStreamIndex = videoStreamIndex;
        _shared->videoStreamId = videoStreamId;
        _shared->doviIPT = doviIPT;
        _shared->doviNalLengthSize = doviNalLengthSize > 0 ? doviNalLengthSize : 4;
        if (videoParams) {
            _shared->videoPar = avcodec_parameters_alloc();
            if (_shared->videoPar && avcodec_parameters_copy(_shared->videoPar, videoParams) < 0) {
                avcodec_parameters_free(&_shared->videoPar);
            }
        }
        _shared->lastYieldWallUs.store(spNowUs());
        _idleProbe = [idleProbe copy];
        _seekBusyProbe = [seekBusyProbe copy];
        _onUpdate = [onUpdate copy];
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (void)_ensureWorker {
    if (_workerStarted || !_shared) return;
    _workerStarted = YES;
    auto sh = _shared;
    SPThumbIdleProbe probe = _idleProbe;
    SPThumbSeekBusyProbe seekBusy = _seekBusyProbe;
    __weak SPTimelineThumbnailer *weakSelf = self;
    std::thread([sh, probe, seekBusy, weakSelf] {
        spThumbWorkerMain(sh, probe, seekBusy, weakSelf);
    }).detach();
}

- (void)startSweep {
    auto sh = _shared;
    if (!sh || sh->stop.load()) return;
    [self _ensureWorker];
    {
        std::lock_guard<std::mutex> g(sh->mtx);
        sh->sweepArmed = true;
    }
    sh->cv.notify_one();
}

- (void)requestPreviewAt:(double)seconds {
    auto sh = _shared;
    if (!sh || sh->stop.load() || seconds < 0) return;
    [self _ensureWorker];
    {
        std::lock_guard<std::mutex> g(sh->mtx);
        const int64_t tUs = (int64_t)(seconds * 1e6);

        const bool samePending = (sh->hoverTargetUs == tUs);
        const bool sameActiveFresh =
            sh->hoverTargetUs < 0 && sh->activeHoverTargetUs == tUs &&
            sh->hoverSeq.load() == sh->activeHoverBase;
        if (samePending || sameActiveFresh) return;
        sh->hoverTargetUs = tUs;

        sh->hoverSeq.fetch_add(1);
    }
    sh->cv.notify_one();
}

- (nullable id)previewImageAt:(double)seconds isExact:(nullable BOOL *)outExact {
    if (outExact) *outExact = NO;
    if (_encodedByKeyUs.empty() || seconds < 0) return nil;
    const int64_t tUs = (int64_t)(seconds * 1e6);
    auto it = _encodedByKeyUs.upper_bound(tUs);
    if (it != _encodedByKeyUs.begin()) --it;
    _lastQueryKeyUs = it->first;

    bool covered = false;
    {
        auto c = _coveredByKeyUs.find(it->first);
        covered = c != _coveredByKeyUs.end() &&
                  spthumb::spThumbCoverageContains(c->second.first, c->second.second, tUs);
    }

    if (!spthumb::spThumbPreviewWithinReach(tUs, it->first,
                                            _shared ? _shared->durationUs : 0, covered)) {
        return nil;
    }
    id img = [self _decodedImageForKeyUs:it->first jpeg:it->second];
    if (img && outExact && covered) *outExact = YES;
    return img;
}

- (BOOL)_mergeCoverageForKeyUs:(int64_t)keyUs targetUs:(int64_t)targetUs {
    const int64_t from = std::min(keyUs, targetUs);
    const int64_t until = std::max(keyUs, targetUs);
    auto c = _coveredByKeyUs.find(keyUs);
    if (c == _coveredByKeyUs.end()) {
        _coveredByKeyUs.emplace(keyUs, std::make_pair(from, until));
        return YES;
    }
    BOOL widened = NO;
    if (from < c->second.first) { c->second.first = from; widened = YES; }
    if (until > c->second.second) { c->second.second = until; widened = YES; }
    return widened;
}

- (void)_mainNoteResolvedTargetUs:(int64_t)targetUs forKeyUs:(int64_t)keyUs {
    if (!_shared || _shared->stop.load()) return;
    int64_t k = keyUs;
    if (!_encodedByKeyUs.count(k)) {

        auto near = _encodedByKeyUs.lower_bound(k - 1);
        if (near == _encodedByKeyUs.end() || llabs(near->first - k) > 1) return;
        k = near->first;
    }
    if ([self _mergeCoverageForKeyUs:k targetUs:targetUs]) {
        _dustGen++;
        if (_onUpdate) _onUpdate();
    }
}

- (void)_mainStoreDustKeys:(NSData *)keys sweepSpacingUs:(int64_t)spacing {
    if (!_shared || _shared->stop.load()) return;
    _dustKeys = keys;
    _dustSweepSpacingUs = spacing;
    _dustGen++;
    if (spDebug()) NSLog(@"[c%u][Dust] 关键帧表 %lu 项，扫描桶 %.1fs", _spLogId,
                         (unsigned long)(keys.length / sizeof(SPDustKey)), spacing / 1e6);
    if (_onUpdate) _onUpdate();
}

- (nullable SPThumbDustSnapshot *)dustSnapshot {
    if (!_shared) return nil;
    if (_dustSnapCache && _dustSnapCacheGen == _dustGen) return _dustSnapCache;
    NSMutableData *covers = [NSMutableData dataWithCapacity:_coveredByKeyUs.size() * sizeof(SPDustCover)];
    for (const auto &kv : _coveredByKeyUs) {
        SPDustCover c;
        c.keyUs = kv.first; c.fromUs = kv.second.first; c.untilUs = kv.second.second;
        auto col = _dustColorByKeyUs.find(kv.first);
        if (col != _dustColorByKeyUs.end()) {
            c.hue = col->second[0]; c.sat = col->second[1]; c.luma = col->second[2]; c.valid = 1;
        } else {
            c.hue = 0; c.sat = 0; c.luma = 0; c.valid = 0;
        }
        [covers appendBytes:&c length:sizeof c];
    }
    _dustSnapCache = [[SPThumbDustSnapshot alloc] initWithGeneration:_dustGen
                                                                keys:_dustKeys ?: [NSData data]
                                                              covers:covers
                                                      sweepSpacingUs:_dustSweepSpacingUs];
    _dustSnapCacheGen = _dustGen;
    return _dustSnapCache;
}

- (id)_decodedImageForKeyUs:(int64_t)keyUs jpeg:(NSData *)jpeg {
    auto f = _lruIdx.find(keyUs);
    if (f != _lruIdx.end()) {
        _lru.splice(_lru.begin(), _lru, f->second);
        return f->second->second;
    }

    if (jpeg.length == 0) return nil;

    CGImageSourceRef src =
        CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    CGImageRef cg = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src) CFRelease(src);
    if (!cg) {

        auto bad = _encodedByKeyUs.find(keyUs);
        if (bad != _encodedByKeyUs.end()) {
            _encodedBytes -= std::min(_encodedBytes, (size_t)bad->second.length);
            _encodedByKeyUs.erase(bad);
        }
        _coveredByKeyUs.erase(keyUs);

        if (auto sh = _shared) {
            std::lock_guard<std::mutex> g(sh->mtx);
            sh->evictedKeys.push_back(keyUs);
        }
        return nil;
    }
    id boxed = CFBridgingRelease(cg);
    [self _lruInsert:boxed forKeyUs:keyUs];
    return boxed;
}

- (void)_lruInsert:(id)image forKeyUs:(int64_t)keyUs {
    auto f = _lruIdx.find(keyUs);
    if (f != _lruIdx.end()) {
        f->second->second = image;
        _lru.splice(_lru.begin(), _lru, f->second);
        return;
    }
    _lru.emplace_front(keyUs, image);
    _lruIdx[keyUs] = _lru.begin();
    while (_lru.size() > spthumb::decodedLruCap(_sawHDR)) {
        _lruIdx.erase(_lru.back().first);
        _lru.pop_back();
    }
}

- (void)_mainStorePreviewImage:(id)image
                      forKeyUs:(int64_t)keyUs
              resolvedTargetUs:(int64_t)resolvedTargetUs {
    if (!_shared || _shared->stop.load() || !image) return;
    _sawHDR = YES;
    if (!_encodedByKeyUs.count(keyUs)) _encodedByKeyUs[keyUs] = nil;
    [self _lruInsert:image forKeyUs:keyUs];
    [self _mergeCoverageForKeyUs:keyUs targetUs:resolvedTargetUs];
    _dustGen++;
    if (_onUpdate) _onUpdate();
}

- (void)_mainStoreJPEG:(NSData *)jpeg
              forKeyUs:(int64_t)keyUs
      resolvedTargetUs:(int64_t)resolvedTargetUs
           previewImage:(nullable id)previewImage
              dustValid:(BOOL)dustValid dustHue:(float)dustHue dustSat:(float)dustSat dustLuma:(float)dustLuma {
    if (!_shared || _shared->stop.load()) return;
    if (dustValid) {
        _dustColorByKeyUs[keyUs] = {dustHue, dustSat, dustLuma};
        if (spDebug() && _dustColorByKeyUs.size() <= 12)
            NSLog(@"[c%u][Dust] 色 key=%.1fs hue=%.0f° sat=%.2f luma=%.2f", _spLogId, keyUs / 1e6,
                  dustHue * 360, dustSat, dustLuma);
    }
    _dustGen++;
    auto old = _encodedByKeyUs.find(keyUs);
    if (old != _encodedByKeyUs.end())
        _encodedBytes -= std::min(_encodedBytes, (size_t)old->second.length);
    _encodedByKeyUs[keyUs] = jpeg;
    _encodedBytes += jpeg.length;
    [self _mergeCoverageForKeyUs:keyUs targetUs:resolvedTargetUs];

    constexpr size_t kEncodedBytesCap = 16 * 1024 * 1024;
    const int64_t ref = _lastQueryKeyUs > 0 ? _lastQueryKeyUs : keyUs;
    while (_encodedBytes > kEncodedBytesCap && _encodedByKeyUs.size() > 1) {
        auto first = _encodedByKeyUs.begin();
        auto last = std::prev(_encodedByKeyUs.end());
        auto victim = llabs(first->first - ref) >= llabs(last->first - ref)
                          ? first : last;
        if (victim->first == keyUs) break;
        _encodedBytes -= std::min(_encodedBytes, (size_t)victim->second.length);
        auto lru = _lruIdx.find(victim->first);
        if (lru != _lruIdx.end()) { _lru.erase(lru->second); _lruIdx.erase(lru); }

        if (auto sh = _shared) {
            std::lock_guard<std::mutex> g(sh->mtx);
            sh->evictedKeys.push_back(victim->first);
        }
        _coveredByKeyUs.erase(victim->first);
        _dustColorByKeyUs.erase(victim->first);
        _encodedByKeyUs.erase(victim);
    }

    if (previewImage) [self _lruInsert:previewImage forKeyUs:keyUs];
    if (_onUpdate) _onUpdate();
}

- (void)noteInteraction {
    auto sh = _shared;
    if (!sh) return;

    std::lock_guard<std::mutex> g(sh->mtx);
    sh->lastYieldWallUs.store(spNowUs());
    sh->everInteracted.store(true);
    sh->yieldSeq.fetch_add(1);
    sh->hoverTargetUs = -1;
}

- (void)cancelPreviewRequest {
    auto sh = _shared;
    if (!sh) return;
    {
        std::lock_guard<std::mutex> g(sh->mtx);
        sh->hoverTargetUs = -1;

        sh->activeHoverTargetUs = INT64_MIN;

        sh->cancelSeq.fetch_add(1);
    }
    sh->cv.notify_one();
}

- (void)shutdown {
    auto sh = _shared;
    if (!sh) return;
    sh->stop.store(true);
    {
        std::lock_guard<std::mutex> g(sh->mtx);
        sh->yieldSeq.fetch_add(1);
    }
    sh->cv.notify_all();
    _shared.reset();
    _encodedByKeyUs.clear();
    _encodedBytes = 0;
    _coveredByKeyUs.clear();
    _lru.clear();
    _lruIdx.clear();
    _idleProbe = nil;
    _seekBusyProbe = nil;
    _onUpdate = nil;
}

@end
