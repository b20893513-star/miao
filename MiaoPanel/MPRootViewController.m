#import "MPRootViewController.h"
#import "../MiaoReport.h"
#import <notify.h>

static NSString *const kMPSbCmdPath = @"/var/mobile/Documents/miao-sbcmd.txt";

/// I comandi vanno a SpringBoard, che e' l'unico che puo' aprire Safari e
/// scandire la sessione. Stesso bus del tweak: file piu' notifica.
static void MPSend(NSString *line, const char *note) {
	NSString *body = [NSString stringWithFormat:@"%@\n%.0f", line,
		[[NSDate date] timeIntervalSince1970]];
	[body writeToFile:kMPSbCmdPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	notify_post(note);
}

@interface MPRootViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UISegmentedControl *count;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) NSArray<MiaoRunReport *> *sessions;
@property (nonatomic, strong) NSMutableSet<NSString *> *expanded;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation MPRootViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Miao";
	self.expanded = [NSMutableSet set];
	self.sessions = @[];

	self.table = [[UITableView alloc] initWithFrame:self.view.bounds
											  style:UITableViewStyleInsetGrouped];
	self.table.dataSource = self;
	self.table.delegate = self;
	self.table.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.table];
	[NSLayoutConstraint activateConstraints:@[
		[self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];

	UIRefreshControl *rc = [UIRefreshControl new];
	[rc addTarget:self action:@selector(pulled:) forControlEvents:UIControlEventValueChanged];
	self.table.refreshControl = rc;

	[self buildHeader];
	[self buildToolbar];
	[self reload];
}

- (void)buildHeader {
	self.header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 96)];

	self.status = [UILabel new];
	self.status.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
	self.status.textColor = UIColor.secondaryLabelColor;
	self.status.numberOfLines = 2;
	self.status.translatesAutoresizingMaskIntoConstraints = NO;

	self.count = [[UISegmentedControl alloc] initWithItems:@[ @"1", @"3", @"5", @"10", @"25", @"50" ]];
	self.count.selectedSegmentIndex = 0;
	self.count.translatesAutoresizingMaskIntoConstraints = NO;

	[self.header addSubview:self.status];
	[self.header addSubview:self.count];
	[NSLayoutConstraint activateConstraints:@[
		[self.status.topAnchor constraintEqualToAnchor:self.header.topAnchor constant:6],
		[self.status.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor constant:20],
		[self.status.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor constant:-20],
		[self.count.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:10],
		[self.count.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor constant:20],
		[self.count.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor constant:-20],
	]];
	self.table.tableHeaderView = self.header;
}

- (void)buildToolbar {
	self.navigationController.toolbarHidden = NO;
	UIBarButtonItem *go = [[UIBarButtonItem alloc] initWithTitle:@"Avvia"
														  style:UIBarButtonItemStyleDone
														 target:self action:@selector(start)];
	UIBarButtonItem *stop = [[UIBarButtonItem alloc] initWithTitle:@"Stop"
															style:UIBarButtonItemStylePlain
														   target:self action:@selector(stop)];
	UIBarButtonItem *flex = [[UIBarButtonItem alloc]
		initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
	UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"Pulisci"
															 style:UIBarButtonItemStylePlain
															target:self action:@selector(clear)];
	self.toolbarItems = @[ go, flex, stop, flex, clear ];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
		initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
							 target:self action:@selector(reload)];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	self.navigationController.toolbarHidden = NO;
	// il tweak scrive mentre guardiamo: senza refresh la lista resta indietro
	__weak __typeof(self) weakSelf = self;
	self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES
												  block:^(__unused NSTimer *t) { [weakSelf reload]; }];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self.timer invalidate];
	self.timer = nil;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	CGFloat h = 96;
	if (self.header.frame.size.height != h ||
		self.header.frame.size.width != self.table.bounds.size.width) {
		self.header.frame = CGRectMake(0, 0, self.table.bounds.size.width, h);
		self.table.tableHeaderView = self.header;
	}
}

#pragma mark - Comandi

- (NSInteger)chosenCount {
	NSArray *vals = @[ @1, @3, @5, @10, @25, @50 ];
	NSInteger i = self.count.selectedSegmentIndex;
	if (i < 0 || i >= (NSInteger)vals.count) return 1;
	return [vals[(NSUInteger)i] integerValue];
}

- (void)start {
	NSInteger n = [self chosenCount];
	MPSend([NSString stringWithFormat:@"session %ld", (long)n], "com.noxlab.miao.session");
	self.status.text = [NSString stringWithFormat:@"Avviate %ld sessioni, il resto lo fa SpringBoard", (long)n];
}

- (void)stop {
	MPSend(@"stop", "com.noxlab.miao.stop");
	self.status.text = @"Stop inviato";
}

- (void)clear {
	UIAlertController *a = [UIAlertController
		alertControllerWithTitle:@"Pulisci risultati"
						 message:@"Cancella lo storico delle sessioni sul dispositivo."
				  preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
	[a addAction:[UIAlertAction actionWithTitle:@"Cancella" style:UIAlertActionStyleDestructive
									   handler:^(__unused UIAlertAction *x) {
		MiaoReportClear();
		[self reload];
	}]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)pulled:(UIRefreshControl *)rc {
	[self reload];
	[rc endRefreshing];
}

#pragma mark - Dati

- (void)reload {
	self.sessions = MiaoReportRead(30);
	[self updateStatus];
	[self.table reloadData];
}

- (void)updateStatus {
	if (!self.sessions.count) {
		BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:kMiaoEventsPath];
		self.status.text = exists ? @"Nessuna sessione registrata."
								 : @"Nessun dato: il tweak non ha ancora scritto, o l'app non legge il file.";
		return;
	}
	NSInteger ok = 0, done = 0;
	MiaoRunReport *last = self.sessions.firstObject;
	for (MiaoRunReport *r in self.sessions) {
		if (r.end <= 0) continue;
		done++;
		if (r.ok) ok++;
	}
	NSString *now = last.end > 0 ? @"" : @" · una in corso";
	self.status.text = [NSString stringWithFormat:@"%ld complete, %ld riuscite%@\nQuante sessioni avviare:",
		(long)done, (long)ok, now];
}

- (MiaoRunReport *)sessionAt:(NSInteger)section {
	if (section < 0 || section >= (NSInteger)self.sessions.count) return nil;
	return self.sessions[(NSUInteger)section];
}

- (BOOL)isExpanded:(MiaoRunReport *)r {
	return r.sid.length && [self.expanded containsObject:r.sid];
}

#pragma mark - Tabella

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
	return (NSInteger)self.sessions.count;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
	MiaoRunReport *r = [self sessionAt:section];
	if (!r) return 0;
	return 1 + ([self isExpanded:r] ? (NSInteger)r.steps.count : 0);
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	MiaoRunReport *r = [self sessionAt:ip.section];
	UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
	if (!cell)
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
	cell.detailTextLabel.numberOfLines = 2;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	cell.textLabel.font = [UIFont systemFontOfSize:16];
	cell.detailTextLabel.font = [UIFont systemFontOfSize:12];

	if (ip.row == 0) {
		NSString *verdict = r.verdict.length ? r.verdict : (r.end > 0 ? @"senza verdetto" : @"in corso");
		NSString *mark = r.end <= 0 ? @"…" : (r.ok ? @"OK" : @"KO");
		cell.textLabel.text = [NSString stringWithFormat:@"%@ — %@", mark, verdict];
		cell.textLabel.textColor = r.end <= 0 ? UIColor.secondaryLabelColor
											  : (r.ok ? UIColor.systemGreenColor : UIColor.systemRedColor);

		static NSDateFormatter *df = nil;
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			df = [NSDateFormatter new];
			df.dateFormat = @"HH:mm:ss";
		});
		NSString *when = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:r.start]];
		NSString *dur = r.end > 0 ? [NSString stringWithFormat:@"%.1f s", [r durationMs] / 1000.0] : @"—";
		cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %lu passi · %ld falliti · seed %08x",
			when, dur, (unsigned long)r.steps.count, (long)[r failedCount], r.seed];
		cell.accessoryType = [self isExpanded:r] ? UITableViewCellAccessoryNone
												 : UITableViewCellAccessoryDisclosureIndicator;
		return cell;
	}

	MiaoStepInfo *s = r.steps[(NSUInteger)(ip.row - 1)];
	cell.textLabel.text = [NSString stringWithFormat:@"%@ %@ · %.0f ms",
		s.ok ? @"✓" : @"✕", s.name, s.ms];
	cell.textLabel.textColor = s.ok ? UIColor.labelColor : UIColor.systemRedColor;
	cell.detailTextLabel.text = s.detail.length ? s.detail : @"";
	cell.accessoryType = UITableViewCellAccessoryNone;
	return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	if (ip.row != 0) return;
	MiaoRunReport *r = [self sessionAt:ip.section];
	if (!r.sid.length) return;
	if ([self.expanded containsObject:r.sid]) [self.expanded removeObject:r.sid];
	else [self.expanded addObject:r.sid];
	[tv reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)ip.section]
	  withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end
