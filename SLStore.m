// Send Later 1.0.0 - SLStore.m: log, queue, dates and the IMCore helpers (both processes).
//
// Queue (DESIGN.md section 2): binary plist {version:1, items:[...]} replaced whole by an atomic write
// (temp file + rename), so a crash mid-write leaves the old file and an unlocked read is never torn.
// Every read-modify-write holds flock(LOCK_EX) on Queue.lock, reads hold LOCK_SH. The lock is taken
// with a bounded wait so a stuck peer can never hang SpringBoard; a missing or garbage file reads as
// empty, but a file that exists and cannot be read is never overwritten.
// IMCore helpers (DESIGN.md section 3) are main-thread only; classes via NSClassFromString only.
// Logs: counts, lengths, states, id tails and selector availability only (DESIGN.md section 6).

#import "SLShared.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define SL_STORE_LOCK_WAIT      2.0         // s: longest wait for Queue.lock
#define SL_STORE_VERSION        1
#define SL_STORE_KEY_VERSION    @"version"
#define SL_STORE_KEY_ITEMS      @"items"

typedef enum {
    SLStoreFileOK,
    SLStoreFileMissing,         // no file yet: empty queue
    SLStoreFileGarbage,         // not a queue plist: read as empty, replaced on the next change
    SLStoreFileError            // exists but unreadable: read as empty, never overwritten
} SLStoreFileStatus;

#pragma mark - Log

static pthread_mutex_t gSLLogLock = PTHREAD_MUTEX_INITIALIZER;

NSString *SLProcessTag(void) {
    static NSString *tag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundle isEqualToString:@"com.apple.springboard"]) {
            tag = @"SB";
        } else if ([bundle isEqualToString:@"com.apple.MobileSMS"]) {
            tag = @"SMS";
        } else {
            const char *name = getprogname();
            tag = name ? [NSString stringWithUTF8String:name] : nil;
        }
        if (!tag.length) {
            tag = @"?";
        }
    });
    return tag;
}

void SLLog(NSString *format, ...) {
    if (![format isKindOfClass:[NSString class]]) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Timestamp from libc (thread-safe, unlike an iOS 6 NSDateFormatter).
    struct timeval tv;
    gettimeofday(&tv, NULL);
    time_t secs = (time_t)tv.tv_sec;
    struct tm local;
    localtime_r(&secs, &local);
    char stamp[32];
    if (strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &local) == 0) {
        stamp[0] = '\0';
    }
    NSString *line = [NSString stringWithFormat:@"%s.%03d [%@] %@\n", stamp, (int)(tv.tv_usec / 1000),
                      SLProcessTag(), message ?: @""];
    NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    if (!bytes.length) {
        return;
    }

    pthread_mutex_lock(&gSLLogLock);
    static BOOL checkedSize = NO;
    if (!checkedSize) {
        // First line of this process: start over when the log has grown past the cap.
        checkedSize = YES;
        struct stat st;
        if (stat(SL_LOG_PATH, &st) == 0 && st.st_size > (off_t)SL_LOG_MAX_BYTES) {
            truncate(SL_LOG_PATH, 0);
        }
    }
    int fd = open(SL_LOG_PATH, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        const char *p = (const char *)bytes.bytes;
        size_t left = bytes.length;
        while (left > 0) {
            ssize_t n = write(fd, p, left);
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n <= 0) {
                break;
            }
            p += n;
            left -= (size_t)n;
        }
        close(fd);
    }
    pthread_mutex_unlock(&gSLLogLock);
    if (fd < 0) {
        NSLog(@"SendLater: %@", message);
    }
}

NSString *SLIDTail(NSString *itemID) {
    if (![itemID isKindOfClass:[NSString class]] || !itemID.length) {
        return @"----";
    }
    return itemID.length <= 4 ? itemID : [itemID substringFromIndex:itemID.length - 4];
}

#pragma mark - Small helpers

static BOOL SLStoreIsString(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0;
}

static NSString *SLStoreString(id value) {
    return SLStoreIsString(value) ? (NSString *)value : nil;
}

// Logs a missing class/selector once per process (by name only).
static void SLStoreLogMissOnce(NSString *key, NSString *message) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seen = [[NSMutableSet alloc] init];
    });
    BOOL first = NO;
    @synchronized (seen) {
        if (![seen containsObject:key]) {
            [seen addObject:key];
            first = YES;
        }
    }
    if (first) {
        SLLog(@"%@", message);
    }
}

static Class SLStoreClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) {
        SLStoreLogMissOnce(name, [NSString stringWithFormat:@"imcore: class %@ missing", name]);
    }
    return cls;
}

// YES when target answers sel. A nil target is not a miss; a missing selector is logged once.
static BOOL SLStoreCan(id target, SEL sel) {
    if (!target || !sel) {
        return NO;
    }
    if ([target respondsToSelector:sel]) {
        return YES;
    }
    NSString *owner = NSStringFromClass(object_getClass(target)) ?: @"?";
    NSString *selName = NSStringFromSelector(sel);
    SLStoreLogMissOnce([NSString stringWithFormat:@"%@ %@", owner, selName],
                       [NSString stringWithFormat:@"imcore: %@ does not answer %@", owner, selName]);
    return NO;
}

static void SLStoreLoadIMCore(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_LAZY)) {
            SLLog(@"imcore: dlopen failed");
        }
    });
}

static void SLStoreWarnOffMain(NSString *what) {
    if (![NSThread isMainThread]) {
        SLLog(@"%@: called off the main thread", what);
    }
}

// "iMessage;-;+15555550123" -> service "iMessage", style 45 ('-') / 43 ('+').
static void SLStoreGUIDParts(NSString *guid, NSString **service, NSInteger *style) {
    NSArray *parts = SLStoreIsString(guid) ? [guid componentsSeparatedByString:@";"] : nil;
    if (parts.count < 3) {
        return;
    }
    if (service && !*service) {
        *service = SLStoreString([parts objectAtIndex:0]);
    }
    if (style && !*style) {
        NSString *mark = [parts objectAtIndex:1];
        if ([mark isEqualToString:@"-"]) {
            *style = SL_STYLE_SINGLE;
        } else if ([mark isEqualToString:@"+"]) {
            *style = SL_STYLE_GROUP;
        }
    }
}

#pragma mark - Queue: validation

// A clean copy of obj, or nil when a required key is missing. Optional keys of the wrong type are
// removed so every reader can trust any key it finds.
static NSDictionary *SLStoreValidItem(id obj) {
    if (![obj isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *item = obj;
    id state = [item objectForKey:SLKeyState];
    if (!SLStoreIsString([item objectForKey:SLKeyID]) || !SLStoreIsString([item objectForKey:SLKeyText])
        || !SLStoreIsString([item objectForKey:SLKeyChatGUID]) || ![[item objectForKey:SLKeyFire] isKindOfClass:[NSDate class]]
        || !([state isEqual:SLStateScheduled] || [state isEqual:SLStateFailed])) {
        return nil;
    }

    static NSDictionary *optionalTypes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        optionalTypes = @{ SLKeyCreated: [NSDate class], SLKeyChatID: [NSString class], SLKeyStyle: [NSNumber class],
                           SLKeyService: [NSString class], SLKeyHandles: [NSArray class], SLKeyTitle: [NSString class],
                           SLKeyReason: [NSString class] };
    });
    NSMutableDictionary *clean = nil;
    for (NSString *key in optionalTypes) {
        id value = [item objectForKey:key];
        if (!value) {
            continue;
        }
        BOOL ok = [value isKindOfClass:[optionalTypes objectForKey:key]];
        if (ok && [key isEqualToString:SLKeyHandles]) {
            for (id handle in (NSArray *)value) {
                if (![handle isKindOfClass:[NSString class]]) {
                    ok = NO;
                    break;
                }
            }
        }
        if (!ok) {
            if (!clean) {
                clean = [item mutableCopy];
            }
            [clean removeObjectForKey:key];
        }
    }
    return clean ? [clean copy] : item;
}

// Valid items only, first of each id, sorted by fire (then created, then id). Never nil.
static NSArray *SLStoreClean(NSArray *raw, NSUInteger *dropped) {
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:raw.count];
    NSMutableSet *ids = [NSMutableSet set];
    NSUInteger bad = 0;
    for (id obj in raw) {
        NSDictionary *item = SLStoreValidItem(obj);
        NSString *itemID = [item objectForKey:SLKeyID];
        if (!item || [ids containsObject:itemID]) {
            bad++;
            continue;
        }
        [ids addObject:itemID];
        [items addObject:item];
    }
    if (dropped) {
        *dropped += bad;
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [(NSDate *)[a objectForKey:SLKeyFire] compare:[b objectForKey:SLKeyFire]];
        if (order == NSOrderedSame) {
            NSDate *ca = [a objectForKey:SLKeyCreated], *cb = [b objectForKey:SLKeyCreated];
            if (ca && cb) {
                order = [ca compare:cb];
            }
        }
        if (order == NSOrderedSame) {
            order = [(NSString *)[a objectForKey:SLKeyID] compare:[b objectForKey:SLKeyID]];
        }
        return order;
    }];
}

static NSUInteger SLStoreIndexOfID(NSArray *items, NSString *itemID) {
    NSUInteger index = 0;
    for (NSDictionary *item in items) {
        if ([[item objectForKey:SLKeyID] isEqual:itemID]) {
            return index;
        }
        index++;
    }
    return NSNotFound;
}

#pragma mark - Queue: file and lock

// Set while this thread holds Queue.lock, so a nested call can't deadlock on its own lock.
static pthread_key_t gSLStoreHeldKey;

static BOOL SLStoreLockHeld(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pthread_key_create(&gSLStoreHeldKey, NULL);
    });
    return pthread_getspecific(gSLStoreHeldKey) != NULL;
}

static void SLStoreSetLockHeld(BOOL held) {
    pthread_setspecific(gSLStoreHeldKey, held ? (void *)1 : NULL);
}

static BOOL SLStoreEnsureDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:SL_DIR isDirectory:&isDir] && isDir) {
        return YES;
    }
    NSError *error = nil;
    if ([fm createDirectoryAtPath:SL_DIR withIntermediateDirectories:YES
                       attributes:@{ NSFilePosixPermissions: @0755 } error:&error]) {
        return YES;
    }
    SLLog(@"queue: cannot create the folder (%@ %ld)", error.domain, (long)error.code);
    return NO;
}

// Opens Queue.lock and takes op (LOCK_SH / LOCK_EX), waiting at most SL_STORE_LOCK_WAIT.
// Returns the locked fd, or -1.
static int SLStoreLock(int op) {
    if (!SLStoreEnsureDir()) {
        return -1;
    }
    BOOL existed = access(SL_LOCK_PATH, F_OK) == 0;
    int fd = open(SL_LOCK_PATH, O_RDWR | O_CREAT, 0644);
    if (fd < 0) {
        int err = errno;
        SLLog(@"queue: cannot open the lock (errno %d)", err);
        return -1;
    }
    if (!existed) {
        // Must stay usable while the phone is locked (SpringBoard sends then).
        [[NSFileManager defaultManager] setAttributes:@{ NSFileProtectionKey: NSFileProtectionNone }
                                         ofItemAtPath:[NSString stringWithUTF8String:SL_LOCK_PATH] error:NULL];
    }
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + SL_STORE_LOCK_WAIT;
    while (flock(fd, op | LOCK_NB) != 0) {
        int err = errno;
        if (err != EWOULDBLOCK && err != EINTR) {
            close(fd);
            SLLog(@"queue: flock failed (errno %d)", err);
            return -1;
        }
        if (CFAbsoluteTimeGetCurrent() >= deadline) {
            close(fd);
            SLLog(@"queue: lock busy for %.0f s, giving up", SL_STORE_LOCK_WAIT);
            return -1;
        }
        usleep(5000);
    }
    return fd;
}

static void SLStoreUnlock(int fd) {
    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
}

// Reads the queue file (caller holds the lock, or accepts an unlocked read).
static NSArray *SLStoreReadFile(SLStoreFileStatus *status, NSUInteger *dropped) {
    *status = SLStoreFileOK;
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:SL_QUEUE_PATH options:0 error:&error];
    if (!data) {
        *status = [[NSFileManager defaultManager] fileExistsAtPath:SL_QUEUE_PATH] ? SLStoreFileError : SLStoreFileMissing;
        return @[];
    }
    id root = nil;
    @try {
        root = data.length ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                                         format:NULL error:NULL] : nil;
    } @catch (NSException *exception) {
        root = nil;
    }
    id raw = [root isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)root objectForKey:SL_STORE_KEY_ITEMS] : nil;
    if (![raw isKindOfClass:[NSArray class]]) {
        *status = SLStoreFileGarbage;
        return @[];
    }
    return SLStoreClean(raw, dropped);
}

static BOOL SLStoreWriteFile(NSArray *items, NSString **problem) {
    NSDictionary *root = @{ SL_STORE_KEY_VERSION: @(SL_STORE_VERSION), SL_STORE_KEY_ITEMS: items ?: @[] };
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:&error];
    if (!data) {
        *problem = [NSString stringWithFormat:@"cannot encode (%ld)", (long)error.code];
        return NO;
    }
    // Atomic = temp file + rename: readers see the old or the new file, never half of one.
    if (![data writeToFile:SL_QUEUE_PATH options:NSDataWritingAtomic | NSDataWritingFileProtectionNone error:&error]) {
        *problem = [NSString stringWithFormat:@"cannot write (%@ %ld)", error.domain, (long)error.code];
        return NO;
    }
    return YES;
}

static void SLStoreLogRead(NSString *what, SLStoreFileStatus status, NSUInteger dropped) {
    if (status == SLStoreFileError) {
        SLLog(@"queue: %@: file unreadable, treated as empty", what);
    } else if (status == SLStoreFileGarbage) {
        SLLog(@"queue: %@: file is not a queue, treated as empty", what);
    }
    if (dropped) {
        SLLog(@"queue: %@: dropped %lu malformed item(s)", what, (unsigned long)dropped);
    }
}

// The locked read-modify-write behind every change. change gets the current valid items and returns
// the new list, or nil to leave the queue alone. NO = not locked, unreadable, threw or not written.
static BOOL SLStoreModify(NSString *what, NSArray *(^change)(NSArray *items), BOOL *outChanged) {
    if (outChanged) {
        *outChanged = NO;
    }
    if (!change) {
        return NO;
    }
    if (SLStoreLockHeld()) {
        SLLog(@"queue: %@: nested change refused", what);
        return NO;
    }
    int fd = SLStoreLock(LOCK_EX);
    if (fd < 0) {
        return NO;
    }
    SLStoreSetLockHeld(YES);

    SLStoreFileStatus status = SLStoreFileOK;
    NSUInteger dropped = 0, droppedNew = 0;
    NSString *problem = nil;
    BOOL ok = YES, changed = NO;
    NSArray *before = SLStoreReadFile(&status, &dropped);
    if (status == SLStoreFileError) {
        ok = NO;                    // never replace a queue we could not read
        problem = @"file unreadable, not changed";
    } else {
        id after = nil;
        @try {
            after = change(before);
        } @catch (NSException *exception) {
            ok = NO;
            problem = [NSString stringWithFormat:@"change threw %@", exception.name];
        }
        if (ok && after) {
            if ([after isKindOfClass:[NSArray class]]) {
                NSArray *clean = SLStoreClean(after, &droppedNew);
                changed = ![clean isEqualToArray:before];
                // Also rewrite to clean out malformed entries or a garbage file.
                if (changed || dropped || status == SLStoreFileGarbage) {
                    ok = SLStoreWriteFile(clean, &problem);
                }
            } else {
                ok = NO;
                problem = @"change returned a non-array";
            }
        }
    }

    SLStoreSetLockHeld(NO);
    SLStoreUnlock(fd);

    SLStoreLogRead(what, status, dropped);
    if (droppedNew) {
        SLLog(@"queue: %@: refused %lu invalid item(s)", what, (unsigned long)droppedNew);
    }
    if (problem) {
        SLLog(@"queue: %@: %@", what, problem);
    }
    if (ok && changed) {
        notify_post(SL_NOTIFY_CHANGED);
    }
    if (outChanged) {
        *outChanged = ok && changed;
    }
    return ok;
}

#pragma mark - Queue: public

NSArray *SLQueueItems(void) {
    BOOL nested = SLStoreLockHeld();        // inside a change block this thread already holds LOCK_EX
    int fd = nested ? -1 : SLStoreLock(LOCK_SH);
    SLStoreFileStatus status = SLStoreFileOK;
    NSUInteger dropped = 0;
    NSArray *items = SLStoreReadFile(&status, &dropped);    // unlocked read if the lock failed: still whole
    if (!nested) {
        SLStoreUnlock(fd);
    }
    SLStoreLogRead(@"read", status, dropped);
    return items ?: @[];
}

// The chat match behind both the list and the delete hook: either key.
static BOOL SLStoreItemInChat(NSDictionary *item, NSString *guid, NSString *identifier) {
    return (guid && [[item objectForKey:SLKeyChatGUID] isEqual:guid])
        || (identifier && [[item objectForKey:SLKeyChatID] isEqual:identifier]);
}

NSArray *SLQueueItemsForChat(NSString *chatGUID, NSString *chatID) {
    NSString *guid = SLStoreString(chatGUID), *identifier = SLStoreString(chatID);
    if (!guid && !identifier) {
        return @[];
    }
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *item in SLQueueItems()) {
        if (SLStoreItemInChat(item, guid, identifier)) {
            [matches addObject:item];
        }
    }
    return [matches copy];
}

BOOL SLQueueUpdate(NSArray *(^change)(NSArray *items)) {
    return SLStoreModify(@"update", change, NULL);
}

NSUInteger SLQueueRemoveForChat(NSString *chatGUID, NSString *chatID, BOOL *ok) {
    NSString *guid = SLStoreString(chatGUID), *identifier = SLStoreString(chatID);
    if (ok) {
        *ok = YES;
    }
    if (!guid && !identifier) {
        return 0;
    }
    __block NSUInteger removed = 0;
    BOOL written = SLStoreModify(@"remove chat", ^NSArray *(NSArray *items) {
        removed = 0;
        NSMutableArray *rest = [NSMutableArray arrayWithCapacity:items.count];
        for (NSDictionary *item in items) {
            if (SLStoreItemInChat(item, guid, identifier)) {
                removed++;
            } else {
                [rest addObject:item];
            }
        }
        return removed ? rest : nil;
    }, NULL);
    if (ok) {
        *ok = written;
    }
    return written ? removed : 0;
}

// Insert, or replace the item with the same id.
static BOOL SLStorePut(NSDictionary *item, NSString *what) {
    NSDictionary *valid = SLStoreValidItem(item);
    if (!valid) {
        SLLog(@"queue: %@: invalid item refused", what);
        return NO;
    }
    NSString *itemID = [valid objectForKey:SLKeyID];
    __block BOOL replaced = NO;
    BOOL changed = NO;
    BOOL ok = SLStoreModify(what, ^NSArray *(NSArray *items) {
        NSMutableArray *next = [items mutableCopy];
        NSUInteger index = SLStoreIndexOfID(items, itemID);
        if (index == NSNotFound) {
            [next addObject:valid];
        } else {
            replaced = YES;
            [next replaceObjectAtIndex:index withObject:valid];
        }
        return next;
    }, &changed);
    if (ok) {
        SLLog(@"queue: %@ %@ (%@%@, len %lu)", what, SLIDTail(itemID), [valid objectForKey:SLKeyState],
              replaced ? @", replaced" : @"", (unsigned long)[(NSString *)[valid objectForKey:SLKeyText] length]);
    }
    return ok;
}

BOOL SLQueueAdd(NSDictionary *item) {
    return SLStorePut(item, @"add");
}

BOOL SLQueuePut(NSDictionary *item) {
    return SLStorePut(item, @"put");
}

NSDictionary *SLQueueTake(NSString *itemID) {
    if (!SLStoreIsString(itemID)) {
        return nil;
    }
    __block NSDictionary *taken = nil;
    BOOL changed = NO;
    BOOL ok = SLStoreModify(@"take", ^NSArray *(NSArray *items) {
        NSUInteger index = SLStoreIndexOfID(items, itemID);
        if (index == NSNotFound) {
            return nil;
        }
        taken = [items objectAtIndex:index];
        NSMutableArray *rest = [items mutableCopy];
        [rest removeObjectAtIndex:index];
        return rest;
    }, &changed);
    if (!ok) {
        // Not removed from the file (busy / unreadable / not written), so not claimed: never send it.
        SLLog(@"queue: take %@: could not claim", SLIDTail(itemID));
        return nil;
    }
    if (!taken || !changed) {
        SLLog(@"queue: take %@: already gone", SLIDTail(itemID));
        return nil;
    }
    SLLog(@"queue: took %@", SLIDTail(itemID));
    return taken;
}

BOOL SLQueueRemove(NSString *itemID) {
    if (!SLStoreIsString(itemID)) {
        return NO;
    }
    BOOL changed = NO;
    BOOL ok = SLStoreModify(@"remove", ^NSArray *(NSArray *items) {
        NSUInteger index = SLStoreIndexOfID(items, itemID);
        if (index == NSNotFound) {
            return nil;
        }
        NSMutableArray *rest = [items mutableCopy];
        [rest removeObjectAtIndex:index];
        return rest;
    }, &changed);
    SLLog(@"queue: remove %@: %@", SLIDTail(itemID), (ok && changed) ? @"removed" : (ok ? @"not found" : @"failed"));
    return ok && changed;
}

#pragma mark - Items, dates, text

NSString *SLNewItemID(void) {
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    if (!uuid) {
        return nil;
    }
    NSString *string = (NSString *)CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid));
    CFRelease(uuid);
    return string;
}

NSDate *SLDefaultFireDate(void) {
    // Every current time zone offset is a multiple of 15 minutes, so 5-minute steps of absolute time
    // are also 5-minute steps on the local clock.
    NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate] + 60.0 * 60.0;
    return [NSDate dateWithTimeIntervalSinceReferenceDate:ceil(t / 300.0) * 300.0];
}

NSString *SLFireString(NSDate *date) {
    if (![date isKindOfClass:[NSDate class]]) {
        return @"";
    }
    NSLocale *locale = [NSLocale currentLocale];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDate *today = nil, *day = nil;
    BOOL gotToday = [calendar rangeOfUnit:NSDayCalendarUnit startDate:&today interval:NULL forDate:now];
    BOOL gotDay = [calendar rangeOfUnit:NSDayCalendarUnit startDate:&day interval:NULL forDate:date];
    NSInteger days = NSIntegerMin;
    if (gotToday && gotDay && today && day) {
        days = [[calendar components:NSDayCalendarUnit fromDate:today toDate:day options:0] day];
    }

    NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
    timeFormatter.locale = locale;
    timeFormatter.dateStyle = NSDateFormatterNoStyle;
    timeFormatter.timeStyle = NSDateFormatterShortStyle;
    NSString *time = [timeFormatter stringFromDate:date] ?: @"";

    NSString *dayPart = nil;
    if (days == 0) {
        dayPart = @"Today";
    } else if (days == 1) {
        dayPart = @"Tomorrow";
    } else {
        NSString *template = nil;
        if (days >= 2 && days <= 6) {
            template = @"EEEE";
        } else {
            NSInteger year = [[calendar components:NSYearCalendarUnit fromDate:date] year];
            NSInteger thisYear = [[calendar components:NSYearCalendarUnit fromDate:now] year];
            template = (year == thisYear) ? @"MMMd" : @"yMMMd";
        }
        NSDateFormatter *dayFormatter = [[NSDateFormatter alloc] init];
        dayFormatter.locale = locale;
        dayFormatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:template options:0 locale:locale] ?: template;
        dayPart = [dayFormatter stringFromDate:date] ?: @"";
    }
    return [NSString stringWithFormat:@"%@, %@", dayPart, time];
}

NSString *SLCleanText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || !text.length) {
        return nil;
    }
    NSString *objectMark = [NSString stringWithFormat:@"%C", (unichar)0xFFFC];
    NSString *clean = [text stringByReplacingOccurrencesOfString:objectMark withString:@""];
    NSString *trimmed = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? clean : nil;
}

NSDictionary *SLMakeItem(IMChat *chat, NSString *title, NSString *text, NSDate *fire) {
    NSString *body = SLCleanText(text);
    NSString *itemID = SLNewItemID();
    if (!chat || !body || ![fire isKindOfClass:[NSDate class]] || !itemID) {
        SLLog(@"item: not made (chat %d, text %d, fire %d, id %d)", chat ? 1 : 0, body ? 1 : 0,
              [fire isKindOfClass:[NSDate class]] ? 1 : 0, itemID ? 1 : 0);
        return nil;
    }

    NSString *guid = nil, *chatID = nil, *service = nil;
    NSInteger style = 0;
    NSMutableArray *handles = [NSMutableArray array];
    @try {
        guid = SLStoreCan(chat, @selector(guid)) ? SLStoreString([chat guid]) : nil;
        chatID = SLStoreCan(chat, @selector(chatIdentifier)) ? SLStoreString([chat chatIdentifier]) : nil;
        if (SLStoreCan(chat, @selector(chatStyle))) {
            style = [chat chatStyle];
        }
        IMAccount *account = SLStoreCan(chat, @selector(account)) ? [chat account] : nil;
        service = SLStoreCan(account, @selector(serviceName)) ? SLStoreString([account serviceName]) : nil;
        NSArray *participants = SLStoreCan(chat, @selector(participants)) ? [chat participants] : nil;
        for (id handle in participants) {
            NSString *handleID = SLStoreCan(handle, @selector(ID)) ? SLStoreString([(IMHandle *)handle ID]) : nil;
            if (handleID) {
                [handles addObject:handleID];
            }
        }
    } @catch (NSException *exception) {
        SLLog(@"item: IMChat threw %@", exception.name);
    }
    SLStoreGUIDParts(guid, &service, &style);       // fills only what the chat did not give
    if (!guid || !chatID) {
        SLLog(@"item: chat lacks guid %d / identifier %d", guid ? 1 : 0, chatID ? 1 : 0);
        return nil;
    }

    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    [item setObject:itemID forKey:SLKeyID];
    [item setObject:body forKey:SLKeyText];
    [item setObject:fire forKey:SLKeyFire];
    [item setObject:[NSDate date] forKey:SLKeyCreated];
    [item setObject:guid forKey:SLKeyChatGUID];
    [item setObject:chatID forKey:SLKeyChatID];
    [item setObject:@(style) forKey:SLKeyStyle];
    if (service) {
        [item setObject:service forKey:SLKeyService];
    }
    [item setObject:[handles copy] forKey:SLKeyHandles];
    if (SLStoreIsString(title)) {
        [item setObject:title forKey:SLKeyTitle];
    }
    [item setObject:SLStateScheduled forKey:SLKeyState];
    return [item copy];
}

NSDictionary *SLItemWithState(NSDictionary *item, NSString *state, NSString *reason) {
    if (![item isKindOfClass:[NSDictionary class]] || !SLStoreIsString(state)) {
        return nil;
    }
    NSMutableDictionary *copy = [item mutableCopy];
    [copy setObject:state forKey:SLKeyState];
    if ([state isEqualToString:SLStateFailed] && SLStoreIsString(reason)) {
        [copy setObject:reason forKey:SLKeyReason];
    } else {
        [copy removeObjectForKey:SLKeyReason];      // reason is for failed items only
    }
    return [copy copy];
}

NSDictionary *SLItemWithFire(NSDictionary *item, NSDate *fire) {
    if (![item isKindOfClass:[NSDictionary class]] || ![fire isKindOfClass:[NSDate class]]) {
        return nil;
    }
    NSMutableDictionary *copy = [item mutableCopy];
    [copy setObject:fire forKey:SLKeyFire];
    [copy setObject:SLStateScheduled forKey:SLKeyState];
    [copy removeObjectForKey:SLKeyReason];
    return [copy copy];
}

#pragma mark - IMCore (main thread)

static BOOL SLStoreDaemonConnected(void) {
    Class cls = SLStoreClass(@"IMDaemonController");
    id daemon = SLStoreCan(cls, @selector(sharedInstance)) ? [cls sharedInstance] : nil;
    return SLStoreCan(daemon, @selector(isConnected)) && [(IMDaemonController *)daemon isConnected];
}

// +serviceWithName: waits for imagent (blockUntilConnected, which SpringBoard must never do), so the
// non-blocking twin is used; the blocking one only as a fallback and only once connected.
static id SLStoreServiceNamed(NSString *name) {
    Class cls = SLStoreClass(@"IMService");
    if (!cls) {
        return nil;
    }
    SEL nonBlocking = NSSelectorFromString(@"serviceWithNameNonBlocking:");
    if (SLStoreCan(cls, nonBlocking)) {
        return ((id (*)(id, SEL, id))objc_msgSend)(cls, nonBlocking, name);
    }
    if (SLStoreCan(cls, @selector(serviceWithName:)) && SLStoreDaemonConnected()) {
        return [cls serviceWithName:name];
    }
    return nil;
}

IMAccount *SLAccountForService(NSString *serviceName) {
    if (!SLStoreIsString(serviceName)) {
        return nil;
    }
    SLStoreLoadIMCore();
    SLStoreWarnOffMain(@"account");
    IMAccount *account = nil;
    @try {
        Class cls = SLStoreClass(@"IMAccountController");
        IMAccountController *controller = SLStoreCan(cls, @selector(sharedInstance)) ? [cls sharedInstance] : nil;
        id service = controller ? SLStoreServiceNamed(serviceName) : nil;
        if (service && SLStoreCan(controller, @selector(bestAccountForService:))) {
            account = [controller bestAccountForService:service];
        }
        if (!account && SLStoreCan(controller, @selector(activeAccounts))) {
            for (id candidate in [controller activeAccounts]) {
                if (SLStoreCan(candidate, @selector(serviceName))
                    && [[(IMAccount *)candidate serviceName] isEqual:serviceName]) {
                    account = candidate;
                    break;
                }
            }
        }
    } @catch (NSException *exception) {
        SLLog(@"account: IMAccountController threw %@", exception.name);
        account = nil;
    }
    return account;
}

// YES once the registry has its chats (not loading, more than 0): a miss on paths 1-2 is then a real miss.
static BOOL SLStoreRegistryLoaded(IMChatRegistry *registry) {
    if (!SLStoreCan(registry, @selector(_isLoading)) || !SLStoreCan(registry, @selector(numberOfExistingChats))) {
        return NO;
    }
    return ![registry _isLoading] && [registry numberOfExistingChats] > 0;
}

IMChat *SLFindChat(NSDictionary *item, NSString **how, BOOL allowCreate) {
    if (how) {
        *how = nil;
    }
    if (![item isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    SLStoreLoadIMCore();
    SLStoreWarnOffMain(@"find");

    NSString *guid = SLStoreString([item objectForKey:SLKeyChatGUID]);
    NSString *chatID = SLStoreString([item objectForKey:SLKeyChatID]);
    NSString *service = SLStoreString([item objectForKey:SLKeyService]);
    id styleValue = [item objectForKey:SLKeyStyle];
    NSInteger style = [styleValue isKindOfClass:[NSNumber class]] ? [(NSNumber *)styleValue integerValue] : 0;
    SLStoreGUIDParts(guid, &service, &style);
    id handlesValue = [item objectForKey:SLKeyHandles];
    NSArray *handles = [handlesValue isKindOfClass:[NSArray class]] ? handlesValue : nil;

    IMChat *chat = nil;
    NSString *path = nil;
    BOOL skippedGroup = NO;
    @try {
        Class cls = SLStoreClass(@"IMChatRegistry");
        IMChatRegistry *registry = SLStoreCan(cls, @selector(sharedInstance)) ? [cls sharedInstance] : nil;
        IMAccount *account = nil;
        BOOL triedAccount = NO;
        // 1. the exact chat
        if (registry && guid && SLStoreCan(registry, @selector(existingChatWithGUID:))) {
            chat = [registry existingChatWithGUID:guid];
            path = chat ? @"guid" : nil;
        }
        // 2. same identifier (e.g. the number's chat on the other service)
        if (registry && !chat && chatID && SLStoreCan(registry, @selector(existingChatWithChatIdentifier:))) {
            chat = [registry existingChatWithChatIdentifier:chatID];
            path = chat ? @"identifier" : nil;
        }
        // Paths 3-4 make a chat object, so only when the caller allows it (DESIGN 3).
        if (!allowCreate) {
            registry = nil;
        }
        // A group the loaded registry doesn't know was deleted: never rebuild it (it would have no people).
        if (registry && !chat && style == SL_STYLE_GROUP && SLStoreRegistryLoaded(registry)) {
            skippedGroup = YES;
            registry = nil;
        }
        // 3. one-to-one: the chat for that person's handle on the item's service
        if (registry && !chat && style == SL_STYLE_SINGLE && handles.count == 1 && service) {
            account = SLAccountForService(service);
            triedAccount = YES;
            NSString *handleID = SLStoreString([handles objectAtIndex:0]);
            IMHandle *handle = (handleID && SLStoreCan(account, @selector(imHandleWithID:))) ? [account imHandleWithID:handleID] : nil;
            if (handle && SLStoreCan(registry, @selector(chatForIMHandle:))) {
                chat = [registry chatForIMHandle:handle];
                path = chat ? @"handle" : nil;
            }
        }
        // 4. last resort: a chat object with the real identifier (never a new group)
        if (registry && !chat && chatID && service && (style == SL_STYLE_SINGLE || style == SL_STYLE_GROUP)) {
            if (!triedAccount) {
                account = SLAccountForService(service);
            }
            SEL create = NSSelectorFromString(@"_createdChatWithIdentifier:style:account:");
            if (account && SLStoreCan(registry, create)) {
                chat = ((id (*)(id, SEL, id, unsigned char, id))objc_msgSend)(registry, create, chatID,
                                                                             (unsigned char)style, account);
                path = chat ? @"created" : nil;
            }
        }
    } @catch (NSException *exception) {
        SLLog(@"find: IMChatRegistry threw %@", exception.name);
        chat = nil;
        path = nil;
    }
    if (!chat) {
        SLLog(@"find %@: no chat (guid %d, identifier %d, service %d, style %ld, handles %lu, create %d%@)",
              SLIDTail([item objectForKey:SLKeyID]), guid ? 1 : 0, chatID ? 1 : 0, service ? 1 : 0, (long)style,
              (unsigned long)handles.count, allowCreate ? 1 : 0, skippedGroup ? @", group not in loaded registry" : @"");
    }
    if (how) {
        *how = path;
    }
    return chat;
}

// Exactly the Reactions path: one text part, 0x100005 flags through a 64-bit-argument cast.
// body is already cleaned. nil (with *reason set) when IMMessage is missing or refuses.
static id SLStoreMakeMessage(NSString *body, NSString **reason) {
    Class messageClass = SLStoreClass(@"IMMessage");
    SEL make = @selector(instantMessageWithText:flags:);
    if (!SLStoreCan(messageClass, make)) {
        *reason = @"Messages is not available";
        return nil;
    }
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:body];
    [attributed addAttribute:SL_PART_ATTRIBUTE value:@0 range:NSMakeRange(0, attributed.length)];

    id message = nil;
    @try {
        message = ((id (*)(id, SEL, id, unsigned long long))objc_msgSend)(messageClass, make, attributed, SL_IM_FLAGS);
    } @catch (NSException *exception) {
        SLLog(@"send: IMMessage factory threw %@", exception.name);
        message = nil;
    }
    if (!message) {
        SLLog(@"send: no IMMessage");
        *reason = @"Message could not be created";
    }
    return message;
}

#define SL_STORE_JOINED     3       // -[IMChat joinState]: joined

// The listener bits -[IMChatRegistry _chat:sendMessage:] needs (any one of them, else it drops the send):
// kFZListenerCapChats / ChatObserver / SendMessages from IMFoundation; iOS 6.1 SDK values as fallback.
static unsigned int SLStoreChatCapsMask(void) {
    static unsigned int mask;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SLStoreLoadIMCore();
        const char *names[3] = { "kFZListenerCapChats", "kFZListenerCapChatObserver", "kFZListenerCapSendMessages" };
        const unsigned int fallback[3] = { 0x4, 0x800, 0x1000 };
        int found = 0;
        for (int i = 0; i < 3; i++) {
            const unsigned int *value = (const unsigned int *)dlsym(RTLD_DEFAULT, names[i]);
            if (value) {
                mask |= *value;
                found++;
            } else {
                mask |= fallback[i];
            }
        }
        SLLog(@"imcore: chat capability bits 0x%x (%d of 3 found)", mask, found);
    });
    return mask;
}

// This process's listener capabilities; NO when IMDaemonController can't tell.
static BOOL SLStoreListenerCaps(unsigned int *caps) {
    Class cls = SLStoreClass(@"IMDaemonController");
    id daemon = SLStoreCan(cls, @selector(sharedInstance)) ? [cls sharedInstance] : nil;
    if (!SLStoreCan(daemon, @selector(capabilitiesForListenerID:))) {
        return NO;
    }
    *caps = [(IMDaemonController *)daemon capabilitiesForListenerID:nil];
    return YES;
}

void SLLogIMCoreState(NSString *when) {
    SLStoreLoadIMCore();
    unsigned int caps = 0;
    BOOL known = NO;
    @try {
        known = SLStoreListenerCaps(&caps);
    } @catch (NSException *exception) {
        SLLog(@"imcore %@: capability read threw %@", when, exception.name);
    }
    unsigned int mask = SLStoreChatCapsMask();
    SLLog(@"imcore %@: connected %d, listener caps %@, chat bits %@", when, SLStoreDaemonConnected() ? 1 : 0,
          known ? [NSString stringWithFormat:@"0x%x", caps] : @"unknown",
          known ? ((caps & mask) ? @"yes" : @"NO") : @"unknown");
}

// The gate IMCore itself applies before a send really leaves (checked before an item is claimed):
// an account, a listener allowed to send chats, a joined chat, and -canSendMessage:.
NSString *SLChatNotReady(IMChat *chat, NSString *text, BOOL join) {
    if (!chat) {
        return @"no chat";
    }
    SLStoreLoadIMCore();
    SLStoreWarnOffMain(@"ready");
    NSString *problem = nil;
    unsigned int caps = 0;
    BOOL capsKnown = NO, operational = NO;
    int state = -1;
    @try {
        IMAccount *account = SLStoreCan(chat, @selector(account)) ? [chat account] : nil;
        operational = SLStoreCan(account, @selector(isOperational)) && [account isOperational];
        capsKnown = SLStoreListenerCaps(&caps);
        if (!account) {
            problem = @"chat has no account";
        } else if (capsKnown && !(caps & SLStoreChatCapsMask())) {
            problem = @"listener lacks the chat capabilities";
        }
        if (!problem && SLStoreCan(chat, @selector(joinState))) {
            state = [chat joinState];
            if (state != SL_STORE_JOINED) {
                // IMChat would park the message until a join that may never complete here.
                if (join && SLStoreCan(chat, @selector(join))) {
                    [chat join];
                }
                problem = join ? @"chat not joined, join requested" : @"chat not joined";
            }
        }
        NSString *body = SLCleanText(text);
        if (!problem && body && SLStoreCan(chat, @selector(canSendMessage:))) {
            NSString *reason = nil;
            id message = SLStoreMakeMessage(body, &reason);
            if (!message) {
                problem = @"no IMMessage";
            } else if (![chat canSendMessage:message]) {
                problem = @"chat cannot send it now";
            }
        }
    } @catch (NSException *exception) {
        problem = [NSString stringWithFormat:@"readiness check threw %@", exception.name];
    }
    static BOOL loggedReady = NO;
    if (problem || !loggedReady) {
        loggedReady = loggedReady || !problem;
        SLLog(@"ready: %@ (caps %@, join state %d, operational %d)", problem ?: @"yes",
              capsKnown ? [NSString stringWithFormat:@"0x%x", caps] : @"unknown", state, operational ? 1 : 0);
    }
    return problem;
}

NSString *SLSendText(IMChat *chat, NSString *text) {
    NSString *body = SLCleanText(text);
    if (!chat) {
        return @"Conversation not found";
    }
    if (!body) {
        return @"Nothing to send";
    }
    SLStoreLoadIMCore();
    SLStoreWarnOffMain(@"send");

    if (!SLStoreCan(chat, @selector(sendMessage:))) {
        return @"Messages is not available";
    }
    NSString *reason = nil;
    id message = SLStoreMakeMessage(body, &reason);
    if (!message) {
        return reason;
    }
    @try {
        [chat sendMessage:message];
    } @catch (NSException *exception) {
        SLLog(@"send: -[IMChat sendMessage:] threw %@", exception.name);
        return @"Messages could not send it";
    }
    SLLog(@"send: handed to imagent (len %lu)", (unsigned long)body.length);
    return nil;
}
