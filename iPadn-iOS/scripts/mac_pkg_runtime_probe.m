// Standalone, user-invoked runtime test app. NOT a Mac PKG downloader.
// It contains no Apple credentials and will never run the emulator on launch.
// Some non-jailbroken iPhones may terminate this process when dynamic code
// protection is enforced; keep it separate from the real iPadn application.
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#include <stdint.h>

// Detailed diagnostics distinguish missing x86 guest CPU, symbol loading,
// and actual x86 emulator initialization errors.
extern int32_t iPadnMacUnicornProbe(char *error, int32_t capacity);

static double ResidentMemoryMB(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                      (task_info_t)&info, &count);
    return status == KERN_SUCCESS ? (double)info.resident_size / 1048576.0 : -1.0;
}

@interface ProbeViewController : UIViewController
@property (nonatomic, strong) UILabel *result;
@property (nonatomic, strong) UIButton *runButton;
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
    description.text = @"检查普通 iPhone 能否初始化静态链接的 Unicorn x86-64 模拟引擎（App 本身为 ARM64）。不读取 Apple 账号、不下载安装包，可能因 iOS 执行限制导致独立测试 App 退出。";

    self.result = [[UILabel alloc] init];
    self.result.translatesAutoresizingMaskIntoConstraints = NO;
    self.result.numberOfLines = 0;
    self.result.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.result.text = @"尚未运行。";
    self.result.accessibilityIdentifier = @"runtime-probe.status";

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.runButton setTitle:@"开始兼容性测试" forState:UIControlStateNormal];
    self.runButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.runButton addTarget:self action:@selector(runProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.runButton.accessibilityIdentifier = @"runtime-probe.start";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, description, self.runButton, self.result]];
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
    self.runButton.enabled = NO;
    self.result.text = @"正在检查 Unicorn；如果 App 闪退，请记录这一现象。";
    double before = ResidentMemoryMB();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char diagnostic[512] = {0};
        int32_t result = iPadnMacUnicornProbe(diagnostic, (int32_t)sizeof(diagnostic));
        NSString *detail = [NSString stringWithUTF8String:diagnostic];
        if (!detail) detail = @"无法解码初始化诊断信息";
        double after = ResidentMemoryMB();
        dispatch_async(dispatch_get_main_queue(), ^{
            ProbeViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.result.text = [NSString stringWithFormat:
                @"Unicorn: %@ (返回码 %d)\n诊断信息: %@\n运行前常驻内存: %.1f MB\n运行后常驻内存: %.1f MB\n这仅验证引擎初始化，不代表 Mac PKG 解密成功。",
                result == 0 ? @"初始化成功" : @"初始化失败", result, detail, before, after];
            strongSelf.runButton.enabled = YES;
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
