#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/** Why the page's web process ended, as WebKit gives it (`_WKProcessTerminationReason`). */
typedef NS_ENUM(NSInteger, AIOPageEnd) {
    /** WebKit didn't say (an older WebKit calling only the public delegate method). */
    AIOPageEndUnknown = -1,
    AIOPageEndMemory = 0,
    AIOPageEndCPU = 1,
    /** Asked for by WebKit's client side, an idle exit or a process swap. */
    AIOPageEndRequested = 2,
    /** A crash, a hang, or the network or graphics process asking for it. */
    AIOPageEndCrash = 3,
    /** WebKit's graphics (GPU) process crashed too many times. */
    AIOPageEndGPUCrashes = 4,
};

/**
 * A WKWebView made at runtime. tvOS ships WebKit but leaves it out of the SDK,
 * so every call goes through the Objective-C runtime. Fine for a sideloaded
 * app; the App Store would refuse it.
 *
 * The page comes from `scheme://localhost/`, served from `root` in the app.
 */
@interface AIOWebView : UIView

/** False when this tvOS has no WebKit to load. */
@property (nonatomic, readonly) BOOL available;
/** A message the page posted to `aiostreamsNative`, parsed from JSON. */
@property (nonatomic, copy, nullable) void (^onMessage)(NSDictionary<NSString *, id> *message);
@property (nonatomic, copy, nullable) void (^onLoadFinished)(void);
@property (nonatomic, copy, nullable) void (^onLoadFailed)(NSString *error);
/**
 * The page's process ended, for `reason`. The handler loads the page again, at
 * `url`, where it was; without one, the view loads it itself.
 */
@property (nonatomic, copy, nullable) void (^onProcessEnded)(NSURL *_Nullable url, AIOPageEnd reason);
/**
 * The page's process stopped answering WebKit (`responsive` NO), or answers
 * again (YES). WebKit's private calls, so an older WebKit may not make them.
 */
@property (nonatomic, copy, nullable) void (^onResponsiveness)(BOOL responsive);
/** A link to anywhere but the app's own pages, such as an external player's. */
@property (nonatomic, copy, nullable) void (^onOpenURL)(NSURL *url);
/** A file the app served, or failed to. */
@property (nonatomic, copy, nullable) void (^onServed)(NSString *path, NSInteger status, NSUInteger bytes);
/** The JPEG the app serves at a `/thumbnail/` path, or nil; called on the main thread. */
@property (nonatomic, copy, nullable) NSData *_Nullable (^thumbnailAtPath)(NSString *path);
/** In place of WebKit's own user agent. */
@property (nonatomic, copy, nullable) NSString *userAgent;

- (instancetype)initWithFrame:(CGRect)frame scheme:(NSString *)scheme root:(NSURL *)root NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/** Replaces the script run at document start, in the main frame, before the page's own. */
- (void)setStartScript:(NSString *)script;
- (void)loadURL:(NSURL *)url;
- (void)evaluateJavaScript:(NSString *)script;
/** As `evaluateJavaScript:`, with `done` called on the main thread once the page has run it. */
- (void)evaluateJavaScript:(NSString *)script done:(void (^)(void))done;
/** Makes the page focused and active, which `:focus` and `:focus-visible` need. */
- (void)focusPage;
/** Forgets everything WebKit saved for pages: storage, IndexedDB, caches. */
- (void)removeAllWebData:(void (^)(void))done;
/**
 * The page's web process's memory as tvOS counts it against its limit, in MB,
 * or -1 where WebKit doesn't say. WebKit's own process, so the app can't
 * measure it itself; asked of WebKit's private process list.
 */
@property (nonatomic, readonly) NSInteger webProcessMB;
/**
 * WebKit's graphics process's memory in MB, or -1 where WebKit doesn't say.
 * It draws the page and holds its decoded pictures and layers, which the web
 * process's figure leaves out.
 */
@property (nonatomic, readonly) NSInteger gpuProcessMB;
/**
 * How the last `webProcessMB` got its figure, or why it got none (which
 * private WebKit call is missing, or what the system said), for diagnostics.
 */
@property (nonatomic, readonly, copy, nullable) NSString *webProcessRoute;
/** As `webProcessRoute`, for the last `gpuProcessMB`. */
@property (nonatomic, readonly, copy, nullable) NSString *gpuProcessRoute;

@end

NS_ASSUME_NONNULL_END
