#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

#if __has_include(<substrate.h>)
#import <substrate.h>
#else
extern void MSHookFunction(void *symbol, void *replace, void **result);
#endif

#define MP_IMAGE_BASE   0x100000000ULL
#define MP_KEY_BUY      @"sm_pro_purchased"
#define MP_KEY_GRACE    @"sm_offline_grace_start_utc"
#define MP_KEY_UNREACH  @"sm_offline_unreachable_minutes"

/*
 * Offsets (from the __TEXT image base 0x100000000) inside MonitorPlus 1.6.0
 *
 * 0x492778  SubscriptionModel.isSubscribed @Published setter (self in x20, value in x0)
 *            -> also writes NSUserDefaults sm_pro_purchased. Every "false" path
 *               (entitlement fail / grace expired / restore fail) funnels here.
 * 0x4931A8  Transaction.updates / entitlement write-back closure
 * 0x4925B8  refreshEntitlementOnLaunchOrForeground() write-back closure
 * 0x4943A0  checkEntitlement(retryIntervals:)  <- async StoreKit2 validation.
 *            No-op'ing it means the negative result is never produced at all,
 *            so neither isSubscribed nor purchaseStatus can be flipped back.
 */

// All four are __swiftcall void functions: an empty replacement is enough.
static void mp_noop(void) { }
static void (*mp_setter_orig)(void);
static void (*mp_validator_orig)(void);
static void (*mp_refresh_orig)(void);
static void (*mp_check_orig)(void);

%group MPDefaults
%hook NSUserDefaults
- (BOOL)boolForKey:(NSString *)key {
    if ([key isEqualToString:MP_KEY_BUY]) return YES;
    return %orig;
}
- (id)objectForKey:(NSString *)key {
    if ([key isEqualToString:MP_KEY_BUY]) return @YES;
    return %orig;
}
- (NSInteger)integerForKey:(NSString *)key {
    if ([key isEqualToString:MP_KEY_UNREACH]) return 0;   // grace never expires
    return %orig;
}
- (double)doubleForKey:(NSString *)key {
    if ([key isEqualToString:MP_KEY_UNREACH]) return 0.0;
    return %orig;
}
- (void)setBool:(BOOL)value forKey:(NSString *)key {
    if ([key isEqualToString:MP_KEY_BUY]) value = YES;
    %orig;
}
- (void)setObject:(id)value forKey:(NSString *)key {
    if ([key isEqualToString:MP_KEY_BUY]) value = @YES;
    %orig;
}
- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    if ([key isEqualToString:MP_KEY_UNREACH]) value = 0;
    %orig;
}
- (void)removeObjectForKey:(NSString *)key {
    if ([key isEqualToString:MP_KEY_BUY]) return;
    %orig;
}
%end
%end

%group MPRealm
%hook _TtC11MonitorPlus12RealmSession
- (BOOL)isSubscribed { return YES; }
%end
%end

%group MPSubscription
// Re-validation entry points. Blocking them stops every foreground/background
// re-check before it can reach checkEntitlement().
%hook _TtC11MonitorPlus17SubscriptionModel
- (void)handleWillEnterForeground { }
- (void)handleDidEnterBackground { }
%end
%end

%ctor {
    @autoreleasepool {
        %init(MPDefaults);
        if (objc_getClass("_TtC11MonitorPlus12RealmSession") != NULL) %init(MPRealm);
        if (objc_getClass("_TtC11MonitorPlus17SubscriptionModel") != NULL) %init(MPSubscription);

        // Locate the MonitorPlus image by scanning ALL loaded images.
        // (image 0 is not guaranteed to be the app under every injection path.)
        uintptr_t slide = 0;
        BOOL found = NO;
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm) continue;
            NSString *path = [NSString stringWithUTF8String:nm];
            if ([path.lastPathComponent isEqualToString:@"MonitorPlus"]) {
                slide = _dyld_get_image_vmaddr_slide(i);
                found = YES;
                break;
            }
        }

        if (!found) {
            NSLog(@"[MonitorPlusHook] MonitorPlus image NOT found (%u images); only ObjC hooks active", count);
            return;
        }

        uintptr_t base      = (uintptr_t)MP_IMAGE_BASE + slide;
        uintptr_t setter    = base + 0x492778;
        uintptr_t validator = base + 0x4931A8;
        uintptr_t refresh   = base + 0x4925B8;
        uintptr_t check     = base + 0x4943A0;

        MSHookFunction((void *)setter,    (void *)mp_noop, (void **)&mp_setter_orig);
        MSHookFunction((void *)validator, (void *)mp_noop, (void **)&mp_validator_orig);
        MSHookFunction((void *)refresh,   (void *)mp_noop, (void **)&mp_refresh_orig);
        MSHookFunction((void *)check,     (void *)mp_noop, (void **)&mp_check_orig);

        NSLog(@"[MonitorPlusHook] slide=0x%lx setter=0x%lx(orig=%p) validator=0x%lx(orig=%p) refresh=0x%lx(orig=%p) check=0x%lx(orig=%p)",
              (unsigned long)slide,
              (unsigned long)setter,    mp_setter_orig,
              (unsigned long)validator, mp_validator_orig,
              (unsigned long)refresh,   mp_refresh_orig,
              (unsigned long)check,     mp_check_orig);
    }
}
