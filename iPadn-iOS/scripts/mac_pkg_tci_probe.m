// Independent, user-triggered no-JIT x86-64 CPU interpreter test.
// GPL-2.0 source: https://github.com/Naville/unicorn/tree/53471ef9cf480fab094bf13db3e5d2f9e2c30dc5
// This test contains no Apple authentication, StoreAgent or Mac PKG processing.
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <unicorn/unicorn.h>

static NSString *const kTCIRunPending = @"macpkg-tci-run-pending";
static NSString *const kTCIResult = @"macpkg-tci-last-result";

static double TCIMemoryMB(void) {
    mach_task_basic_info_data_t data = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&data, &count) != KERN_SUCCESS) { return -1; }
    return (double)data.resident_size / 1048576.0;
}

static NSString *TCIExecuteFixedCode(void) {
    // Host is signed iPhone arm64. Guest uses x86-64 TCI bytecode interpreter.
    // Unlike Unicorn's JIT backend, TCI never emits ARM64 executable pages.
    uc_engine *engine = NULL;
    uc_err error = uc_open(UC_ARCH_X86, UC_MODE_64, &engine);
    if (error != UC_ERR_OK) {
        return [NSString stringWithFormat:@"初始化失败：%s (%d)", uc_strerror(error), error];
    }
    NSString *message = nil;
    const uint64_t address = 0x100000;
    // mov rax,0x1234 ; add rax,7 ; expected rax=0x123b.
    const uint8_t code[] = {0x48,0xc7,0xc0,0x34,0x12,0x00,0x00,
                            0x48,0x83,0xc0,0x07};
    error = uc_mem_map(engine, address, 0x1000, UC_PROT_ALL);
    if (error != UC_ERR_OK) { goto finish; }
    error = uc_mem_write(engine, address, code, sizeof(code));
    if (error != UC_ERR_OK) { goto finish; }
    error = uc_emu_start(engine, address, address + sizeof(code), 500000, 64);
    if (error != UC_ERR_OK) { goto finish; }
    uint64_t rax = 0;
    error = uc_reg_read(engine, UC_X86_REG_RAX, &rax);
    if (error == UC_ERR_OK) {
        message = rax == 0x123b
            ? @"TCI 解释执行成功！RAX=0x123b（预期值），没有使用 JIT。"
            : [NSString stringWithFormat:@"执行结果不匹配：RAX=0x%llx（预期 0x123b）",
                (unsigned long long)rax];
    }
finish:
    if (!message) {
        message = [NSString stringWithFormat:@"TCI 返回错误：%s（代码 %d）",
                   uc_strerror(error), error];
    }
    uc_close(engine);
    return message;
}

@interface TCITestViewController : UIViewController
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) UILabel *status;
@end

@implementation TCITestViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [[UILabel alloc] init];
    title.text = @"Mac PKG / 无 JIT 测试";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    title.numberOfLines = 0;
    UILabel *details = [[UILabel alloc] init];
    details.text = @"v0.5 · Unicorn TCI 解释执行 x86-64。此版本不生成或执行未签名的 ARM64 代码；无需越狱，不访问 Apple 账号，也不下载安装包。此实验分支仍可能有兼容性问题。";
    details.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    details.textColor = UIColor.secondaryLabelColor;
    details.numberOfLines = 0;
    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"执行无 JIT 指令测试" forState:UIControlStateNormal];
    self.runButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.runButton addTarget:self action:@selector(runTest:) forControlEvents:UIControlEventTouchUpInside];
    self.runButton.accessibilityIdentifier = @"tci-probe.start";
    self.status = [[UILabel alloc] init];
    self.status.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.status.numberOfLines = 0;
    self.status.accessibilityIdentifier = @"tci-probe.status";
    BOOL pending = [[NSUserDefaults standardUserDefaults] boolForKey:kTCIRunPending];
    NSString *previous = [[NSUserDefaults standardUserDefaults] stringForKey:kTCIResult];
    self.status.text = pending
        ? @"上次无 JIT 解释执行未正常结束，请提供对应的 iOS .ips 崩溃日志，不要反复测试。"
        : previous ?: @"尚未执行。";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[title, details, self.runButton, self.status]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 28;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *area = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:area.topAnchor constant:40],
        [stack.leadingAnchor constraintEqualToAnchor:area.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:area.trailingAnchor constant:-24]
    ]];
    if (pending) self.runButton.enabled = NO;
}

- (void)runTest:(id)sender {
    self.runButton.enabled = NO;
    self.status.text = @"解释器执行中；只运行固定的 11 字节 x86-64 测试代码。";
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    [preferences setBool:YES forKey:kTCIRunPending];
    [preferences synchronize];
    double startMB = TCIMemoryMB();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = TCIExecuteFixedCode();
        double endMB = TCIMemoryMB();
        NSString *report = [NSString stringWithFormat:
            @"%@\n运行前内存：%.1f MB\n运行后内存：%.1f MB\n仅验证解释器，不代表 Mac PKG 下载或处理成功。",
            result, startMB, endMB];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:report forKey:kTCIResult];
        [defaults setBool:NO forKey:kTCIRunPending];
        [defaults synchronize];
        dispatch_async(dispatch_get_main_queue(), ^{
            TCITestViewController *selfRef = weakSelf;
            selfRef.status.text = report;
            selfRef.runButton.enabled = YES;
        });
    });
}
@end

@interface TCITestDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation TCITestDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[TCITestViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(TCITestDelegate.class));
    }
}
