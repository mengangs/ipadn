// Standalone ipatool Go -> Unicorn TCI -> Go guest-hook diagnostic.
// All exercised data is synthetic, without Apple authentication or assets.
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#include <stdint.h>

extern int32_t iPadnMacTCIGoGuestProbe(char *diagnostic, int32_t capacity);
extern int32_t iPadnMacTCIGuestMemoryProbe(char *diagnostic, int32_t capacity);
extern int32_t iPadnMacTCIMachOLoadProbe(char *diagnostic, int32_t capacity);
extern int32_t iPadnMacTCICrossImageProbe(char *diagnostic, int32_t capacity);
extern int32_t iPadnMacTCIServiceShimProbe(char *diagnostic, int32_t capacity);

// The batch invokes only the five already-existing, independently bounded,
// synthetic compatibility probes. Never call the StoreAgent link-only export.
static int32_t iPadnRunOfflineStage(NSUInteger stage, char *diagnostic, int32_t capacity) {
    switch (stage) {
        case 0: return iPadnMacTCIGoGuestProbe(diagnostic, capacity);
        case 1: return iPadnMacTCIGuestMemoryProbe(diagnostic, capacity);
        case 2: return iPadnMacTCIMachOLoadProbe(diagnostic, capacity);
        case 3: return iPadnMacTCICrossImageProbe(diagnostic, capacity);
        case 4: return iPadnMacTCIServiceShimProbe(diagnostic, capacity);
        default: return -100;
    }
}

static NSString *const kGoTCIPending = @"macpkg-go-tci-pending";
static NSString *const kGoTCIResult = @"macpkg-go-tci-result";
static NSString *const kGoTCIMemoryPending = @"macpkg-go-tci-memory-pending";
static NSString *const kGoTCIMemoryResult = @"macpkg-go-tci-memory-result";
static NSString *const kGoTCIMachOPending = @"macpkg-go-tci-macho-pending";
static NSString *const kGoTCIMachOResult = @"macpkg-go-tci-macho-result";
static NSString *const kGoTCICrossPending = @"macpkg-go-tci-cross-pending";
static NSString *const kGoTCICrossResult = @"macpkg-go-tci-cross-result";
static NSString *const kGoTCIServicePending = @"macpkg-go-tci-service-pending";
static NSString *const kGoTCIServiceResult = @"macpkg-go-tci-service-result";
static NSString *const kGoTCIBatchPending = @"macpkg-go-tci-batch-pending";
static NSString *const kGoTCIBatchProgress = @"macpkg-go-tci-batch-progress";
static NSString *const kGoTCIBatchResult = @"macpkg-go-tci-batch-result";

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
@property(nonatomic, strong) UIButton *machoTest;
@property(nonatomic, strong) UIButton *crossTest;
@property(nonatomic, strong) UIButton *serviceTest;
@property(nonatomic, strong) UIButton *batchTest;
@property(nonatomic, strong) UIButton *advancedToggle;
@property(nonatomic, strong) UIButton *copyReportButton;
@property(nonatomic, strong) UIStackView *individualTests;
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
    details.text = @"v1.1 · 一次点击完成目前全部五项离线兼容性检查，并保存分阶段报告。可选择展开单项测试。全程不使用 Apple 账号、私有框架或安装包；合成测试全部通过仍不代表官方 Mac PKG 可以下载或处理。";
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

    self.machoTest = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.machoTest setTitle:@"运行模拟 Mach-O 装载测试（可选）" forState:UIControlStateNormal];
    self.machoTest.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.machoTest.titleLabel.numberOfLines = 0;
    [self.machoTest addTarget:self action:@selector(confirmMachOProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.machoTest.accessibilityIdentifier = @"go-tci-probe.macho";

    self.crossTest = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.crossTest setTitle:@"验证两个 Mach-O 之间的符号绑定（可选）" forState:UIControlStateNormal];
    self.crossTest.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.crossTest.titleLabel.numberOfLines = 0;
    [self.crossTest addTarget:self action:@selector(confirmCrossImageProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.crossTest.accessibilityIdentifier = @"go-tci-probe.cross-image";

    self.serviceTest = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.serviceTest setTitle:@"验证跨动态库 Go 模拟系统服务（可选）" forState:UIControlStateNormal];
    self.serviceTest.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.serviceTest.titleLabel.numberOfLines = 0;
    [self.serviceTest addTarget:self action:@selector(confirmServiceProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.serviceTest.accessibilityIdentifier = @"go-tci-probe.service-shim";

    self.batchTest = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.batchTest setTitle:@"一次运行全部 5 项兼容性测试" forState:UIControlStateNormal];
    self.batchTest.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.batchTest.titleLabel.numberOfLines = 0;
    [self.batchTest addTarget:self action:@selector(confirmBatchProbe:) forControlEvents:UIControlEventTouchUpInside];
    self.batchTest.accessibilityIdentifier = @"go-tci-probe.batch";

    self.advancedToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.advancedToggle setTitle:@"显示单项测试" forState:UIControlStateNormal];
    self.advancedToggle.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    [self.advancedToggle addTarget:self action:@selector(toggleIndividualTests:) forControlEvents:UIControlEventTouchUpInside];
    self.advancedToggle.accessibilityIdentifier = @"go-tci-probe.show-individual";

    self.copyReportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.copyReportButton setTitle:@"复制诊断结果" forState:UIControlStateNormal];
    self.copyReportButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.copyReportButton addTarget:self action:@selector(copyDiagnostics:) forControlEvents:UIControlEventTouchUpInside];
    self.copyReportButton.accessibilityIdentifier = @"go-tci-probe.copy-results";

    self.individualTests = [[UIStackView alloc] initWithArrangedSubviews:
        @[self.test, self.memoryTest, self.machoTest, self.crossTest, self.serviceTest]];
    self.individualTests.axis = UILayoutConstraintAxisVertical;
    self.individualTests.spacing = 18;
    self.individualTests.hidden = YES;

    self.status = [[UILabel alloc] init];
    self.status.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.status.numberOfLines = 0;
    self.status.accessibilityIdentifier = @"go-tci-probe.status";

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL pending = [defaults boolForKey:kGoTCIPending];
    BOOL memoryPending = [defaults boolForKey:kGoTCIMemoryPending];
    BOOL machoPending = [defaults boolForKey:kGoTCIMachOPending];
    BOOL crossPending = [defaults boolForKey:kGoTCICrossPending];
    BOOL servicePending = [defaults boolForKey:kGoTCIServicePending];
    BOOL batchPending = [defaults boolForKey:kGoTCIBatchPending];
    NSInteger lastStage = [defaults integerForKey:kGoTCIBatchProgress];
    self.status.text = batchPending
        ? [NSString stringWithFormat:@"上次批量测试在第 %ld/5 项中断。为避免重复触发闪退，批量运行已停用；以下是已保存的报告：\n%@", (long)lastStage,
            [defaults stringForKey:kGoTCIBatchResult] ?: @"没有已完成的结果。"]
        : servicePending
        ? @"上一次 Go 模拟系统服务测试没有正常结束，请勿反复运行。"
        : crossPending
        ? @"上一次跨库绑定测试没有正常返回，请勿重复运行。"
        : machoPending
        ? @"上一次 Mach-O 装载测试没有正常返回，请不要反复尝试。"
        : memoryPending
        ? @"上一次 104 MiB 内存测试未正常返回。请不要重复内存压力测试。"
        : pending ? @"上一次 Go ↔ TCI 测试没有正常返回，请提供 iOS 崩溃日志。"
        : ([defaults stringForKey:kGoTCIBatchResult] ?: [defaults stringForKey:kGoTCIServiceResult] ?: [defaults stringForKey:kGoTCICrossResult] ?: [defaults stringForKey:kGoTCIMachOResult] ?: [defaults stringForKey:kGoTCIMemoryResult] ?: [defaults stringForKey:kGoTCIResult] ?: @"尚未运行。");
    if (pending) self.test.enabled = NO;
    if (memoryPending) self.memoryTest.enabled = NO;
    if (machoPending) self.machoTest.enabled = NO;
    if (crossPending) self.crossTest.enabled = NO;
    if (servicePending) self.serviceTest.enabled = NO;
    if (batchPending) self.batchTest.enabled = NO;
    self.copyReportButton.enabled = self.status.text.length > 0;

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[header, details, self.batchTest, self.advancedToggle, self.individualTests, self.copyReportButton, self.status]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 26;
    // Additional tests are intentionally scrollable instead of hiding results
    // below the Home indicator on smaller iPhone displays.
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:34],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-34],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]
    ]];
}
- (void)toggleIndividualTests:(id)sender {
    self.individualTests.hidden = !self.individualTests.hidden;
    [self.advancedToggle setTitle:self.individualTests.hidden ? @"显示单项测试" : @"收起单项测试"
                        forState:UIControlStateNormal];
}
- (void)copyDiagnostics:(id)sender {
    if (self.status.text.length == 0) return;
    [UIPasteboard generalPasteboard].string = self.status.text;
    [self.copyReportButton setTitle:@"报告已复制" forState:UIControlStateNormal];
}
- (void)confirmBatchProbe:(id)sender {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"运行全部 5 项离线测试"
        message:@"一次按顺序验证 Go 回调、104 MiB 虚拟内存、Mach-O 装载、跨库调用、Go 模拟服务。每项结束后保存报告，首次失败即停止。内存映射和实验性代码有导致独立测试 App 退出的风险。不会运行 Apple StoreAgent、下载 PKG 或读取 Apple 账号。要开始吗？"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"运行全部"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf runBatchProbe];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)runBatchProbe {
    self.batchTest.enabled = NO;
    self.test.enabled = NO;
    self.memoryTest.enabled = NO;
    self.machoTest.enabled = NO;
    self.crossTest.enabled = NO;
    self.serviceTest.enabled = NO;
    [self.copyReportButton setTitle:@"复制诊断结果" forState:UIControlStateNormal];

    NSArray<NSString *> *stages = @[@"Go ↔ TCI 回调", @"104 MiB 模拟内存",
                                    @"单个 Mach-O 装载", @"跨 Mach-O 符号调用",
                                    @"Go 模拟系统服务"];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *intro = @"Mac PKG / Go+TCI 离线兼容性批量诊断 v1.1\n仅使用自制模拟程序，不代表官方 Mac PKG 下载或 StoreAgent 可用。\n";
    [defaults setObject:intro forKey:kGoTCIBatchResult];
    [defaults setInteger:0 forKey:kGoTCIBatchProgress];
    [defaults setBool:YES forKey:kGoTCIBatchPending];
    [defaults synchronize];
    self.status.text = intro;
    double before = residentMB();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *report = [intro mutableCopy];
        BOOL success = YES;
        for (NSUInteger index = 0; index < stages.count; index++) {
            NSString *name = stages[index];
            NSUserDefaults *storage = [NSUserDefaults standardUserDefaults];
            [storage setInteger:(NSInteger)index+1 forKey:kGoTCIBatchProgress];
            [storage setObject:report forKey:kGoTCIBatchResult];
            [storage synchronize];
            NSString *progress = [NSString stringWithFormat:@"%@\n进行中 [%lu/5] %@…",
                                  report, (unsigned long)index+1, name];
            dispatch_async(dispatch_get_main_queue(), ^{
                MacGoTCITestViewController *controller = weakSelf;
                if (controller) controller.status.text = progress;
            });
            char diagnostic[512] = {0};
            int32_t code = iPadnRunOfflineStage(index, diagnostic, (int32_t)sizeof(diagnostic));
            NSString *detail = [NSString stringWithUTF8String:diagnostic] ?: @"诊断文本编码失败";
            [report appendFormat:@"\n[%lu/5] %@：%@（返回码 %d）\n%@\n",
                                 (unsigned long)index+1, name,
                                 code == 0 ? @"通过" : @"失败", code, detail];
            [storage setObject:report forKey:kGoTCIBatchResult];
            [storage synchronize];
            if (code != 0) { success = NO; break; }
        }
        double after = residentMB();
        [report appendFormat:@"\n总结果：%@\n进程常驻内存 %.1f → %.1f MB\n",
            success ? @"5/5 项全部通过" : @"已在出错阶段停止", before, after];
        [report appendString:@"真实 Apple StoreAgent 初始化、Mac App Store PKG 下载和导出：未测试。"];
        NSUserDefaults *storage = [NSUserDefaults standardUserDefaults];
        [storage setObject:report forKey:kGoTCIBatchResult];
        [storage setBool:NO forKey:kGoTCIBatchPending];
        [storage synchronize];
        dispatch_async(dispatch_get_main_queue(), ^{
            MacGoTCITestViewController *controller = weakSelf;
            if (!controller) return;
            controller.status.text = report;
            controller.batchTest.enabled = YES;
            controller.test.enabled = YES;
            controller.memoryTest.enabled = YES;
            controller.machoTest.enabled = YES;
            controller.crossTest.enabled = YES;
            controller.serviceTest.enabled = YES;
            controller.copyReportButton.enabled = YES;
        });
    });
}
- (void)confirmServiceProbe:(id)sender {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Go 模拟系统服务测试"
        message:@"原创 x86-64 动态库调用另一个动态库的模拟服务入口，由 Go Hook 检查参数并返回数据。这是独立的实验性测试，不会调用 Apple StoreAgent 或访问你的账号。可能异常退出，确认运行吗？"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"开始测试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf runServiceProbe];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)runServiceProbe {
    self.serviceTest.enabled = NO;
    self.crossTest.enabled = NO;
    self.machoTest.enabled = NO;
    self.memoryTest.enabled = NO;
    self.test.enabled = NO;
    self.status.text = @"正在验证跨动态库服务导入、Go Hook、寄存器参数和模拟内存读写…";
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setBool:YES forKey:kGoTCIServicePending];
    [prefs synchronize];
    double before = residentMB();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char diagnostic[512] = {0};
        int32_t code = iPadnMacTCIServiceShimProbe(diagnostic, (int32_t)sizeof(diagnostic));
        NSString *message = [NSString stringWithUTF8String:diagnostic] ?: @"诊断信息编码错误";
        double after = residentMB();
        NSString *result = [NSString stringWithFormat:
            @"Go 模拟系统服务：%@（返回码 %d）\n%@\n内存前 %.1f MB；后 %.1f MB\n未运行 Apple StoreAgent 或处理 PKG。",
            code == 0 ? @"成功" : @"失败", code, message, before, after];
        NSUserDefaults *store = [NSUserDefaults standardUserDefaults];
        [store setObject:result forKey:kGoTCIServiceResult];
        [store setBool:NO forKey:kGoTCIServicePending];
        [store synchronize];
        dispatch_async(dispatch_get_main_queue(), ^{
            MacGoTCITestViewController *controller = weakSelf;
            if (!controller) return;
            controller.status.text = result;
            controller.serviceTest.enabled = YES;
            controller.crossTest.enabled = YES;
            controller.serviceTest.enabled = YES;
            controller.machoTest.enabled = YES;
            controller.memoryTest.enabled = YES;
            controller.test.enabled = YES;
        });
    });
}
- (void)confirmCrossImageProbe:(id)sender {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"跨 Mach-O 符号绑定测试"
        message:@"将加载两份原创测试动态库，验证一个库导入另一个库的函数，并用无 JIT 解释器执行。可能因实验性兼容问题异常退出；不访问 Apple 账号，也不处理受保护安装包。确定继续吗？"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"开始测试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf runCrossImageProbe];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)runCrossImageProbe {
    self.serviceTest.enabled = NO;
    self.crossTest.enabled = NO;
    self.machoTest.enabled = NO;
    self.memoryTest.enabled = NO;
    self.test.enabled = NO;
    self.status.text = @"正在解析两个 Mach-O 的导入/导出符号，准备执行跨库调用…";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:kGoTCICrossPending];
    [defaults synchronize];
    double before = residentMB();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char diagnostic[512] = {0};
        int32_t code = iPadnMacTCICrossImageProbe(diagnostic, (int32_t)sizeof(diagnostic));
        NSString *message = [NSString stringWithUTF8String:diagnostic] ?: @"诊断信息编码错误";
        double after = residentMB();
        NSString *result = [NSString stringWithFormat:
            @"跨 Mach-O 符号绑定：%@（返回码 %d）\n%@\n内存前 %.1f MB；后 %.1f MB\n仍未执行 Apple StoreAgent 或下载 Mac PKG。",
            code == 0 ? @"成功" : @"失败", code, message, before, after];
        NSUserDefaults *store = [NSUserDefaults standardUserDefaults];
        [store setObject:result forKey:kGoTCICrossResult];
        [store setBool:NO forKey:kGoTCICrossPending];
        [store synchronize];
        dispatch_async(dispatch_get_main_queue(), ^{
            MacGoTCITestViewController *controller = weakSelf;
            if (!controller) return;
            controller.status.text = result;
            controller.crossTest.enabled = YES;
            controller.machoTest.enabled = YES;
            controller.memoryTest.enabled = YES;
            controller.test.enabled = YES;
        });
    });
}
- (void)confirmMachOProbe:(id)sender {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"模拟 Mach-O 装载测试"
        message:@"仅加载我们自己编写的极小 x86-64 Mach-O 测试程序，使用 ipatool 的加载器验证符号、重定位和解释执行。不使用 Apple 私有资源或安装包。实验性代码仍可能异常退出，确定继续？"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"开始测试"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf runMachOProbe];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)runMachOProbe {
    self.serviceTest.enabled = NO;
    self.machoTest.enabled = NO;
    self.memoryTest.enabled = NO;
    self.crossTest.enabled = NO;
    self.test.enabled = NO;
    self.status.text = @"正在用 ipatool 的 Go 加载器读取并重定位模拟 Mach-O…";
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setBool:YES forKey:kGoTCIMachOPending];
    [prefs synchronize];
    double before = residentMB();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char diagnostic[512] = {0};
        int32_t code = iPadnMacTCIMachOLoadProbe(diagnostic, (int32_t)sizeof(diagnostic));
        NSString *message = [NSString stringWithUTF8String:diagnostic] ?: @"诊断信息编码错误";
        double after = residentMB();
        NSString *result = [NSString stringWithFormat:
            @"模拟 Mach-O 装载：%@（返回码 %d）\n%@\n内存前 %.1f MB；后 %.1f MB\n未加载 Apple StoreAgent，也未下载或解密 PKG。",
            code == 0 ? @"成功" : @"失败", code, message, before, after];
        NSUserDefaults *store = [NSUserDefaults standardUserDefaults];
        [store setObject:result forKey:kGoTCIMachOResult];
        [store setBool:NO forKey:kGoTCIMachOPending];
        [store synchronize];
        dispatch_async(dispatch_get_main_queue(), ^{
            MacGoTCITestViewController *controller = weakSelf;
            if (!controller) return;
            controller.status.text = result;
            controller.machoTest.enabled = YES;
            controller.memoryTest.enabled = YES;
            controller.crossTest.enabled = YES;
            controller.serviceTest.enabled = YES;
            controller.test.enabled = YES;
        });
    });
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
    self.serviceTest.enabled = NO;
    self.memoryTest.enabled = NO;
    self.crossTest.enabled = NO;
    self.machoTest.enabled = NO;
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
            controller.machoTest.enabled = YES;
            controller.crossTest.enabled = YES;
            controller.serviceTest.enabled = YES;
        });
    });
}
- (void)runProbe:(id)sender {
    self.serviceTest.enabled = NO;
    self.test.enabled = NO;
    self.memoryTest.enabled = NO;
    self.machoTest.enabled = NO;
    self.crossTest.enabled = NO;
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
            strongSelf.machoTest.enabled = YES;
            strongSelf.crossTest.enabled = YES;
            strongSelf.serviceTest.enabled = YES;
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
