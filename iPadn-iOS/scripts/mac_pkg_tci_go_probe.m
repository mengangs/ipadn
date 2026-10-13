// Standalone ipatool Go -> Unicorn TCI -> Go guest-hook diagnostic.
// All exercised data is synthetic, without Apple authentication or assets.
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#include <stdint.h>

extern int32_t iPadnMacTCIGoGuestProbe(char *diagnostic, int32_t capacity);
extern int32_t iPadnMacTCIGuestMemoryProbe(char *diagnostic, int32_t capacity);

static NSString *const kGoTCIPending = @"macpkg-go-tci-pending";
static NSString *const kGoTCIResult = @"macpkg-go-tci-result";
static NSString *const kGoTCIMemoryPending = @"macpkg-go-tci-memory-pending";
static NSString *const kGoTCIMemoryResult = @"macpkg-go-tci-memory-result";

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
@property(nonatomic, strong) UIButton *memoryTest;
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
    details.text = @"v0.7 · 已验证的 Go ↔ TCI 回调测试仍保留。新增可选的 104 MiB 模拟内存测试，验证 StoreAgent 所需 scratch / heap / stack 地址布局。内存测试可能因设备内存压力退出；不会下载 Apple 资源或处理安装包。";
    details.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    details.textColor = UIColor.secondaryLabelColor;
    details.numberOfLines = 0;

    self.test = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.test setTitle:@"运行 Go ↔ TCI 回调测试" forState:UIControlStateNormal];
    self.test.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.test addTarget:self action:@selector(runProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.test.accessibilityIdentifier = @"go-tci-probe.start";

    self.memoryTest = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.memoryTest setTitle:@"检查 StoreAgent 模拟内存（104 MiB，可选）" forState:UIControlStateNormal];
    self.memoryTest.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.memoryTest.titleLabel.numberOfLines = 0;
    [self.memoryTest addTarget:self action:@selector(confirmMemoryProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.memoryTest.accessibilityIdentifier = @"go-tci-probe.memory";

    self.status = [[UILabel alloc] init];
    self.status.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.status.numberOfLines = 0;
    self.status.accessibilityIdentifier = @"go-tci-probe.status";

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL pending = [defaults boolForKey:kGoTCIPending];
    BOOL memoryPending = [defaults boolForKey:kGoTCIMemoryPending];
    self.status.text = memoryPending
        ? @"上一次 104 MiB 内存测试未正常返回。请不要重复内存压力测试。"
        : pending ? @"上一次 Go ↔ TCI 测试没有正常返回，请提供 iOS 崩溃日志。"
        : ([defaults stringForKey:kGoTCIMemoryResult] ?: [defaults stringForKey:kGoTCIResult] ?: @"尚未运行。");
    if (pending) self.test.enabled = NO;
    if (memoryPending) self.memoryTest.enabled = NO;

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[header, details, self.test, self.memoryTest, self.status]];
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
- (void)confirmMemoryProbe:(id)sender {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"模拟内存压力测试"
        message:@"将单独创建并校验 104 MiB 的 x86 模拟内存区域，可能因 iPhone 内存压力导致这个测试 App 退出。不会运行 StoreAgent 或读取 Apple 账号。要继续吗？"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"开始测试"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf runMemoryProbe];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)runMemoryProbe {
    self.memoryTest.enabled = NO;
    self.test.enabled = NO;
    self.status.text = @"正在创建模拟内存：scratch 32 MiB、heap 64 MiB、stack 8 MiB…";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:kGoTCIMemoryPending];
    [defaults synchronize];
    double before = residentMB();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buf[512] = {0};
        int32_t code = iPadnMacTCIGuestMemoryProbe(buf, (int32_t)sizeof(buf));
        double after = residentMB();
        NSString *message = [NSString stringWithUTF8String:buf] ?: @"诊断信息编码错误";
        NSString *result = [NSString stringWithFormat:
            @"模拟内存测试：%@（返回码 %d）\n%@\n前 %.1f MB；后 %.1f MB\n未初始化 StoreAgent，也未下载或解密 PKG。",
            code == 0 ? @"成功" : @"失败", code, message, before, after];
        NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
        [prefs setObject:result forKey:kGoTCIMemoryResult];
        [prefs setBool:NO forKey:kGoTCIMemoryPending];
        [prefs synchronize];
        dispatch_async(dispatch_get_main_queue(), ^{
            MacGoTCITestViewController *controller = weakSelf;
            if (!controller) return;
            controller.status.text = result;
            controller.test.enabled = YES;
            controller.memoryTest.enabled = YES;
        });
    });
}
- (void)runProbe:(id)sender {
    self.test.enabled = NO;
    self.memoryTest.enabled = NO;
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
            strongSelf.memoryTest.enabled = YES;
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
