/* ===================================================================
 *  YTXClean v6 —— 悦通行广告净化插件（诊断版）
 *
 *  【重要】根据 ytx_clean.log 的实证重写。v3 的问题是"扫得太宽"：
 *    - Sigmob 前缀命中了它内嵌的 SDWebImage（SigmobSDImageCoder 等纯图片类）
 *    - "AdManager" 兜底命中了 ABU 的基础设施（Tracker/Persistence/Cache/Device）
 *    - 返回 id 的方法统一换成空 UIView，App 当 ATBannerView 用 → unrecognized selector 崩
 *
 *  v6 的修正：
 *    ① 只处理 void / BOOL 返回，绝不替换 id 返回（消除类型不匹配崩溃）
 *    ② 类前缀收窄为日志里真实出现的广告族，并加显式排除表
 *    ③ 方法动词收窄，且不再匹配 delegate 回调（xxxDidFinishLoad 之类）
 *    ④ 加 YTX_LEVEL 分级开关，二分定位
 *
 *  日志：Documents/ytx_clean.log，Filza 搜索
 * =================================================================== */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - ============ 【调试开关】改这个数字重新编译 ============

//   0 = 空壳，只写日志，零 hook      → 测"注入本身是否导致闪退"
//   1 = 只拦摇一摇传感器              → 测传感器 hook
//   2 = + 只拦开屏广告                → 测开屏 hook
//   3 = + 内置广告（native/banner）   → 风险最高，最后开
#define YTX_LEVEL 2

// 传感器屏蔽窗口（秒）。摇一摇只在开屏阶段出现，超时自动放行。
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

    // 启动前 3 秒只走 NSLog：插件注入在 Agora 库里，加载极早，
    // 此时碰 NSFileHandle 有崩溃风险
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

#pragma mark - ① 类筛选：只认日志里实证出现的广告族

// 允许的类前缀（来自 ytx_clean.log 实测）
static NSString * const AD_PREFIX[] = {
    @"YT",          // 悦通行自有广告封装（YTNativeExpressAdManager）
    @"Wind",        // WindMill / Sigmob 系（WindSplashAdManager / WindMillSDK.*）
    @"UBiX",        // UBiXSplashAdManager
    @"PTG",         // PTGNativeExpressAdManager
    @"GM",          // GMNativeExpressAdManager（GroMore）
    @"MS",          // MSDrawAdManager / MSBUNativeExpressAdManagerProxy
    @"LY",          // LYBaseAdManager（LYJT）
    @"SF",          // SFBaseAdManager / SFCacheAdManager
    @"FLink",       // FLinkBaseAdManager
    @"Medpro",      // MedproSEBaseAdManager / MedproAdManager
    @"Oct",         // OctAdvert / OctBackgroundAdvert
    @"ABU",         // GroMore ABU 系
    @"AT",          // AnyThink / TopOn
    @"GDT",         // 优量汇
    @"KSAd",        // 快手
    @"BU", @"CSJ", @"Pangolin",
    nil
};

// 显式排除：这些是 SDK 内嵌的基础设施/图片库，跟广告无关，
// 但前缀恰好命中上面的允许表（Sigmob 内嵌了 SDWebImage）
static NSString * const EXCLUDE_SUBSTR[] = {
    @"SDImage", @"SDWebImage", @"SDAnimated", @"SDDevice", @"SDGraphics",
    @"ImageCoder", @"ImageFrame", @"ImagePlayer", @"ImageAsset",
    @"Persistence", @"PlistStorage", @"KeyChainStorage",
    @"MemoryCache", @"DiskCache", @"ShareCache", @"Cache",
    @"Tracker", @"TrackReport", @"TrackerSched", @"TrackerConfig",
    @"Device", @"Geo", @"Location", @"Network", @"NetworkConfig",
    @"Log", @"LogConfig", @"LogManager",
    @"Request", @"RequestRouter", @"Response",
    @"Config", @"ConfigGroup", @"ConfigAdapter",
    @"WeakProxy", @"WeakWrapper", @"Proxy",
    @"Event", @"Reporter", @"Uploader",
    @"Address", @"Size", @"Image", @"Timer",
    @"StoreKit", @"IPV6", @"MapKey",
    nil
};

static BOOL YTXShouldSkipClass(NSString *cls) {
    for (int i = 0; EXCLUDE_SUBSTR[i]; i++) {
        if ([cls rangeOfString:EXCLUDE_SUBSTR[i]].length > 0) return YES;
    }
    return NO;
}

static BOOL YTXIsAdClass(NSString *cls) {
    if (cls.length == 0) return NO;
    if (YTXShouldSkipClass(cls)) return NO;
    for (int i = 0; AD_PREFIX[i]; i++) {
        if ([cls hasPrefix:AD_PREFIX[i]]) return YES;
    }
    // 兜底仅保留"明确广告语义"的两种后缀，不再用宽松的 AdManager
    BOOL explicit = ([cls rangeOfString:@"SplashAd"].length > 0)
                 || ([cls rangeOfString:@"Advert"].length > 0)
                 || ([cls rangeOfString:@"RewardedVideo"].length > 0)
                 || ([cls rangeOfString:@"Interstitial"].length > 0)
                 || ([cls rangeOfString:@"NativeExpress"].length > 0);
    return explicit;
}

#pragma mark - ② 方法筛选：动词收窄 + 排除回调

// 只有这些动词会被拦截
static NSString * const VERBS_SPLASH[] = { @"showsplash", @"splash", nil };
static NSString * const VERBS_INNER[]  = { @"loadad", @"loadaddata", @"showad",
                                           @"shownative", @"showbanner",
                                           @"showinterstitial", @"showreward",
                                           @"readyforplacementid", @"adready", nil };

// 命中即跳过：delegate 回调、生命周期、配置类
static NSString * const SEL_SKIP[] = {
    @"didfinish", @"didfail", @"didload", @"didclick", @"didclose", @"diddismiss",
    @"didexpose", @"didvisible", @"willappear", @"didappear", @"viewdid",
    @"callback", @"delegate", @"observer", @"notification",
    @"setup", @"config", @"register", @"init", @"prepare",
    nil
};

static BOOL YTXShouldSkipSelector(NSString *lower) {
    for (int i = 0; SEL_SKIP[i]; i++) {
        if ([lower rangeOfString:SEL_SKIP[i]].length > 0) return YES;
    }
    return NO;
}

// 短动词必须整词匹配，避免 load→download、ad→address
static NSString * const STRICT[] = { @"load", @"splash", @"banner", @"native", @"reward", nil };

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
            NSUInteger loc = r.location;
            NSUInteger end = loc + r.length;
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

#pragma mark - ③ 置空：只处理 void / BOOL，绝不碰 id

static NSMutableSet *gDone;

static void YTXNeuterClass(Class cls, NSString *cname, int level) {
    Class targets[2] = { cls, object_getClass(cls) };   // 实例方法 + 类方法

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

            if (YTXShouldSkipSelector(lower)) continue;

            BOOL hit = YTXVerbHit(lower, VERBS_SPLASH);
            if (!hit && level >= 3) hit = YTXVerbHit(lower, VERBS_INNER);
            if (!hit) continue;

            // 只处理 void / BOOL。id 返回一律跳过 —— v3 在这里栽了跟头
            char ret[256];
            memset(ret, 0, sizeof(ret));
            method_getReturnType(m, ret, sizeof(ret));
            char r = ret[0];
            if (r != 'v' && r != 'B') continue;

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
    if (level < 2) return;   // level 0/1 完全不扫类

    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *list = (Class *)malloc(sizeof(Class) * (unsigned)n);
    n = objc_getClassList(list, n);

    int found = 0;
    for (int i = 0; i < n; i++) {
        Class c = list[i];
        if (!c) continue;
        NSString *name = NSStringFromClass(c);
        if (!YTXIsAdClass(name)) continue;
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

#pragma mark - ④ 传感器层：掐掉摇一摇

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

#pragma mark - 入口

__attribute__((constructor))
static void YTXEntry(void) {
    gStart = CFAbsoluteTimeGetCurrent();
    YTXLog([NSString stringWithFormat:@"========== YTXClean v6 loaded, LEVEL=%d ==========", YTX_LEVEL]);

#if YTX_LEVEL == 0
    YTXLog(@"LEVEL 0: 空壳，零 hook。若仍闪退说明问题在注入位置，不在代码。");
    return;
#endif

    dispatch_async(dispatch_get_main_queue(), ^{
        YTXHookSensors();          // LEVEL >= 1
        YTXScan(YTX_LEVEL);        // LEVEL >= 2 才生效
    });

    // 广告 SDK 懒加载，分多轮补扫
    NSTimeInterval delays[] = {1.0, 3.0, 8.0};
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTXScan(YTX_LEVEL);
        });
    }
}
