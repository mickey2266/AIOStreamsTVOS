#import "AIOWebView.h"

#import <dlfcn.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <sys/resource.h>

/** In libSystem, but its header (libproc.h) isn't in the tvOS SDK. Weak, so a missing one is NULL. */
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer) __attribute__((weak_import));

/*
 * Follows the WKWebView wrapper of the working aiostreams-tvos project: WebKit
 * loaded with dlopen, the page focused through its content view, and the
 * whole screen given to the page to lay out in. Added here: a URL scheme that
 * serves the bundled web app, and a policy for links that leave it.
 */

static NSString *const kHandlerName = @"aiostreamsNative";

static void AIOLoadWebKit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSClassFromString(@"WKWebView") != Nil) return;
        NSArray<NSString *> *paths = @[
            @"/System/Library/Frameworks/WebKit.framework/WebKit",
            @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
        ];
        for (NSString *path in paths) {
            if (dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(@"WKWebView") != Nil) break;
        }
    });
}

static id AIOSend0(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static void AIOSendVoid(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(target, sel);
}

static void AIOSendObject(id target, NSString *selectorName, id value) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, value);
}

static void AIOSendBool(id target, NSString *selectorName, BOOL value) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, value);
}

static NSString *AIOMimeType(NSString *extension) {
    static NSDictionary<NSString *, NSString *> *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = @{
            @"html": @"text/html; charset=utf-8", @"js": @"text/javascript; charset=utf-8",
            @"mjs": @"text/javascript; charset=utf-8", @"css": @"text/css; charset=utf-8",
            @"json": @"application/json", @"map": @"application/json", @"svg": @"image/svg+xml",
            @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"webp": @"image/webp",
            @"avif": @"image/avif", @"gif": @"image/gif", @"ico": @"image/x-icon", @"woff": @"font/woff",
            @"woff2": @"font/woff2", @"ttf": @"font/ttf", @"wasm": @"application/wasm",
            @"txt": @"text/plain; charset=utf-8", @"webmanifest": @"application/manifest+json",
        };
    });
    return types[extension.lowercaseString] ?: @"application/octet-stream";
}

#pragma mark - Delegate

/**
 * Takes WebKit's delegate calls and serves the app's scheme. The user content
 * controller keeps it strongly, so it holds the view weakly.
 */
@interface AIOWebKitDelegate : NSObject
@property (nonatomic, weak) AIOWebView *owner;
@property (nonatomic, copy) NSString *scheme;
@property (nonatomic, strong) NSURL *root;
/** Tasks WebKit hasn't stopped, which may still be answered. Main thread only. */
@property (nonatomic, strong) NSHashTable *liveTasks;
/** Reads the bundled files, so a chunk or font loading mid-scroll doesn't hold up the main thread. */
@property (nonatomic, strong) dispatch_queue_t fileQueue;
@end

@interface AIOWebView ()
@property (nonatomic, strong, nullable) id webView;
@property (nonatomic, strong, nullable) id contentController;
@property (nonatomic, strong) AIOWebKitDelegate *delegate;
@property (nonatomic, strong, nullable) NSURL *lastURL;
- (void)receiveBody:(id)body;
- (void)navigationFinished;
- (void)navigationFailed:(NSError *)error;
- (void)contentProcessEnded:(AIOPageEnd)reason;
- (void)responsive:(BOOL)responsive;
- (void)openURL:(NSURL *)url;
- (void)served:(NSString *)path status:(NSInteger)status bytes:(NSUInteger)bytes;
@end

@implementation AIOWebKitDelegate

+ (void)initialize {
    if (self != [AIOWebKitDelegate class]) return;
    AIOLoadWebKit();
    // WebKit checks some delegates for these at runtime.
    for (NSString *name in @[@"WKScriptMessageHandler", @"WKNavigationDelegate", @"WKUIDelegate", @"WKURLSchemeHandler"]) {
        Protocol *protocol = objc_getProtocol(name.UTF8String);
        if (protocol) class_addProtocol(self, protocol);
    }
}

- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    [self.owner receiveBody:AIOSend0(message, @"body")];
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.owner navigationFinished];
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    [self.owner navigationFailed:error];
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    [self.owner navigationFailed:error];
}

/** WebKit calls this one, with the reason, in place of the public one below when the delegate has it. */
- (void)_webView:(id)webView webContentProcessDidTerminateWithReason:(NSInteger)reason {
    AIOPageEnd known = reason >= AIOPageEndMemory && reason <= AIOPageEndGPUCrashes ? (AIOPageEnd)reason : AIOPageEndUnknown;
    [self.owner contentProcessEnded:known];
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    [self.owner contentProcessEnded:AIOPageEndUnknown];
}

/** WebKit's private calls when the page's process stops answering it, and when it answers again. */
- (void)_webViewWebProcessDidBecomeUnresponsive:(id)webView {
    [self.owner responsive:NO];
}

- (void)_webViewWebProcessDidBecomeResponsive:(id)webView {
    [self.owner responsive:YES];
}

/** The app's pages and what they embed load; a link anywhere else goes to the system. */
- (void)webView:(id)webView
    decidePolicyForNavigationAction:(id)action
                    decisionHandler:(void (^)(NSInteger))decisionHandler {
    NSURLRequest *request = AIOSend0(action, @"request");
    NSURL *url = request.URL;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    id frame = AIOSend0(action, @"targetFrame");
    BOOL mainFrame = frame && ((BOOL (*)(id, SEL))objc_msgSend)(frame, NSSelectorFromString(@"isMainFrame"));
    BOOL ours = [scheme isEqualToString:self.scheme] ||
                [@[@"about", @"data", @"blob"] containsObject:scheme];
    // Frames such as trailers load; the page itself never leaves, as a TV has no browser.
    BOOL embedded = !mainFrame && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
    if (ours || embedded) {
        decisionHandler(1);  // WKNavigationActionPolicyAllow
        return;
    }
    decisionHandler(0);  // WKNavigationActionPolicyCancel
    if (url) [self.owner openURL:url];
}

- (void)webView:(id)webView startURLSchemeTask:(id)task {
    NSURLRequest *request = AIOSend0(task, @"request");
    NSURL *url = request.URL;
    NSString *path = url.path.length > 1 ? url.path : @"/index.html";
    if ([path hasPrefix:@"/thumbnail/"]) {
        // Seek-bar thumbnails the player made, which the page was sent the paths of. In memory already.
        AIOWebView *owner = self.owner;
        NSData *data = owner.thumbnailAtPath ? owner.thumbnailAtPath(path) : nil;
        [self answer:task url:url path:path data:data];
        return;
    }
    if (!self.liveTasks) self.liveTasks = [NSHashTable weakObjectsHashTable];
    if ([path hasPrefix:@"/fit/"]) {
        // A picture the page asked the app to draw down (patches/web/0042, ImageFit.swift).
        AIOWebView *owner = self.owner;
        NSInteger width = path.lastPathComponent.integerValue;
        NSString *address = nil;
        for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
            if ([item.name isEqualToString:@"u"]) address = item.value;
        }
        NSURL *source = address ? [NSURL URLWithString:address] : nil;
        if (!owner.fitImage || !source || width <= 0) {
            [self answer:task url:url path:path data:nil type:nil];
            return;
        }
        [self.liveTasks addObject:task];
        __weak AIOWebKitDelegate *weakSelf = self;
        owner.fitImage(source, width, ^(NSData *data, NSString *type) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AIOWebKitDelegate *strongSelf = weakSelf;
                // WebKit throws if a task it stopped is answered.
                if (!strongSelf || ![strongSelf.liveTasks containsObject:task]) return;
                [strongSelf.liveTasks removeObject:task];
                [strongSelf answer:task url:url path:path data:data type:type];
            });
        });
        return;
    }
    if (!self.fileQueue) {
        self.fileQueue = dispatch_queue_create("io.github.aiostreams.web-files", DISPATCH_QUEUE_CONCURRENT);
    }
    [self.liveTasks addObject:task];
    NSString *rootPath = self.root.URLByStandardizingPath.path;
    NSURL *file = [self.root URLByAppendingPathComponent:[path substringFromIndex:1]].URLByStandardizingPath;
    if ([path hasPrefix:@"/app-fonts/"]) {
        // The app's own subtitle fonts (App/Fonts), for the page's @font-face (BridgeScript): tvOS has
        // no casual or script face for its Casual and Cursive. Only a .ttf the app carries, by name.
        NSString *name = path.lastPathComponent;
        NSURL *font = [name.pathExtension.lowercaseString isEqualToString:@"ttf"]
            ? [NSBundle.mainBundle URLForResource:name.stringByDeletingPathExtension withExtension:@"ttf"]
            : nil;
        file = font.URLByStandardizingPath;
        rootPath = file.URLByDeletingLastPathComponent.path;
    }
    __weak AIOWebKitDelegate *weakSelf = self;
    dispatch_async(self.fileQueue, ^{
        // Nothing outside the bundled build.
        NSData *data = [file.path hasPrefix:[rootPath stringByAppendingString:@"/"]]
            ? [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil]
            : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            AIOWebKitDelegate *strongSelf = weakSelf;
            // WebKit throws if a task it stopped is answered.
            if (!strongSelf || ![strongSelf.liveTasks containsObject:task]) return;
            [strongSelf.liveTasks removeObject:task];
            [strongSelf answer:task url:url path:path data:data];
        });
    });
}

/** Main thread. A file under `/static/` has its content hash in its name, so it never changes. */
- (void)answer:(id)task url:(NSURL *)url path:(NSString *)path data:(nullable NSData *)data {
    [self answer:task url:url path:path data:data type:nil];
}

/** As above, with the type given rather than taken from the path's extension. */
- (void)answer:(id)task url:(NSURL *)url path:(NSString *)path data:(nullable NSData *)data type:(nullable NSString *)type {
    NSInteger status = data ? 200 : 404;
    data = data ?: [NSData data];
    BOOL hashed = status == 200 && [path hasPrefix:@"/static/"];
    // A fitted picture's address names its source, which doesn't change under it.
    BOOL fitted = status == 200 && [path hasPrefix:@"/fit/"];
    NSDictionary *headers = @{
        @"Content-Type": data.length ? (type ?: AIOMimeType(path.pathExtension)) : @"text/plain",
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
        @"Cache-Control": hashed ? @"public, max-age=31536000, immutable"
                                 : fitted ? @"public, max-age=86400" : @"no-cache",
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                              statusCode:status
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    AIOSendObject(task, @"didReceiveResponse:", response);
    AIOSendObject(task, @"didReceiveData:", data);
    AIOSendVoid(task, @"didFinish");
    [self.owner served:path status:status bytes:data.length];
}

- (void)webView:(id)webView stopURLSchemeTask:(id)task {
    // A file still being read is dropped when it arrives.
    [self.liveTasks removeObject:task];
}

@end

#pragma mark - View

@implementation AIOWebView

- (instancetype)initWithFrame:(CGRect)frame scheme:(NSString *)scheme root:(NSURL *)root {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    _delegate = [AIOWebKitDelegate new];
    _delegate.owner = self;
    _delegate.scheme = scheme.lowercaseString;
    _delegate.root = root;
    [self build];
    return self;
}

- (BOOL)available {
    return self.webView != nil;
}

- (void)build {
    AIOLoadWebKit();
    Class configurationClass = NSClassFromString(@"WKWebViewConfiguration");
    Class webViewClass = NSClassFromString(@"WKWebView");
    Class controllerClass = NSClassFromString(@"WKUserContentController");
    if (!configurationClass || !webViewClass || !controllerClass) return;

    id configuration = [configurationClass new];
    id controller = [controllerClass new];
    SEL addHandler = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if ([controller respondsToSelector:addHandler]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addHandler, self.delegate, kHandlerName);
    }
    AIOSendObject(configuration, @"setUserContentController:", controller);
    self.contentController = controller;

    SEL setScheme = NSSelectorFromString(@"setURLSchemeHandler:forURLScheme:");
    if ([configuration respondsToSelector:setScheme]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(configuration, setScheme, self.delegate, self.delegate.scheme);
    }
    AIOSendBool(configuration, @"setAllowsInlineMediaPlayback:", YES);
    AIOSendBool(configuration, @"setMediaPlaybackRequiresUserAction:", NO);
    SEL mediaTypes = NSSelectorFromString(@"setMediaTypesRequiringUserActionForPlayback:");
    if ([configuration respondsToSelector:mediaTypes]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(configuration, mediaTypes, 0);
    }

    id webView = ((id (*)(id, SEL))objc_msgSend)(webViewClass, @selector(alloc));
    SEL init = NSSelectorFromString(@"initWithFrame:configuration:");
    webView = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webView, init, self.bounds, configuration);
    if (!webView) return;

    UIView *view = (UIView *)webView;
    view.frame = self.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // The player is drawn beneath, so the page must be see-through.
    view.opaque = NO;
    view.backgroundColor = UIColor.clearColor;
    UIScrollView *scrollView = AIOSend0(webView, @"scrollView");
    scrollView.backgroundColor = UIColor.clearColor;
    scrollView.opaque = NO;
    // The page lays itself out to the screen and scrolls itself.
    scrollView.scrollEnabled = NO;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    AIOSendObject(webView, @"setUnderPageBackgroundColor:", UIColor.clearColor);
    AIOSendObject(webView, @"setNavigationDelegate:", self.delegate);
    AIOSendObject(webView, @"setUIDelegate:", self.delegate);
    // Lets Safari on a Mac inspect the page, for debugging.
    AIOSendBool(webView, @"setInspectable:", YES);
    AIOSendObject(webView, @"setApplicationNameForUserAgent:", @"AIOStreamsTV");

    [self addSubview:view];
    self.webView = webView;
}

- (void)setStartScript:(NSString *)script {
    id controller = self.contentController;
    Class scriptClass = NSClassFromString(@"WKUserScript");
    if (!controller || !scriptClass) return;
    AIOSendVoid(controller, @"removeAllUserScripts");
    // At document start, in the main frame only, before the page's own scripts.
    SEL scriptInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (![scriptClass instancesRespondToSelector:scriptInit]) return;
    id userScript = ((id (*)(id, SEL))objc_msgSend)(scriptClass, @selector(alloc));
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, scriptInit, script, 0, YES);
    AIOSendObject(controller, @"addUserScript:", userScript);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    ((UIView *)self.webView).frame = self.bounds;
    [self fillScreen];
}

/**
 * WebKit fits the page to the screen less tvOS's safe area (the margin kept
 * for TVs that overscan) but draws it from the left edge, leaving a strip on
 * the right. The page keeps its own margins, so the web view gets the whole
 * screen to lay out in.
 */
- (void)fillScreen {
    id webView = self.webView;
    if (!webView) return;
    CGSize size = self.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    SEL unobscured = NSSelectorFromString(@"_setUnobscuredSafeAreaInsets:");
    if ([webView respondsToSelector:unobscured]) {
        ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(webView, unobscured, UIEdgeInsetsZero);
    }
    SEL obscured = NSSelectorFromString(@"_setObscuredInsets:");
    if ([webView respondsToSelector:obscured]) {
        ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(webView, obscured, UIEdgeInsetsZero);
    }
    SEL layout = NSSelectorFromString(@"_overrideLayoutParametersWithMinimumLayoutSize:maximumUnobscuredSizeOverride:");
    if ([webView respondsToSelector:layout]) {
        ((void (*)(id, SEL, CGSize, CGSize))objc_msgSend)(webView, layout, size, size);
    }
}

- (void)setUserAgent:(NSString *)userAgent {
    _userAgent = [userAgent copy];
    AIOSendObject(self.webView, @"setCustomUserAgent:", _userAgent);
}

- (void)loadURL:(NSURL *)url {
    self.lastURL = url;
    AIOSendObject(self.webView, @"loadRequest:", [NSURLRequest requestWithURL:url]);
}

- (void)evaluateJavaScript:(NSString *)script {
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (!self.webView || ![self.webView respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.webView, sel, script, nil);
}

- (void)evaluateJavaScript:(NSString *)script done:(void (^)(void))done {
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (!self.webView || ![self.webView respondsToSelector:sel]) {
        done();
        return;
    }
    // WebKit calls it on the main thread, with the result or an error; only that it ran matters.
    void (^finished)(id, NSError *) = ^(id result, NSError *error) {
        done();
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.webView, sel, script, finished);
}

- (void)focusPage {
    UIView *view = (UIView *)self.webView;
    if (!view) return;
    // WebKit counts the page focused while its content view is first responder.
    UIView *content = [self contentViewIn:view];
    if (![content becomeFirstResponder]) [view becomeFirstResponder];
}

- (nullable UIView *)contentViewIn:(UIView *)view {
    if ([NSStringFromClass(view.class) hasPrefix:@"WKContentView"]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = [self contentViewIn:subview];
        if (found) return found;
    }
    return nil;
}

- (void)removeAllWebData:(void (^)(void))done {
    Class storeClass = NSClassFromString(@"WKWebsiteDataStore");
    id store = AIOSend0(storeClass, @"defaultDataStore");
    id types = AIOSend0(storeClass, @"allWebsiteDataTypes");
    SEL remove = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
    if (!store || !types || ![store respondsToSelector:remove]) {
        done();
        return;
    }
    void (^finished)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), done);
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, remove, types, NSDate.distantPast, finished);
}

#pragma mark Delegate calls

- (void)receiveBody:(id)body {
    if (![body isKindOfClass:NSString.class] || !self.onMessage) return;
    NSData *data = [(NSString *)body dataUsingEncoding:NSUTF8StringEncoding];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([json isKindOfClass:NSDictionary.class]) self.onMessage(json);
}

- (void)navigationFinished {
    if (self.onLoadFinished) self.onLoadFinished();
}

- (void)navigationFailed:(NSError *)error {
    // A navigation the page replaced with another is not a failure.
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    // Nor is a link the app handed to the system ("frame load interrupted").
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) return;
    if (self.onLoadFailed) self.onLoadFailed(error.localizedDescription ?: @"The page could not load.");
}

- (void)contentProcessEnded:(AIOPageEnd)reason {
    // Where the page was, rather than its start.
    NSURL *current = AIOSend0(self.webView, @"URL");
    NSURL *url = current ?: self.lastURL;
    // The owner loads it, so the start script it sets carries the storage as it is now.
    if (self.onProcessEnded) {
        self.onProcessEnded(url, reason);
        return;
    }
    if (url) AIOSendObject(self.webView, @"loadRequest:", [NSURLRequest requestWithURL:url]);
}

/** A pid WebKit gives for one of its processes, or 0 where it doesn't. */
static pid_t AIOPid(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return 0;
    return ((pid_t (*)(id, SEL))objc_msgSend)(target, sel);
}

/**
 * Another process's footprint, as tvOS counts it against that process's
 * limit, in bytes; 0 with `why` set where the system won't say (the app's
 * sandbox may refuse another process).
 */
static uint64_t AIOFootprintOfPid(pid_t pid, NSString **why) {
    if (pid <= 0) {
        *why = @"WebKit gave no pid";
        return 0;
    }
    if (proc_pid_rusage == NULL) {
        *why = @"no proc_pid_rusage";
        return 0;
    }
    struct rusage_info_v0 usage;
    memset(&usage, 0, sizeof(usage));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&usage) != 0) {
        *why = [NSString stringWithFormat:@"proc_pid_rusage(%d) failed: %s", pid, strerror(errno)];
        return 0;
    }
    if (usage.ri_phys_footprint == 0) *why = [NSString stringWithFormat:@"proc_pid_rusage(%d) gave 0", pid];
    return usage.ri_phys_footprint;
}

/** WebKit's process list, asked of the class and then of the view's own pool. */
- (nullable NSArray *)webContentProcessInfos:(NSString **)why {
    Class poolClass = NSClassFromString(@"WKProcessPool");
    id pool = AIOSend0(AIOSend0(self.webView, @"configuration"), @"processPool");
    for (id target in @[poolClass ?: NSNull.null, pool ?: NSNull.null]) {
        if (target == NSNull.null) continue;
        id infos = AIOSend0(target, @"_webContentProcessInfo") ?: AIOSend0(target, @"_webContentProcessInfoForTesting");
        if ([infos isKindOfClass:NSArray.class] && [(NSArray *)infos count] > 0) return infos;
        if (infos) {
            *why = [infos isKindOfClass:NSArray.class] ? @"WebKit's process list is empty"
                                                        : @"WebKit's process list isn't a list";
            return nil;
        }
    }
    *why = poolClass ? @"WKProcessPool has no _webContentProcessInfo" : @"no WKProcessPool";
    return nil;
}

- (NSInteger)webProcessMB {
    pid_t page = AIOPid(self.webView, @"_webProcessIdentifier");
    NSString *listWhy = nil;
    NSArray *infos = [self webContentProcessInfos:&listWhy];
    if (infos) {
        SEL footprintSel = NSSelectorFromString(@"physicalFootprint");
        SEL pidSel = NSSelectorFromString(@"pid");
        size_t largest = 0;
        BOOL any = NO;
        for (id info in infos) {
            if (![info respondsToSelector:footprintSel]) continue;
            size_t bytes = ((size_t (*)(id, SEL))objc_msgSend)(info, footprintSel);
            pid_t pid = [info respondsToSelector:pidSel] ? ((pid_t (*)(id, SEL))objc_msgSend)(info, pidSel) : 0;
            if (page > 0 && pid == page) {
                _webProcessRoute = @"WebKit's process list";
                return (NSInteger)(bytes >> 20);
            }
            // Without the page's own, the largest: a spare process WebKit keeps warm is small.
            if (bytes > largest) largest = bytes;
            any = YES;
        }
        if (any) {
            _webProcessRoute = @"WebKit's process list, largest process";
            return (NSInteger)(largest >> 20);
        }
        listWhy = @"WebKit's process list has no physicalFootprint";
    }
    NSString *pidWhy = nil;
    uint64_t bytes = AIOFootprintOfPid(page, &pidWhy);
    if (bytes > 0) {
        _webProcessRoute = [NSString stringWithFormat:@"the system, pid %d (%@)", page, listWhy];
        return (NSInteger)(bytes >> 20);
    }
    _webProcessRoute = [NSString stringWithFormat:@"no size: %@; %@", listWhy, pidWhy];
    return -1;
}

- (NSInteger)gpuProcessMB {
    id info = AIOSend0(NSClassFromString(@"WKProcessPool"), @"_gpuProcessInfo");
    SEL footprintSel = NSSelectorFromString(@"physicalFootprint");
    if (info && [info respondsToSelector:footprintSel]) {
        _gpuProcessRoute = @"WebKit's process info";
        size_t bytes = ((size_t (*)(id, SEL))objc_msgSend)(info, footprintSel);
        return (NSInteger)(bytes >> 20);
    }
    NSString *infoWhy = info ? @"_gpuProcessInfo has no physicalFootprint" : @"WKProcessPool has no _gpuProcessInfo";
    pid_t gpu = AIOPid(self.webView, @"_gpuProcessIdentifier");
    NSString *pidWhy = nil;
    uint64_t bytes = AIOFootprintOfPid(gpu, &pidWhy);
    if (bytes > 0) {
        _gpuProcessRoute = [NSString stringWithFormat:@"the system, pid %d (%@)", gpu, infoWhy];
        return (NSInteger)(bytes >> 20);
    }
    _gpuProcessRoute = [NSString stringWithFormat:@"no size: %@; %@", infoWhy, pidWhy];
    return -1;
}

- (void)responsive:(BOOL)responsive {
    if (self.onResponsiveness) self.onResponsiveness(responsive);
}

- (void)openURL:(NSURL *)url {
    if (self.onOpenURL) self.onOpenURL(url);
}

- (void)served:(NSString *)path status:(NSInteger)status bytes:(NSUInteger)bytes {
    if (self.onServed) self.onServed(path, status, bytes);
}

@end
