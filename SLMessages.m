// Send Later 1.0.0 - SLMessages.m: everything the user sees in Messages (DESIGN.md sections 1 and 5).
//
// Touch and hold Send -> sheet: "Send Later..." (SLScheduleController, a date picker) and
// "Scheduled Messages (N)" (SLListController, this chat's queue). The queue is SLStore.m; SpringBoard
// (SLSender.m) does the timed sending. Main thread only. Logs: id tails, counts, lengths, states and
// lookup paths; never text, titles, handles or chat ids (DESIGN 6).

#import "SLShared.h"

#define SLM_HOLD_SECONDS        0.5
#define SLM_PICKER_PORTRAIT     216.0f
#define SLM_PICKER_LANDSCAPE    162.0f      // iOS 6 pickers take 162 / 180 / 216
#define SLM_GROUPED_INSET       20.0f       // iPhone grouped cell: 10 pt each side
#define SLM_PAD                 10.0f
#define SLM_TEXT_LINES          4           // schedule screen
#define SLM_LIST_LINES          6           // list rows
#define SLM_PUT_TRIES           4           // Send Now: extra tries to keep a failed item
#define SLM_PUT_RETRY           1.0         // s between them

static NSString * const SLMFooter = @"Your iPhone sends it at this time, even if Messages is closed. It needs to be on, with a connection.";
static NSString * const SLMGone = @"This message was already sent.";

static char kSLMHoldKey;                    // on a CKMessageEntryView: our recognizer is attached
static Class gSLMEntryClass;                // CKMessageEntryView
static Ivar gSLMSendIvar;                   // its _sendButton (NULL: touch and hold is off)

typedef enum {
    SLMChangeDone,
    SLMChangeGone,                          // not in the queue any more (SpringBoard sent it meanwhile)
    SLMChangeFailed                         // queue busy / not written: nothing changed
} SLMChange;

@class SLScheduleController;
// fire nil = Cancel. Return NO to keep the sheet open (the change could not be saved).
typedef BOOL (^SLMScheduleDone)(SLScheduleController *controller, NSDate *fire);

static UIActionSheet *gSLMSheet;            // the hold sheet while it is up
static id gSLMSheetDelegate;                // its delegate (UIActionSheet delegates are assign)
static __weak UIViewController *gSLMModal;  // our navigation controller while presented on Messages

#pragma mark - Small helpers

static NSString *SLMChar(unichar c)
{
    return [NSString stringWithFormat:@"%C", c];
}

static NSString *SLMEllipsis(NSString *s)
{
    return [s stringByAppendingString:SLMChar(0x2026)];
}

static void SLMAlert(NSString *title, NSString *message)
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:nil
                                          cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
}

// respondsToSelector:, logging each missing class/selector pair once.
static BOOL SLMResponds(id obj, SEL sel)
{
    if (!obj) {
        return NO;
    }
    if ([obj respondsToSelector:sel]) {
        return YES;
    }
    static NSMutableSet *logged;
    if (!logged) {
        logged = [NSMutableSet set];
    }
    NSString *key = [NSString stringWithFormat:@"%@ %@", NSStringFromClass([obj class]), NSStringFromSelector(sel)];
    if (![logged containsObject:key]) {
        [logged addObject:key];
        SLLog(@"missing selector -[%@]", key);
    }
    return NO;
}

static NSString *SLMTail(NSString *itemID)
{
    return itemID.length ? SLIDTail(itemID) : @"????";
}

static BOOL SLMBusy(void)
{
    if (gSLMSheet.visible) {
        return YES;
    }
    UIViewController *modal = gSLMModal;
    return modal && (modal.presentingViewController || ([modal isViewLoaded] && modal.view.window));
}

static NSDate *SLMMinuteFloor(NSDate *date)
{
    NSTimeInterval t = floor([date timeIntervalSinceReferenceDate] / 60.0) * 60.0;
    return [NSDate dateWithTimeIntervalSinceReferenceDate:t];
}

// now + SL_MIN_LEAD, rounded up to a whole minute (the picker shows minutes; seconds are dropped).
static NSDate *SLMEarliestFire(void)
{
    NSTimeInterval t = ceil(([NSDate timeIntervalSinceReferenceDate] + SL_MIN_LEAD) / 60.0) * 60.0;
    return [NSDate dateWithTimeIntervalSinceReferenceDate:t];
}

static CGFloat SLMTextHeight(NSString *text, UIFont *font, CGFloat width, NSUInteger lines)
{
    if (!text.length || width <= 0.0f) {
        return 0.0f;
    }
    CGFloat maxHeight = ceilf(font.lineHeight * lines);
    CGSize size = [text sizeWithFont:font constrainedToSize:CGSizeMake(width, maxHeight)
                       lineBreakMode:NSLineBreakByWordWrapping];
    return MIN(maxHeight, ceilf(size.height));
}

static UIFont *SLMTimeFont(void)   { return [UIFont boldSystemFontOfSize:16.0f]; }
static UIFont *SLMStatusFont(void) { return [UIFont systemFontOfSize:14.0f]; }
static UIFont *SLMBodyFont(void)   { return [UIFont systemFontOfSize:15.0f]; }

// "Not Sent - <reason>" (en dash) for a failed item, nil for a scheduled one.
static NSString *SLMStatusText(NSDictionary *item)
{
    if (![[item objectForKey:SLKeyState] isEqual:SLStateFailed]) {
        return nil;
    }
    NSString *reason = [item objectForKey:SLKeyReason];
    if (![reason isKindOfClass:[NSString class]] || !reason.length) {
        return @"Not Sent";
    }
    return [NSString stringWithFormat:@"Not Sent %C %@", (unichar)0x2013, reason];
}

// Replaces the item's fire date only if it is still queued (SpringBoard may have sent it meanwhile;
// a plain put would bring it back and send it twice).
static SLMChange SLMReschedule(NSString *itemID, NSDate *fire)
{
    __block BOOL found = NO;
    BOOL ok = SLQueueUpdate(^NSArray *(NSArray *items) {
        found = NO;
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
        for (NSDictionary *item in items) {
            if (!found && [[item objectForKey:SLKeyID] isEqual:itemID]) {
                NSDictionary *changed = SLItemWithFire(item, fire);
                if (changed) {
                    found = YES;
                    [out addObject:changed];
                    continue;
                }
            }
            [out addObject:item];
        }
        return found ? out : items;
    });
    SLLog(@"change time %@: %@ (in %.0f s)", SLMTail(itemID),
          !ok ? @"queue write failed" : (found ? @"rescheduled" : @"already gone"), [fire timeIntervalSinceNow]);
    return !ok ? SLMChangeFailed : (found ? SLMChangeDone : SLMChangeGone);
}

// SLQueueRemove that tells "not there any more" from "could not write".
static SLMChange SLMRemove(NSString *itemID)
{
    __block BOOL found = NO;
    BOOL ok = SLQueueUpdate(^NSArray *(NSArray *items) {
        found = NO;
        NSMutableArray *rest = [NSMutableArray arrayWithCapacity:items.count];
        for (NSDictionary *item in items) {
            if (!found && [[item objectForKey:SLKeyID] isEqual:itemID]) {
                found = YES;
                continue;
            }
            [rest addObject:item];
        }
        return found ? rest : nil;
    });
    SLLog(@"list: delete %@: %@", SLMTail(itemID), !ok ? @"queue write failed" : (found ? @"removed" : @"already gone"));
    return !ok ? SLMChangeFailed : (found ? SLMChangeDone : SLMChangeGone);
}

// Alert for a Change Time / Delete that did not happen (nothing for SLMChangeDone).
static void SLMChangeAlert(SLMChange result, NSString *failedMessage)
{
    if (result == SLMChangeGone) {
        SLMAlert(@"Send Later", SLMGone);
    } else if (result == SLMChangeFailed) {
        SLMAlert(@"Send Later", failedMessage);
    }
}

// Send Now failed and the item has to go back as failed. A busy queue is retried a few times (strong
// reference to the item); if it still can't be kept, its text goes to the pasteboard so it isn't lost.
static void SLMKeepFailed(NSDictionary *item, int triesLeft)
{
    if (!item) {
        return;
    }
    NSString *tail = SLMTail([item objectForKey:SLKeyID]);
    if (SLQueuePut(item)) {
        if (triesLeft < SLM_PUT_TRIES) {
            SLLog(@"send now %@: kept as failed on a retry", tail);
        }
        return;
    }
    if (triesLeft > 0) {
        SLLog(@"send now %@: queue write failed, retry in %.0f s", tail, SLM_PUT_RETRY);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SLM_PUT_RETRY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SLMKeepFailed(item, triesLeft - 1);
        });
        return;
    }
    NSString *text = [item objectForKey:SLKeyText];
    BOOL copied = NO;
    if ([text isKindOfClass:[NSString class]] && text.length) {
        [UIPasteboard generalPasteboard].string = text;
        copied = YES;
    }
    SLLog(@"send now %@: could not keep it (copied %d)", tail, copied);
    SLMAlert(@"Send Later", copied
             ? @"The message couldn't be kept in Scheduled Messages. Its text was copied, so you can paste it and send it again."
             : @"The message couldn't be kept in Scheduled Messages.");
}

// The keyboard and the entry bar live in their own window above the app's, so the keyboard is put
// away first (as MessageWallpapers does) or it would cover the date picker / list.
static void SLMPresent(CKTranscriptController *tc, UIView *entryView, UIViewController *root)
{
    [entryView endEditing:YES];
    [[[UIApplication sharedApplication] keyWindow] endEditing:YES];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    gSLMModal = nav;
    [tc presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Schedule screen

@interface SLScheduleController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (id)initWithText:(NSString *)text fireDate:(NSDate *)fire changing:(BOOL)changing done:(SLMScheduleDone)done;
@end

@implementation SLScheduleController {
    NSString *_text;
    NSDate *_initialFire;
    BOOL _changing;
    BOOL _finished;
    SLMScheduleDone _done;
    UITableView *_table;
    UIDatePicker *_picker;
}

- (id)initWithText:(NSString *)text fireDate:(NSDate *)fire changing:(BOOL)changing done:(SLMScheduleDone)done
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _text = [text isKindOfClass:[NSString class]] ? [text copy] : @"";
        _initialFire = fire ?: SLDefaultFireDate();
        _changing = changing;
        _done = [done copy];
        self.title = changing ? @"Change Time" : @"Send Later";
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                          target:self action:@selector(slmCancel:)];
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:(changing ? @"Save" : @"Schedule")
                                             style:UIBarButtonItemStyleDone
                                            target:self action:@selector(slmDone:)];
    }
    return self;
}

- (void)loadView
{
    UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.backgroundColor = [UIColor groupTableViewBackgroundColor];
    CGRect b = view.bounds;

    _table = [[UITableView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, b.size.width, b.size.height - SLM_PICKER_PORTRAIT)
                                          style:UITableViewStyleGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [view addSubview:_table];

    _picker = [[UIDatePicker alloc] initWithFrame:CGRectMake(0.0f, b.size.height - SLM_PICKER_PORTRAIT,
                                                             b.size.width, SLM_PICKER_PORTRAIT)];
    _picker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _picker.datePickerMode = UIDatePickerModeDateAndTime;
    [self slmRefreshLimits];
    NSDate *start = SLMMinuteFloor(_initialFire);
    if ([start compare:_picker.minimumDate] == NSOrderedAscending) {
        start = _picker.minimumDate;
    } else if ([start compare:_picker.maximumDate] == NSOrderedDescending) {
        start = _picker.maximumDate;
    }
    [_picker setDate:start animated:NO];
    [_picker addTarget:self action:@selector(slmPickerChanged:) forControlEvents:UIControlEventValueChanged];
    [view addSubview:_picker];

    self.view = view;
}

// Picker docked at the bottom; the shorter iOS 6 picker height in landscape.
- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat height = (b.size.width > b.size.height) ? SLM_PICKER_LANDSCAPE : SLM_PICKER_PORTRAIT;
    _picker.frame = CGRectMake(0.0f, b.size.height - height, b.size.width, height);
    _table.frame = CGRectMake(0.0f, 0.0f, b.size.width, MAX(0.0f, b.size.height - height));
}

- (BOOL)shouldAutorotate
{
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation
{
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    [_table reloadData];    // the message row's height depends on the width
}

- (void)slmRefreshLimits
{
    NSDate *earliest = SLMEarliestFire();
    _picker.minimumDate = earliest;
    _picker.maximumDate = SLMMinuteFloor([NSDate dateWithTimeIntervalSinceNow:SL_MAX_LEAD]);
    if ([_picker.date compare:earliest] == NSOrderedAscending) {
        [_picker setDate:earliest animated:(_picker.window != nil)];
    }
}

- (NSDate *)slmChosenDate
{
    NSDate *fire = SLMMinuteFloor(_picker.date ?: _initialFire);
    NSDate *latest = [NSDate dateWithTimeIntervalSinceNow:SL_MAX_LEAD];
    if ([fire compare:latest] == NSOrderedDescending) {
        fire = SLMMinuteFloor(latest);
    }
    return fire;
}

- (void)slmUpdateSendRow
{
    UITableViewCell *cell = [_table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
    if (cell) {
        cell.detailTextLabel.text = SLFireString([self slmChosenDate]);
        [cell setNeedsLayout];
    }
}

- (void)slmPickerChanged:(UIDatePicker *)picker
{
    [self slmUpdateSendRow];
}

- (void)slmFinish:(NSDate *)fire
{
    _finished = YES;
    self.navigationItem.leftBarButtonItem.enabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    SLMScheduleDone done = _done;
    if (!done) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (done(self, fire) || !fire) {
        _done = nil;
        return;
    }
    // Not saved (the block showed why): stay open so the user can try again or cancel.
    _finished = NO;
    self.navigationItem.leftBarButtonItem.enabled = YES;
    self.navigationItem.rightBarButtonItem.enabled = YES;
}

- (void)slmCancel:(id)sender
{
    if (!_finished) {
        [self slmFinish:nil];
    }
}

- (void)slmDone:(id)sender
{
    if (_finished) {
        return;
    }
    NSDate *fire = [self slmChosenDate];
    if ([fire timeIntervalSinceNow] < SL_MIN_LEAD) {
        SLMAlert(@"Send Later", @"Choose a time at least a minute from now.");
        [self slmRefreshLimits];
        [self slmUpdateSendRow];
        return;
    }
    [self slmFinish:fire];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section != 0) {
        return 44.0f;
    }
    CGFloat width = tableView.bounds.size.width - SLM_GROUPED_INSET - 2.0f * SLM_PAD;
    return MAX(44.0f, SLMTextHeight(_text, SLMBodyFont(), width, SLM_TEXT_LINES) + 2.0f * SLM_PAD);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        static NSString * const textID = @"SLMText";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:textID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:textID];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = SLMBodyFont();
            cell.textLabel.textColor = [UIColor grayColor];
            cell.textLabel.numberOfLines = SLM_TEXT_LINES;
            cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        }
        cell.textLabel.text = _text;
        return cell;
    }
    static NSString * const sendID = @"SLMSend";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:sendID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:sendID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = @"Send";
    cell.detailTextLabel.text = SLFireString([self slmChosenDate]);
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 1 ? SLMFooter : nil;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}

- (void)dealloc
{
    _table.dataSource = nil;
    _table.delegate = nil;
}

@end

#pragma mark - Scheduled list

@interface SLMListCell : UITableViewCell
- (void)slmShowItem:(NSDictionary *)item;
@end

@implementation SLMListCell {
    UILabel *_time;
    UILabel *_status;
    UILabel *_body;
}

static UILabel *SLMMakeLabel(UIFont *font, UIColor *color, NSInteger lines)
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = font;
    label.textColor = color;
    label.highlightedTextColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor clearColor];
    label.numberOfLines = lines;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _time = SLMMakeLabel(SLMTimeFont(), [UIColor blackColor], 1);
        _status = SLMMakeLabel(SLMStatusFont(), [UIColor colorWithRed:0.85f green:0.1f blue:0.1f alpha:1.0f], 2);
        _body = SLMMakeLabel(SLMBodyFont(), [UIColor grayColor], SLM_LIST_LINES);
        [self.contentView addSubview:_time];
        [self.contentView addSubview:_status];
        [self.contentView addSubview:_body];
    }
    return self;
}

- (void)slmShowItem:(NSDictionary *)item
{
    NSDate *fire = [item objectForKey:SLKeyFire];
    NSString *text = [item objectForKey:SLKeyText];
    NSString *status = SLMStatusText(item);
    _time.text = [fire isKindOfClass:[NSDate class]] ? SLFireString(fire) : @"";
    _status.text = status;
    _status.hidden = (status == nil);
    _body.text = [text isKindOfClass:[NSString class]] ? text : @"";
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat width = MAX(0.0f, b.size.width - 2.0f * SLM_PAD);
    CGFloat y = SLM_PAD;
    CGFloat h = ceilf(_time.font.lineHeight);
    _time.frame = CGRectMake(SLM_PAD, y, width, h);
    y += h;
    if (!_status.hidden) {
        h = SLMTextHeight(_status.text, _status.font, width, 2);
        _status.frame = CGRectMake(SLM_PAD, y + 2.0f, width, h);
        y += 2.0f + h;
    }
    h = MIN(SLMTextHeight(_body.text, _body.font, width, SLM_LIST_LINES), MAX(0.0f, b.size.height - SLM_PAD - y - 3.0f));
    _body.frame = CGRectMake(SLM_PAD, y + 3.0f, width, h);
}

@end

static CGFloat SLMListRowHeight(NSDictionary *item, CGFloat tableWidth)
{
    CGFloat width = tableWidth - SLM_GROUPED_INSET - 2.0f * SLM_PAD;
    CGFloat h = SLM_PAD + ceilf(SLMTimeFont().lineHeight);
    NSString *status = SLMStatusText(item);
    if (status) {
        h += 2.0f + SLMTextHeight(status, SLMStatusFont(), width, 2);
    }
    NSString *text = [item objectForKey:SLKeyText];
    if ([text isKindOfClass:[NSString class]] && text.length) {
        h += 3.0f + SLMTextHeight(text, SLMBodyFont(), width, SLM_LIST_LINES);
    }
    return MAX(44.0f, h + SLM_PAD);
}

@interface SLListController : UITableViewController <UIActionSheetDelegate>
- (id)initWithChatGUID:(NSString *)chatGUID chatID:(NSString *)chatID transcript:(CKTranscriptController *)tc;
@end

@implementation SLListController {
    NSString *_chatGUID;
    NSString *_chatID;
    __weak CKTranscriptController *_tc;
    NSArray *_items;
    int _notifyToken;
    BOOL _notifyRegistered;
    UIActionSheet *_sheet;
    NSString *_sheetItemID;
    NSInteger _sendIndex;
    NSInteger _changeIndex;
    NSInteger _deleteIndex;
}

- (id)initWithChatGUID:(NSString *)chatGUID chatID:(NSString *)chatID transcript:(CKTranscriptController *)tc
{
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _chatGUID = [chatGUID copy];
        _chatID = [chatID copy];
        _tc = tc;
        _items = SLQueueItemsForChat(_chatGUID, _chatID) ?: [NSArray array];
        self.title = @"Scheduled";
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:self action:@selector(slmDone:)];
        // Live updates when SpringBoard (or this list) changes the queue.
        __weak SLListController *weakSelf = self;
        uint32_t status = notify_register_dispatch(SL_NOTIFY_CHANGED, &_notifyToken, dispatch_get_main_queue(), ^(int token) {
            [weakSelf slmReload];
        });
        _notifyRegistered = (status == NOTIFY_STATUS_OK);
        if (!_notifyRegistered) {
            SLLog(@"list: notify_register_dispatch failed (%u)", status);
        }
        SLLog(@"list: %lu items", (unsigned long)_items.count);
    }
    return self;
}

- (void)dealloc
{
    if (_notifyRegistered) {
        notify_cancel(_notifyToken);
    }
    _sheet.delegate = nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self slmReload];
}

- (BOOL)shouldAutorotate
{
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation
{
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    [self.tableView reloadData];    // row heights depend on the width
}

- (void)slmReload
{
    NSArray *fresh = SLQueueItemsForChat(_chatGUID, _chatID) ?: [NSArray array];
    if ([fresh isEqualToArray:_items]) {
        return;     // e.g. the echo of our own write
    }
    _items = fresh;
    if ([self isViewLoaded]) {
        [self.tableView reloadData];
    }
}

- (NSDictionary *)slmItemWithID:(NSString *)itemID
{
    for (NSDictionary *item in _items) {
        if ([[item objectForKey:SLKeyID] isEqual:itemID]) {
            return item;
        }
    }
    return nil;
}

- (void)slmDone:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _items.count ? (NSInteger)_items.count : 1;     // 1 = the empty-state row
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= _items.count) {
        return 44.0f;
    }
    return SLMListRowHeight([_items objectAtIndex:(NSUInteger)indexPath.row], tableView.bounds.size.width);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row >= _items.count) {
        static NSString * const emptyID = @"SLMEmpty";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:emptyID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:emptyID];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = [UIColor grayColor];
            cell.textLabel.text = @"No Scheduled Messages";
        }
        return cell;
    }
    static NSString * const itemID = @"SLMItem";
    SLMListCell *cell = (SLMListCell *)[tableView dequeueReusableCellWithIdentifier:itemID];
    if (!cell) {
        cell = [[SLMListCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:itemID];
    }
    [cell slmShowItem:[_items objectAtIndex:(NSUInteger)indexPath.row]];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return (NSUInteger)indexPath.row < _items.count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSUInteger row = (NSUInteger)indexPath.row;
    if (editingStyle != UITableViewCellEditingStyleDelete || row >= _items.count) {
        return;
    }
    NSString *itemID = [[_items objectAtIndex:row] objectForKey:SLKeyID];
    SLMChange result = SLMRemove(itemID);
    BOOL removed = (result == SLMChangeDone);
    SLMChangeAlert(result, @"This message couldn't be deleted. Please try again.");
    NSMutableArray *expected = [_items mutableCopy];
    [expected removeObjectAtIndex:row];
    NSArray *fresh = SLQueueItemsForChat(_chatGUID, _chatID) ?: [NSArray array];
    _items = fresh;
    // Animate only when the table's model matches exactly; the last row becomes the empty-state row.
    if (removed && fresh.count && [fresh isEqualToArray:expected]) {
        [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [tableView reloadData];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSUInteger row = (NSUInteger)indexPath.row;
    if (row >= _items.count || _sheet) {
        return;
    }
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil
                                         destructiveButtonTitle:nil otherButtonTitles:nil];
    _sendIndex = [sheet addButtonWithTitle:@"Send Now"];
    _changeIndex = [sheet addButtonWithTitle:SLMEllipsis(@"Change Time")];
    _deleteIndex = [sheet addButtonWithTitle:@"Delete"];
    sheet.destructiveButtonIndex = _deleteIndex;
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
    _sheet = sheet;
    _sheetItemID = [[_items objectAtIndex:row] objectForKey:SLKeyID];
    [sheet showInView:self.navigationController.view ?: self.view];
}

#pragma mark Row actions

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    if (actionSheet != _sheet) {
        return;
    }
    _sheet.delegate = nil;
    _sheet = nil;
    NSString *itemID = _sheetItemID;
    _sheetItemID = nil;
    if (!itemID || buttonIndex < 0 || buttonIndex == actionSheet.cancelButtonIndex) {
        return;
    }
    if (buttonIndex == _sendIndex) {
        [self slmSendNow:itemID];
    } else if (buttonIndex == _changeIndex) {
        [self slmChangeTime:itemID];
    } else if (buttonIndex == _deleteIndex) {
        SLMChangeAlert(SLMRemove(itemID), @"This message couldn't be deleted. Please try again.");
        [self slmReload];
    }
}

- (void)slmSendNow:(NSString *)itemID
{
    NSDictionary *item = SLQueueTake(itemID);     // claim: SpringBoard can't send it now
    if (!item) {
        SLLog(@"send now %@: already gone", SLMTail(itemID));
        [self slmReload];
        return;
    }
    IMChat *chat = nil;
    NSString *how = nil;
    CKTranscriptController *tc = _tc;
    @try {
        CKConversation *conversation = SLMResponds(tc, @selector(conversation)) ? [tc conversation] : nil;
        IMChat *shown = SLMResponds(conversation, @selector(chat)) ? [conversation chat] : nil;
        NSString *guid = SLMResponds(shown, @selector(guid)) ? [shown guid] : nil;
        if (guid.length && [guid isEqual:[item objectForKey:SLKeyChatGUID]]) {
            chat = shown;
            how = @"transcript";
        }
    } @catch (NSException *e) {
        SLLog(@"send now: reading the transcript's chat threw %@", e.name);
    }
    if (!chat) {
        NSString *found = nil;
        chat = SLFindChat(item, &found, YES);
        how = found;
    }
    NSString *text = [item objectForKey:SLKeyText];
    NSString *reason = chat ? SLSendText(chat, text) : @"Conversation not found";
    if (!reason) {
        SLLog(@"send now %@: sent via %@ (%lu chars)", SLMTail(itemID), how ?: @"?", (unsigned long)text.length);
    } else {
        SLLog(@"send now %@: failed (chat %d)", SLMTail(itemID), chat != nil);
        SLMAlert(@"Couldn't Send", reason);
        SLMKeepFailed(SLItemWithState(item, SLStateFailed, reason) ?: item, SLM_PUT_TRIES);
    }
    [self slmReload];
}

- (void)slmChangeTime:(NSString *)itemID
{
    NSDictionary *item = [self slmItemWithID:itemID];
    if (!item) {
        [self slmReload];
        return;
    }
    NSDate *fire = [item objectForKey:SLKeyFire];
    NSDate *start = ([fire isKindOfClass:[NSDate class]] && [fire timeIntervalSinceNow] > 0.0) ? fire : SLDefaultFireDate();
    __weak SLListController *weakSelf = self;
    SLScheduleController *sc = [[SLScheduleController alloc] initWithText:[item objectForKey:SLKeyText]
                                                                  fireDate:start
                                                                  changing:YES
                                                                      done:^BOOL(SLScheduleController *controller, NSDate *date) {
        SLMChange result = date ? SLMReschedule(itemID, date) : SLMChangeDone;
        if (result == SLMChangeFailed) {
            SLMAlert(@"Send Later", @"The time couldn't be changed. Please try again.");
            return NO;
        }
        [controller dismissViewControllerAnimated:YES completion:^{
            [weakSelf slmReload];
            SLMChangeAlert(result, nil);
        }];
        return YES;
    }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sc];
    [self presentViewController:nav animated:YES completion:nil];
}

@end

#pragma mark - The hold sheet

@interface SLMMenu : NSObject <UIActionSheetDelegate>
@property (nonatomic, weak) CKTranscriptController *tc;
@property (nonatomic, weak) CKMessageEntryView *entryView;
@property (nonatomic, strong) CKConversation *conversation;
@property (nonatomic, strong) IMChat *chat;
@property (nonatomic, copy) NSString *chatGUID;
@property (nonatomic, copy) NSString *chatID;
@property (nonatomic, copy) NSString *chatTitle;
@property (nonatomic, copy) NSString *text;        // cleaned; nil when there is none
@property (nonatomic, assign) BOOL plainText;      // no attachments, no subject
@property (nonatomic, assign) NSInteger laterIndex;
@property (nonatomic, assign) NSInteger listIndex;
@end

@implementation SLMMenu

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    actionSheet.delegate = nil;
    if (gSLMSheet == actionSheet) {
        gSLMSheet = nil;
    }
    if (buttonIndex >= 0 && buttonIndex != actionSheet.cancelButtonIndex) {
        if (buttonIndex == self.laterIndex) {
            [self slmScheduleNew];
        } else if (buttonIndex == self.listIndex) {
            [self slmShowList];
        }
    }
    // Last: this may release self (anything still needed holds its own reference).
    if (gSLMSheetDelegate == self) {
        gSLMSheetDelegate = nil;
    }
}

- (CKTranscriptController *)slmLiveController
{
    CKTranscriptController *tc = self.tc;
    if (!tc || ![tc isViewLoaded] || !tc.view.window || tc.presentedViewController) {
        SLLog(@"sheet: the conversation is no longer on screen");
        return nil;
    }
    return tc;
}

- (void)slmScheduleNew
{
    if (!self.plainText) {
        SLMAlert(@"Send Later", @"Only plain text can be scheduled. Remove photos, videos and the subject first.");
        return;
    }
    CKTranscriptController *tc = [self slmLiveController];
    if (!tc || !self.text.length) {
        return;
    }
    SLMMenu *menu = self;
    SLScheduleController *sc = [[SLScheduleController alloc] initWithText:self.text
                                                                  fireDate:SLDefaultFireDate()
                                                                  changing:NO
                                                                      done:^BOOL(SLScheduleController *controller, NSDate *fire) {
        [menu slmFinishNew:controller fire:fire];
        return YES;
    }];
    SLMPresent(tc, self.entryView, sc);
}

- (void)slmFinishNew:(SLScheduleController *)controller fire:(NSDate *)fire
{
    if (!fire) {
        [controller dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    NSDictionary *item = SLMakeItem(self.chat, self.chatTitle, self.text, fire);
    BOOL added = item ? SLQueueAdd(item) : NO;
    NSString *itemID = [item objectForKey:SLKeyID];
    NSDate *itemFire = [item objectForKey:SLKeyFire] ?: fire;
    if (added) {
        SLLog(@"scheduled %@ (%lu chars, in %.0f s)", SLMTail(itemID), (unsigned long)self.text.length,
              [itemFire timeIntervalSinceNow]);
    } else {
        SLLog(@"schedule failed (item %d)", item != nil);
    }
    // The box is cleared only once the modal is gone and the entry bar is back on screen.
    [controller dismissViewControllerAnimated:YES completion:^{
        if (!added) {
            SLMAlert(@"Send Later", @"This message couldn't be scheduled. Please try again.");
            return;
        }
        [self slmClearEntry];
        SLMAlert([NSString stringWithFormat:@"Scheduled for %@.", SLFireString(itemFire)],
                 @"To see, change or cancel it, touch and hold Send.");
    }];
}

- (void)slmClearEntry
{
    CKTranscriptController *tc = self.tc;
    CKConversation *conversation = self.conversation;
    CKConversation *shown = SLMResponds(tc, @selector(conversation)) ? [tc conversation] : nil;
    if (!tc || !conversation || shown != conversation) {
        SLLog(@"clear: another conversation is showing now; box left as is");
        return;
    }
    CKMessageEntryView *entry = SLMResponds(tc, @selector(entryView)) ? [tc entryView] : nil;
    if (!entry) {
        entry = self.entryView;
    }
    CKContentEntryView *field = SLMResponds(entry, @selector(entryField)) ? [entry entryField] : nil;
    BOOL cleared = NO, draft = NO, notified = NO;
    @try {
        if (SLMResponds(field, @selector(clearMessage))) {
            [field clearMessage];
            cleared = YES;
        }
    } @catch (NSException *e) {
        SLLog(@"clear: clearMessage threw %@", e.name);
    }
    @try {
        if (SLMResponds(conversation, @selector(setUnsentComposition:))) {
            [conversation setUnsentComposition:nil];
            draft = YES;
        }
    } @catch (NSException *e) {
        SLLog(@"clear: setUnsentComposition: threw %@", e.name);
    }
    @try {
        if (field && SLMResponds(tc, @selector(entryFieldContentChanged:))) {
            [tc entryFieldContentChanged:field];     // Send button state, typing indicator
            notified = YES;
        }
    } @catch (NSException *e) {
        SLLog(@"clear: entryFieldContentChanged: threw %@", e.name);
    }
    SLLog(@"clear: field %d, draft %d, notified %d", cleared, draft, notified);
}

- (void)slmShowList
{
    CKTranscriptController *tc = [self slmLiveController];
    if (!tc) {
        return;
    }
    SLListController *list = [[SLListController alloc] initWithChatGUID:self.chatGUID chatID:self.chatID transcript:tc];
    SLMPresent(tc, self.entryView, list);
}

@end

static void SLMShowMenu(UIView *held)
{
    if (SLMBusy()) {
        return;
    }
    Class entryClass = NSClassFromString(@"CKMessageEntryView");
    UIView *view = held;            // the recognizer's view: the entry view itself
    while (view && !(entryClass && [view isKindOfClass:entryClass])) {
        view = view.superview;
    }
    if (!view) {
        SLLog(@"hold: no CKMessageEntryView");
        return;
    }
    CKMessageEntryView *entry = (CKMessageEntryView *)view;
    id delegate = SLMResponds(entry, @selector(delegate)) ? [entry delegate] : nil;
    Class tcClass = NSClassFromString(@"CKTranscriptController");
    if (!tcClass || ![delegate isKindOfClass:tcClass]) {
        SLLog(@"hold: the entry bar's delegate is not a CKTranscriptController");
        return;
    }
    CKTranscriptController *tc = delegate;
    if (![tc isViewLoaded] || !tc.view.window || tc.presentedViewController) {
        SLLog(@"hold: transcript not on screen or showing something");
        return;
    }

    CKConversation *conversation = nil;
    IMChat *chat = nil;
    NSString *chatGUID = nil, *chatID = nil, *title = nil, *text = nil;
    BOOL media = NO, subject = NO;
    @try {
        conversation = SLMResponds(tc, @selector(conversation)) ? [tc conversation] : nil;
        chat = SLMResponds(conversation, @selector(chat)) ? [conversation chat] : nil;
        chatGUID = SLMResponds(chat, @selector(guid)) ? [chat guid] : nil;
        chatID = SLMResponds(chat, @selector(chatIdentifier)) ? [chat chatIdentifier] : nil;
        id name = SLMResponds(conversation, @selector(name)) ? [conversation name] : nil;
        title = [name isKindOfClass:[NSString class]] ? name : nil;

        CKContentEntryView *field = SLMResponds(entry, @selector(entryField)) ? [entry entryField] : nil;
        CKMessageComposition *composition = SLMResponds(field, @selector(messageComposition)) ? [field messageComposition] : nil;
        id raw = SLMResponds(composition, @selector(textString)) ? [composition textString] : nil;
        if (![raw isKindOfClass:[NSString class]]) {
            raw = nil;
        }
        text = raw ? SLCleanText(raw) : nil;
        BOOL any = (text != nil);
        if (!any && [field respondsToSelector:@selector(hasContent)]) {
            any = [field hasContent];
        }
        // Attachments show up as U+FFFC in the text; isTextOnly covers the rest.
        if (raw && [raw rangeOfString:SLMChar(0xFFFC)].location != NSNotFound) {
            media = YES;
        }
        if (any && SLMResponds(composition, @selector(isTextOnly)) && ![composition isTextOnly]) {
            media = YES;
        }
        id subj = SLMResponds(composition, @selector(subject)) ? [composition subject] : nil;
        if ([subj isKindOfClass:[NSString class]] &&
            [[subj stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length]) {
            subject = YES;
        }
    } @catch (NSException *e) {
        SLLog(@"hold: reading the conversation threw %@", e.name);
    }

    BOOL content = text || media || subject;
    if (!chat || (!chatGUID.length && !chatID.length)) {
        SLLog(@"hold: no chat yet (content %d)", content);
        if (content) {
            SLMAlert(@"Send Later", @"Send Later works in an existing conversation. Send a first message, then try again.");
        }
        return;
    }
    NSArray *items = SLQueueItemsForChat(chatGUID, chatID);
    NSUInteger count = items.count;
    SLLog(@"hold: text %lu chars, media %d, subject %d, scheduled %lu", (unsigned long)text.length, media, subject,
          (unsigned long)count);
    if (!content && !count) {
        return;
    }

    SLMMenu *menu = [[SLMMenu alloc] init];
    menu.tc = tc;
    menu.entryView = entry;
    menu.conversation = conversation;
    menu.chat = chat;
    menu.chatGUID = chatGUID;
    menu.chatID = chatID;
    menu.chatTitle = title;
    menu.text = text;
    menu.plainText = !media && !subject;

    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:menu cancelButtonTitle:nil
                                         destructiveButtonTitle:nil otherButtonTitles:nil];
    menu.laterIndex = content ? [sheet addButtonWithTitle:SLMEllipsis(@"Send Later")] : -1;
    menu.listIndex = count ? [sheet addButtonWithTitle:[NSString stringWithFormat:@"Scheduled Messages (%lu)", (unsigned long)count]] : -1;
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
    gSLMSheet.delegate = nil;     // a stale sheet must never call a released delegate
    gSLMSheet = sheet;
    gSLMSheetDelegate = menu;
    [sheet showInView:tc.view];
}

#pragma mark - Recognizer

@interface SLMHoldTarget : NSObject <UIGestureRecognizerDelegate>
+ (SLMHoldTarget *)shared;
@end

@implementation SLMHoldTarget

+ (SLMHoldTarget *)shared
{
    static SLMHoldTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        target = [[SLMHoldTarget alloc] init];
    });
    return target;
}

// While our sheet or modal is up, Send behaves as stock.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    return !SLMBusy();
}

// The recognizer sits on the entry view: a disabled Send button is not the hit-test view (ChatKit's
// -hitTest:withEvent: returns the entry view for it), so a recognizer on the button would never see an
// empty-box hold. Only touches inside the live Send button are taken; everything else is stock.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    UIView *entryView = gestureRecognizer.view;
    if (!gSLMSendIvar || !gSLMEntryClass || ![entryView isKindOfClass:gSLMEntryClass]) {
        return NO;
    }
    id button = object_getIvar(entryView, gSLMSendIvar);
    if (![button isKindOfClass:[UIView class]] || [(UIView *)button isHidden] || ![(UIView *)button window]) {
        return NO;
    }
    UIView *sendButton = button;
    return CGRectContainsPoint(sendButton.bounds, [touch locationInView:sendButton]);
}

- (void)slmHeld:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        SLMShowMenu(recognizer.view);
    }
}

@end

#pragma mark - Entry points

// Runs in every -[CKMessageEntryView layoutSubviews]: an ivar read and an associated-object check,
// nothing that lays out or draws (MessageWallpapers styles this bar from the same hook).
void SLAttachToEntryView(CKMessageEntryView *entryView)
{
    static BOOL resolved;
    if (!resolved) {
        resolved = YES;
        gSLMEntryClass = NSClassFromString(@"CKMessageEntryView");
        Ivar ivar = gSLMEntryClass ? class_getInstanceVariable(gSLMEntryClass, "_sendButton") : NULL;
        const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        if (type && type[0] == '@') {
            gSLMSendIvar = ivar;
        } else {
            SLLog(@"no CKMessageEntryView._sendButton ivar (class %@): touch and hold is off",
                  gSLMEntryClass ? @"present" : @"missing");
        }
    }
    if (!gSLMSendIvar || !entryView || ![entryView isKindOfClass:gSLMEntryClass]
        || objc_getAssociatedObject(entryView, &kSLMHoldKey)) {
        return;
    }
    SLMHoldTarget *target = [SLMHoldTarget shared];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:target
                                                                                       action:@selector(slmHeld:)];
    hold.minimumPressDuration = SLM_HOLD_SECONDS;
    // The press that opens the sheet never sends: an enabled Send button is a descendant, so its tracking
    // is cancelled when the hold is recognized.
    hold.cancelsTouchesInView = YES;
    hold.delegate = target;         // takes only touches inside the Send button
    [(UIView *)entryView addGestureRecognizer:hold];
    objc_setAssociatedObject(entryView, &kSLMHoldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static BOOL logged;
    if (!logged) {
        logged = YES;
        id button = object_getIvar(entryView, gSLMSendIvar);
        SLLog(@"hold recognizer on the entry view (Send button %@)",
              button ? NSStringFromClass([button class]) : @"not made yet");
    }
}

// Deleting a conversation (not Clear All) cancels its scheduled messages: otherwise no list could show
// them again, and SpringBoard would send into a conversation the user removed.
void SLConversationWillDelete(CKConversation *conversation)
{
    NSString *guid = nil, *chatID = nil;
    @try {
        IMChat *chat = SLMResponds(conversation, @selector(chat)) ? [conversation chat] : nil;
        id rawGUID = SLMResponds(chat, @selector(guid)) ? [chat guid] : nil;
        id rawID = SLMResponds(chat, @selector(chatIdentifier)) ? [chat chatIdentifier] : nil;
        guid = ([rawGUID isKindOfClass:[NSString class]] && [rawGUID length]) ? rawGUID : nil;
        chatID = ([rawID isKindOfClass:[NSString class]] && [rawID length]) ? rawID : nil;
    } @catch (NSException *e) {
        SLLog(@"delete: reading the chat threw %@", e.name);
    }
    if (!guid && !chatID) {
        SLLog(@"delete: conversation without a chat, nothing to cancel");
        return;
    }
    BOOL ok = NO;
    NSUInteger removed = SLQueueRemoveForChat(guid, chatID, &ok);
    if (removed || !ok) {
        SLLog(@"delete: conversation removed, %lu scheduled cancelled%@", (unsigned long)removed,
              ok ? @"" : @" (queue write failed, kept)");
    }
}

void SLMessagesStart(void)
{
    Class entryClass = NSClassFromString(@"CKMessageEntryView");
    SLLog(@"Messages UI: CKMessageEntryView %@, CKTranscriptController %@, _sendButton %@",
          entryClass ? @"yes" : @"NO",
          NSClassFromString(@"CKTranscriptController") ? @"yes" : @"NO",
          (entryClass && class_getInstanceVariable(entryClass, "_sendButton")) ? @"yes" : @"NO");
}
