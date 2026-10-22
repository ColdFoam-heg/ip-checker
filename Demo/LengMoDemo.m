// LengMoDemo.dylib — 教学注入插件（只用于开发者自有 App「IP 体检」）
//
// 它演示 dylib 注入的完整原理：
//   1) 构造函数在 App 启动前被 dyld 自动执行（比 main 还早）
//   2) 用 Objective-C Runtime 替换 ScoreBridge.finalScore 的实现（Hook）
//   3) 在界面上放一个可拖动的悬浮菜单（外挂菜单的最小形态）
//   4) 带一个故意崩溃的按钮，配套崩溃日志分析教学
//
// 安全设计：只在 Bundle ID == com.lengmo.IPChecker 时激活，
// 被误装进其他 App 时只打一行日志、保持沉默、什么都不做。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// MARK: - Hook：替换 ScoreBridge.finalScore:

static IMP gOrigFinalScoreIMP = NULL;
static BOOL gLockScore = NO;
static BOOL gHookInstalled = NO;

static NSInteger HookedFinalScore(id self, SEL _cmd, NSInteger raw) {
    if (gLockScore) {
        return 100;
    }
    if (gOrigFinalScoreIMP != NULL) {
        return ((NSInteger (*)(id, SEL, NSInteger))gOrigFinalScoreIMP)(self, _cmd, raw);
    }
    return raw;
}

static void InstallScoreHook(void) {
    Class cls = NSClassFromString(@"ScoreBridge");
    if (cls == Nil) {
        NSLog(@"[LengMoDemo] 没找到 ScoreBridge 类，宿主不是 IP 体检，钩子不装");
        return;
    }
    Method m = class_getClassMethod(cls, @selector(finalScore:));
    if (m == NULL) {
        NSLog(@"[LengMoDemo] 没找到 finalScore: 方法，钩子不装");
        return;
    }
    gOrigFinalScoreIMP = method_setImplementation(m, (IMP)HookedFinalScore);
    gHookInstalled = YES;
    NSLog(@"[LengMoDemo] 评分钩子已安装：finalScore: 的实现已被替换");
}

// MARK: - 教学崩溃（故意解引用空指针，产生一份真实崩溃日志）

__attribute__((noinline))
static void TeachingCrash(void) {
    NSLog(@"[LengMoDemo] 即将故意崩溃，用于崩溃日志教学");
    volatile int *badPtr = (volatile int *)0x0;
    *badPtr = 42;
}

// MARK: - 悬浮 UI 辅助

static UIButton *gMenuButton = nil;
static UILabel *gDebugLabel = nil;

static UIWindow *FindKeyWindow(void) {
    UIWindow *found = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) { found = w; break; }
        }
        if (found == nil) { found = ws.windows.firstObject; }
        if (found != nil) { break; }
    }
    return found;
}

static UIViewController *TopViewController(void) {
    UIWindow *win = FindKeyWindow();
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController != nil) {
        vc = vc.presentedViewController;
    }
    return vc;
}

@interface LengMoMenuHandler : NSObject
+ (instancetype)shared;
- (void)onMenuTap;
- (void)onPan:(UIPanGestureRecognizer *)pan;
- (void)toggleDebugPanel;
- (void)confirmCrash;
@end

@implementation LengMoMenuHandler

+ (instancetype)shared {
    static LengMoMenuHandler *h = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [[LengMoMenuHandler alloc] init]; });
    return h;
}

- (void)onPan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
}

- (void)toggleDebugPanel {
    UIWindow *win = FindKeyWindow();
    if (win == nil) { return; }
    if (gDebugLabel != nil) {
        [gDebugLabel removeFromSuperview];
        gDebugLabel = nil;
        return;
    }
    UIDevice *dev = [UIDevice currentDevice];
    NSString *sys = [NSString stringWithFormat:@"%@ %@", dev.systemName, dev.systemVersion];
    NSString *hookText = gHookInstalled ? @"已替换 finalScore" : @"未安装";
    NSString *text = [NSString stringWithFormat:@"[LengMoDemo] 插件已活在进程里\nBundle: %@\n系统: %@\n评分钩子: %@", [NSBundle mainBundle].bundleIdentifier, sys, hookText];
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(12, 54, 302, 76)];
    lb.numberOfLines = 0;
    lb.font = [UIFont systemFontOfSize:11];
    lb.textColor = [UIColor whiteColor];
    lb.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    lb.text = text;
    lb.layer.cornerRadius = 8;
    lb.clipsToBounds = YES;
    gDebugLabel = lb;
    [win addSubview:lb];
}

- (void)confirmCrash {
    UIViewController *top = TopViewController();
    if (top == nil) { return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"故意崩溃？"
        message:@"点了之后 App 会立刻闪退，系统会生成一份崩溃日志。等下你去「设置 → 隐私与安全性 → 分析与改进 → 分析数据」里，找最新一份 IPChecker 开头的 .ips 文件发给 LengMo，我们一起读它。"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"让它崩" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        TeachingCrash();
    }]];
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)onMenuTap {
    UIViewController *top = TopViewController();
    if (top == nil) { return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"LengMo 注入菜单"
        message:@"这个菜单是 LengMoDemo.dylib 画出来的，App 本身没有这段代码。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *lockTitle = gLockScore ? @"评分锁定 100 分：开（点我关）" : @"评分锁定 100 分：关（点我开）";
    [ac addAction:[UIAlertAction actionWithTitle:lockTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        gLockScore = !gLockScore;
        NSLog(@"[LengMoDemo] 评分锁定 = %@", gLockScore ? @"开" : @"关");
    }]];
    NSString *dbgTitle = (gDebugLabel != nil) ? @"调试面板：开（点我关）" : @"调试面板：关（点我开）";
    [ac addAction:[UIAlertAction actionWithTitle:dbgTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[LengMoMenuHandler shared] toggleDebugPanel];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"触发一次崩溃（教学）" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[LengMoMenuHandler shared] confirmCrash];
        });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭菜单" style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController != nil && gMenuButton != nil) {
        ac.popoverPresentationController.sourceView = gMenuButton;
        ac.popoverPresentationController.sourceRect = gMenuButton.bounds;
    }
    [top presentViewController:ac animated:YES completion:nil];
}

@end

static void SetupFloatingUI(void) {
    UIWindow *win = FindKeyWindow();
    if (win == nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SetupFloatingUI();
        });
        return;
    }
    if (gMenuButton != nil) { return; }
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat sz = 54;
    btn.frame = CGRectMake(win.bounds.size.width - sz - 14, win.bounds.size.height * 0.38, sz, sz);
    btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.55 blue:0.6 alpha:0.92];
    btn.layer.cornerRadius = sz / 2;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOpacity = 0.3;
    btn.layer.shadowOffset = CGSizeMake(0, 2);
    btn.layer.shadowRadius = 4;
    [btn setTitle:@"LM" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [btn addTarget:[LengMoMenuHandler shared] action:@selector(onMenuTap) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[LengMoMenuHandler shared] action:@selector(onPan:)];
    [btn addGestureRecognizer:pan];
    gMenuButton = btn;
    [win addSubview:btn];
    NSLog(@"[LengMoDemo] 悬浮菜单按钮已显示");
}

// MARK: - 入口：dyld 加载这个 dylib 时自动执行（比 main 还早）

__attribute__((constructor))
static void LengMoDemoInit(void) {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier;
        if (![bid isEqualToString:@"com.lengmo.IPChecker"]) {
            NSLog(@"[LengMoDemo] 宿主是 %@，不是目标 App，保持沉默", bid);
            return;
        }
        NSLog(@"[LengMoDemo] 插件已注入 IP 体检，开始干活");
        InstallScoreHook();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            SetupFloatingUI();
        }];
    }
}
