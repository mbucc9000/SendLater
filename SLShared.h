// Send Later 1.0.0 - SLShared.h: the contract shared by every file (see DESIGN.md).
//
// iOS 6.1.2, armv7, ARC. ChatKit / IMCore / PersistentConnection classes are reached ONLY through
// NSClassFromString / objc_getClass (no class symbols are linked), and every private selector is called
// behind respondsToSelector:. The interfaces below only give the compiler method signatures.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>

#define SL_VERSION              @"1.0.0"
#define SL_DIR                  @"/var/mobile/Library/SendLater"
#define SL_QUEUE_PATH           @"/var/mobile/Library/SendLater/Queue.plist"
#define SL_LOCK_PATH            "/var/mobile/Library/SendLater/Queue.lock"
#define SL_LOG_PATH             "/var/mobile/SendLater.log"
#define SL_LOG_MAX_BYTES        (256 * 1024)
#define SL_NOTIFY_CHANGED       "com.mbucc9000.sendlater/changed"
#define SL_TIMER_SERVICE        @"com.mbucc9000.sendlater"
#define SL_IM_FLAGS             0x100005ULL                 // finished | fromMe | wasDataDetected
#define SL_PART_ATTRIBUTE       @"__kIMMessagePartAttributeName"
#define SL_STYLE_GROUP          43                          // '+'
#define SL_STYLE_SINGLE         45                          // '-'
#define SL_MAX_LATE             (6.0 * 60.0 * 60.0)         // s: a missed item older than this fails instead
#define SL_MIN_LEAD             60.0                        // s: earliest allowed fire time from now
#define SL_MAX_LEAD             (366.0 * 24.0 * 60.0 * 60.0)
#define SL_RETRY_INTERVAL       5.0                         // s between SpringBoard readiness retries
#define SL_RETRY_LIMIT          8
#define SL_STARTUP_DELAY        20.0                        // s after SpringBoard finished launching
#define SL_POWER_HOLD           60.0                        // s the power assertion outlives the last send

// Item keys (DESIGN.md section 2)
#define SLKeyID                 @"id"
#define SLKeyText               @"text"
#define SLKeyFire               @"fire"         // NSDate
#define SLKeyCreated            @"created"      // NSDate
#define SLKeyChatGUID           @"chatGUID"     // -[IMChat guid]
#define SLKeyChatID             @"chatID"       // -[IMChat chatIdentifier]
#define SLKeyStyle              @"style"        // NSNumber (unsigned char chatStyle)
#define SLKeyService            @"service"      // -[IMAccount serviceName]
#define SLKeyHandles            @"handles"      // NSArray of NSString (-[IMHandle ID])
#define SLKeyTitle              @"title"        // -[CKConversation name], UI only
#define SLKeyState              @"state"
#define SLKeyReason             @"reason"       // failed only
#define SLStateScheduled        @"scheduled"
#define SLStateFailed           @"failed"

#pragma mark - Private API used (signatures only; verified against the iOS 6.1 SDK / device dumps)

@interface IMService : NSObject
+ (id)serviceWithName:(NSString *)name;
- (NSString *)name;
@end

@interface IMHandle : NSObject
- (NSString *)ID;
@end

@interface IMAccount : NSObject
- (NSString *)serviceName;
- (id)service;
- (IMHandle *)imHandleWithID:(NSString *)handleID;
- (BOOL)isActive;
- (BOOL)isOperational;
@end

@interface IMAccountController : NSObject
+ (id)sharedInstance;
- (IMAccount *)bestAccountForService:(id)service;
- (NSArray *)activeAccounts;
@end

@interface IMMessage : NSObject
+ (id)instantMessageWithText:(NSAttributedString *)text flags:(unsigned long long)flags;   // @20@0:4@8Q12
- (NSString *)guid;
@end

@interface IMChat : NSObject
- (NSString *)guid;
- (NSString *)chatIdentifier;
- (unsigned char)chatStyle;
- (NSArray *)participants;          // IMHandle
- (IMAccount *)account;
- (void)sendMessage:(id)imMessage;
- (BOOL)canSendMessage:(id)imMessage;   // c12@0:4@8: [account hasCapability:0x400] + transfers
- (int)joinState;                       // i8@0:4: 3 = joined (a send to an unjoined chat is parked)
- (void)join;                           // v8@0:4: no-op when joined
@end

@interface IMChatRegistry : NSObject
+ (id)sharedInstance;
- (IMChat *)existingChatWithGUID:(NSString *)guid;
- (IMChat *)existingChatWithChatIdentifier:(NSString *)identifier;
- (IMChat *)chatForIMHandle:(IMHandle *)handle;
- (unsigned int)numberOfExistingChats;
- (BOOL)_isLoading;
// - (IMChat *)_createdChatWithIdentifier:(NSString *)ident style:(unsigned char)style account:(IMAccount *)a;
//   (@20@0:4@8C12@16) - call through an explicit objc_msgSend cast.
@end

@interface IMDaemonController : NSObject
+ (id)sharedInstance;
- (BOOL)isConnected;
- (BOOL)isConnecting;
- (BOOL)connectToDaemon;
- (unsigned int)capabilitiesForListenerID:(NSString *)listenerID;     // I12@0:4@8; nil = this process
@end

@interface PCPersistentTimer : NSObject
- (id)initWithFireDate:(NSDate *)date serviceIdentifier:(NSString *)service target:(id)target
              selector:(SEL)selector userInfo:(id)userInfo;     // @28@0:4@8@12@16:20@24
- (void)setMinimumEarlyFireProportion:(double)proportion;       // v16@0:4d8
- (void)setDisableSystemWaking:(BOOL)disable;
- (void)scheduleInRunLoop:(NSRunLoop *)runLoop;
- (void)invalidate;
- (BOOL)isValid;
@end

@interface CKMessageComposition : NSObject
- (NSString *)textString;
- (NSString *)subject;
- (BOOL)isTextOnly;
- (BOOL)hasNonwhiteSpaceContent;
@end

@interface CKContentEntryView : UIView
- (CKMessageComposition *)messageComposition;
- (void)clearMessage;
- (BOOL)hasContent;
@end

@interface CKConversation : NSObject
- (IMChat *)chat;
- (NSString *)name;
- (void)setUnsentComposition:(id)composition;
@end

@interface CKMessageEntryView : UIImageView
- (CKContentEntryView *)entryField;
- (id)delegate;                     // the CKTranscriptController
@end

@interface CKTranscriptController : UIViewController
- (CKConversation *)conversation;
- (CKMessageEntryView *)entryView;
- (void)entryFieldContentChanged:(id)entryField;
@end

#pragma mark - SLStore.m (both processes)

void SLLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *SLProcessTag(void);                       // @"SB" / @"SMS" / getprogname()
NSString *SLIDTail(NSString *itemID);               // last 4 characters, for logs

NSArray *SLQueueItems(void);                        // every valid item, sorted by fire date; never nil
NSArray *SLQueueItemsForChat(NSString *chatGUID, NSString *chatID);   // matches either key
BOOL SLQueueAdd(NSDictionary *item);
NSDictionary *SLQueueTake(NSString *itemID);        // removes and returns it (claim); nil when already gone
BOOL SLQueuePut(NSDictionary *item);                // insert, or replace the item with the same id
BOOL SLQueueRemove(NSString *itemID);
BOOL SLQueueUpdate(NSArray *(^change)(NSArray *items));   // locked read-modify-write; notifies when changed
NSUInteger SLQueueRemoveForChat(NSString *chatGUID, NSString *chatID, BOOL *ok);  // count removed (same match)

NSString *SLNewItemID(void);
NSDate *SLDefaultFireDate(void);                    // now + 1 h, rounded up to the next 5 minutes
NSString *SLFireString(NSDate *date);               // "Today, 3:05 PM" (DESIGN 5)
NSString *SLCleanText(NSString *text);              // U+FFFC removed; nil when nothing but whitespace is left

// Builds a new scheduled item for this chat (nil when the chat lacks a guid/identifier).
NSDictionary *SLMakeItem(IMChat *chat, NSString *title, NSString *text, NSDate *fire);
NSDictionary *SLItemWithState(NSDictionary *item, NSString *state, NSString *reason);   // copy, state changed
NSDictionary *SLItemWithFire(NSDictionary *item, NSDate *fire);                         // copy, rescheduled

IMAccount *SLAccountForService(NSString *serviceName);
// how: "guid" / "identifier" / "handle" / "created". allowCreate NO = existing chats only (paths 1-2);
// path 4 is never used for a group once the registry has loaded (DESIGN 3).
IMChat *SLFindChat(NSDictionary *item, NSString **how, BOOL allowCreate);
// nil when IMCore would really send on this chat now, else a short log label (never user text). join: ask an
// unjoined chat to join, so a later try can find it ready (DESIGN 4).
NSString *SLChatNotReady(IMChat *chat, NSString *text, BOOL join);
void SLLogIMCoreState(NSString *when);                     // connected + listener capability mask, for the log
NSString *SLSendText(IMChat *chat, NSString *text);        // nil = handed to imagent, else a short reason

#pragma mark - SLSender.m (SpringBoard)

void SLSenderStart(void);                           // once, from -[SpringBoard applicationDidFinishLaunching:]

#pragma mark - SLMessages.m (MobileSMS)

void SLAttachToEntryView(CKMessageEntryView *entryView);   // from -[CKMessageEntryView layoutSubviews]
void SLMessagesStart(void);                                 // once, from %ctor in MobileSMS
void SLConversationWillDelete(CKConversation *conversation);  // from -[CKConversation _deleteAllMessagesAndRemoveGroup:YES]
