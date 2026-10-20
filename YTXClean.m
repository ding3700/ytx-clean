/* ===================================================================
 *  YTXClean v3 —— 悦通行广告净化插件（纯 Objective-C，不用 Logos）
 *
 *  为什么不用 .xm：theos 的 Logos 预处理器在某些环境下不运行，
 *  .xm 会被直接当普通文件编译，%config/%hook/%orig 全部报错。
 *  这里改用 runtime API 手写 hook，行为等价且更可控。
 *
 *  报告确认的架构：
 *    AnyThink(TopOn 聚合, AT*) + GroMore(ABU*) + 优量汇(GDT*) + 快手(KSAd*)
 *    + QuMeng / LYJT / Smartdigimkt
 *
 *  【核心策略：调度层截断】
 *    让 ATAdManager 的 loadAD / showSplash / splashReady /
 *    retrieveBannerView / getNativeAdOffer 失效
 *    → 下游各家 SDK 拿不到素材，开屏与内置广告同时断供
 *
 *  日志：Documents/ytx_clean.log，Filza 搜索查看
 * =================================================================== */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - 可调参数

// 启动后多少秒内屏蔽传感器。摇一摇只在开屏阶段出现，超时自动放行，
// 不影响 App 内其它需要陀螺仪的功能。
static const NSTimeInterval kSensorBlockSeconds = 15.0;
#define YTX_DEBUG 1

#pragma mark - 日志

static NSString *YTXLogPath(void) {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [doc stringByAppendingPathComponent:@"ytx_clean.log"];
}

static void YTXLog(NSString *line) {
#if YTX_DEBUG
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:YTXLogPath()]) {
        [@"" writeToFile:YTXLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:YTXLogPath()];
    [fh seekToEndOfFile];
    [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    NSLog(@"[YTXClean] %@", line);
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

#pragma mark - ① 调度层：自动发现并置空广告方法

// 广告 SDK 类前缀（报告实测 + 常见聚合/联盟补充）
static NSString * const SDK_PREFIXES[] = {
    @"AT",            // AnyThink / TopOn 聚合
    @"ABU",           // GroMore（字节聚合）
    @"GDT",           // 优量汇
    @"KSAd", @"KS",   // 快手联盟
    @"QuMeng", @"LYJT", @"Smartdigi", @"Smartdigimkt",
    @"BUAd", @"CSJ", @"Pangolin",
    @"BaiduMob", @"Sigmob", @"WindAd", @"Mercury", @"AdScope", @"TradPlus",
    nil
};

// 广告调度方法特征：命中即置空
static NSString * const AD_VERBS[] = {
    @"loadad", @"load",
    @"showsplash", @"splash",
    @"showbanner", @"banner",
    @"shownative", @"native",
    @"retrievebanner", @"getnativeadoffer", @"getnativead",
    @"readyforplacementid", @"adready", @"isadready",
    @"showad", @"presentad", @"displayad", @"showinterstitial",
    @"showreward", @"reward", @"popupad",
    nil
};

// 短动词必须整词匹配，避免 load→download、ad→address 误伤
static NSString * const STRICT_VERBS[] = { @"load", @"splash", @"banner", @"native", @"reward", nil };

static BOOL YTXIsSDKClass(NSString *cls) {
    if (cls.length == 0) return NO;
    for (int i = 0; SDK_PREFIXES[i]; i++) {
        if ([cls hasPrefix:SDK_PREFIXES[i]]) return YES;
    }
    BOOL hasAd = (([cls rangeOfString:@"Advert"].length > 0)
                  || ([cls rangeOfString:@"AdManager"].length > 0));
    BOOL notSystem = (![cls hasPrefix:@"UI"]) && (![cls hasPrefix:@"NS"]) && (![cls hasPrefix:@"CA"]);
    return (hasAd && notSystem);
}

static BOOL YTXVerbMatch(NSString *lower, NSString **outVerb) {
    for (int i = 0; AD_VERBS[i]; i++) {
        NSString *v = AD_VERBS[i];
        NSRange r = [lower rangeOfString:v];
        if (r.length == 0) continue;

        BOOL strict = NO;
        for (int k = 0; STRICT_VERBS[k]; k++) {
            if ([v isEqualToString:STRICT_VERBS[k]]) { strict = YES; break; }
        }
        if (strict) {
            NSUInteger loc = r.location;
            NSUInteger end = loc + r.length;
            BOOL okLeft = (loc == 0)
                || ![[NSCharacterSet letterCharacterSet] characterIsMember:[lower characterAtIndex:loc - 1]];
            BOOL okRight = (end >= lower.length)
                || ![[NSCharacterSet letterCharacterSet] characterIsMember:[lower characterAtIndex:end]];
            if (!(okLeft && okRight)) { continue; }
        }
        if (outVerb) { *outVerb = v; }
        return YES;
    }
    return NO;
}

static NSMutableSet *gNeutered;

static void YTXNeuterClass(Class cls, NSString *cname) {
    // 类方法 + 实例方法都扫；只处理本类自己实现的，不动父类
    Class targets[2] = { object_getClass(cls), cls };

    for (int t = 0; t < 2; t++) {
        Class target = targets[t];
        if (!target) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(target, &mc);
        if (!ms || mc == 0) { if (ms) free(ms); continue; }

        for (unsigned int i = 0; i < mc; i++) {
            Method m = ms[i];
            if (!m) continue;
            SEL sel = method_getName(m);          // 注意：不是 method_getSEL
            if (!sel) continue;
            NSString *selName = NSStringFromSelector(sel);
            NSString *lower = selName.lowercaseString;

            // 跳过 init/setter/getter/判定类：返回 nil 会崩
            if ([lower hasPrefix:@"init"] || [lower hasPrefix:@"new"] ||
                [lower hasPrefix:@"set"] || [lower hasPrefix:@"is"] ||
                [lower hasPrefix:@"can"] || [lower hasPrefix:@"has"] ||
                [lower hasPrefix:@"get"] || [lower hasPrefix:@"add"] ||
                [lower hasPrefix:@"remove"] || [lower hasPrefix:@"register"] ||
                [lower hasPrefix:@"delegate"] || [lower hasPrefix:@"shared"] ||
                [lower hasPrefix:@"alloc"] || [lower hasPrefix:@"copy"]) continue;

            NSString *verb = nil;
            if (!YTXVerbMatch(lower, &verb)) continue;

            NSString *key = [NSString stringWithFormat:@"%@|%@", cname, selName];
            @synchronized (gNeutered) {
                if ([gNeutered containsObject:key]) continue;
                [gNeutered addObject:key];
            }

            char ret[256];
            memset(ret, 0, sizeof(ret));
            method_getReturnType(m, ret, sizeof(ret));
            char r = ret[0];
            IMP imp = NULL;
            NSString *desc = nil;

            // block 只声明 (self)：多余参数在 arm64 上安全忽略
            if (r == 'v') {
                imp = imp_implementationWithBlock(^void(id _self) {
                    YTXLogOnce(key, [NSString stringWithFormat:@"neuter:[%@ %@] (void)", cname, selName]);
                });
                desc = @"void";
            } else if (r == 'B') {
                imp = imp_implementationWithBlock(^BOOL(id _self) {
                    YTXLogOnce(key, [NSString stringWithFormat:@"neuter:[%@ %@] -> NO", cname, selName]);
                    return NO;
                });
                desc = @"NO";
            } else if (r == '@' || r == '#') {
                imp = imp_implementationWithBlock(^id(id _self) {
                    YTXLogOnce(key, [NSString stringWithFormat:@"neuter:[%@ %@] -> empty view", cname, selName]);
                    // 返回零尺寸空 view 而非 nil，避免 addSubview:nil 崩
                    UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
                    v.hidden = YES;
                    v.userInteractionEnabled = NO;
                    return v;
                });
                desc = @"empty";
            } else {
                continue;   // 结构体等其它返回类型跳过，防崩
            }

            if (imp) {
                method_setImplementation(m, imp);
                YTXLog([NSString stringWithFormat:@"HOOKED [%@ %@] verb=%@ ret=%@", cname, selName, verb, desc]);
            }
        }
        free(ms);
    }
}

static void YTXScanAndHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gNeutered = [[NSMutableSet alloc] init]; });

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *list = (Class *)malloc(sizeof(Class) * (unsigned)count);
    count = objc_getClassList(list, count);

    int found = 0;
    for (int i = 0; i < count; i++) {
        Class c = list[i];
        if (!c) continue;
        NSString *name = NSStringFromClass(c);
        if (!YTXIsSDKClass(name)) continue;
        @synchronized (gNeutered) {
            NSString *mk = [@"cls|" stringByAppendingString:name];
            if ([gNeutered containsObject:mk]) continue;
            [gNeutered addObject:mk];
        }
        YTXLog([NSString stringWithFormat:@"SDK class: %@", name]);
        YTXNeuterClass(c, name);
        found++;
    }
    free(list);
    if (found) YTXLog([NSString stringWithFormat:@"scan round done, new SDK classes: %d", found]);
}

#pragma mark - ② 传感器层：掐掉摇一摇

static CFAbsoluteTime gStart = 0;

static BOOL YTXInSensorWindow(void) {
    if (gStart == 0) return YES;
    return ((CFAbsoluteTimeGetCurrent() - gStart) < kSensorBlockSeconds);
}

// 保存原实现，窗口外放行
static IMP orig_acc1, orig_acc2, orig_dm1, orig_dm2, orig_gy1, orig_gy2;
static IMP orig_mb, orig_me;
static IMP orig_vda;

static void YTXHookSensors(void) {
    Class CMM = objc_getClass("CMMotionManager");
    if (CMM) {
        SEL sels[3] = { @selector(startAccelerometerUpdates),
                        @selector(startDeviceMotionUpdates),
                        @selector(startGyroUpdates) };
        IMP *slots[3] = { &orig_acc1, &orig_dm1, &orig_gy1 };
        for (int i = 0; i < 3; i++) {
            Method m = class_getInstanceMethod(CMM, sels[i]);
            if (!m) continue;
            *(slots[i]) = method_getImplementation(m);
            IMP o = *(slots[i]);
            SEL s = sels[i];
            method_setImplementation(m, imp_implementationWithBlock(^void(id self) {
                if (YTXInSensorWindow()) {
                    YTXLogOnce([NSString stringWithFormat:@"s%d", i], @"shake blocked: simple sensor start");
                    return;
                }
                if (o) ((void (*)(id, SEL))o)(self, s);
            }));
            YTXLog([NSString stringWithFormat:@"hooked CMMotionManager %@", NSStringFromSelector(s)]);
        }

        // 带 queue + handler 的三个
        Method m1 = class_getInstanceMethod(CMM, @selector(startAccelerometerUpdatesToQueue:withHandler:));
        if (m1) {
            orig_acc2 = method_getImplementation(m1);
            IMP o = orig_acc2;
            method_setImplementation(m1, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMAccelerometerData *, NSError *)) {
                if (YTXInSensorWindow()) { YTXLogOnce(@"acc2", @"shake blocked: accelerometer+queue"); return; }
                if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMAccelerometerData *, NSError *)))o)(self, @selector(startAccelerometerUpdatesToQueue:withHandler:), q, h);
            }));
            YTXLog(@"hooked startAccelerometerUpdatesToQueue:withHandler:");
        }

        Method m2 = class_getInstanceMethod(CMM, @selector(startDeviceMotionUpdatesToQueue:withHandler:));
        if (m2) {
            orig_dm2 = method_getImplementation(m2);
            IMP o = orig_dm2;
            method_setImplementation(m2, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMDeviceMotion *, NSError *)) {
                if (YTXInSensorWindow()) { YTXLogOnce(@"dm2", @"shake blocked: deviceMotion+queue"); return; }
                if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMDeviceMotion *, NSError *)))o)(self, @selector(startDeviceMotionUpdatesToQueue:withHandler:), q, h);
            }));
            YTXLog(@"hooked startDeviceMotionUpdatesToQueue:withHandler:");
        }

        Method m3 = class_getInstanceMethod(CMM, @selector(startGyroUpdatesToQueue:withHandler:));
        if (m3) {
            orig_gy2 = method_getImplementation(m3);
            IMP o = orig_gy2;
            method_setImplementation(m3, imp_implementationWithBlock(^void(id self, NSOperationQueue *q, void (^h)(CMGyroData *, NSError *)) {
                if (YTXInSensorWindow()) { YTXLogOnce(@"gy2", @"shake blocked: gyro+queue"); return; }
                if (o) ((void (*)(id, SEL, NSOperationQueue *, void (^)(CMGyroData *, NSError *)))o)(self, @selector(startGyroUpdatesToQueue:withHandler:), q, h);
            }));
            YTXLog(@"hooked startGyroUpdatesToQueue:withHandler:");
        }
    }

    // 少数 SDK 走系统 motion 事件，一并吞掉（同样只在开屏窗口内）
    Class R = objc_getClass("UIResponder");
    if (R) {
        Method mb = class_getInstanceMethod(R, @selector(motionBegan:withEvent:));
        if (mb) {
            orig_mb = method_getImplementation(mb);
            IMP o = orig_mb;
            method_setImplementation(mb, imp_implementationWithBlock(^void(id self, UIEventSubtype motion, UIEvent *ev) {
                if (motion == UIEventSubtypeMotionShake && YTXInSensorWindow()) {
                    YTXLogOnce(@"mb", @"shake swallowed: motionBegan");
                    return;
                }
                if (o) ((void (*)(id, SEL, UIEventSubtype, UIEvent *))o)(self, @selector(motionBegan:withEvent:), motion, ev);
            }));
            YTXLog(@"hooked UIResponder motionBegan:withEvent:");
        }
        Method me = class_getInstanceMethod(R, @selector(motionEnded:withEvent:));
        if (me) {
            orig_me = method_getImplementation(me);
            IMP o = orig_me;
            method_setImplementation(me, imp_implementationWithBlock(^void(id self, UIEventSubtype motion, UIEvent *ev) {
                if (motion == UIEventSubtypeMotionShake && YTXInSensorWindow()) {
                    YTXLogOnce(@"me", @"shake swallowed: motionEnded");
                    return;
                }
                if (o) ((void (*)(id, SEL, UIEventSubtype, UIEvent *))o)(self, @selector(motionEnded:withEvent:), motion, ev);
            }));
            YTXLog(@"hooked UIResponder motionEnded:withEvent:");
        }
    }
}

#pragma mark - ③ 视图层兜底：清扫漏网 banner

static BOOL YTXIsAdView(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if ([cls hasPrefix:@"UI"] || [cls hasPrefix:@"CA"] || [cls hasPrefix:@"NS"]) return NO;
    return YTXIsSDKClass(cls);
}

static void YTXSweep(UIView *root, int depth) {
    if (!root || depth > 6) return;
    for (UIView *v in root.subviews) {
        if (YTXIsAdView(v)) {
            YTXLogOnce([@"sw|" stringByAppendingString:NSStringFromClass([v class])],
                       [NSString stringWithFormat:@"sweep remove: %@", NSStringFromClass([v class])]);
            v.hidden = YES;
            [v removeFromSuperview];
            continue;
        }
        YTXSweep(v, depth + 1);
    }
}

static void YTXSweepAll(void) {
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
    for (UIWindow *w in wins) YTXSweep(w, 0);
}

static void YTXHookViewController(void) {
    Class VC = objc_getClass("UIViewController");
    if (!VC) return;
    Method m = class_getInstanceMethod(VC, @selector(viewDidAppear:));
    if (!m) return;
    orig_vda = method_getImplementation(m);
    IMP o = orig_vda;
    method_setImplementation(m, imp_implementationWithBlock(^void(id self, BOOL animated) {
        if (o) ((void (*)(id, SEL, BOOL))o)(self, @selector(viewDidAppear:), animated);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTXSweepAll();
        });
    }));
    YTXLog(@"hooked UIViewController viewDidAppear:");
}

#pragma mark - 入口

__attribute__((constructor))
static void YTXEntry(void) {
    gStart = CFAbsoluteTimeGetCurrent();
    YTXLog(@"========== YTXClean v3 loaded (pure ObjC) ==========");

    // 系统类的 hook 放主队列，确保 UIKit / CoreMotion 已加载
    dispatch_async(dispatch_get_main_queue(), ^{
        YTXHookSensors();
        YTXHookViewController();
        YTXScanAndHook();
    });

    // 聚合 SDK 的类懒加载，注册晚于 dylib，分多轮扫
    NSTimeInterval delays[] = {1.0, 3.0, 8.0};
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTXScanAndHook();
            YTXSweepAll();
        });
    }
}
