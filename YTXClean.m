/* ===================================================================
 *  YTXClean v9 —— 悦通行广告净化插件
 *
 *  v9 相比 v6 的三处实质改动：
 *    ① Swift 模块支持：WindMillSDK.* 是 Swift 写的，方法不暴露给 ObjC runtime，
 *       class_copyMethodList 拿不到任何东西 → 方法级 hook 对它完全无效。
 *       改成在【视图层】按类名匹配隐藏，绕开方法层。
 *    ② LEVEL 5 透视模式：纯 dump 整个 view 树，零拦截，让真实类名自己报出来。
 *    ③ 版本号与 LEVEL 写进启动日志，一眼可验。
 *
 *  日志：Documents/ytx_clean.log，Filza 搜索
 * =================================================================== */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - ============ 【唯一需要改的地方】 ============

//   0 = 空壳，零 hook
//   1 = 只拦摇一摇传感器
//   2 = + 只拦开屏
//   3 = + 方法级内置广告（仅 void/BOOL，安全）
//   4 = + 视图级隐藏（含 Swift 模块，治滚动/小窗广告）
//   5 = 透视模式：只 dump view 树，零拦截（不闪退，用来找真凶）
#define YTX_LEVEL 5

static const NSTimeInterval kSensorBlockSeconds = 15.0;
#define YTX_DEBUG 1

#pragma mark - 日志

static NSString *YTXLogPath(void) {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [doc stringByAppendingPathComponent:@"ytx_clean.log"];
}

static CFAbsoluteTime gStart = 0;

static void YTXLog(NSString *line) {
#if YTX_DEBUG
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSLog(@"[YTXClean] %@", line);

    // 启动前 3 秒只走 NSLog：插件注入在 Agora 库，加载极早，碰文件有崩溃风险
    if (gStart > 0 && (CFAbsoluteTimeGetCurrent() - gStart) < 3.0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:YTXLogPath()]) {
        [@"" writeToFile:YTXLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:YTXLogPath()];
    [fh seekToEndOfFile];
    [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
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

#pragma mark - 广告类判定（视图层用，含 Swift 模块）

static NSString * const AD_PREFIX[] = {
    // Swift 聚合层（日志实测，方法打不到，只能打视图）
    @"WindMillSDK", @"WindMill",
    // ObjC 广告族
    @"YT", @"UBiX", @"PTG", @"GM", @"MS", @"LY", @"SF", @"FLink",
    @"Medpro", @"Oct", @"ABU", @"AT", @"GDT", @"KSAd",
    @"BU", @"CSJ", @"Pangolin", @"Sigmob", @"Wind",
    nil
};

// 排除：SDK 内嵌的无关基础设施
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

#pragma mark - LEVEL 5：透视 dump（零拦截）

static void YTXDumpTree(UIView *root, int depth, NSMutableString *buf) {
    if (!root || depth > 8) return;
    NSString *cls = NSStringFromClass([root class]);
    NSString *frame = NSStringFromCGRect(root.frame);
    NSString *tag = (root.tag != 0) ? [NSString stringWithFormat:@" tag=%ld", (long)root.tag] : @"";
    NSString *hidden = root.isHidden ? @" [hidden]" : @"";
    NSString *alpha = (root.alpha < 1.0) ? [NSString stringWithFormat:@" alpha=%.2f", root.alpha] : @"";

    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    [buf appendFormat:@"%@%@ | %@%@%@%@\n", pad, cls, frame, tag, hidden, alpha];

    for (UIView *sub in root.subviews) {
        YTXDumpTree(sub, depth + 1, buf);
    }
}

static void YTXDumpAll(NSString *scene) {
    NSMutableArray *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) [wins addObject:w];
        }
    }
    if (wins.count == 0) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w) [wins addObject:w];
    }

    NSMutableString *buf = [NSMutableString string];
    [buf appendFormat:@"\n########## DUMP [%@] windows=%lu ##########\n", scene, (unsigned long)wins.count];
    for (UIWindow *w in wins) {
        NSString *wcls = NSStringFromClass([w class]);
        NSString *rvc = NSStringFromClass([w.rootViewController class]);
        [buf appendFormat:@"== WINDOW %@ root=%@ level=%.1f frame=%@\n",
         wcls, rvc, w.windowLevel, NSStringFromCGRect(w.frame)];
        YTXDumpTree(w, 1, buf);
    }
    [buf appendString:@"########## DUMP END ##########\n"];
    YTXLog(buf);
}

#pragma mark - LEVEL 4：视图级隐藏（只隐藏不移除，防 Auto Layout 崩）

static void YTXHideAds(UIView *root, int depth) {
    if (!root || depth > 8) return;
    for (UIView *v in root.subviews) {
        if (YTXIsAdView(v)) {
            YTXLogOnce([@"hide|" stringByAppendingString:NSStringFromClass([v class])],
                       [NSString stringWithFormat:@"view hide: %@ frame=%@",
                        NSStringFromClass([v class]), NSStringFromCGRect(v.frame)]);
            v.hidden = YES;
            v.alpha = 0.0;
            v.userInteractionEnabled = NO;
            continue;
        }
        YTXHideAds(v, depth + 1);
    }
}

static void YTXHideAll(void) {
    NSMutableArray *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) [wins addObject:w];
        }
    }
    if (wins.count == 0) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w) [wins addObject:w];
    }
    for (UIWindow *w in wins) YTXHideAds(w, 0);
}

#pragma mark - 方法层（LEVEL >= 2，仅 void/BOOL）

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
            NSString *desc = nil;
            if (r == 'v') {
                imp = imp_implementationWithBlock(^void(id _self) {
                    YTXLogOnce(key, [NSString stringWithFormat:@"neuter:[%@ %@] (void)", cname, selName]);
                });
                desc = @"void";
            } else {
                imp = imp_implementationWithBlock(^BOOL(id _self) {
                    YTXLogOnce(key, [NSString stringWithFormat:@"neuter:[%@ %@] -> NO", cname, selName]);
                    return NO;
                });
                desc = @"NO";
            }
            if (imp) {
                method_setImplementation(m, imp);
                YTXLog([NSString stringWithFormat:@"HOOKED [%@ %@] ret=%@", cname, selName, desc]);
            }
        }
        free(ms);
    }
}

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
        YTXLog([NSString stringWithFormat:@"AD class: %@", name]);
        YTXNeuterClass(c, name, level);
        found++;
    }
    free(list);
    if (found) YTXLog([NSString stringWithFormat:@"scan done, new: %d", found]);
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
            if (YTXInSensorWindow()) {
                YTXLogOnce([NSString stringWithFormat:@"s%d", i], @"shake blocked: simple start");
                return;
            }
            if (o) ((void (*)(id, SEL))o)(self, s);
        }));
        YTXLog([NSString stringWithFormat:@"hooked CMMotionManager %@", NSStringFromSelector(s)]);
    }

    Method m1 = class_getInstanceMethod(CMM, @selector(startAccelerometerUpdatesToQueue:withHandler:));
    if (m1) {
        IMP o = method_getImplementation(m1);
        method_setImplementation(m1, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMAccelerometerData *, NSError *)) {
            if (YTXInSensorWindow()) { YTXLogOnce(@"acc2", @"shake blocked: accelerometer+queue"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMAccelerometerData *, NSError *)))o)(self, @selector(startAccelerometerUpdatesToQueue:withHandler:), q, h);
        }));
        YTXLog(@"hooked startAccelerometerUpdatesToQueue:withHandler:");
    }

    Method m2 = class_getInstanceMethod(CMM, @selector(startDeviceMotionUpdatesToQueue:withHandler:));
    if (m2) {
        IMP o = method_getImplementation(m2);
        method_setImplementation(m2, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMDeviceMotion *, NSError *)) {
            if (YTXInSensorWindow()) { YTXLogOnce(@"dm2", @"shake blocked: deviceMotion+queue"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMDeviceMotion *, NSError *)))o)(self, @selector(startDeviceMotionUpdatesToQueue:withHandler:), q, h);
        }));
        YTXLog(@"hooked startDeviceMotionUpdatesToQueue:withHandler:");
    }

    Method m3 = class_getInstanceMethod(CMM, @selector(startGyroUpdatesToQueue:withHandler:));
    if (m3) {
        IMP o = method_getImplementation(m3);
        method_setImplementation(m3, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMGyroData *, NSError *)) {
            if (YTXInSensorWindow()) { YTXLogOnce(@"gy2", @"shake blocked: gyro+queue"); return; }
            if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMGyroData *, NSError *)))o)(self, @selector(startGyroUpdatesToQueue:withHandler:), q, h);
        }));
        YTXLog(@"hooked startGyroUpdatesToQueue:withHandler:");
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
        YTXLog(@"hooked UIResponder motionBegan:withEvent:");
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
        YTXLog(@"hooked UIResponder motionEnded:withEvent:");
    }
}

#pragma mark - 页面出现时触发（LEVEL 4 隐藏 / LEVEL 5 dump）

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
    YTXLog(@"hooked UIViewController viewDidAppear:");
}

#pragma mark - 入口

__attribute__((constructor))
static void YTXEntry(void) {
    gStart = CFAbsoluteTimeGetCurrent();
    YTXLog([NSString stringWithFormat:@"========== YTXClean v9 loaded, LEVEL=%d ==========", YTX_LEVEL]);

#if YTX_LEVEL == 0
    YTXLog(@"LEVEL 0: 空壳，零 hook。若仍闪退说明问题在注入位置。");
    return;
#endif

    dispatch_async(dispatch_get_main_queue(), ^{
        YTXHookSensors();
        YTXScan(YTX_LEVEL);
#if YTX_LEVEL >= 4
        YTXHookViewController();
#endif
    });

    NSTimeInterval delays[] = {1.0, 3.0, 8.0};
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTXScan(YTX_LEVEL);
#if YTX_LEVEL == 5
            if (i == 2) YTXDumpAll(@"t8s");
#elif YTX_LEVEL >= 4
            YTXHideAll();
#endif
        });
    }
}
