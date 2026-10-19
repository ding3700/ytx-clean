/* ===================================================================
 *  YTXClean —— 悦通行广告净化插件
 *
 *  针对悦通行 Frameworks 里实测存在的广告 SDK：
 *    AnyThinkSDK(TopOn 聚合) / KSAdSDK(快手) / QuMengAdSDK(趣盟)
 *    LYJTAdSDK / SmartdigimktSDK / TTSDK(字节系)
 *
 *  四层拦截：
 *    ① 传感器层   —— 掐掉 CMMotionManager 与 motion 事件（治摇一摇）
 *    ② 窗口层     —— 广告 window 直接隐藏移除（治开屏）
 *    ③ 视图层     —— 拦 addSubview + 定时清扫（治内置 banner / 信息流）
 *    ④ 自动发现层 —— 运行时遍历全部类，广告类的 show/present 类方法自动置空
 *                    （不需要预先知道 QuMeng / LYJT 的类名）
 *
 *  日志：悦通行沙盒 Documents/ytx_clean.log，Filza 搜索查看
 * =================================================================== */

%config generator=internal;   // 纯 runtime 实现，不依赖 CydiaSubstrate

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma mark - ============ 可调参数 ============

// 启动后多少秒内屏蔽传感器。摇一摇广告只在开屏阶段出现，
// 超时后自动放行，不影响 App 内其它需要陀螺仪的功能。
static const NSTimeInterval kSensorBlockSeconds = 15.0;

// 日志开关：验证通过后改成 0，省一点性能
#define YTX_DEBUG 1

#pragma mark - ============ 日志 ============

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

#pragma mark - ============ 广告类判定 ============

// 强关键词：系统类不会命中，命中即可信
static NSString * const AD_KEYS[] = {
    @"SplashAd", @"AdSplash", @"Splash", @"splash",
    @"AdView", @"AdViewController", @"AdManager", @"AdCell", @"AdBanner", @"BannerAd",
    @"Advert", @"advert", @"Promot", @"promot",
    @"GDT", @"BUAd", @"CSJ", @"KSAd", @"Pangolin",
    @"AnyThink", @"ATAd", @"ATNative", @"ATBanner", @"ATSplash",
    @"QuMeng", @"LYJT", @"Smartdigimkt", @"Smartdigi",
    nil
};

// 白名单：命中先过一遍再判广告，防止误杀（Read/Load/Address 这类）
static NSString * const SAFE_KEYS[] = {
    @"Address", @"Advisory", @"Advanced", @"Adapter", @"Adaptor",
    @"Add", @"Read", @"Load", @"Shadow", @"Gradient", @"Badge", @"Header", @"Trade",
    nil
};

static BOOL YTXIsAdName(NSString *cls) {
    if (cls.length == 0) return NO;
    for (int i = 0; SAFE_KEYS[i]; i++) {
        if ([cls rangeOfString:SAFE_KEYS[i]].length > 0) return NO;
    }
    for (int i = 0; AD_KEYS[i]; i++) {
        if ([cls rangeOfString:AD_KEYS[i]].length > 0) return YES;
    }
    return NO;
}

static BOOL YTXIsAdObject(id obj) {
    if (!obj) return NO;
    Class c = [obj class];
    for (Class it = c; it; it = class_getSuperclass(it)) {
        if (YTXIsAdName(NSStringFromClass(it))) return YES;
    }
    return NO;
}

// 启动时记录，避免同一条规则反复刷屏
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

#pragma mark - ============ ① 传感器层：掐掉摇一摇 ============

static CFAbsoluteTime gStartTime = 0;

static BOOL YTXInSensorWindow(void) {
    if (gStartTime == 0) return YES;
    return (CFAbsoluteTimeGetCurrent() - gStartTime) < kSensorBlockSeconds;
}

%hook CMMotionManager

- (void)startAccelerometerUpdates {
    if (YTXInSensorWindow()) { YTXLogOnce(@"acc1", @"shake blocked: startAccelerometerUpdates"); return; }
    %orig;
}

- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(void (^)(CMAccelerometerData *, NSError *))handler {
    if (YTXInSensorWindow()) { YTXLogOnce(@"acc2", @"shake blocked: startAccelerometerUpdatesToQueue"); return; }
    %orig;
}

- (void)startDeviceMotionUpdates {
    if (YTXInSensorWindow()) { YTXLogOnce(@"dm1", @"shake blocked: startDeviceMotionUpdates"); return; }
    %orig;
}

- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(void (^)(CMDeviceMotion *, NSError *))handler {
    if (YTXInSensorWindow()) { YTXLogOnce(@"dm2", @"shake blocked: startDeviceMotionUpdatesToQueue"); return; }
    %orig;
}

- (void)startGyroUpdates {
    if (YTXInSensorWindow()) { YTXLogOnce(@"gy1", @"shake blocked: startGyroUpdates"); return; }
    %orig;
}

- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(void (^)(CMGyroData *, NSError *))handler {
    if (YTXInSensorWindow()) { YTXLogOnce(@"gy2", @"shake blocked: startGyroUpdatesToQueue"); return; }
    %orig;
}

%end

// 部分 SDK 仍走系统 motion 事件，一并吞掉（同样只在开屏窗口内）
%hook UIResponder

- (void)motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake && YTXInSensorWindow()) {
        YTXLogOnce(@"mb", @"shake swallowed: motionBegan");
        return;
    }
    %orig;
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake && YTXInSensorWindow()) {
        YTXLogOnce(@"me", @"shake swallowed: motionEnded");
        return;
    }
    %orig;
}

%end

#pragma mark - ============ ③ 视图层：广告不上树 ============

%hook UIView

- (void)addSubview:(UIView *)view {
    if (YTXIsAdObject(view)) {
        YTXLogOnce([@"as:" stringByAppendingString:NSStringFromClass([view class])],
                   [NSString stringWithFormat:@"addSubview block: %@", NSStringFromClass([view class])]);
        view.hidden = YES;
        [view removeFromSuperview];
        return;
    }
    %orig;
}

- (void)insertSubview:(UIView *)view atIndex:(NSInteger)index {
    if (YTXIsAdObject(view)) {
        YTXLogOnce([@"is:" stringByAppendingString:NSStringFromClass([view class])],
                   [NSString stringWithFormat:@"insertSubview block: %@", NSStringFromClass([view class])]);
        view.hidden = YES;
        [view removeFromSuperview];
        return;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (self.window && YTXIsAdObject(self)) {
        YTXLogOnce([@"mw:" stringByAppendingString:NSStringFromClass([self class])],
                   [NSString stringWithFormat:@"didMoveToWindow remove: %@", NSStringFromClass([self class])]);
        self.hidden = YES;
        [self removeFromSuperview];
    }
}

%end

#pragma mark - ============ 内置广告清扫（补漏） ============

// 递归清扫已存在的广告视图，depth 限制防卡顿
static void YTXSweep(UIView *root, int depth) {
    if (!root || depth > 6) return;
    NSArray *subs = root.subviews;
    for (UIView *v in subs) {
        if (YTXIsAdObject(v)) {
            YTXLogOnce([@"sw:" stringByAppendingString:NSStringFromClass([v class])],
                       [NSString stringWithFormat:@"sweep remove: %@", NSStringFromClass([v class])]);
            v.hidden = YES;
            [v removeFromSuperview];
            continue;
        }
        YTXSweep(v, depth + 1);
    }
}

static NSArray *YTXAllWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) [out addObject:w];
        }
    }
    if (out.count == 0) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w) [out addObject:w];
    }
    return out;
}

static void YTXSweepAll(void) {
    for (UIWindow *w in YTXAllWindows()) YTXSweep(w, 0);
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *cls = NSStringFromClass([self class]);
    if (YTXIsAdName(cls)) {
        YTXLog([NSString stringWithFormat:@"ad VC appeared, dismissing: %@", cls]);
        [self dismissViewControllerAnimated:NO completion:nil];
        [self.navigationController popViewControllerAnimated:NO];
        return;
    }
    // 信息流广告常在页面出现后才异步加载，延迟补扫一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTXSweepAll();
    });
}

%end

#pragma mark - ============ ② 窗口层：开屏 window 直接干掉 ============

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    __weak UIWindow *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *w = weakSelf;
        if (!w) return;
        BOOL hit = NO;
        for (UIView *v in w.subviews) {
            if (YTXIsAdObject(v)) { hit = YES; break; }
        }
        if (hit || YTXIsAdName(NSStringFromClass([w.rootViewController class]))) {
            YTXLog([NSString stringWithFormat:@"window kill: %@ / root=%@",
                    NSStringFromClass([w class]),
                    NSStringFromClass([w.rootViewController class])]);
            w.hidden = YES;
            [w resignKeyWindow];
        }
    });
}

%end

#pragma mark - ============ ④ 自动发现：运行时认类并置空 show 方法 ============

static NSMutableSet *gAutoHooked;

// 只对返回 void / BOOL / id 的方法置空，避开 CGRect 等结构体返回，防崩
static void YTXNeuterMethodsOfClass(Class cls, NSString *cname) {
    static NSArray *verbs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        verbs = @[@"show", @"present", @"display", @"popup", @"pop",
                  @"splash", @"expose", @"render"];
    });

    // 实例方法 + 类方法都扫
    Class targets[2] = { cls, object_getClass(cls) };
    for (int t = 0; t < 2; t++) {
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(targets[t], &mc);
        if (!ms) continue;
        for (unsigned int i = 0; i < mc; i++) {
            Method m = ms[i];
            SEL sel = method_getSEL(m);
            NSString *selName = NSStringFromSelector(sel);
            NSString *lower = selName.lowercaseString;

            // 排除 setter / getter / 判定方法
            if ([lower hasPrefix:@"set"] || [lower hasPrefix:@"is"] ||
                [lower hasPrefix:@"can"] || [lower hasPrefix:@"has"] ||
                [selName hasSuffix:@":"] == NO && [lower hasPrefix:@"get"]) continue;

            BOOL match = NO;
            for (NSString *v in verbs) {
                if ([lower rangeOfString:v].length > 0) { match = YES; break; }
            }
            if (!match) continue;

            char ret[256];
            method_getReturnType(m, ret, sizeof(ret));
            char r = ret[0];
            IMP imp = NULL;

            // block 只声明 (self, _cmd)，多余参数在 arm64 上安全忽略
            if (r == 'v') {
                imp = imp_implementationWithBlock(^void(id _self) {
                    YTXLogOnce([NSString stringWithFormat:@"call:%@ %@", cname, selName],
                               [NSString stringWithFormat:@"neutered call: -[%@ %@]", cname, selName]);
                });
            } else if (r == 'B') {
                imp = imp_implementationWithBlock(^BOOL(id _self) {
                    YTXLogOnce([NSString stringWithFormat:@"call:%@ %@", cname, selName],
                               [NSString stringWithFormat:@"neutered call: -[%@ %@] -> NO", cname, selName]);
                    return NO;
                });
            } else if (r == '@' || r == '#') {
                imp = imp_implementationWithBlock(^id(id _self) {
                    YTXLogOnce([NSString stringWithFormat:@"call:%@ %@", cname, selName],
                               [NSString stringWithFormat:@"neutered call: -[%@ %@] -> nil", cname, selName]);
                    return nil;
                });
            }
            if (imp) {
                method_setImplementation(m, imp);
                YTXLog([NSString stringWithFormat:@"auto-hook: [%@ %@] ret=%c", cname, selName, r]);
            }
        }
        free(ms);
    }
}

static void YTXScanAndHookClasses(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gAutoHooked = [[NSMutableSet alloc] init]; });

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *list = (Class *)malloc(sizeof(Class) * (unsigned)count);
    count = objc_getClassList(list, count);

    int found = 0;
    for (int i = 0; i < count; i++) {
        Class c = list[i];
        if (!c) continue;
        NSString *name = NSStringFromClass(c);
        if (!YTXIsAdName(name)) continue;
        if ([gAutoHooked containsObject:name]) continue;
        @synchronized (gAutoHooked) {
            if ([gAutoHooked containsObject:name]) continue;
            [gAutoHooked addObject:name];
        }
        YTXLog([NSString stringWithFormat:@"ad class found: %@", name]);
        YTXNeuterMethodsOfClass(c, name);
        found++;
    }
    free(list);
    if (found) YTXLog([NSString stringWithFormat:@"scan done, new ad classes: %d", found]);
}

#pragma mark - ============ 兜底：拦广告跳转 ============

static BOOL YTXIsAdURL(NSURL *url) {
    if (!url) return NO;
    NSString *s = url.absoluteString.lowercaseString;
    NSArray *keys = @[@"ad.", @"ads.", @"advert", @"click", @"track", @"gdt", @"csj",
                      @"pangolin", @"snssdk", @"mobads", @"union", @"adx", @"kuaishou", @"adscope"];
    for (NSString *k in keys) {
        if ([s rangeOfString:k].length > 0) {
            YTXLog([NSString stringWithFormat:@"block(ad url): %@", s]);
            return YES;
        }
    }
    return NO;
}

%hook UIApplication

- (BOOL)openURL:(NSURL *)url {
    if (YTXIsAdURL(url)) return NO;
    return %orig;
}

- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    if (YTXIsAdURL(url)) { if (completion) completion(NO); return; }
    %orig;
}

%end

#pragma mark - ============ 入口 ============

%ctor {
    gStartTime = CFAbsoluteTimeGetCurrent();
    YTXLog(@"========== YTXClean loaded ==========");

    // 广告 SDK 多为懒加载，类注册晚于 dylib 加载，所以分多轮扫描
    YTXScanAndHookClasses();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTXScanAndHookClasses(); YTXSweepAll();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTXScanAndHookClasses(); YTXSweepAll();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTXScanAndHookClasses(); YTXSweepAll();
    });
}
