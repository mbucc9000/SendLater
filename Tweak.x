// Send Later 1.0.0 - Tweak.x: the only hooks (DESIGN.md sections 4 and 5).
//
// SpringBoard: start the scheduler once launching is done.
// MobileSMS:   add the touch-and-hold recognizer to the entry bar (Send button touches only), and cancel
//              a conversation's scheduled messages when the conversation is deleted.

#import "SLShared.h"

%group SLSpringBoard

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application
{
    %orig;
    static BOOL started = NO;
    if (!started) {
        started = YES;
        SLSenderStart();
    }
}

%end

%end

%group SLMobileSMS

%hook CKMessageEntryView

- (void)layoutSubviews
{
    %orig;
    SLAttachToEntryView((CKMessageEntryView *)self);
}

%end

%hook CKConversation

// v12@0:4c8 (iOS 6.1 ChatKit): deleteAllMessagesAndRemoveGroup -> YES, deleteAllMessages (Clear All) -> NO.
- (void)_deleteAllMessagesAndRemoveGroup:(BOOL)removeGroup
{
    if (removeGroup) {
        SLConversationWillDelete((CKConversation *)self);     // before %orig: the chat is still there
    }
    %orig;
}

%end

%end

%ctor
{
    @autoreleasepool {
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundle isEqualToString:@"com.apple.springboard"]) {
            SLLog(@"Send Later %@ loaded in SpringBoard", SL_VERSION);
            %init(SLSpringBoard);
        } else if ([bundle isEqualToString:@"com.apple.MobileSMS"]) {
            SLLog(@"Send Later %@ loaded in MobileSMS", SL_VERSION);
            SLMessagesStart();
            %init(SLMobileSMS);
        }
    }
}
