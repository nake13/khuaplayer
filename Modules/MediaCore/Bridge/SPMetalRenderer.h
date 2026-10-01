// Internal Metal renderer. Sample IOSurface-backed pixel buffers without a
// CPU copy, applying color conversion, transfer functions, tone mapping and fit.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

@interface SPMetalRenderer : NSObject

// Playback-instance identifier used by initialization and subsequent logs.
- (instancetype)initWithLayer:(CAMetalLayer *)layer logId:(unsigned)logId;

// Immutable owning playback instance; zero means unassigned.
@property (nonatomic, readonly) unsigned spLogId;

// Share one Metal device across rendering and subtitle modules so textures
// and command queues always belong to the same device.
@property (nonatomic, readonly, strong) id<MTLDevice> device;

// Warm GPU and display resources on a background launch queue.
- (void)warmUpGPU;

// Accept a frame for asynchronous submission. The input must remain valid
// during the call; retained texture references survive GPU use. YES means the
// frame was accepted, not that GPU presentation has completed. Use commit
// counters when actual command submission is required.
- (BOOL)renderPixelBuffer:(CVPixelBufferRef)buffer;

// A background speculative first frame is accepted only before this submission
// session has accepted another frame. Late race results return NO and may be
// discarded. Speculative output does not increment committedFrameCount.
- (BOOL)renderSpeculativeFirstFrame:(CVPixelBufferRef)buffer;

// Present black for the empty-window state; main-thread call.
- (void)clearToBlack;

// Thread-safe reactivation of retained frame or clear intent after a window
// becomes visible, granting another bounded submission retry budget.
- (void)kickSubmitDrain;

// Thread-safe session boundary: advance the submission generation and clear
// queued or retained frames so old work cannot render using new media settings.
- (void)discardPendingSubmits;

// Thread-safe occlusion control. While suspended, retain only the latest
// intent; resume and kick the drain when the window becomes visible.
- (void)setSubmitsSuspended:(BOOL)suspended;

// Monotonic actual frame-commit count. Acceptance alone does not prove a
// commit; compare with the session's initial snapshot for no-frame failure handling.
@property (atomic, readonly) uint64_t committedFrameCount;
// Monotonic encoding failures excluding unavailable drawables. Combine with
// commit count to distinguish occlusion from unsupported or unrenderable frames.
@property (atomic, readonly) uint64_t hardRenderFailureCount;

// Main-thread user-facing description of the current output path.
- (NSString *)outputModeDescription;

// Set stream color metadata using the original FFmpeg AVColor enum values.
- (void)setColorimetryWithPrimaries:(int)primaries
                           transfer:(int)trc
                         colorspace:(int)colorspace
                              range:(int)range
                           peakNits:(float)peakNits;
// Flush the color/DoVi mode published by the setters above to CAMetalLayer and
// the matching generic render PSO.  When a matching SDR or HDR mode needs
// no layer mutation or PSO rebuild, completion may run inline; otherwise it runs
// on main after pixelFormat/colorspace/outputMode and the PSO agree. Opening
// code uses this as the publication barrier before any frame in that generation
// is submitted.
- (void)synchronizeOutputModeWithCompletion:(void (^)(BOOL ready))completion;

// Viewport dimensions in physical pixels.
- (void)setViewportPixelSize:(CGSize)size;
// Diagnostic readback of the next post-shader frame, gated by SP_RENDERDUMP.
- (void)requestRenderDumpToPath:(NSString *)path;
// Main-thread display-mode selection. Potential headroom determines EDR
// eligibility; current headroom is dynamic and may remain one until EDR starts.
// Reevaluate when moving the window between displays.
- (void)updateOutputModeWithMaxEDR:(CGFloat)currentEDR potentialEDR:(CGFloat)potentialEDR;
// Refresh current display headroom as it changes after EDR activation.
- (void)setDisplayEDRHeadroom:(CGFloat)currentEDR;
// Thread-safe SDR inverse tone mapping into available EDR headroom, capped
// at 6x. The core resets the request on new media. Eligible SDR uses the
// floating-point extended-color layer; HDR and non-EDR displays are unchanged.
- (void)setSDRBoostEnabled:(BOOL)enabled;
- (BOOL)sdrBoostEnabled;
// Thread-safe query of potential display EDR capability.
- (BOOL)displayEdrCapable;
// Current display headroom, at least one.
- (CGFloat)displayEDRHeadroom;
// Sample aspect ratio; display ratio is pixel width times SAR divided by height.
- (void)setSampleAspect:(float)sar;
// Dolby Vision Profile 5 uses its dedicated IPTPQ color-conversion path
// instead of the ordinary YCbCr matrix.
- (void)setDoviIPT:(BOOL)on;
// Queue per-frame RPU metadata by packet timestamp and bind by decoded frame
// timestamp before rendering. Seek and session boundaries clear the ring;
// missing timestamps apply the newest value immediately.
- (void)queueDoviReshapeFloats:(const float *)data ptsUs:(int64_t)ptsUs;
- (void)bindDoviReshapeForPtsUs:(int64_t)ptsUs frameIntervalUs:(int64_t)frameIntervalUs;
- (void)clearDoviReshapeQueue;
// Clear RPU history and restore defaults before a new session begins decoding.
// Publishing the Dolby Vision mode later must not erase early frame metadata.
- (void)resetDoviSessionState;

// Subtitle texture and rectangle in viewport coordinates; nil removes the overlay.
@property (nonatomic, strong) id<MTLTexture> subtitleTexture;
@property (nonatomic) CGRect subtitleRect;

- (void)setCompareBuffer:(CVPixelBufferRef)buffer;

- (void)setCompareSplitEnabled:(BOOL)enabled;

// Picture controls.
- (void)setAspectMode:(int)mode;   // 0: original, 4: crop; other values are retired.
- (void)setForcedAspect:(float)ratio; // Positive values force display aspect; zero restores the default.
- (void)setCropAspect:(float)ratio;   // Positive values apply centered aspect cropping; zero disables it.
- (void)setRotation:(int)deg;      // 0/90/180/270
// Clockwise rotation from the stream's display matrix, composed with the user
// rotation above. Media-scoped: it is cleared with the picture transform.
- (void)setSourceRotation:(int)deg;
- (void)setMirror:(int)m;          // 0: none, 1: horizontal, 2: vertical.
- (void)resetPictureTransform;     // Restore picture geometry defaults when opening new media.
- (void)setBrightness:(float)v;    // -0.5~0.5
- (void)setContrast:(float)v;      // 0.5~2
- (void)setSaturation:(float)v;    // 0~2
- (void)setGamma:(float)v;         // 0.5~2

// Main-thread depth-effect setters, sampled during encoding. Zero blur and
// color strengths write directly to the drawable; otherwise use an intermediate
// image, blur pyramid and composition. Anchor is in top-left drawable pixels.
// Allocate resources on demand and release them when idle.
- (void)setDragEffectStrength:(float)strength colorStrength:(float)colorStrength anchorPx:(CGPoint)anchor;
// Prewarm depth-effect pipelines on a background queue at interaction start.
// Reuse the process cache without holding the configuration mutex.
- (void)prewarmDragEffectPipelines;

@property (nonatomic, readonly) BOOL isReady;

@end
