/* ===================================================================
 *  YTXClean v10 —— 悦通行广告净化插件（性能优化版）
 *
 *  上一版问题：拦截生效了，但启动变慢近 10 秒。
 *  性能瓶颈有三个：
 *    ① 日志同步写文件：每条日志都 open+seek+write+close，
 *       一轮扫描几百条 = 几百次磁盘 I/O，全在主线程
 *    ② 扫描轮次太多：0/1/3/8 秒共 4 轮，每轮遍历全部类
 *    ③ 扫描跑在主队列：阻塞 UI 渲染
 *
 *  v10 的修正：
 *    ① 日志改【异步批量写】：主线程只往内存数组 append，
 *       后台队列攒够一批或定时才落盘
 *    ② 轮次减到 2 轮（启动 + 3 秒），去掉 1 秒和 8 秒
 *    ③ 扫描挪到后台队列，只把 UI 操作留主线程
 *    ④ YTX_DEBUG 设 0 可完全关日志，零 I/O 开销
 *
 *  日志：Documents/ytx_clean.log
 * =================================================================== */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - ============ 【可调开关】 ============

//   0 = 空壳，零 hook
//   1 = 只拦摇一摇传感器
//   2 = + 只拦开屏
//   3 = + 方法级内置广告（仅 void/BOOL）
//   4 = + 视图级隐藏（治滚动/小窗广告）
//   5 = 透视模式：只 dump view 树，零拦截
#define YTX_LEVEL 4

// 调试日志总开关。验证通过后设 0 —— 日志文件 I/O 是启动变慢的主因之一
#define YTX_DEBUG 0

// 传感器屏蔽窗口（秒）
static const NSTimeInterval kSensorBlockSeconds = 15.0;

#pragma mark - 异步日志（核心优化）

static NSMutableArray *gLogBuf;
static dispatch_queue_t gLogQ;
static NSString *gLogPath;

static NSString *YTXLogPath(void) {
    if (!gLogPath) {
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        gLogPath = [doc stringByAppendingPathComponent:@"ytx_clean.log"];
    }
    return gLogPath;
}

// 批量落盘，跑在后台队列，不阻塞主线程
static void YTXFlush(void) {
    NSArray *batch = nil;
    @synchronized (gLogBuf) {
        if (gLogBuf.count == 0) return;
        batch = [gLogBuf copy];
        [gLogBuf removeAllObjects];
    }
    dispatch_async(gLogQ, ^{
        NSString *text = [[batch componentsJoinedByString:@""] stringByAppendingString:@"\n"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:YTXLogPath()]) {
            [@"" writeToFile:YTXLogPath() atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:YTXLogPath()];
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    });
}

static CFAbsoluteTime gStart = 0;

static void YTXLog(NSString *line) {
#if YTX_DEBUG
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
        gLogBuf = [[NSMutableArray alloc] init];
        gLogQ = dispatch_queue_create("ytx.log", DISPATCH_QUEUE_SERIAL);
    });
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSLog(@"[YTXClean] %@", line);

    // 只做内存 append，磁盘写入交给后台队列
    @synchronized (gLogBuf) {
        [gLogBuf addObject:out];
        if (gLogBuf.count >= 40) {
            NSArray *batch = [gLogBuf copy];
            [gLogBuf removeAllObjects];
            dispatch_async(gLogQ, ^{
                NSString *text = [batch componentsJoinedByString:@""];
                NSFileManager *fm = [NSFileManager defaultManager];
                if (![fm fileExistsAtPath:YTXLogPath()]) {
                    [@"" writeToFile:YTXLogPath() atomically:NO encoding:NSUTF8StringEncoding error:nil];
                }
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:YTXLogPath()];
                if (!fh) return;
                [fh seekToEndOfFile];
                [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            });
        }
    }
#endif
}

static NSMutableSet *gLogged;
static void YTXLogOnce(NSString *key, NSString *line) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLogged = [[NSMutableSet alloc] init]; });
    @synchronized (gLogged) {
        if ([gLogged containsObject:key]) return;
        [gLogged addObject:key];
    }
    YTXLog(line);
}

#pragma mark - 广告类判定

static NSString * const AD_PREFIX[] = {
    @"WindMillSDK", @"WindMill",
    @"YT", @"UBiX", @"PTG", @"GM", @"MS", @"LY", @"SF", @"FLink",
    @"Medpro", @"Oct", @"ABU", @"AT", @"GDT", @"KSAd",
    @"BU", @"CSJ", @"Pangolin", @"Sigmob", @"Wind",
    nil
};

static NSString * const EXCLUDE[] = {
    @"SDImage", @"SDWebImage", @"SDAnimated", @"ImageCoder", @"ImageFrame",
    @"Persistence", @"PlistStorage", @"KeyChainStorage",
    @"MemoryCache", @"DiskCache", @"ShareCache",
    @"Tracker", @"TrackReport", @"TrackerSched", @"TrackerConfig",
    @"Device", @"Geo", @"Location", @"Network", @"NetworkConfig",
    @"Log", @"LogConfig", @"LogManager",
    @"Request", @"RequestRouter", @"Response",
    @"Config", @"ConfigGroup", @"ConfigAdapter",
    @"WeakProxy", @"WeakWrapper",
    @"Event", @"Reporter", @"Uploader",
    @"Address", @"Size", @"Timer", @"StoreKit", @"IPV6",
    nil
};

static BOOL YTXIsAdName(NSString *cls) {
    if (cls.length == 0) return NO;
    for (int i = 0; EXCLUDE[i]; i++) {
        if ([cls rangeOfString:EXCLUDE[i]].length > 0) return NO;
    }
    for (int i = 0; AD_PREFIX[i]; i++) {
        if ([cls hasPrefix:AD_PREFIX[i]]) return YES;
    }
    return NO;
}

static BOOL YTXIsAdView(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if ([cls hasPrefix:@"UI"] || [cls hasPrefix:@"CA"] || [cls hasPrefix:@"NS"]) return NO;
    return YTXIsAdName(cls);
}

#pragma mark - LEVEL 4：视图级隐藏（只隐藏不移除）

static void YTXHideAds(UIView *root, int depth) {
    if (!root || depth > 6) return;
    for (UIView *v in root.subviews) {
        if (YTXIsAdView(v)) {
            YTXLogOnce([@"hide|" stringByAppendingString:NSStringFromClass([v class])],
                       [NSString stringWithFormat:@"view hide: %@", NSStringFromClass([v class])]);
            v.hidden = YES;
            v.alpha = 0.0;
            v.userInteractionEnabled = NO;
            continue;
        }
        YTXHideAds(v, depth + 1);
    }
}

static NSArray *YTXWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) [out addObject:w];
        }
    }
    if (out.count == 0) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w) [out addObject:w];
    }
    return out;
}

static void YTXHideAll(void) {
    for (UIWindow *w in YTXWindows()) YTXHideAds(w, 0);
}

#pragma mark - LEVEL 5：透视 dump

static void YTXDumpTree(UIView *root, int depth, NSMutableString *buf) {
    if (!root || depth > 8) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    [buf appendFormat:@"%@%@ | %@\n", pad, NSStringFromClass([root class]), NSStringFromCGRect(root.frame)];
    for (UIView *sub in root.subviews) YTXDumpTree(sub, depth + 1, buf);
}

static void YTXDumpAll(NSString *scene) {
    NSArray *wins = YTXWindows();
    NSMutableString *buf = [NSMutableString string];
    [buf appendFormat:@"\n########## DUMP [%@] ##########\n", scene];
    for (UIWindow *w in wins) {
        [buf appendFormat:@"== WINDOW %@ root=%@\n",
         NSStringFromClass([w class]), NSStringFromClass([w.rootViewController class])];
        YTXDumpTree(w, 1, buf);
    }
    [buf appendString:@"########## END ##########\n"];
    YTXLog(buf);
}

#pragma mark - 方法层（仅 void/BOOL）

static NSString * const VERBS_SPLASH[] = { @"showsplash", @"splash", nil };
static NSString * const VERBS_INNER[]  = { @"loadad", @"loadaddata", @"showad",
                                           @"shownative", @"showbanner",
                                           @"showinterstitial", @"showreward",
                                           @"readyforplacementid", @"adready", nil };
static NSString * const SEL_SKIP[] = {
    @"didfinish", @"didfail", @"didload", @"didclick", @"didclose", @"diddismiss",
    @"didexpose", @"didvisible", @"willappear", @"didappear", @"viewdid",
    @"callback", @"delegate", @"observer", @"notification",
    @"setup", @"config", @"register", @"init", @"prepare",
    nil
};
static NSString * const STRICT[] = { @"load", @"splash", @"banner", @"native", @"reward", nil };

static BOOL YTXSkipSelector(NSString *lower) {
    for (int i = 0; SEL_SKIP[i]; i++) {
        if ([lower rangeOfString:SEL_SKIP[i]].length > 0) return YES;
    }
    return NO;
}

static BOOL YTXVerbHit(NSString *lower, NSString *const verbs[]) {
    for (int i = 0; verbs[i]; i++) {
        NSString *v = verbs[i];
        NSRange r = [lower rangeOfString:v];
        if (r.length == 0) continue;
        BOOL strict = NO;
        for (int k = 0; STRICT[k]; k++) {
            if ([v isEqualToString:STRICT[k]]) { strict = YES; break; }
        }
        if (strict) {
            NSUInteger loc = r.location, end = loc + r.length;
            BOOL okL = (loc == 0)
                || ![[NSCharacterSet letterCharacterSet] characterIsMember:[lower characterAtIndex:loc - 1]];
            BOOL okR = (end >= lower.length)
                || ![[NSCharacterSet letterCharacterSet] characterIsMember:[lower characterAtIndex:end]];
            if (!(okL && okR)) continue;
        }
        return YES;
    }
    return NO;
}

static NSMutableSet *gDone;

static void YTXNeuterClass(Class cls, NSString *cname, int level) {
    Class targets[2] = { cls, object_getClass(cls) };
    for (int t = 0; t < 2; t++) {
        if (!targets[t]) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(targets[t], &mc);
        if (!ms || mc == 0) { if (ms) free(ms); continue; }

        for (unsigned int i = 0; i < mc; i++) {
            Method m = ms[i];
            if (!m) continue;
            SEL sel = method_getName(m);
            if (!sel) continue;
            NSString *selName = NSStringFromSelector(sel);
            NSString *lower = selName.lowercaseString;
            if (YTXSkipSelector(lower)) continue;

            BOOL hit = YTXVerbHit(lower, VERBS_SPLASH);
            if (!hit && level >= 3) hit = YTXVerbHit(lower, VERBS_INNER);
            if (!hit) continue;

            char ret[256];
            memset(ret, 0, sizeof(ret));
            method_getReturnType(m, ret, sizeof(ret));
            char r = ret[0];
            if (r != 'v' && r != 'B') continue;   // 只处理 void/BOOL，绝不碰 id

            NSString *key = [NSString stringWithFormat:@"%@|%@", cname, selName];
            @synchronized (gDone) {
                if ([gDone containsObject:key]) continue;
                [gDone addObject:key];
            }

            IMP imp = NULL;
            if (r == 'v') {
                imp = imp_implementationWithBlock(^void(id _self) {
                    YTXLogOnce(key, [NSString stringWithFormat:@"neuter:[%@ %@]", cname, selName]);
                });
            } else {
                imp = imp_implementationWithBlock(^BOOL(id _self) {
                    YTXLogOnce(key, [NSString stringWithFormat:@"neuter:[%@ %@] -> NO", cname, selName]);
                    return NO;
                });
            }
            if (imp) method_setImplementation(m, imp);
        }
        free(ms);
    }
}

// 跑在后台队列，不阻塞主线程
static void YTXScan(int level) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gDone = [[NSMutableSet alloc] init]; });
    if (level < 2) return;

    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *list = (Class *)malloc(sizeof(Class) * (unsigned)n);
    n = objc_getClassList(list, n);

    int found = 0;
    for (int i = 0; i < n; i++) {
        Class c = list[i];
        if (!c) continue;
        NSString *name = NSStringFromClass(c);
        if (!YTXIsAdName(name)) continue;
        @synchronized (gDone) {
            NSString *mk = [@"cls|" stringByAppendingString:name];
            if ([gDone containsObject:mk]) continue;
            [gDone addObject:mk];
        }
        YTXNeuterClass(c, name, level);
        found++;
    }
    free(list);
    if (found) YTXLog([NSString stringWithFormat:@"scan: %d new ad classes", found]);
}

#pragma mark - 传感器层

static BOOL YTXInSensorWindow(void) {
    if (gStart == 0) return YES;
    return ((CFAbsoluteTimeGetCurrent() - gStart) < kSensorBlockSeconds);
}

static void YTXHookSensors(void) {
    Class CMM = objc_getClass("CMMotionManager");
    if (!CMM) return;

    SEL sels[3] = { @selector(startAccelerometerUpdates),
                    @selector(startDeviceMotionUpdates),
                    @selector(startGyroUpdates) };
    for (int i = 0; i < 3; i++) {
        Method m = class_getInstanceMethod(CMM, sels[i]);
        if (!m) continue;
        IMP o = method_getImplementation(m);
        SEL s = sels[i];
        method_setImplementation(m, imp_implementationWithBlock(^void(id self) {
            if (YTXInSensorWindow()) { return; }
            if (o) ((void (*)(id, SEL))o)(self, s);
        }));
    }

    Method m1 = class_getInstanceMethod(CMM, @selector(startAccelerometerUpdatesToQueue:withHandler:));
    if (m1) {
        IMP o = method_getImplementation(m1);
        method_setImplementation(m1, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMAccelerometerData *, NSError *)) {
            if (YTXInSensorWindow()) { YTXLogOnce(@"acc2", @"shake blocked: accelerometer"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMAccelerometerData *, NSError *)))o)(self, @selector(startAccelerometerUpdatesToQueue:withHandler:), q, h);
        }));
    }

    Method m2 = class_getInstanceMethod(CMM, @selector(startDeviceMotionUpdatesToQueue:withHandler:));
    if (m2) {
        IMP o = method_getImplementation(m2);
        method_setImplementation(m2, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMDeviceMotion *, NSError *)) {
            if (YTXInSensorWindow()) { YTXLogOnce(@"dm2", @"shake blocked: deviceMotion"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMDeviceMotion *, NSError *)))o)(self, @selector(startDeviceMotionUpdatesToQueue:withHandler:), q, h);
        }));
    }

    Method m3 = class_getInstanceMethod(CMM, @selector(startGyroUpdatesToQueue:withHandler:));
    if (m3) {
        IMP o = method_getImplementation(m3);
        method_setImplementation(m3, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMGyroData *, NSError *)) {
            if (YTXInSensorWindow()) { YTXLogOnce(@"gy2", @"shake blocked: gyro"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMGyroData *, NSError *)))o)(self, @selector(startGyroUpdatesToQueue:withHandler:), q, h);
        }));
    }

    Class R = objc_getClass("UIResponder");
    if (!R) return;
    Method mb = class_getInstanceMethod(R, @selector(motionBegan:withEvent:));
    if (mb) {
        IMP o = method_getImplementation(mb);
        method_setImplementation(mb, imp_implementationWithBlock(^void(id self, UIEventSubtype motion, UIEvent *ev) {
            if (motion == UIEventSubtypeMotionShake && YTXInSensorWindow()) {
                YTXLogOnce(@"mb", @"shake swallowed: motionBegan"); return;
            }
            if (o) ((void (*)(id, SEL, UIEventSubtype, UIEvent *))o)(self, @selector(motionBegan:withEvent:), motion, ev);
        }));
    }
    Method me = class_getInstanceMethod(R, @selector(motionEnded:withEvent:));
    if (me) {
        IMP o = method_getImplementation(me);
        method_setImplementation(me, imp_implementationWithBlock(^void(id self, UIEventSubtype motion, UIEvent *ev) {
            if (motion == UIEventSubtypeMotionShake && YTXInSensorWindow()) {
                YTXLogOnce(@"me", @"shake swallowed: motionEnded"); return;
            }
            if (o) ((void (*)(id, SEL, UIEventSubtype, UIEvent *))o)(self, @selector(motionEnded:withEvent:), motion, ev);
        }));
    }
}

#pragma mark - 页面出现（LEVEL 4 隐藏 / LEVEL 5 dump）

static void YTXHookViewController(void) {
    Class VC = objc_getClass("UIViewController");
    if (!VC) return;
    Method m = class_getInstanceMethod(VC, @selector(viewDidAppear:));
    if (!m) return;
    IMP o = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^void(id self, BOOL animated) {
        if (o) ((void (*)(id, SEL, BOOL))o)(self, @selector(viewDidAppear:), animated);
        NSString *vcName = NSStringFromClass([self class]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
#if YTX_LEVEL == 5
            YTXDumpAll(vcName);
#elif YTX_LEVEL >= 4
            YTXHideAll();
#endif
        });
    }));
}

#pragma mark - 入口

__attribute__((constructor))
static void YTXEntry(void) {
    gStart = CFAbsoluteTimeGetCurrent();
    YTXLog([NSString stringWithFormat:@"========== YTXClean v10 loaded, LEVEL=%d ==========", YTX_LEVEL]);

#if YTX_LEVEL == 0
    YTXLog(@"LEVEL 0: 空壳，零 hook。");
    return;
#endif

    dispatch_async(dispatch_get_main_queue(), ^{
        YTXHookSensors();
#if YTX_LEVEL >= 4
        YTXHookViewController();
#endif
    });

    // 扫描挪到后台队列，不阻塞 UI 渲染
    dispatch_queue_t bg = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    dispatch_async(bg, ^{
        YTXScan(YTX_LEVEL);
    });

    // 轮次从 4 轮减到 2 轮（启动 + 3 秒）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), bg, ^{
        YTXScan(YTX_LEVEL);
#if YTX_LEVEL == 5
        dispatch_async(dispatch_get_main_queue(), ^{ YTXDumpAll(@"t3s"); });
#elif YTX_LEVEL >= 4
        dispatch_async(dispatch_get_main_queue(), ^{ YTXHideAll(); });
#endif
        YTXFlush();   // 扫描结束统一落盘
    });
}
