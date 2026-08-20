#import "MPRootViewController.h"
#import "../MiaoReport.h"
#import <notify.h>
#import <sys/stat.h>

static NSString *const kMPSbCmdPath = @"/var/mobile/Documents/miao-sbcmd.txt";
static NSString *const kMPSbCmdFallback =
	@"/var/mobile/Library/Preferences/com.noxlab.miao.sbcmd.txt";

/// I comandi vanno a SpringBoard, che e' l'unico che puo' aprire Safari e
/// scandire la sessione. Stesso bus del tweak: file piu' notifica.
static void MPSend(NSString *line, const char *note) {
	NSString *body = [NSString stringWithFormat:@"%@\n%.0f", line,
		[[NSDate date] timeIntervalSince1970]];
	for (NSString *path in @[ kMPSbCmdPath, kMPSbCmdFallback ]) {
		NSString *dir = [path stringByDeletingLastPathComponent];
		[[NSFileManager defaultManager] createDirectoryAtPath:dir
								  withIntermediateDirectories:YES attributes:nil error:nil];
		[body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
	}
	notify_post(note);
}

@interface MPRootViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UISegmentedControl *count;
@property (nonatomic, strong) UIStackView *personas;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) NSArray<MiaoRunReport *> *sessions;
@property (nonatomic, strong) NSMutableSet<NSString *> *expanded;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *diagLine;
@end

@implementation MPRootViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Miao";
	self.expanded = [NSMutableSet set];
	self.sessions = @[];
	self.diagLine = @"";

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

- (UIButton *)personaButton:(NSString *)title mood:(NSString *)mood {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	UIButtonConfiguration *cfg = [UIButtonConfiguration grayButtonConfiguration];
	cfg.title = title;
	cfg.cornerStyle = UIButtonConfigurationCornerStyleMedium;
	cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 10, 8, 10);
	cfg.titleTextAttributesTransformer =
		^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *incoming) {
			NSMutableDictionary *m = [incoming mutableCopy] ?: [NSMutableDictionary dictionary];
			m[NSFontAttributeName] = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
			return m;
		};
	b.configuration = cfg;
	b.accessibilityIdentifier = mood;
	[b addTarget:self action:@selector(startPersona:) forControlEvents:UIControlEventTouchUpInside];
	return b;
}

- (void)buildHeader {
	self.header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 310)];

	self.status = [UILabel new];
	self.status.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
	self.status.textColor = UIColor.secondaryLabelColor;
	self.status.numberOfLines = 4;
	self.status.translatesAutoresizingMaskIntoConstraints = NO;

	self.count = [[UISegmentedControl alloc] initWithItems:@[ @"1", @"3", @"5", @"10", @"50", @"700" ]];
	self.count.selectedSegmentIndex = 0;
	self.count.translatesAutoresizingMaskIntoConstraints = NO;

	UIButton *b0 = [self personaButton:@"Curioso" mood:@"curious"];
	UIButton *b1 = [self personaButton:@"Casual" mood:@"casual"];
	UIButton *b2 = [self personaButton:@"Mirato" mood:@"focused"];
	UIButton *b3 = [self personaButton:@"Click ads+" mood:@"clickall"];
	UIButton *b4 = [self personaButton:@"Sessione lunga" mood:@"videolong"];
	UIButton *b5 = [self personaButton:@"Maratona 700" mood:@"mix"];

	UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[ b0, b1, b2 ]];
	row1.axis = UILayoutConstraintAxisHorizontal;
	row1.distribution = UIStackViewDistributionFillEqually;
	row1.spacing = 8;

	UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[ b3, b4 ]];
	row2.axis = UILayoutConstraintAxisHorizontal;
	row2.distribution = UIStackViewDistributionFillEqually;
	row2.spacing = 8;

	UIStackView *row3 = [[UIStackView alloc] initWithArrangedSubviews:@[ b5 ]];
	row3.axis = UILayoutConstraintAxisHorizontal;
	row3.distribution = UIStackViewDistributionFillEqually;
	row3.spacing = 8;

	self.personas = [[UIStackView alloc] initWithArrangedSubviews:@[ row1, row2, row3 ]];
	self.personas.axis = UILayoutConstraintAxisVertical;
	self.personas.spacing = 8;
	self.personas.translatesAutoresizingMaskIntoConstraints = NO;

	[self.header addSubview:self.status];
	[self.header addSubview:self.count];
	[self.header addSubview:self.personas];
	[NSLayoutConstraint activateConstraints:@[
		[self.status.topAnchor constraintEqualToAnchor:self.header.topAnchor constant:6],
		[self.status.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor constant:20],
		[self.status.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor constant:-20],
		[self.count.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:10],
		[self.count.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor constant:20],
		[self.count.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor constant:-20],
		[self.personas.topAnchor constraintEqualToAnchor:self.count.bottomAnchor constant:12],
		[self.personas.leadingAnchor constraintEqualToAnchor:self.header.leadingAnchor constant:20],
		[self.personas.trailingAnchor constraintEqualToAnchor:self.header.trailingAnchor constant:-20],
		[self.personas.bottomAnchor constraintEqualToAnchor:self.header.bottomAnchor constant:-10],
	]];
	self.table.tableHeaderView = self.header;
}

- (void)buildToolbar {
	self.navigationController.toolbarHidden = NO;
	UIBarButtonItem *stop = [[UIBarButtonItem alloc] initWithTitle:@"Stop"
															style:UIBarButtonItemStylePlain
														   target:self action:@selector(stop)];
	UIBarButtonItem *link = [[UIBarButtonItem alloc] initWithTitle:@"Collega PC"
															 style:UIBarButtonItemStylePlain
															target:self action:@selector(enableSSH)];
	UIBarButtonItem *diag = [[UIBarButtonItem alloc] initWithTitle:@"Diagnosi"
															 style:UIBarButtonItemStylePlain
															target:self action:@selector(diagnose)];
	UIBarButtonItem *flex = [[UIBarButtonItem alloc]
		initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
	UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"Pulisci"
															 style:UIBarButtonItemStylePlain
															target:self action:@selector(clear)];
	self.toolbarItems = @[ stop, flex, link, flex, diag, flex, clear ];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
		initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
							 target:self action:@selector(reload)];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	self.navigationController.toolbarHidden = NO;
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
	CGFloat w = self.table.bounds.size.width;
	CGSize sz = [self.header systemLayoutSizeFittingSize:CGSizeMake(w, UILayoutFittingCompressedSize.height)];
	CGFloat h = MAX(310, sz.height);
	if (fabs(self.header.frame.size.height - h) > 0.5 ||
		fabs(self.header.frame.size.width - w) > 0.5) {
		self.header.frame = CGRectMake(0, 0, w, h);
		self.table.tableHeaderView = self.header;
	}
}

#pragma mark - Comandi

- (NSInteger)chosenCount {
	NSArray *vals = @[ @1, @3, @5, @10, @50, @700 ];
	NSInteger i = self.count.selectedSegmentIndex;
	if (i < 0 || i >= (NSInteger)vals.count) return 1;
	return [vals[(NSUInteger)i] integerValue];
}

- (void)startPersona:(UIButton *)sender {
	NSString *mood = sender.accessibilityIdentifier ?: @"casual";
	NSInteger n = [self chosenCount];
	if ([mood isEqualToString:@"mix"]) n = 700;
	MPSend([NSString stringWithFormat:@"session %ld %@", (long)n, mood],
		"com.noxlab.miao.session");
	self.diagLine = [NSString stringWithFormat:@"Avvio %ld × %@", (long)n, mood];
	[self updateStatus];
}

- (void)stop {
	MPSend(@"stop", "com.noxlab.miao.stop");
	self.diagLine = @"Stop inviato";
	[self updateStatus];
}

/// Un tap: scrive la chiave SSH del PC cosi' Cursor puo' leggere i log.
- (void)enableSSH {
	static NSString *const kPub =
		@"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9JlrtHJ8hZHmO3vV9OiiHmdS3LFoEpUXibCyyxvMNe miao-ci\n";
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray<NSString *> *okPaths = [NSMutableArray array];
	NSMutableArray<NSString *> *errs = [NSMutableArray array];

	NSArray *homes = @[
		@"/var/mobile",
		@"/var/jb/var/mobile",
	];
	for (NSString *home in homes) {
		BOOL isDir = NO;
		if (![fm fileExistsAtPath:home isDirectory:&isDir] || !isDir) continue;
		NSString *sshDir = [home stringByAppendingPathComponent:@".ssh"];
		NSError *e = nil;
		[fm createDirectoryAtPath:sshDir withIntermediateDirectories:YES attributes:nil error:&e];
		if (e) {
			[errs addObject:[NSString stringWithFormat:@"%@: %@", sshDir, e.localizedDescription]];
			continue;
		}
		NSString *ak = [sshDir stringByAppendingPathComponent:@"authorized_keys"];
		NSError *we = nil;
		[kPub writeToFile:ak atomically:YES encoding:NSUTF8StringEncoding error:&we];
		if (we) {
			[errs addObject:[NSString stringWithFormat:@"%@: %@", ak, we.localizedDescription]];
			continue;
		}
		chmod(sshDir.fileSystemRepresentation, 0700);
		chmod(ak.fileSystemRepresentation, 0600);
		[okPaths addObject:ak];
	}

	NSString *msg;
	if (okPaths.count) {
		msg = [NSString stringWithFormat:
			@"Fatto.\n\nChiave scritta in:\n%@\n\nTieni OpenSSH installato. Dal PC posso leggere le sessioni.",
			[okPaths componentsJoinedByString:@"\n"]];
		self.diagLine = [NSString stringWithFormat:@"SSH ok (%lu path)", (unsigned long)okPaths.count];
	} else {
		msg = [NSString stringWithFormat:
			@"Non sono riuscito a scrivere la chiave.\n%@",
			errs.count ? [errs componentsJoinedByString:@"\n"] : @"Nessun path mobile trovato"];
		self.diagLine = @"SSH: scrittura fallita";
	}
	UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Collega PC"
															   message:msg
														preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
	[self updateStatus];
}

- (void)diagnose {
	MiaoReportDiag *d = MiaoReportDiagnose();
	self.diagLine = d.summary ?: @"?";
	NSString *msg = [NSString stringWithFormat:
		@"%@\n\nprimario: %@\nfallback: %@\nattivo: %@\nbyte: %llu  righe: %ld  sessioni: %ld\nleggi: %@  scrivi: %@\nerr: %@",
		d.summary ?: @"?",
		d.primaryPath, d.fallbackPath, d.activePath,
		d.bytes, (long)d.lineCount, (long)d.sessionCount,
		d.canRead ? @"si" : @"NO", d.canWrite ? @"si" : @"NO",
		d.lastError.length ? d.lastError : @"—"];
	UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Diagnosi storage"
															   message:msg
														preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
	[self reload];
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
		self.diagLine = @"Storico cancellato";
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
	NSMutableString *s = [NSMutableString string];
	if (!self.sessions.count) {
		/* Niente scrittura di prova al refresh automatico: solo lettura. */
		BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:kMiaoEventsPath];
		unsigned long long bytes = [[[NSFileManager defaultManager]
			attributesOfItemAtPath:kMiaoEventsPath error:nil] fileSize];
		NSString *fb = @"/var/mobile/Library/Preferences/com.noxlab.miao.events.jsonl";
		unsigned long long fbBytes = [[[NSFileManager defaultManager]
			attributesOfItemAtPath:fb error:nil] fileSize];
		if (!exists && fbBytes == 0) {
			[s appendString:@"Nessun file eventi: sandbox o tweak non ha scritto. Tocca Diagnosi."];
		} else if (bytes == 0 && fbBytes == 0) {
			[s appendString:@"File eventi vuoto. Avvia una persona, poi tira per aggiornare."];
		} else {
			[s appendFormat:@"File %llu/%llu byte ma 0 sessioni. Tocca Diagnosi.",
				bytes, fbBytes];
		}
	} else {
		NSInteger ok = 0, done = 0;
		MiaoRunReport *last = self.sessions.firstObject;
		for (MiaoRunReport *r in self.sessions) {
			if (r.end <= 0) continue;
			done++;
			if (r.ok) ok++;
		}
		NSString *now = last.end > 0 ? @"" : @" · una in corso";
		[s appendFormat:@"%ld complete, %ld riuscite%@", (long)done, (long)ok, now];
	}
	[s appendString:@"\nQuante sessioni · scegli persona:"];
	if (self.diagLine.length) [s appendFormat:@"\n%@", self.diagLine];
	self.status.text = s;
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
