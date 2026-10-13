// Standalone ipatool Go -> Unicorn TCI -> Go guest-hook diagnostic.
// All exercised data is synthetic, without Apple authentication or assets.
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#include <stdint.h>

extern int32_t iPadnMacTCIGoGuestProbe(char *diagnostic, int32_t capacity);

static NSString *const kGoTCIPending = @"macpkg-go-tci-pending";
static NSString *const kGoTCIResult = @"macpkg-go-tci-result";

static double residentMB(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    return task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                     (task_info_t)&info, &size) == KERN_SUCCESS
        ? (double)info.resident_size / 1048576.0 : -1.0;
}
@interface MacGoTCITestViewController : UIViewController
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *test;
@end
@implementation MacGoTCITestViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *header = [[UILabel alloc] init];
    header.text = @"Mac PKG / Go + 无 JIT 测试";
    header.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    header.numberOfLines = 0;

    UILabel *details = [[UILabel alloc] init];
    details.text = @"v0.6 · 在普通 iPhone 上检查 ipatool 的 Go 层能否调用 Unicorn TCI，模拟 x86-64 函数调用后返回 Go 回调。仅使用固定测试指令；不读取 Apple 账号或处理安装包。";
    details.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    details.textColor = UIColor.secondaryLabelColor;
    details.numberOfLines = 0;

    self.test = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.test setTitle:@"运行 Go ↔ TCI 回调测试" forState:UIControlStateNormal];
    self.test.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.test addTarget:self action:@selector(runProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.test.accessibilityIdentifier = @"go-tci-probe.start";

    self.status = [[UILabel alloc] init];
    self.status.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.status.numberOfLines = 0;
    self.status.accessibilityIdentifier = @"go-tci-probe.status";

    BOOL pending = [[NSUserDefaults standardUserDefaults] boolForKey:kGoTCIPending];
    self.status.text = pending
        ? @"上一次 Go ↔ TCI 测试没有正常结束。请停止重试，并提供 iOS 崩溃日志。"
        : ([[NSUserDefaults standardUserDefaults] stringForKey:kGoTCIResult] ?: @"尚未运行。");
    if (pending) self.test.enabled = NO;

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[header, details, self.test, self.status]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 26;
    [self.view addSubview:stack];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:34],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24]
    ]];
}
- (void)runProbe:(id)sender {
    self.test.enabled = NO;
    self.status.text = @"正在执行固定 x86-64 函数调用和 Go 回调…";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:kGoTCIPending];
    [defaults synchronize];
    double before = residentMB();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buf[512] = {0};
        int32_t code = iPadnMacTCIGoGuestProbe(buf, (int32_t)sizeof(buf));
        NSString *message = [NSString stringWithUTF8String:buf] ?: @"诊断信息编码错误";
        double after = residentMB();
        NSString *result = [NSString stringWithFormat:
            @"Go → TCI → Go: %@（返回码 %d）\n%@\n运行前内存 %.1f MB；运行后 %.1f MB\n不代表 StoreAgent 或 Mac PKG 解密成功。",
            code == 0 ? @"成功" : @"失败", code, message, before, after];
        NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
        [prefs setObject:result forKey:kGoTCIResult];
        [prefs setBool:NO forKey:kGoTCIPending];
        [prefs synchronize];
        dispatch_async(dispatch_get_main_queue(), ^{
            MacGoTCITestViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.status.text = result;
            strongSelf.test.enabled = YES;
        });
    });
}
@end
@interface MacGoTCIAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation MacGoTCIAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[MacGoTCITestViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(MacGoTCIAppDelegate.class));
    }
}
