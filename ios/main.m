#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <SafariServices/SafariServices.h>
#import <Mobile/Mobile.h>

static UIColor *WBBlue(void) { return [UIColor colorWithRed:0.20 green:0.41 blue:0.93 alpha:1]; }
static UIColor *WBBackground(void) { return [UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1]; }
static NSString *WBText(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSDictionary *WBDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static BOOL WBBool(id value) { return [value isKindOfClass:NSNumber.class] && [value boolValue]; }
static NSString *WBNumber(id value) { return [value isKindOfClass:NSNumber.class] ? [value stringValue] : @"—"; }

@interface WBHeroStack : UIStackView
@property CAGradientLayer *gradient;
@property BOOL gradientEnabled;
@end
@implementation WBHeroStack
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.gradientEnabled) return;
    if (!self.gradient) {
        self.gradient = [CAGradientLayer layer];
        self.gradient.colors = @[(id)[UIColor colorWithRed:0.15 green:0.24 blue:0.51 alpha:1].CGColor, (id)WBBlue().CGColor];
        self.gradient.startPoint = CGPointMake(0, 0); self.gradient.endPoint = CGPointMake(1, 1);
        self.gradient.cornerRadius = 21; [self.layer insertSublayer:self.gradient atIndex:0];
    }
    self.gradient.frame = self.bounds;
}
@end

@interface GatewayController : UITabBarController <UITabBarControllerDelegate, WKNavigationDelegate, WKUIDelegate, SFSafariViewControllerDelegate, NSURLSessionTaskDelegate>
@property dispatch_queue_t engineQueue;
@property BOOL running;
@property BOOL busy;
@property BOOL backgrounded;
@property BOOL stopRequested;
@property BOOL operationBusy;
@property BOOL overviewFetching;
@property BOOL configFetching;
@property BOOL polling;
@property NSUInteger generation;
@property UIBackgroundTaskIdentifier backgroundTask;
@property (copy) NSString *baseURL;
@property (copy) NSString *notice;
@property (copy) NSString *overviewError;
@property (copy) NSString *configNotice;
@property NSDictionary *overview;
@property NSDictionary *config;
@property NSURLSession *session;
@property NSTimer *overviewTimer;
@property NSTimer *loginTimer;
@property (copy) NSString *loginState;
@property (copy) NSString *loginToken;
@property NSDate *loginDeadline;
@property SFSafariViewController *browser;
@property NSArray<UINavigationController *> *pages;
@property UIStackView *homeStack;
@property UIStackView *accountsStack;
@property UIStackView *settingsStack;
@property UILabel *settingsMessage;
@property UITextField *keyField;
@property UITextField *accountLimit;
@property UITextField *globalLimit;
@property UITextField *cooldownField;
@property UISwitch *preferExpiring;
@property UIStepper *accountStepper;
@property UIStepper *globalStepper;
@property BOOL configDirty;
@property BOOL fillingConfig;
@property UIButton *saveButton;
@property WKWebView *web;
@property UIViewController *panelController;
@property UITextView *jsonEditor;
@property UILabel *jsonMessage;
@property UIViewController *jsonController;
@end

@implementation GatewayController
- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.text = text; label.numberOfLines = 0; label.textColor = color;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.adjustsFontForContentSizeCategory = YES;
    label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:label.font];
    return label;
}
- (UIStackView *)vertical:(CGFloat)spacing {
    UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = spacing; return stack;
}
- (UIButton *)button:(NSString *)title action:(void (^)(GatewayController *))action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *style = [UIButtonConfiguration plainButtonConfiguration];
    style.title = title; style.baseForegroundColor = WBBlue(); style.contentInsets = NSDirectionalEdgeInsetsMake(10, 0, 10, 0);
    button.configuration = style; button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.titleLabel.numberOfLines = 0;
    __weak GatewayController *weakSelf = self;
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        GatewayController *owner = weakSelf; if (owner) action(owner);
    }] forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return button;
}
- (UIStackView *)card:(NSArray<UIView *> *)views color:(UIColor *)color {
    UIStackView *card = color ? [WBHeroStack new] : [self vertical:8];
    card.axis = UILayoutConstraintAxisVertical; card.spacing = 8; card.backgroundColor = color ?: UIColor.whiteColor;
    card.layer.cornerRadius = 21; card.layoutMargins = UIEdgeInsetsMake(18, 20, 18, 20);
    card.layoutMarginsRelativeArrangement = YES;
    for (UIView *view in views) [card addArrangedSubview:view];
    return card;
}
- (UIView *)divider {
    UIView *line = [UIView new]; line.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1];
    [line.heightAnchor constraintEqualToConstant:1].active = YES; return line;
}
- (void)clear:(UIStackView *)stack {
    for (UIView *v in stack.arrangedSubviews) { [stack removeArrangedSubview:v]; [v removeFromSuperview]; }
}
- (UIStackView *)pageContent:(UIViewController *)page {
    page.view.backgroundColor = WBBackground();
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [page.view addSubview:scroll];
    UIStackView *content = [self vertical:16]; content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:page.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:page.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:page.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:page.view.keyboardLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    return content;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.engineQueue = dispatch_queue_create("workbuddy.engine", DISPATCH_QUEUE_SERIAL);
    self.backgroundTask = UIBackgroundTaskInvalid; self.notice = @"已停止 · 仅在前台运行";
    self.delegate = self; self.view.tintColor = WBBlue();
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    NSMutableArray *pages = [NSMutableArray new];
    NSArray *titles = @[@"工作台", @"账号", @"设置"];
    NSArray *tabs = @[@"首页", @"账号", @"设置"];
    NSArray *icons = @[@"square.grid.2x2.fill", @"person.crop.circle", @"gearshape"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIViewController *page = [UIViewController new]; page.title = titles[i];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
        nav.navigationBar.prefersLargeTitles = YES;
        nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:tabs[i] image:[UIImage systemImageNamed:icons[i]] tag:(NSInteger)i];
        [pages addObject:nav];
    }
    self.pages = pages; self.viewControllers = pages;
    self.tabBar.backgroundColor = UIColor.whiteColor; self.tabBar.tintColor = WBBlue();
    self.homeStack = [self pageContent:self.pages[0].topViewController];
    self.accountsStack = [self pageContent:self.pages[1].topViewController];
    self.settingsStack = [self pageContent:self.pages[2].topViewController];
    self.pages[1].topViewController.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"＋ 添加" style:UIBarButtonItemStylePlain target:self action:@selector(chooseRealm)];
    [self buildSettings]; [self render];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(enteredBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(enteredForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
}
- (BOOL)canOperate { return self.running && !self.busy && !self.backgrounded && !self.operationBusy; }
- (void)render {
    [self renderHome]; [self renderAccounts]; [self updateSettingsState];
}
- (void)renderHome {
    [self clear:self.homeStack];
    [self.homeStack addArrangedSubview:[self label:@"YOUR LOCAL GATEWAY" size:11 weight:UIFontWeightSemibold color:UIColor.secondaryLabelColor]];
    NSString *state = self.busy ? @"◌ 正在处理…" : self.running ? @"● 网关运行中" : @"○ 网关未启动";
    UIButton *toggle = [self button:self.busy ? @"请稍候…" : self.running ? @"■  停止网关" : @"▶  启动网关" action:^(GatewayController *s) { [s toggleGateway]; }];
    toggle.backgroundColor = UIColor.whiteColor; toggle.layer.cornerRadius = 13;
    toggle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter; toggle.enabled = !self.busy && !self.backgrounded;
    UIStackView *hero = [self card:@[
        [self label:state size:13 weight:UIFontWeightMedium color:[UIColor colorWithWhite:1 alpha:0.8]],
        [self label:@"连接，从本机开始" size:26 weight:UIFontWeightBold color:UIColor.whiteColor],
        [self label:@"OpenAI 兼容接口，安全留在本机。" size:14 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.85]],
        toggle,
        [self label:@"仅限前台运行 · 切入后台自动停止" size:12 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.8]]
    ] color:[UIColor colorWithRed:0.16 green:0.29 blue:0.62 alpha:1]];
    ((WBHeroStack *)hero).gradientEnabled = YES;
    hero.spacing = 16; [self.homeStack addArrangedSubview:hero];
    [self.homeStack addArrangedSubview:[self label:self.notice ?: @"" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
    UIButton *copyAll = [self button:@"接入信息                         复制全部 ↗" action:^(GatewayController *s) { [s copyConnection:0]; }];
    copyAll.enabled = [self canOperate]; [self.homeStack addArrangedSubview:copyAll];
    NSString *address = self.running && !self.busy ? [self.baseURL stringByAppendingString:@"/v1"] : @"启动网关后显示本机地址";
    UIButton *copyAddress = [self button:address action:^(GatewayController *s) { [s copyConnection:1]; }];
    UIButton *copyKey = [self button:self.running ? @"•••• •••• •••• ••••     复制密钥" : @"启动后可复制密钥" action:^(GatewayController *s) { [s copyConnection:2]; }];
    copyAddress.enabled = copyKey.enabled = [self canOperate];
    [self.homeStack addArrangedSubview:[self card:@[[self label:@"BASE URL" size:11 weight:UIFontWeightSemibold color:UIColor.secondaryLabelColor], copyAddress, [self divider], [self label:@"API KEY" size:11 weight:UIFontWeightSemibold color:UIColor.secondaryLabelColor], copyKey] color:nil]];
    NSString *counts = self.overview ? [NSString stringWithFormat:@"%@ / %@", WBNumber(self.overview[@"healthy"]), WBNumber(self.overview[@"total"])] : @"— / —";
    UIStackView *stats = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self card:@[[self label:@"可用账号" size:12 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor], [self label:counts size:24 weight:UIFontWeightBold color:UIColor.labelColor]] color:nil],
        [self card:@[[self label:@"配置存储" size:12 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor], [self label:self.config ? @"本机已保存" : @"启动后读取" size:17 weight:UIFontWeightSemibold color:UIColor.labelColor]] color:nil]
    ]]; stats.spacing = 12; stats.distribution = UIStackViewDistributionFillEqually;
    [self.homeStack addArrangedSubview:stats];
    UIButton *panel = [self button:@"高级管理面板  ›\n模型、用量与运行日志" action:^(GatewayController *s) { [s openPanel]; }];
    panel.enabled = [self canOperate]; [self.homeStack addArrangedSubview:[self card:@[panel] color:nil]];
}
- (void)renderAccounts {
    [self clear:self.accountsStack];
    [self.accountsStack addArrangedSubview:[self label:@"PERSONAL ACCOUNTS" size:11 weight:UIFontWeightSemibold color:UIColor.secondaryLabelColor]];
    [self.accountsStack addArrangedSubview:[self card:@[
        [self label:@"只连接你自己的账号" size:18 weight:UIFontWeightSemibold color:WBBlue()],
        [self label:@"通过官方授权页登录，凭证保存在本机。" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]
    ] color:[UIColor colorWithRed:0.89 green:0.93 blue:1 alpha:1]]];
    self.pages[1].viewControllers.firstObject.navigationItem.rightBarButtonItem.enabled = [self canOperate] && !self.loginToken;
    NSString *message = !self.running ? @"网关未启动，请在首页启动后读取账号。" : self.operationBusy ? @"正在执行账号或配置操作…" : self.overviewFetching && !self.overview ? @"正在读取已授权账号…" : self.overviewError;
    if (message.length) [self.accountsStack addArrangedSubview:[self label:message size:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
    [self.accountsStack addArrangedSubview:[self label:self.notice ?: @"" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
    UIButton *refresh = [self button:@"已授权账号                       刷新列表 ↻" action:^(GatewayController *s) { [s refreshOverview]; }];
    refresh.enabled = [self canOperate] && !self.overviewFetching; [self.accountsStack addArrangedSubview:refresh];
    NSArray *accounts = [self.overview[@"accounts"] isKindOfClass:NSArray.class] ? self.overview[@"accounts"] : @[];
    if (self.running && self.overview && !accounts.count) {
        [self.accountsStack addArrangedSubview:[self card:@[[self label:@"还没有授权账号" size:18 weight:UIFontWeightSemibold color:UIColor.labelColor], [self label:@"添加本人账号后，即可在此查看额度与运行状态。" size:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]] color:nil]];
    }
    for (id entry in accounts) {
        NSDictionary *a = WBDict(entry); NSString *uid = WBText(a[@"uid"]); if (!uid.length) continue;
        BOOL paused = WBBool(a[@"paused"]), disabled = WBBool(a[@"disabled"]), cooling = WBBool(a[@"cooling"]);
        NSString *status = disabled ? @"不可用" : paused ? @"已暂停" : cooling ? @"冷却中" : @"可用";
        NSString *realm = [WBText(a[@"realm"]) isEqualToString:@"global"] ? @"国际账号" : @"国内账号";
        NSString *name = WBText(a[@"nickname"]); if (!name.length) name = uid;
        UIButton *balance = [self button:@"刷新额度" action:^(GatewayController *s) { [s account:uid operation:@"balance"]; }];
        UIButton *pause = [self button:paused ? @"恢复" : @"暂停" action:^(GatewayController *s) { [s account:uid operation:paused ? @"resume" : @"pause"]; }];
        UIButton *remove = [self button:@"移除" action:^(GatewayController *s) { [s confirmRemoval:uid name:name]; }];
        remove.tintColor = UIColor.systemRedColor;
        UIButtonConfiguration *red = remove.configuration; red.baseForegroundColor = UIColor.systemRedColor; remove.configuration = red;
        balance.enabled = pause.enabled = remove.enabled = [self canOperate];
        UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[balance, pause, remove]];
        actions.distribution = UIStackViewDistributionFillEqually; actions.spacing = 8;
        NSMutableArray *rows = [NSMutableArray arrayWithArray:@[
            [self label:[NSString stringWithFormat:@"W  %@", name] size:19 weight:UIFontWeightSemibold color:UIColor.labelColor],
            [self label:[NSString stringWithFormat:@"%@%@ · %@", realm, WBBool(a[@"enterprise"]) ? @" · 企业版" : @"", status] size:13 weight:UIFontWeightMedium color:disabled ? UIColor.systemRedColor : WBBlue()],
            [self divider],
            [self label:[NSString stringWithFormat:@"剩余额度  %@ / %@", WBNumber(a[@"credits"]), WBNumber(a[@"credits_total"])] size:16 weight:UIFontWeightSemibold color:UIColor.labelColor],
            [self label:[NSString stringWithFormat:@"在途请求  %@\n凭证位置  此设备 · 排除备份", WBNumber(a[@"in_flight"])] size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]
        ]];
        NSString *reason = disabled ? WBText(a[@"disabled_reason"]) : cooling ? WBText(a[@"reason"]) : @"";
        if (reason.length) [rows addObject:[self label:reason size:13 weight:UIFontWeightRegular color:UIColor.systemOrangeColor]];
        if (cooling) [rows addObject:[self label:[NSString stringWithFormat:@"冷却剩余 %@ 秒", WBNumber(a[@"cool_remaining_sec"])] size:12 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
        [rows addObject:actions]; [self.accountsStack addArrangedSubview:[self card:rows color:nil]];
    }
    NSString *authTitle = self.loginToken ? @"等待官方授权结果…" : @"开始官方授权  ↗";
    UIButton *add = [self button:authTitle action:^(GatewayController *s) { [s chooseRealm]; }];
    add.enabled = [self canOperate] && !self.loginToken;
    NSMutableArray *authRows = [NSMutableArray arrayWithArray:@[
        [self label:@"添加账号" size:18 weight:UIFontWeightSemibold color:UIColor.labelColor],
        [self label:@"1  选择国内版或国际版\n\n2  在系统浏览器视图完成本人授权\n\n3  返回此页，等待授权结果" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor], add
    ]];
    if (self.loginToken) [authRows addObject:[self button:@"取消等待" action:^(GatewayController *s) { [s cancelLogin]; s.notice = @"已取消等待，可重新发起授权。"; [s render]; }]];
    [self.accountsStack addArrangedSubview:[self card:authRows color:nil]];
    [self.accountsStack addArrangedSubview:[self label:@"授权期间保持应用前台；重启网关后需重新发起。\n上游 OAuth 与推理服务可用性仍待验证。" size:12 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
}
- (UITextField *)field:(NSString *)placeholder numeric:(BOOL)numeric {
    UITextField *field = [UITextField new]; field.placeholder = placeholder;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; field.borderStyle = UITextBorderStyleRoundedRect;
    field.keyboardType = numeric ? UIKeyboardTypeNumberPad : UIKeyboardTypeASCIICapable;
    field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [field addTarget:self action:@selector(configEdited) forControlEvents:UIControlEventEditingChanged]; return field;
}
- (UIView *)limitControl:(UITextField *)field {
    UIStepper *stepper = [UIStepper new]; stepper.minimumValue = 1; stepper.maximumValue = 64; stepper.stepValue = 1;
    stepper.value = MAX(1, MIN(64, field.text.integerValue));
    __weak UITextField *weakField = field;
    __weak UIStepper *weakStepper = stepper;
    [stepper addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        UIStepper *sender = (UIStepper *)action.sender;
        weakField.text = [NSString stringWithFormat:@"%.0f", sender.value]; [weakField sendActionsForControlEvents:UIControlEventEditingChanged];
    }] forControlEvents:UIControlEventValueChanged];
    [field addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        weakStepper.value = MAX(1, MIN(64, weakField.text.integerValue));
    }] forControlEvents:UIControlEventEditingChanged];
    stepper.accessibilityLabel = field == self.accountLimit ? @"调整账号并发上限" : @"调整国际版单账号并发上限";
    if (field == self.accountLimit) self.accountStepper = stepper; else self.globalStepper = stepper;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[field, stepper]]; row.spacing = 12; row.alignment = UIStackViewAlignmentCenter;
    return row;
}
- (void)buildSettings {
    [self.settingsStack addArrangedSubview:[self label:@"GATEWAY PREFERENCES" size:11 weight:UIFontWeightSemibold color:UIColor.secondaryLabelColor]];
    self.settingsMessage = [self label:@"启动网关后读取设置。" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    [self.settingsStack addArrangedSubview:self.settingsMessage];
    self.keyField = [self field:@"API 密钥" numeric:NO]; self.keyField.secureTextEntry = YES;
    self.keyField.textContentType = UITextContentTypePassword;
    [self.settingsStack addArrangedSubview:[self label:@"安全与接入" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
    [self.settingsStack addArrangedSubview:[self card:@[[self label:@"API 密钥" size:15 weight:UIFontWeightMedium color:UIColor.labelColor], self.keyField, [self divider], [self label:@"监听范围                     仅本机 · 固定" size:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]] color:nil]];
    self.accountLimit = [self field:@"1–64" numeric:YES]; self.globalLimit = [self field:@"1–64" numeric:YES]; self.cooldownField = [self field:@"例如 10m、30s、1h（≤24h）" numeric:NO];
    self.preferExpiring = [UISwitch new]; self.preferExpiring.onTintColor = WBBlue();
    [self.preferExpiring addTarget:self action:@selector(configEdited) forControlEvents:UIControlEventValueChanged];
    UIStackView *switchRow = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:@"优先使用临期额度" size:15 weight:UIFontWeightRegular color:UIColor.labelColor], self.preferExpiring]];
    switchRow.spacing = 8; switchRow.alignment = UIStackViewAlignmentCenter;
    [self.settingsStack addArrangedSubview:[self label:@"请求与调度" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
    [self.settingsStack addArrangedSubview:[self card:@[
        [self label:@"账号并发上限" size:15 weight:UIFontWeightRegular color:UIColor.labelColor], [self limitControl:self.accountLimit], [self divider],
        [self label:@"国际版单账号并发上限" size:15 weight:UIFontWeightRegular color:UIColor.labelColor], [self limitControl:self.globalLimit], [self divider],
        [self label:@"限流冷却时间" size:15 weight:UIFontWeightRegular color:UIColor.labelColor], self.cooldownField, [self divider], switchRow
    ] color:nil]];
    [self.settingsStack addArrangedSubview:[self label:@"高级" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
    [self.settingsStack addArrangedSubview:[self card:@[
        [self button:@"完整 JSON 配置  ›" action:^(GatewayController *s) { [s openJSON]; }], [self divider],
        [self button:@"关于与开源许可  ›" action:^(GatewayController *s) { [s openLicense]; }]
    ] color:nil]];
    self.saveButton = [self button:@"保存设置" action:^(GatewayController *s) { [s saveForm]; }];
    [self.settingsStack addArrangedSubview:self.saveButton];
    [self.settingsStack addArrangedSubview:[self button:@"重新读取配置" action:^(GatewayController *s) { [s confirmReloadConfig]; }]];
    [self.settingsStack addArrangedSubview:[self label:@"保存后立即生效 · 不提供后台常驻选项" size:12 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
    self.pages[2].topViewController.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStylePlain target:self action:@selector(saveForm)];
}
- (void)configEdited {
    if (!self.fillingConfig) { self.configDirty = YES; self.configNotice = @"有未保存的修改"; [self updateSettingsState]; }
}
- (void)updateSettingsState {
    BOOL enabled = [self canOperate] && self.config && !self.configFetching;
    for (UITextField *field in @[self.keyField, self.accountLimit, self.globalLimit, self.cooldownField]) field.enabled = enabled;
    self.preferExpiring.enabled = enabled; self.accountStepper.enabled = enabled; self.globalStepper.enabled = enabled; self.saveButton.enabled = enabled;
    self.pages[2].viewControllers.firstObject.navigationItem.rightBarButtonItem.enabled = enabled;
    self.settingsMessage.text = !self.running ? @"网关未启动，启动后读取与保存配置。" : self.operationBusy ? @"正在保存或执行操作…" : self.configFetching ? @"正在读取配置…" : self.configNotice ?: @"配置仅保存在此设备。";
}
- (void)fillConfig:(NSDictionary *)config {
    self.config = config; self.fillingConfig = YES;
    self.keyField.text = WBText(config[@"api_key"]);
    NSDictionary *pool = WBDict(config[@"pool"]);
    self.accountLimit.text = WBNumber(pool[@"max_in_flight"]); self.globalLimit.text = WBNumber(pool[@"max_in_flight_global"]);
    self.accountStepper.value = self.accountLimit.text.integerValue; self.globalStepper.value = self.globalLimit.text.integerValue;
    self.cooldownField.text = WBText(WBDict(config[@"cooldown"])[@"soft_rate"]);
    self.preferExpiring.on = WBBool(pool[@"prefer_expiring"]);
    self.configDirty = NO; self.fillingConfig = NO; [self updateSettingsState]; [self renderHome];
}
- (void)request:(NSString *)path method:(NSString *)method body:(NSDictionary *)body completion:(void (^)(NSDictionary *, NSString *))completion {
    if (!self.running || self.busy || self.backgrounded || !self.session) { completion(nil, @"请先启动网关。"); return; }
    NSUInteger generation = self.generation; NSURLSession *session = self.session;
    NSString *base = self.baseURL;
    NSData *payload = body ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : nil;
    if (body && !payload) { completion(nil, @"请求 JSON 无效。"); return; }
    // Read the current key on the same serial queue as Start/Stop. Never block UIKit on Go's lock.
    dispatch_async(self.engineQueue, ^{
        NSString *key = MobileAPIKey();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation || !self.running || self.busy || self.backgrounded) return;
            if (!key.length) { completion(nil, @"未取得本机密钥，请重新启动网关。"); return; }
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]];
            request.HTTPMethod = method; request.timeoutInterval = 45; request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
            [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
            [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
            if (payload) { request.HTTPBody = payload; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; }
            [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSDictionary *result = data ? WBDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
                NSInteger code = [(NSHTTPURLResponse *)response statusCode];
                NSString *failure = error ? @"本机请求失败或超时，请重试。" : nil;
                if (!failure && (code < 200 || code >= 300 || [result[@"ok"] isEqual:@NO])) {
                    failure = WBText(result[@"error"]); if (!failure.length) failure = [NSString stringWithFormat:@"请求失败（HTTP %ld）", (long)code];
                }
                if (!failure && !result.count) failure = @"服务返回了无效响应。";
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation == self.generation && self.running && !self.busy && !self.backgrounded) completion(result, failure);
                });
            }] resume];
        });
    });
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // A loopback API redirect must never forward its Bearer to another origin.
    completionHandler(nil);
}
- (void)refreshOverview {
    if (![self canOperate] || self.overviewFetching) return;
    self.overviewFetching = YES; [self renderAccounts];
    [self request:@"/panel/api/overview" method:@"GET" body:nil completion:^(NSDictionary *result, NSString *error) {
        self.overviewFetching = NO; self.overviewError = error;
        if (!error) self.overview = result;
        if (error) self.notice = [@"账号概况读取失败：" stringByAppendingString:error];
        [self renderHome]; [self renderAccounts];
    }];
}
- (void)loadConfig {
    if (![self canOperate] || self.configFetching) return;
    self.configFetching = YES; [self updateSettingsState];
    [self request:@"/panel/api/config" method:@"GET" body:nil completion:^(NSDictionary *result, NSString *error) {
        self.configFetching = NO;
        if (!error && ![result[@"config"] isKindOfClass:NSDictionary.class]) error = @"配置响应格式无效。";
        self.configNotice = error ?: @"已读取本机配置。";
        // A GET started before typing must not replace the user's draft.
        if (!error && !self.configDirty) [self fillConfig:result[@"config"]];
        [self updateSettingsState];
    }];
}
- (void)confirmReloadConfig {
    if (![self canOperate] || self.configFetching) return;
    if (!self.configDirty) { [self loadConfig]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"放弃未保存的修改？" message:@"重新读取会用本机已保存配置替换表单。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重新读取" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { self.configDirty = NO; [self loadConfig]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSDictionary *)formConfig {
    NSString *key = self.keyField.text ?: @"";
    NSCharacterSet *trim = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if (!key.length || ![[key stringByTrimmingCharactersInSet:trim] isEqualToString:key] || [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4096 || [key rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n\t"]].location != NSNotFound) {
        self.configNotice = @"API 密钥不能为空、含首尾空白或换行，且不能超过 4096 字节。"; [self updateSettingsState]; return nil;
    }
    NSCharacterSet *notDigit = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    for (UITextField *field in @[self.accountLimit, self.globalLimit]) {
        NSString *text = field.text ?: @"";
        if (!text.length || [text rangeOfCharacterFromSet:notDigit].location != NSNotFound || text.length > 2 || text.integerValue < 1 || text.integerValue > 64) {
            self.configNotice = @"并发上限必须为 1–64 的整数。"; [self updateSettingsState]; return nil;
        }
    }
    if (!self.cooldownField.text.length) { self.configNotice = @"请输入冷却时间，例如 10m。"; [self updateSettingsState]; return nil; }
    NSMutableDictionary *out = [self.config mutableCopy]; if (!out) return nil;
    out[@"api_key"] = key;
    NSMutableDictionary *pool = [WBDict(out[@"pool"]) mutableCopy];
    pool[@"max_in_flight"] = @(self.accountLimit.text.integerValue); pool[@"max_in_flight_global"] = @(self.globalLimit.text.integerValue); pool[@"prefer_expiring"] = @(self.preferExpiring.on); out[@"pool"] = pool;
    NSMutableDictionary *cooldown = [WBDict(out[@"cooldown"]) mutableCopy]; cooldown[@"soft_rate"] = self.cooldownField.text; out[@"cooldown"] = cooldown;
    return out;
}
- (void)saveForm {
    [self.view endEditing:YES]; if (![self canOperate] || !self.config || self.configFetching) return;
    NSDictionary *config = [self formConfig]; if (config) [self saveConfig:config fromJSON:NO];
}
- (void)saveConfig:(NSDictionary *)config fromJSON:(BOOL)fromJSON {
    if (![self canOperate]) return;
    self.operationBusy = YES; self.jsonEditor.editable = NO;
    self.jsonController.navigationItem.rightBarButtonItem.enabled = NO;
    self.jsonMessage.text = @"正在校验并保存…"; [self render];
    [self request:@"/panel/api/config" method:@"POST" body:config completion:^(NSDictionary *result, NSString *error) {
        self.operationBusy = NO; self.jsonEditor.editable = YES;
        self.jsonController.navigationItem.rightBarButtonItem.enabled = YES;
        self.configNotice = error ?: @"已保存到本机，并立即生效。";
        self.jsonMessage.text = self.configNotice;
        if (!error) {
            self.configDirty = NO;
            self.config = nil; // Keep stale fields disabled until the authoritative GET succeeds.
            self.notice = @"配置已保存，接入密钥以新配置为准。";
            [self loadConfig];
            // Both native requests and the original panel now use MobileAPIKey's new value.
            if (self.web) [self refreshPanelKey];
            if (fromJSON && self.pages[2].topViewController == self.jsonController) [self.pages[2] popViewControllerAnimated:YES];
        }
        [self render];
    }];
}
- (void)openJSON {
    if (![self canOperate] || !self.config || self.configFetching) { self.configNotice = @"请先启动网关并读取配置。"; [self updateSettingsState]; return; }
    NSDictionary *draft = [self formConfig]; if (!draft) return;
    UIViewController *page = [UIViewController new]; page.title = @"完整 JSON 配置"; self.jsonController = page;
    UIStackView *stack = [self pageContent:page];
    self.jsonMessage = [self label:@"仅支持 mobile 配置字段；服务端严格校验，失败时保留输入。配置中含密钥，请勿分享。" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    self.jsonEditor = [UITextView new]; self.jsonEditor.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.jsonEditor.autocorrectionType = UITextAutocorrectionTypeNo; self.jsonEditor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.jsonEditor.smartQuotesType = UITextSmartQuotesTypeNo; self.jsonEditor.smartDashesType = UITextSmartDashesTypeNo;
    self.jsonEditor.backgroundColor = UIColor.whiteColor; self.jsonEditor.layer.cornerRadius = 12;
    self.jsonEditor.text = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:draft options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding];
    [self.jsonEditor.heightAnchor constraintGreaterThanOrEqualToConstant:420].active = YES;
    [stack addArrangedSubview:self.jsonMessage]; [stack addArrangedSubview:self.jsonEditor];
    page.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStylePlain target:self action:@selector(saveJSON)];
    [self.pages[2] pushViewController:page animated:YES];
}
- (void)saveJSON {
    [self.view endEditing:YES]; if (![self canOperate]) return;
    NSError *error = nil;
    id config = [NSJSONSerialization JSONObjectWithData:[self.jsonEditor.text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
    if (error || ![config isKindOfClass:NSDictionary.class]) { self.jsonMessage.text = @"JSON 格式无效：请输入单个配置对象。"; return; }
    [self saveConfig:config fromJSON:YES];
}
- (void)openLicense {
    UIViewController *page = [UIViewController new]; page.title = @"关于与开源许可";
    UIStackView *stack = [self pageContent:page];
    NSString *version = WBText([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
    [stack addArrangedSubview:[self label:[NSString stringWithFormat:@"WorkBuddy %@\niOS 本机网关 · 独立应用分支", version] size:20 weight:UIFontWeightSemibold color:UIColor.labelColor]];
    NSURL *url = [NSBundle.mainBundle URLForResource:@"LICENSE" withExtension:@"txt"];
    NSString *license = url ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] : nil;
    [stack addArrangedSubview:[self label:license ?: @"未找到打包的 LICENSE.txt，请检查应用资源。" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor]];
    [self.pages[self.selectedIndex] pushViewController:page animated:YES];
}
- (void)account:(NSString *)uid operation:(NSString *)operation {
    if (![self canOperate]) return;
    NSString *encoded = [uid stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"]];
    self.operationBusy = YES; [self render];
    [self request:[NSString stringWithFormat:@"/panel/api/accounts/%@/%@", encoded, operation] method:@"POST" body:@{} completion:^(NSDictionary *result, NSString *error) {
        self.operationBusy = NO;
        NSString *fileError = WBText(result[@"file_error"]);
        self.notice = error ?: (fileError.length ? @"账号已出池，但凭证文件删除失败，重启后可能重新出现。" : @"账号操作成功。");
        self.overviewError = error ?: (fileError.length ? self.notice : nil);
        [self render]; [self refreshOverview];
        if (fileError.length || error) [self alert:@"账号操作结果" message:self.notice];
    }];
}
- (void)confirmRemoval:(NSString *)uid name:(NSString *)name {
    if (![self canOperate]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"移除账号？" message:[NSString stringWithFormat:@"将从本机账号池移除“%@”并删除凭证。再次使用需重新授权。", name] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self account:uid operation:@"remove"]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)alert:(NSString *)title message:(NSString *)message {
    if (self.presentedViewController || self.backgrounded) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)chooseRealm {
    if (![self canOperate] || self.loginToken || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加本人账号" message:@"选择官方授权区域。授权期间请保持应用前台。" preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *realm in @[@"cn", @"global"]) {
        [alert addAction:[UIAlertAction actionWithTitle:[realm isEqualToString:@"cn"] ? @"国内版" : @"国际版" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self startLogin:realm]; }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)startLogin:(NSString *)realm {
    if (![self canOperate] || self.loginToken) return;
    self.operationBusy = YES; [self render];
    [self request:@"/panel/api/login/start" method:@"POST" body:@{@"realm":realm} completion:^(NSDictionary *result, NSString *error) {
        self.operationBusy = NO;
        NSString *state = WBText(result[@"state"]); NSURL *url = [NSURL URLWithString:WBText(result[@"url"])];
        if (!error && (!state.length || ![self allowedAuthorizationURL:url])) error = @"服务未返回有效的官方授权地址或 state。";
        if (error) { self.notice = error; [self render]; [self alert:@"无法发起授权" message:error]; return; }
        self.loginState = state; self.loginToken = NSUUID.UUID.UUIDString; self.loginDeadline = [NSDate dateWithTimeIntervalSinceNow:15 * 60];
        self.notice = @"等待官方授权，请在浏览器视图中完成登录。";
        [self openAuthorization:url]; [self scheduleLoginPoll]; [self render];
    }];
}
- (void)scheduleLoginPoll {
    [self.loginTimer invalidate]; self.loginTimer = nil;
    if (!self.loginToken || self.backgrounded || !self.running) return;
    __weak GatewayController *weakSelf = self;
    self.loginTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) { [weakSelf pollLogin]; }];
}
- (void)pollLogin {
    if (!self.loginToken || self.polling || !self.running || self.busy || self.backgrounded) return;
    if (self.loginDeadline.timeIntervalSinceNow <= 0) { [self cancelLogin]; self.notice = @"授权已超时，请重新添加账号。"; [self render]; return; }
    if (self.operationBusy) { [self scheduleLoginPoll]; return; }
    NSString *token = self.loginToken;
    NSURLComponents *components = [NSURLComponents new]; components.path = @"/panel/api/login/poll";
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"state" value:self.loginState]];
    self.polling = YES;
    [self request:components.string method:@"GET" body:nil completion:^(NSDictionary *result, NSString *error) {
        if (![self.loginToken isEqualToString:token]) return;
        self.polling = NO;
        if (error) { [self cancelLogin]; self.notice = [@"授权查询失败，请重新发起：" stringByAppendingString:error]; [self render]; if (!self.browser) [self alert:@"授权未完成" message:self.notice]; return; }
        if (WBBool(result[@"done"])) {
            [self cancelLogin]; self.notice = @"本人账号已授权并保存在本机。";
            if (self.browser) { [self.browser dismissViewControllerAnimated:YES completion:nil]; self.browser = nil; }
            [self render]; [self refreshOverview];
        } else { [self scheduleLoginPoll]; }
    }];
}
- (void)cancelLogin {
    [self.loginTimer invalidate]; self.loginTimer = nil;
    self.loginState = nil; self.loginToken = nil; self.loginDeadline = nil; self.polling = NO;
}
- (BOOL)allowedAuthorizationURL:(NSURL *)url {
    NSSet *hosts = [NSSet setWithArray:@[@"copilot.tencent.com", @"www.codebuddy.cn", @"codebuddy.cn", @"www.workbuddy.cn", @"workbuddy.cn", @"www.workbuddy.ai", @"workbuddy.ai"]];
    return [url.scheme.lowercaseString isEqualToString:@"https"] && [hosts containsObject:url.host.lowercaseString] && !url.user && !url.password && (!url.port || url.port.integerValue == 443);
}
- (void)openAuthorization:(NSURL *)url {
    if (![self allowedAuthorizationURL:url] || !self.running || self.backgrounded) { self.notice = @"已拦截非预期的授权地址。"; [self renderHome]; return; }
    if (self.presentedViewController) return;
    SFSafariViewController *browser = [[SFSafariViewController alloc] initWithURL:url]; browser.delegate = self; self.browser = browser;
    [self presentViewController:browser animated:YES completion:nil];
}
- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    self.browser = nil;
    if (self.loginToken) { self.notice = @"浏览器已关闭，正在等待授权结果；也可取消后重试。"; [self pollLogin]; }
    else if (self.running) [self refreshOverview];
    [self render];
}
- (void)toggleGateway {
    if (self.busy || self.backgrounded) return;
    if (self.running) { [self stopGateway]; return; }
    self.stopRequested = NO;
    self.busy = YES; self.notice = @"正在启动本机网关…"; [self render];
    dispatch_async(self.engineQueue, ^{
        NSError *error = nil;
        NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
        NSURL *directory = [support URLByAppendingPathComponent:@"WorkBuddy" isDirectory:YES];
        BOOL created = directory && [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error];
        if (created) [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        NSString *base = created ? MobileStart(directory.path, &error) : nil;
        NSString *key = base.length ? MobileAPIKey() : nil;
        if (base.length && !key.length) MobileStop();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (!base.length || !key.length) { self.notice = error.localizedDescription ?: @"启动失败：未取得本机密钥。"; [self finishBackgroundTask]; [self render]; return; }
            self.baseURL = base; self.running = YES; self.generation++;
            NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            configuration.URLCache = nil; configuration.HTTPCookieStorage = nil; configuration.URLCredentialStorage = nil;
            self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
            self.notice = @"运行中 · 仅本机可访问；切入后台会停止。";
            if (self.backgrounded || self.stopRequested) { [self stopGateway]; return; }
            [self render]; [self refreshOverview]; [self loadConfig];
            __weak GatewayController *weakSelf = self;
            self.overviewTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) { [weakSelf refreshOverview]; }];
        });
    });
}
- (void)stopGateway {
    if (self.busy || !self.running) return;
    self.busy = YES; self.generation++;
    [self.overviewTimer invalidate]; self.overviewTimer = nil; [self cancelLogin];
    [self.session invalidateAndCancel]; self.session = nil;
    self.operationBusy = self.overviewFetching = self.configFetching = NO;
    [self.web stopLoading]; [self.web loadHTMLString:@"<p>网关已停止，请返回首页启动。</p>" baseURL:nil];
    [self.web.configuration.userContentController removeAllUserScripts];
    self.web = nil;
    for (UINavigationController *nav in self.pages) [nav popToRootViewControllerAnimated:NO];
    self.panelController = nil; self.jsonEditor.text = @""; self.jsonEditor = nil; self.jsonController = nil; self.jsonMessage = nil;
    if (self.browser) { [self.browser dismissViewControllerAnimated:NO completion:nil]; self.browser = nil; }
    self.overview = nil; self.overviewError = nil; self.config = nil;
    self.keyField.text = self.accountLimit.text = self.globalLimit.text = self.cooldownField.text = @""; self.configDirty = NO;
    self.notice = @"正在停止并保存…"; [self render];
    dispatch_async(self.engineQueue, ^{
        MobileStop();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.running = NO; self.busy = NO; self.baseURL = nil;
            self.notice = @"已停止 · 配置与本人账号保存在本机";
            [self finishBackgroundTask]; [self render];
        });
    });
}
- (void)finishBackgroundTask {
    if (self.backgroundTask != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask]; self.backgroundTask = UIBackgroundTaskInvalid; }
}
- (void)enteredBackground {
    self.backgrounded = YES;
    if (self.running || self.busy) {
        self.stopRequested = YES;
        if (self.backgroundTask == UIBackgroundTaskInvalid) {
            self.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"SaveGateway" expirationHandler:^{ [self finishBackgroundTask]; }];
        }
        [self stopGateway];
    }
}
- (void)enteredForeground {
    self.backgrounded = NO;
    if (!self.running && !self.busy) self.notice = @"已返回前台，请启动网关；授权需重新发起。";
    [self render];
}
- (void)copyConnection:(NSInteger)part {
    if (![self canOperate]) return;
    NSUInteger generation = self.generation; NSString *base = self.baseURL;
    dispatch_async(self.engineQueue, ^{
        NSString *key = MobileAPIKey();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation || ![self canOperate] || !key.length) return;
            NSString *text = part == 1 ? [base stringByAppendingString:@"/v1"] : part == 2 ? key : [NSString stringWithFormat:@"Base URL: %@/v1\nAPI Key: %@", base, key];
            [UIPasteboard.generalPasteboard setItems:@[@{UIPasteboardTypeAutomatic:text}] options:@{UIPasteboardOptionLocalOnly:@YES, UIPasteboardOptionExpirationDate:[NSDate dateWithTimeIntervalSinceNow:120]}];
            self.notice = @"已复制（仅本机剪贴板，2 分钟后过期）。"; [self renderHome];
        });
    });
}
- (void)openPanel {
    if (![self canOperate]) return;
    UIViewController *page = [UIViewController new]; page.title = @"高级管理面板"; self.panelController = page;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new]; configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration]; self.web.navigationDelegate = self; self.web.UIDelegate = self;
    page.view = self.web; [self.pages[0] pushViewController:page animated:YES]; [self refreshPanelKey];
}
- (void)refreshPanelKey {
    NSUInteger generation = self.generation; WKWebView *web = self.web;
    dispatch_async(self.engineQueue, ^{
        NSString *key = MobileAPIKey();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self.generation && [self canOperate] && web == self.web && key.length) [self loadPanelWithKey:key];
        });
    });
}
- (void)loadPanelWithKey:(NSString *)key {
    WKUserContentController *scripts = self.web.configuration.userContentController; [scripts removeAllUserScripts];
    NSString *script = [NSString stringWithFormat:@"if(location.origin===%@){localStorage.setItem('wb2api.key',%@);}", [self JSONString:self.baseURL], [self JSONString:key]];
    [scripts addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    NSString *gatewayUI = @"if(location.pathname.startsWith('/panel/')){const style=document.createElement('style'); style.textContent='[data-view=taskscenter],#view-taskscenter,#compBox,#btnCheckinAll,#btnTravelAll,#btnActivityAll,#btnKeepaliveAll,[data-a=checkin],[data-a=tasks],[data-tab=import]{display:none!important}'; document.head.appendChild(style);}";
    [scripts addUserScript:[[WKUserScript alloc] initWithSource:gatewayUI injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    NSString *configScript = [NSString stringWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"gateway-config" withExtension:@"js"] encoding:NSUTF8StringEncoding error:nil];
    if (configScript) [scripts addUserScript:[[WKUserScript alloc] initWithSource:configScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[self.baseURL stringByAppendingString:@"/panel/"]]]];
}
- (NSString *)JSONString:(NSString *)value {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""] options:0 error:nil];
    NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}
- (BOOL)isPanelURL:(NSURL *)url {
    NSURL *base = [NSURL URLWithString:self.baseURL ?: @""];
    return self.running && !self.busy && [url.scheme isEqualToString:@"http"] && [url.host isEqualToString:@"127.0.0.1"] && [url.port isEqual:base.port] && !url.user && !url.password && [url.path hasPrefix:@"/panel/"];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSURL *url = action.request.URL;
    if ([self isPanelURL:url] || [url.absoluteString isEqualToString:@"about:blank"]) { handler(WKNavigationActionPolicyAllow); return; }
    handler(WKNavigationActionPolicyCancel);
    if (action.navigationType == WKNavigationTypeLinkActivated) [self openAuthorization:url];
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (!action.targetFrame) [self openAuthorization:action.request.URL]; return nil;
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled && self.running) { self.notice = @"高级面板加载失败，可返回首页重新打开。"; [self renderHome]; }
}
- (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController {
    if (self.selectedIndex == 2 && !self.configDirty && self.pages[2].topViewController == self.pages[2].viewControllers.firstObject) [self loadConfig];
    if (self.selectedIndex < 2) [self refreshOverview];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self]; [self.overviewTimer invalidate]; [self.loginTimer invalidate]; [self.session invalidateAndCancel];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController = [GatewayController new]; [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
