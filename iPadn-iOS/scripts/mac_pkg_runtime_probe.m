// Standalone, user-invoked runtime test app. NOT a Mac PKG downloader.
// It contains no Apple credentials and will never run the emulator on launch.
// Some non-jailbroken iPhones may terminate this process when dynamic code
// protection is enforced; keep it separate from the real iPadn application.
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#include <stdint.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

// Detailed diagnostics distinguish missing x86 guest CPU, symbol loading,
// and actual x86 emulator initialization errors.
extern int32_t iPadnMacUnicornProbe(char *error, int32_t capacity);
extern int32_t iPadnMacExecutionProbe(char *error, int32_t capacity);

static double ResidentMemoryMB(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                      (task_info_t)&info, &count);
    return status == KERN_SUCCESS ? (double)info.resident_size / 1048576.0 : -1.0;
}

// This probes memory permissions without jumping into dynamically generated
// code. It is safe to run on ordinary signed iOS apps and does not change any
// code-signing settings or attempt to bypass sandbox restrictions.
static NSString *ExecutablePagePreflight(BOOL *executable) {
    *executable = NO;
    const size_t pageSize = (size_t)getpagesize();
    void *region = mmap(NULL, pageSize, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANON, -1, 0);
    if (region == MAP_FAILED) {
        return [NSString stringWithFormat:@"创建读写内存页失败：errno=%d (%s)",
                errno, strerror(errno)];
    }
    memset(region, 0x90, pageSize);
    int status = mprotect(region, pageSize, PROT_READ | PROT_EXEC);
    int savedErrno = errno;
    // This memory page is NOT executed. mprotect success does not prove that
    // iOS permits execution of dynamically generated, unsigned native code.
    munmap(region, pageSize);
    if (status != 0) {
        return [NSString stringWithFormat:
                @"iOS 拒绝将读写内存切换为可执行内存：errno=%d (%s)。为避免闪退，已阻止下一步执行测试。",
                savedErrno, strerror(savedErrno)];
    }
    *executable = YES;
    return @"mmap(读写) → mprotect(只读+可执行) 成功。尚未实际执行新生成的代码；iOS 代码签名限制仍可能阻止执行。";
}

static NSString *const kRiskyExecutionPending = @"macpkg-probe-unsafe-run-pending";

@interface ProbeViewController : UIViewController
@property (nonatomic, strong) UILabel *result;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) UIButton *executeButton;
@property (nonatomic, strong) UIButton *preflightButton;
@property (nonatomic, assign) BOOL passedPreflight;
@end

@implementation ProbeViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    title.text = @"Mac PKG / Unicorn 兼容性测试";
    title.numberOfLines = 0;

    UILabel *description = [[UILabel alloc] init];
    description.translatesAutoresizingMaskIntoConstraints = NO;
    description.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    description.textColor = UIColor.secondaryLabelColor;
    description.numberOfLines = 0;
    description.text = @"v0.4：先安全检查 iOS 是否允许内存权限切换，再由你决定是否尝试可能闪退的 x86-64 指令执行。初始化测试已在你的设备上通过。不读取 Apple 账号、不下载 PKG。";

    self.result = [[UILabel alloc] init];
    self.result.translatesAutoresizingMaskIntoConstraints = NO;
    self.result.numberOfLines = 0;
    self.result.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    BOOL lastRiskyTestInterrupted = [[NSUserDefaults standardUserDefaults] boolForKey:kRiskyExecutionPending];
    self.result.text = lastRiskyTestInterrupted
        ? @"上一次 x86-64 指令执行没有正常返回。可能是 iOS 内存权限/签名阻止，也可能是其他异常退出；需要 .ips 崩溃报告确定原因。"
        : @"尚未运行。";
    self.result.accessibilityIdentifier = @"runtime-probe.status";

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.runButton setTitle:@"开始兼容性测试" forState:UIControlStateNormal];
    self.runButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.runButton addTarget:self action:@selector(runProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.runButton.accessibilityIdentifier = @"runtime-probe.start";

    self.preflightButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.preflightButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.preflightButton setTitle:@"检查内存权限（安全）" forState:UIControlStateNormal];
    self.preflightButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.preflightButton addTarget:self action:@selector(checkMemoryPermissions:) forControlEvents:UIControlEventTouchUpInside];
    self.preflightButton.accessibilityIdentifier = @"runtime-probe.memory-preflight";

    self.executeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.executeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.executeButton setTitle:@"继续运行 x86-64 指令（有闪退风险）" forState:UIControlStateNormal];
    self.executeButton.enabled = NO;
    self.executeButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.executeButton addTarget:self action:@selector(executeProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.executeButton.accessibilityIdentifier = @"runtime-probe.execute";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, description, self.runButton, self.preflightButton, self.executeButton, self.result]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:32]
    ]];
}

- (void)runProbe:(id)sender {
    [self runDiagnostic:NO];
}

- (void)checkMemoryPermissions:(id)sender {
    BOOL allowed = NO;
    NSString *diagnostic = ExecutablePagePreflight(&allowed);
    self.passedPreflight = allowed;
    self.executeButton.enabled = allowed;
    self.result.text = diagnostic;
}

- (void)executeProbe:(id)sender {
    if (!self.passedPreflight) {
        self.result.text = @"请先点击“检查内存权限（安全）”。如果检查失败，就不要再尝试模拟执行。";
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"有闪退风险"
        message:@"即使内存权限检查通过，普通签名 iPhone 仍可能禁止执行 Unicorn 的动态指令。如果再次闪退，请提供 iOS 的 .ips 崩溃日志。确定继续吗？"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"仍然测试"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [weakSelf runDiagnostic:YES];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runDiagnostic:(BOOL)execute {
    self.runButton.enabled = NO;
    self.executeButton.enabled = NO;
    self.preflightButton.enabled = NO;
    if (execute) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kRiskyExecutionPending];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    self.result.text = execute
        ? @"准备执行 11 字节固定 x86-64 指令（最长 500 毫秒）。可能因 iOS 内存保护导致测试 App 退出。"
        : @"正在检查 Unicorn 初始化。";
    double before = ResidentMemoryMB();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char diagnostic[512] = {0};
        int32_t result = execute
            ? iPadnMacExecutionProbe(diagnostic, (int32_t)sizeof(diagnostic))
            : iPadnMacUnicornProbe(diagnostic, (int32_t)sizeof(diagnostic));
        NSString *detail = [NSString stringWithUTF8String:diagnostic];
        if (!detail) detail = @"无法解码诊断信息";
        double after = ResidentMemoryMB();
        if (execute) {
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kRiskyExecutionPending];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ProbeViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.result.text = [NSString stringWithFormat:
                @"%@：%@ (返回码 %d)\n诊断信息：%@\n运行前常驻内存：%.1f MB\n运行后常驻内存：%.1f MB\n这仅验证模拟器，不代表 Mac PKG 解密成功。",
                execute ? @"x86-64 指令执行" : @"Unicorn 初始化",
                result == 0 ? @"成功" : @"失败",
                result, detail, before, after];
            strongSelf.runButton.enabled = YES;
            strongSelf.preflightButton.enabled = YES;
            strongSelf.executeButton.enabled = strongSelf.passedPreflight;
        });
    });
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[ProbeViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class));
    }
}
