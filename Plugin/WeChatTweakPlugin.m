//
//  WeChatTweakPlugin.m
//  WeChatTweak
//
//  Runtime recall marking plugin.
//  Hooks FFProcessReqsvrZZ's DelRevokedMsg:msgData: to prepend
//  "[已撤回]" to recalled text messages.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP sOriginalDelRevokedMsg = NULL;

static void hooked_DelRevokedMsg(id self, SEL _cmd, id session, id msgData) {
    @try {
        // Only modify text messages (messageType == 1)
        BOOL shouldMark = NO;
        if ([msgData respondsToSelector:NSSelectorFromString(@"messageType")]) {
            NSInteger msgType = ((NSInteger (*)(id, SEL))objc_msgSend)(
                msgData, NSSelectorFromString(@"messageType"));
            shouldMark = (msgType == 1);
        }

        if (shouldMark && [msgData respondsToSelector:NSSelectorFromString(@"msgContent")]) {
            NSString *content = ((NSString *(*)(id, SEL))objc_msgSend)(
                msgData, NSSelectorFromString(@"msgContent"));
            if (content && ![content hasPrefix:@"[已撤回]"]) {
                NSString *marked = [NSString stringWithFormat:@"[已撤回] %@", content];
                if ([msgData respondsToSelector:NSSelectorFromString(@"setMsgContent:")]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(
                        msgData, NSSelectorFromString(@"setMsgContent:"), marked);
                }
            }
        }

        // Persist the modification
        SEL modifySel = NSSelectorFromString(@"ModifyMsgData:msgData:");
        if ([self respondsToSelector:modifySel]) {
            NSMethodSignature *sig = [self methodSignatureForSelector:modifySel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:self];
                [inv setSelector:modifySel];
                [inv setArgument:&session atIndex:2];
                [inv setArgument:&msgData atIndex:3];
                [inv invoke];
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[WeChatTweak] Exception in hooked_DelRevokedMsg: %@", exception);
    }

    // Call original (binary-patched to return 0, effectively a no-op)
    if (sOriginalDelRevokedMsg) {
        ((void (*)(id, SEL, id, id))sOriginalDelRevokedMsg)(self, _cmd, session, msgData);
    }
}

__attribute__((constructor))
static void WeChatTweakPluginInit(void) {
    NSLog(@"[WeChatTweak] Plugin loaded.");

    Class cls = NSClassFromString(@"FFProcessReqsvrZZ");
    if (!cls) {
        NSLog(@"[WeChatTweak] FFProcessReqsvrZZ class not found. Plugin inactive.");
        return;
    }

    SEL sel = NSSelectorFromString(@"DelRevokedMsg:msgData:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        NSLog(@"[WeChatTweak] DelRevokedMsg:msgData: not found. Plugin inactive.");
        return;
    }

    sOriginalDelRevokedMsg = method_setImplementation(method, (IMP)hooked_DelRevokedMsg);
    NSLog(@"[WeChatTweak] Successfully hooked DelRevokedMsg:msgData:");
}
