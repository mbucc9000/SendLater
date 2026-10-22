// Send Later 1.0.0 - SLSender.m: the SpringBoard scheduler (DESIGN.md section 4).
//
// One wake-capable PCPersistentTimer (NSTimer fallback) points at the earliest scheduled item (or write
// retry). When it fires, when the queue changes, and once 20 s after launch, a pass sends every due item:
// a power assertion is held, IMCore readiness is checked without blocking, and each item is claimed with
// SLQueueTake only once SLChatNotReady passes, right before SLSendText, so it is never sent twice. An item
// may wait for IMCore (5 s retries, 8 of its own at most); triggers that arrive meanwhile only mark the pass
// for a rerun. Failed items go back to the queue as failed and get one alert per pass. Everything runs on
// the main thread and nothing blocks.
//
// Logs: item id tails, counts, lengths, lookup paths, selector availability only (DESIGN 6).

#import "SLShared.h"
#include <dlfcn.h>

#define SLS_IMCORE_PATH     "/System/Library/PrivateFrameworks/IMCore.framework/IMCore"
#define SLS_PC_PATH         "/System/Library/PrivateFrameworks/PersistentConnection.framework/PersistentConnection"
#define SLS_IOKIT_PATH      "/System/Library/Frameworks/IOKit.framework/IOKit"
#define SLS_COALESCE        0.2     // s: a burst of queue notifications becomes one reschedule
#define SLS_DUE_SLACK       1.0     // s: an item this close to its time counts as due
#define SLS_ALERT_STALE     30.0    // s: an alert no longer visible after this is forgotten
#define SLS_WRITE_RETRY     (2.0 * SL_POWER_HOLD)  // s: a due item whose claim/write failed is tried again
#define SLS_ASSERT_LEVEL_ON 255     // kIOPMAssertionLevelOn

typedef int SLSIOReturn;
typedef SLSIOReturn (*SLSAssertCreateFn)(CFStringRef type, uint32_t level, CFStringRef name, uint32_t *assertionID);
typedef SLSIOReturn (*SLSAssertReleaseFn)(uint32_t assertionID);

@interface SLSenderTarget : NSObject <UIAlertViewDelegate>
- (void)fire:(id)timer;
@end

static SLSenderTarget *gSLSTarget;
static id gSLSTimer;                    // PCPersistentTimer or NSTimer: the only live one
static NSDate *gSLSTimerDate;
static BOOL gSLSStartupDone;            // due items wait for the startup pass
static CFAbsoluteTime gSLSStartTime;    // wall clock at start: the startup wait also ends by it (sleep-proof)
static BOOL gSLSReschedulePending;
static int gSLSNotifyToken;

static BOOL gSLSPassActive;
static BOOL gSLSPassRerun;
static BOOL gSLSPassWorked;             // this pass found due items
static int gSLSPassRetries;             // tries of this pass (log only)
static unsigned int gSLSPassGen;
static NSUInteger gSLSPassSent;
static NSMutableArray *gSLSPassFailed;  // items marked failed in this pass (for the alert)
static NSMutableSet *gSLSAttempted;     // "id|fire" keys this process already claimed or failed
static NSMutableDictionary *gSLSTries;  // "id|fire" -> NSNumber: this pass's tries of a still-waiting item
static NSMutableDictionary *gSLSRetryAt;    // "id|fire" -> NSDate: a write-failed attempt is tried again then
static NSMutableDictionary *gSLSRetryCount; // "id|fire" -> NSNumber: write retries so far (backoff)

static SLSAssertCreateFn gSLSAssertCreate;
static SLSAssertReleaseFn gSLSAssertRelease;
static uint32_t gSLSAssertID;
static BOOL gSLSAssertHeld;
static unsigned int gSLSPowerGen;

static UIAlertView *gSLSAlert;
static CFAbsoluteTime gSLSAlertShownAt;

static void SLSenderReschedule(void);
static void SLSenderRequestReschedule(void);
static void SLSenderPassStep(void);
static void SLSenderTimerFired(id timer);

#pragma mark - Helpers

static void SLSenderAfter(NSTimeInterval seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

// One line per missing class/selector/function, not one per pass.
static void SLSenderMissing(NSString *what) {
    static NSMutableSet *logged;
    if (!logged) {
        logged = [NSMutableSet set];
    }
    if ([logged containsObject:what]) {
        return;
    }
    [logged addObject:what];
    SLLog(@"missing: %@", what);
}

static BOOL SLSenderIsScheduled(NSDictionary *item) {
    if (![item isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    id state = item[SLKeyState];
    return !state || [state isEqual:SLStateScheduled];
}

static NSDate *SLSenderFireDate(NSDictionary *item) {
    id fire = [item isKindOfClass:[NSDictionary class]] ? item[SLKeyFire] : nil;
    return [fire isKindOfClass:[NSDate class]] ? fire : nil;
}

// Same id + same fire date = the same attempt; a rescheduled item (Change Time) is a new one.
static NSString *SLSenderKey(NSDictionary *item) {
    NSDate *fire = SLSenderFireDate(item);
    return [NSString stringWithFormat:@"%@|%.3f", item[SLKeyID], fire ? [fire timeIntervalSinceReferenceDate] : 0.0];
}

// Due = scheduled, at (or within a second of) its time, and not already tried by this process. The last
// part keeps a queue that can't be written (Take/Put failing) from looping pass after pass.
static BOOL SLSenderIsDue(NSDictionary *item, NSDate *now) {
    NSDate *fire = SLSenderFireDate(item);
    if (!fire || !SLSenderIsScheduled(item) || [fire timeIntervalSinceDate:now] > SLS_DUE_SLACK) {
        return NO;
    }
    return ![gSLSAttempted containsObject:SLSenderKey(item)];
}

static NSString *SLSenderHowLabel(NSString *how) {
    if ([how isEqualToString:@"guid"] || [how isEqualToString:@"identifier"]) {
        return [@"existing " stringByAppendingString:how];
    }
    return how.length ? how : @"unknown path";
}

// Each item counts its own tries, so one that joins a pass late still gets SL_RETRY_LIMIT retries.
static int SLSenderTries(NSDictionary *item) {
    return [gSLSTries[SLSenderKey(item)] intValue];
}

static void SLSenderCountTry(NSDictionary *item) {
    gSLSTries[SLSenderKey(item)] = @(SLSenderTries(item) + 1);
}

// The first try plus SL_RETRY_LIMIT retries are used up: this try is the item's last.
static BOOL SLSenderLastTry(NSDictionary *item) {
    return SLSenderTries(item) > SL_RETRY_LIMIT;
}

#pragma mark - Power assertion

// Held from the first due item of a pass until SL_POWER_HOLD s after the pass ends; a new pass extends it.
static void SLSenderPowerHold(void) {
    gSLSPowerGen++;     // cancels a pending release
    if (gSLSAssertHeld) {
        return;
    }
    if (!gSLSAssertCreate || !gSLSAssertRelease) {
        SLSenderMissing(@"IOPMAssertionCreateWithName / IOPMAssertionRelease");
        return;
    }
    uint32_t assertionID = 0;
    SLSIOReturn result = gSLSAssertCreate(CFSTR("NoIdleSleepAssertion"), SLS_ASSERT_LEVEL_ON,
                                          CFSTR("com.mbucc9000.sendlater"), &assertionID);
    if (result == 0) {
        gSLSAssertHeld = YES;
        gSLSAssertID = assertionID;
        SLLog(@"power: assertion held");
    } else {
        SLLog(@"power: assertion failed (0x%x)", (unsigned int)result);
    }
}

static void SLSenderPowerReleaseLater(void) {
    if (!gSLSAssertHeld) {
        return;
    }
    unsigned int gen = ++gSLSPowerGen;
    SLSenderAfter(SL_POWER_HOLD, ^{
        if (gen != gSLSPowerGen || gSLSPassActive || !gSLSAssertHeld) {
            return;
        }
        SLSIOReturn result = gSLSAssertRelease(gSLSAssertID);
        gSLSAssertHeld = NO;
        gSLSAssertID = 0;
        SLLog(@"power: assertion released (0x%x)", (unsigned int)result);
    });
}

#pragma mark - Timer

static void SLSenderClearTimer(void) {
    if (!gSLSTimer) {
        return;
    }
    @try {
        [gSLSTimer invalidate];
    } @catch (NSException *e) {
        SLLog(@"timer: invalidate threw %@", e.name);
    }
    gSLSTimer = nil;
    gSLSTimerDate = nil;
}

static void SLSenderSetTimer(NSDate *date) {
    if (gSLSTimer && [gSLSTimerDate isEqualToDate:date]
        && (![gSLSTimer respondsToSelector:@selector(isValid)] || [gSLSTimer isValid])) {
        return;     // already pointing there
    }
    SLSenderClearTimer();

    NSString *kind = nil;
    Class pcClass = NSClassFromString(@"PCPersistentTimer");
    SEL initSel = @selector(initWithFireDate:serviceIdentifier:target:selector:userInfo:);
    if (pcClass && [pcClass instancesRespondToSelector:initSel]
        && [pcClass instancesRespondToSelector:@selector(scheduleInRunLoop:)]) {
        PCPersistentTimer *timer = nil;
        @try {
            timer = [(PCPersistentTimer *)[pcClass alloc] initWithFireDate:date serviceIdentifier:SL_TIMER_SERVICE
                                                                     target:gSLSTarget selector:@selector(fire:) userInfo:nil];
            if (timer) {
                if ([timer respondsToSelector:@selector(setMinimumEarlyFireProportion:)]) {
                    [timer setMinimumEarlyFireProportion:1.0];      // never fire early
                } else {
                    SLSenderMissing(@"-[PCPersistentTimer setMinimumEarlyFireProportion:]");
                }
                [timer scheduleInRunLoop:[NSRunLoop mainRunLoop]];
            }
        } @catch (NSException *e) {
            SLLog(@"timer: PCPersistentTimer threw %@", e.name);
            timer = nil;
        }
        if (timer) {
            gSLSTimer = timer;
            kind = @"PCPersistentTimer";
        }
    } else {
        SLSenderMissing(pcClass ? @"PCPersistentTimer init/schedule selectors" : @"PCPersistentTimer");
    }

    if (!gSLSTimer) {
        // Fallback: fires on time only while awake (no system wake).
        NSTimer *timer = [[NSTimer alloc] initWithFireDate:date interval:0 target:gSLSTarget
                                                  selector:@selector(fire:) userInfo:nil repeats:NO];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        gSLSTimer = timer;
        kind = @"NSTimer (no wake)";
    }
    gSLSTimerDate = date;
    SLLog(@"timer: %@ set, fires in %.0f s", kind, [date timeIntervalSinceNow]);
}

static void SLSenderTimerFired(id timer) {
    if (timer && timer == gSLSTimer) {
        SLSenderClearTimer();
    }
    // A real fire means something is due: never leave it for a startup wait that stalls while asleep.
    // The pass holds the power assertion and does its own IMCore readiness retries.
    SLLog(@"timer: fired%@", gSLSStartupDone ? @"" : @", startup wait ended");
    gSLSStartupDone = YES;
    SLSenderReschedule();
}

#pragma mark - Readiness (non-blocking only)

static BOOL SLSenderDaemonConnected(void) {
    Class cls = NSClassFromString(@"IMDaemonController");
    if (!cls || ![cls respondsToSelector:@selector(sharedInstance)]) {
        SLSenderMissing(@"IMDaemonController");
        return NO;
    }
    BOOL connected = NO;
    @try {
        IMDaemonController *daemon = [cls sharedInstance];
        if (![daemon respondsToSelector:@selector(isConnected)]) {
            SLSenderMissing(@"-[IMDaemonController isConnected]");
            return NO;
        }
        connected = [daemon isConnected];
        if (!connected) {
            // Never blockUntilConnected, disconnect or capability changes: SMSBBPlugin shares this connection.
            BOOL connecting = [daemon respondsToSelector:@selector(isConnecting)] && [daemon isConnecting];
            if (!connecting) {
                if ([daemon respondsToSelector:@selector(connectToDaemon)]) {
                    [daemon connectToDaemon];
                    SLLog(@"imcore: not connected, connectToDaemon requested");
                    connected = [daemon isConnected];
                } else {
                    SLSenderMissing(@"-[IMDaemonController connectToDaemon]");
                }
            }
        }
    } @catch (NSException *e) {
        SLLog(@"imcore: daemon check threw %@", e.name);
        connected = NO;
    }
    return connected;
}

// YES while the chat registry is still loading or has no chats: a nil chat then means "not yet".
static BOOL SLSenderRegistryWaiting(void) {
    Class cls = NSClassFromString(@"IMChatRegistry");
    if (!cls || ![cls respondsToSelector:@selector(sharedInstance)]) {
        SLSenderMissing(@"IMChatRegistry");
        return YES;
    }
    BOOL loading = NO;
    BOOL empty = NO;
    unsigned int count = 0;
    @try {
        IMChatRegistry *registry = [cls sharedInstance];
        if ([registry respondsToSelector:@selector(_isLoading)]) {
            loading = [registry _isLoading];
        } else {
            SLSenderMissing(@"-[IMChatRegistry _isLoading]");
        }
        if ([registry respondsToSelector:@selector(numberOfExistingChats)]) {
            count = [registry numberOfExistingChats];
            empty = (count == 0);
        } else {
            SLSenderMissing(@"-[IMChatRegistry numberOfExistingChats]");
        }
    } @catch (NSException *e) {
        SLLog(@"imcore: registry check threw %@", e.name);
    }
    SLLog(@"imcore: registry loading %d, %u chats", loading ? 1 : 0, count);
    return loading || empty;
}

#pragma mark - Alert (DESIGN 1.7)

static NSString *SLSenderAlertName(NSDictionary *item) {
    id title = item[SLKeyTitle];
    if ([title isKindOfClass:[NSString class]] && [title length]) {
        return title;
    }
    id handles = item[SLKeyHandles];
    if ([handles isKindOfClass:[NSArray class]]) {
        NSMutableArray *names = [NSMutableArray array];
        for (id handle in handles) {
            if ([handle isKindOfClass:[NSString class]] && [handle length]) {
                [names addObject:handle];
            }
        }
        if (names.count) {
            return [names componentsJoinedByString:@", "];
        }
    }
    return nil;
}

// One alert at a time; failures while one is up are only logged.
static void SLSenderShowFailures(NSArray *failed) {
    if (!failed.count) {
        return;
    }
    if (gSLSAlert) {
        BOOL visible = [gSLSAlert isVisible];
        if (visible || CFAbsoluteTimeGetCurrent() - gSLSAlertShownAt < SLS_ALERT_STALE) {
            SLLog(@"alert: one is already up, %lu failure(s) only logged", (unsigned long)failed.count);
            return;
        }
        gSLSAlert = nil;    // went away without telling the delegate
    }
    NSString *message = nil;
    if (failed.count == 1) {
        NSString *name = SLSenderAlertName([failed objectAtIndex:0]);
        message = name
            ? [NSString stringWithFormat:@"A scheduled message to %@ couldn't be sent. Open the conversation in Messages "
                                         @"and touch and hold Send to try again.", name]
            : @"A scheduled message couldn't be sent. Open Messages and touch and hold Send in that conversation to try again.";
    } else {
        message = [NSString stringWithFormat:@"%lu scheduled messages couldn't be sent. Open Messages and touch and hold "
                                             @"Send in those conversations to try again.", (unsigned long)failed.count];
    }
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Send Later" message:message delegate:gSLSTarget
                                          cancelButtonTitle:@"OK" otherButtonTitles:nil];
    gSLSAlert = alert;
    gSLSAlertShownAt = CFAbsoluteTimeGetCurrent();
    [alert show];
    SLLog(@"alert: shown for %lu failure(s)", (unsigned long)failed.count);
}

#pragma mark - Pass

// The queue could not be written (Take/Update returned nil/NO), so the item may still be scheduled. Its
// attempt key stays set until a wall-clock retry date SLS_WRITE_RETRY s on (no tight loop: passes meanwhile
// skip it). SLSenderReschedule arms the wake-capable timer for that date, then clears the key so the item
// is picked up again if it is still due. Dropped when the item is gone (Messages sent it).
// The delay doubles per retry of the same attempt (120 s, 240 s ... at most 1 h), so a queue that stays
// unwritable can't wake the phone every 2 minutes forever.
static void SLSenderRetryLater(NSDictionary *item) {
    NSString *key = SLSenderKey(item);
    int count = [gSLSRetryCount[key] intValue];
    gSLSRetryCount[key] = @(count + 1);
    NSTimeInterval delay = MIN(SLS_WRITE_RETRY * (double)(1 << MIN(count, 5)), 3600.0);
    gSLSRetryAt[key] = [NSDate dateWithTimeIntervalSinceNow:delay];
    if (count) {
        SLLog(@"retry %@: write retry %d, next in %.0f s", SLIDTail(item[SLKeyID]), count + 1, delay);
    }
}

// A claim or locked write for this attempt worked: the queue is writable again.
static void SLSenderRetryReset(NSDictionary *item) {
    [gSLSRetryCount removeObjectForKey:SLSenderKey(item)];
}

// Marks a still-scheduled, unchanged item failed in one locked write (no claim needed: nothing is sent).
static void SLSenderFail(NSDictionary *item, NSString *reason, NSString *why) {
    NSString *itemID = item[SLKeyID];
    NSDate *fire = SLSenderFireDate(item);
    [gSLSAttempted addObject:SLSenderKey(item)];
    [gSLSTries removeObjectForKey:SLSenderKey(item)];
    __block NSDictionary *marked = nil;
    BOOL written = SLQueueUpdate(^NSArray *(NSArray *items) {
        marked = nil;
        NSMutableArray *changed = [NSMutableArray arrayWithCapacity:items.count];
        for (NSDictionary *entry in items) {
            if (!marked && SLSenderIsScheduled(entry) && [entry[SLKeyID] isEqual:itemID]
                && [SLSenderFireDate(entry) isEqualToDate:fire]) {
                NSDictionary *failed = SLItemWithState(entry, SLStateFailed, reason);
                if (failed) {
                    marked = failed;
                    [changed addObject:failed];
                    continue;
                }
            }
            [changed addObject:entry];
        }
        return marked ? changed : items;
    });
    if (!written) {
        // Not locked / unreadable / not written: the file still has it as scheduled. No alert now.
        SLLog(@"fail %@: %@, queue write failed, retry in %.0f s", SLIDTail(itemID), why, SLS_WRITE_RETRY);
        SLSenderRetryLater(item);
        return;
    }
    SLSenderRetryReset(item);
    if (!marked) {
        SLLog(@"skip %@: gone or changed meanwhile", SLIDTail(itemID));
        return;
    }
    [gSLSPassFailed addObject:marked];
    SLLog(@"failed %@: %@", SLIDTail(itemID), why);
}

// Puts a claimed item back. Only this process holds it now, so a late put can't double-send; a busy
// queue is retried a few times (SL_RETRY_INTERVAL apart) so the item is not lost.
static void SLSenderPutBack(NSDictionary *item, int triesLeft) {
    if (!item || SLQueuePut(item)) {
        return;
    }
    NSString *tail = SLIDTail(item[SLKeyID]);
    if (triesLeft <= 0) {
        SLLog(@"put %@: queue write failed, gave up", tail);
        return;
    }
    SLLog(@"put %@: queue write failed, retry in %.0f s", tail, SL_RETRY_INTERVAL);
    SLSenderAfter(SL_RETRY_INTERVAL, ^{
        SLSenderPutBack(item, triesLeft - 1);
    });
}

static void SLSenderSendOne(NSDictionary *item, IMChat *chat, NSString *how) {
    NSString *itemID = item[SLKeyID];
    NSString *tail = SLIDTail(itemID);
    [gSLSAttempted addObject:SLSenderKey(item)];
    [gSLSTries removeObjectForKey:SLSenderKey(item)];

    NSDictionary *claimed = SLQueueTake(itemID);
    if (!claimed) {
        // nil = gone (Messages sent/removed it) or not claimed (queue busy/unwritable): look again later.
        SLLog(@"skip %@: not claimed (gone, or queue busy), recheck in %.0f s", tail, SLS_WRITE_RETRY);
        SLSenderRetryLater(item);
        return;
    }
    SLSenderRetryReset(item);
    // Messages may have changed it (Change Time) between our read and the claim.
    if (!SLSenderIsScheduled(claimed) || ![SLSenderFireDate(claimed) isEqualToDate:SLSenderFireDate(item)]) {
        SLLog(@"skip %@: changed meanwhile, putting it back", tail);
        SLSenderPutBack(claimed, SL_RETRY_LIMIT);
        return;
    }

    id rawText = claimed[SLKeyText];
    NSString *text = [rawText isKindOfClass:[NSString class]] ? rawText : nil;
    NSString *reason = nil;
    @try {
        reason = SLSendText(chat, text);
    } @catch (NSException *e) {
        SLLog(@"send %@: threw %@", tail, e.name);
        reason = @"Messages couldn't send it";
    }
    if (!reason) {
        gSLSPassSent++;
        SLLog(@"sent %@ via %@ (%lu chars)", tail, SLSenderHowLabel(how), (unsigned long)text.length);
        return;
    }
    NSDictionary *failed = SLItemWithState(claimed, SLStateFailed, reason);
    [gSLSPassFailed addObject:failed ?: claimed];
    SLLog(@"failed %@: send refused via %@", tail, SLSenderHowLabel(how));
    SLSenderPutBack(failed, SL_RETRY_LIMIT);
}

static void SLSenderPassEnd(void) {
    if (!gSLSPassActive) {
        return;
    }
    gSLSPassActive = NO;
    [gSLSTries removeAllObjects];
    NSArray *failed = gSLSPassFailed;
    gSLSPassFailed = nil;
    BOOL rerun = gSLSPassRerun;
    gSLSPassRerun = NO;
    if (gSLSPassWorked) {
        SLLog(@"pass: done, %lu sent, %lu failed%@", (unsigned long)gSLSPassSent, (unsigned long)failed.count,
              rerun ? @", rerun requested" : @"");
        SLSenderPowerReleaseLater();
    }
    SLSenderShowFailures(failed);
    if (gSLSPassWorked || rerun) {
        SLSenderRequestReschedule();
    }
}

// waits: @[item, user reason, log label] for each item that is not sent this try. An item fails once its
// own retries are used up; the pass tries again in SL_RETRY_INTERVAL s while any item still has some.
static void SLSenderRetryOrFail(NSArray *waits) {
    NSUInteger kept = 0;
    NSString *keptWhy = nil;
    for (NSArray *wait in waits) {
        NSDictionary *item = wait[0];
        if (SLSenderLastTry(item)) {
            SLLog(@"pass: %@ gave up after %d retries (%@)", SLIDTail(item[SLKeyID]), SL_RETRY_LIMIT, wait[2]);
            SLSenderFail(item, wait[1], wait[2]);
        } else {
            kept++;
            keptWhy = keptWhy ?: wait[2];
        }
    }
    if (!kept) {
        SLSenderPassEnd();
        return;
    }
    gSLSPassRetries++;
    unsigned int gen = gSLSPassGen;
    SLLog(@"pass: %lu waiting (%@), next try in %.0f s", (unsigned long)kept, keptWhy, SL_RETRY_INTERVAL);
    SLSenderAfter(SL_RETRY_INTERVAL, ^{
        if (gSLSPassActive && gen == gSLSPassGen) {
            SLSenderPassStep();
        }
    });
}

// One try of the current pass; re-reads the queue each time, so items that came due meanwhile join in.
static void SLSenderPassStep(void) {
    @try {
        NSDate *now = [NSDate date];
        NSMutableArray *due = [NSMutableArray array];
        for (NSDictionary *item in SLQueueItems()) {     // sorted by fire date: oldest first
            if (SLSenderIsDue(item, now)) {
                [due addObject:item];
            }
        }
        if (!due.count) {
            SLSenderPassEnd();
            return;
        }
        gSLSPassWorked = YES;
        SLSenderPowerHold();
        SLLog(@"pass: %lu due (try %d)", (unsigned long)due.count, gSLSPassRetries + 1);

        // Too late to send (phone was off, or SpringBoard was not running): fail instead.
        NSString *missed = [NSString stringWithFormat:@"Missed %C the iPhone was off", (unichar)0x2013];
        NSMutableArray *pending = [NSMutableArray array];
        for (NSDictionary *item in due) {
            if ([now timeIntervalSinceDate:SLSenderFireDate(item)] > SL_MAX_LATE) {
                SLSenderFail(item, missed, @"missed (over 6 h late)");
            } else {
                [pending addObject:item];
            }
        }
        if (!pending.count) {
            SLSenderPassEnd();
            return;
        }
        for (NSDictionary *item in pending) {
            SLSenderCountTry(item);
        }

        NSMutableArray *waits = [NSMutableArray array];
        if (!SLSenderDaemonConnected()) {
            for (NSDictionary *item in pending) {
                [waits addObject:@[item, @"Messages wasn't ready", @"imcore not connected"]];
            }
            SLSenderRetryOrFail(waits);
            return;
        }

        // Once per try. While the registry loads only existing chats are used (paths 1-2); paths 3-4 make a
        // chat object, so only once it has loaded or on the item's last three tries (a created chat asks to
        // join, and the join needs a retry or two to finish).
        BOOL registryWaiting = SLSenderRegistryWaiting();
        for (NSDictionary *item in pending) {
            NSString *tail = SLIDTail(item[SLKeyID]);
            NSString *how = nil;
            IMChat *chat = nil;
            @try {
                chat = SLFindChat(item, &how, !registryWaiting || SLSenderTries(item) >= SL_RETRY_LIMIT - 1);
            } @catch (NSException *e) {
                SLLog(@"find %@: threw %@", tail, e.name);
                chat = nil;
            }
            if (!chat) {
                if (registryWaiting) {
                    [waits addObject:@[item, @"Conversation not found", @"no chat yet"]];
                } else {
                    SLSenderFail(item, @"Conversation not found", @"no chat");
                }
                continue;
            }
            // Claim only what IMCore would really send (DESIGN 4); else wait, then fail visibly.
            NSString *notReady = nil;
            @try {
                notReady = SLChatNotReady(chat, item[SLKeyText], YES);
            } @catch (NSException *e) {
                notReady = [NSString stringWithFormat:@"readiness check threw %@", e.name];
            }
            if (notReady) {
                SLLog(@"wait %@: %@ (via %@)", tail, notReady, SLSenderHowLabel(how));
                [waits addObject:@[item, @"Messages wasn't ready", notReady]];
                continue;
            }
            SLSenderSendOne(item, chat, how);
        }
        if (waits.count) {
            SLSenderRetryOrFail(waits);
            return;
        }
        SLSenderPassEnd();
    } @catch (NSException *e) {
        SLLog(@"pass: threw %@", e.name);
        SLSenderPassEnd();
    }
}

// SLRunDue (DESIGN 4): never nests; a trigger during a pass only asks for a rerun at its end.
static void SLSenderRunDue(void) {
    if (gSLSPassActive) {
        if (!gSLSPassRerun) {
            SLLog(@"pass: busy, rerun after");
        }
        gSLSPassRerun = YES;
        return;
    }
    gSLSPassActive = YES;
    gSLSPassRerun = NO;
    gSLSPassWorked = NO;
    gSLSPassRetries = 0;
    gSLSPassSent = 0;
    gSLSPassGen++;
    gSLSPassFailed = [NSMutableArray array];
    SLSenderPassStep();
}

#pragma mark - Reschedule

// SLReschedule (DESIGN 4): timer to the earliest future scheduled item or write retry; due items start a pass.
static void SLSenderReschedule(void) {
    @try {
        NSDate *now = [NSDate date];
        NSDate *next = nil;
        NSUInteger due = 0;
        NSUInteger scheduled = 0;
        if (!gSLSStartupDone && CFAbsoluteTimeGetCurrent() - gSLSStartTime >= SL_STARTUP_DELAY) {
            gSLSStartupDone = YES;      // mach-time dispatch_after stalls while asleep; the wall clock doesn't
            SLLog(@"start: startup wait over");
        }
        NSArray *items = SLQueueItems();

        // Write retries: due ones are cleared so the item counts as due again; gone ones are dropped (their
        // key is cleared too, so a read glitch can't strand an item that is still there).
        if (gSLSRetryAt.count) {
            NSMutableSet *live = [NSMutableSet set];
            for (NSDictionary *item in items) {
                if (SLSenderIsScheduled(item) && SLSenderFireDate(item)) {
                    [live addObject:SLSenderKey(item)];
                }
            }
            for (NSString *key in [gSLSRetryAt allKeys]) {
                NSDate *at = gSLSRetryAt[key];
                if (![live containsObject:key] || [at timeIntervalSinceDate:now] <= SLS_DUE_SLACK) {
                    [gSLSRetryAt removeObjectForKey:key];
                    [gSLSAttempted removeObject:key];
                    if (![live containsObject:key]) {
                        [gSLSRetryCount removeObjectForKey:key];
                    }
                } else if (!next || [at compare:next] == NSOrderedAscending) {
                    next = at;
                }
            }
        }

        for (NSDictionary *item in items) {
            NSDate *fire = SLSenderFireDate(item);
            if (!fire || !SLSenderIsScheduled(item)) {
                continue;
            }
            scheduled++;
            if ([fire timeIntervalSinceDate:now] > SLS_DUE_SLACK) {
                if (!next || [fire compare:next] == NSOrderedAscending) {
                    next = fire;
                }
            } else if (SLSenderIsDue(item, now)) {
                due++;
            }
        }
        if (due && !gSLSStartupDone) {
            // Due items waiting for the startup pass: a wake-capable timer ends the wait even while asleep.
            NSDate *startupEnd = [NSDate dateWithTimeIntervalSinceReferenceDate:gSLSStartTime + SL_STARTUP_DELAY];
            if (!next || [startupEnd compare:next] == NSOrderedAscending) {
                next = startupEnd;
            }
        }
        if (next) {
            SLSenderSetTimer(next);
        } else if (gSLSTimer) {
            SLSenderClearTimer();
            SLLog(@"timer: none (%lu scheduled)", (unsigned long)scheduled);
        }
        if (due) {
            if (gSLSStartupDone) {
                SLSenderRunDue();
            } else {
                SLLog(@"reschedule: %lu due, left for the startup pass", (unsigned long)due);
            }
        }
    } @catch (NSException *e) {
        SLLog(@"reschedule: threw %@", e.name);
    }
}

// Coalesces bursts (our own Take/Put post SL_NOTIFY_CHANGED too).
static void SLSenderRequestReschedule(void) {
    if (gSLSReschedulePending) {
        return;
    }
    gSLSReschedulePending = YES;
    SLSenderAfter(SLS_COALESCE, ^{
        gSLSReschedulePending = NO;
        SLSenderReschedule();
    });
}

#pragma mark - Start

void SLSenderStart(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SLSenderStart();
        });
        return;
    }
    static BOOL started = NO;
    if (started) {
        return;
    }
    started = YES;
    gSLSStartTime = CFAbsoluteTimeGetCurrent();
    gSLSTarget = [[SLSenderTarget alloc] init];
    gSLSAttempted = [NSMutableSet set];
    gSLSTries = [NSMutableDictionary dictionary];
    gSLSRetryAt = [NSMutableDictionary dictionary];
    gSLSRetryCount = [NSMutableDictionary dictionary];

    if (!dlopen(SLS_IMCORE_PATH, RTLD_LAZY)) {
        SLLog(@"start: IMCore dlopen failed");
    }
    if (!dlopen(SLS_PC_PATH, RTLD_LAZY)) {
        SLLog(@"start: PersistentConnection dlopen failed");
    }
    void *iokit = dlopen(SLS_IOKIT_PATH, RTLD_LAZY);
    void *symbols = iokit ? iokit : RTLD_DEFAULT;
    gSLSAssertCreate = (SLSAssertCreateFn)dlsym(symbols, "IOPMAssertionCreateWithName");
    gSLSAssertRelease = (SLSAssertReleaseFn)dlsym(symbols, "IOPMAssertionRelease");
    SLLog(@"start: PCPersistentTimer %d, IMDaemonController %d, IMChatRegistry %d, IOPM %d",
          NSClassFromString(@"PCPersistentTimer") ? 1 : 0, NSClassFromString(@"IMDaemonController") ? 1 : 0,
          NSClassFromString(@"IMChatRegistry") ? 1 : 0, (gSLSAssertCreate && gSLSAssertRelease) ? 1 : 0);
    SLLogIMCoreState(@"start");     // listener capability mask: what decides whether SpringBoard can send

    uint32_t status = notify_register_dispatch(SL_NOTIFY_CHANGED, &gSLSNotifyToken, dispatch_get_main_queue(), ^(int token) {
        SLSenderRequestReschedule();
    });
    if (status != NOTIFY_STATUS_OK) {
        SLLog(@"start: notify_register_dispatch failed (%u)", status);
    }

    SLSenderReschedule();       // timer for future items now; due ones wait for the startup pass
    SLLog(@"start: startup pass in %.0f s", SL_STARTUP_DELAY);
    SLSenderAfter(SL_STARTUP_DELAY, ^{
        gSLSStartupDone = YES;
        SLLog(@"start: startup pass");
        SLLogIMCoreState(@"startup pass");
        SLSenderReschedule();   // runs the missed items, then sets the timer
    });
}

#pragma mark - Target

@implementation SLSenderTarget

- (void)fire:(id)timer {
    // Handled on the next turn: replacing the timer inside its own callback could free it mid-call.
    id fired = timer;
    dispatch_async(dispatch_get_main_queue(), ^{
        SLSenderTimerFired(fired);
    });
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    UIAlertView *dismissed = alertView;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSLSAlert == dismissed) {
            gSLSAlert = nil;
        }
    });
}

@end
