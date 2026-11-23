// IconLock: keeps the app icon picked in RyukGram.
//
// Instagram 454+ re-applies the icon on launch (the Instagram Plus
// custom-icon benefit check resets it to default for non-subscribers).
// This guards UIApplication's icon setters: a change that does not match
// the icon stored by RyukGram (RYGSelectedAppIconName) is dropped.
// Changes RyukGram makes itself still go through, whether it writes the
// preference before or after calling the setter (re-checked after a delay).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

typedef void (^IconDone)(NSError *);
typedef void (*SetIconIMP)(id, SEL, NSString *, IconDone);

static SetIconIMP origPublic;
static SetIconIMP origPrivate;

static NSSet<NSString *> *alternateIconNames(void) {
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *icons = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleIcons"];
        NSDictionary *alts = icons[@"CFBundleAlternateIcons"];
        names = [NSSet setWithArray:alts.allKeys ?: @[]];
    });
    return names;
}

// The icon RyukGram wants, or nil when it has no valid choice stored
// (then nothing is blocked and Instagram behaves as stock).
static NSString *wantedIcon(void) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:@"RYGSelectedAppIconName"];
    if (![v isKindOfClass:NSString.class] || [(NSString *)v length] == 0) return nil;
    return [alternateIconNames() containsObject:v] ? v : nil;
}

static BOOL sameIcon(NSString *a, NSString *b) {
    if (a.length == 0 && b.length == 0) return YES;
    return [a isEqualToString:b];
}

static void guardedSet(SetIconIMP orig, id self, SEL _cmd, NSString *name, IconDone done) {
    NSString *wanted = wantedIcon();
    if (!wanted || sameIcon(wanted, name)) {
        orig(self, _cmd, name, done);
        return;
    }
    // Mismatch: give RyukGram a moment in case it stores the pick after
    // calling the setter, then decide.
    NSString *nameCopy = [name copy];
    IconDone doneCopy = [done copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *now = wantedIcon();
        if (!now || sameIcon(now, nameCopy)) {
            orig(self, _cmd, nameCopy, doneCopy);
        } else {
            NSLog(@"[IconLock] blocked icon change to %@ (keeping %@)", nameCopy ?: @"default", now);
            if (doneCopy) doneCopy(nil);
        }
    });
}

static void hookPublic(id self, SEL _cmd, NSString *name, IconDone done) {
    guardedSet(origPublic, self, _cmd, name, done);
}

static void hookPrivate(id self, SEL _cmd, NSString *name, IconDone done) {
    guardedSet(origPrivate, self, _cmd, name, done);
}

__attribute__((constructor)) static void IconLockInit(void) {
    Class app = UIApplication.class;
    Method m = class_getInstanceMethod(app, @selector(setAlternateIconName:completionHandler:));
    if (m) origPublic = (SetIconIMP)method_setImplementation(m, (IMP)hookPublic);
    m = class_getInstanceMethod(app, NSSelectorFromString(@"_setAlternateIconName:completionHandler:"));
    if (m) origPrivate = (SetIconIMP)method_setImplementation(m, (IMP)hookPrivate);
}
