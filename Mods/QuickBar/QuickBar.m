//
//  QuickBar.m
//  QuickBar — LiveContainer guest-app overlay.
//
//  Design (final):
//    * Default: a short dark tab glued to the very top edge (y = 0, no inset),
//      showing only a small gamepad glyph. Bottom corners rounded, top flat.
//    * Idle 3s: fades to 15% so it barely affects the game picture.
//    * Tap: tab widens to reveal "应用列表" and a compact app-switch card
//      drops below it. Current app is highlighted; tapping another app
//      switches via LCSharedUtils and the current guest exits.
//    * Tab can be dragged horizontally anywhere along the top edge; its
//      position (as a width ratio) is remembered and survives rotation.
//    * Landscape and portrait both supported.
//
//  Target: stock LiveContainer 3.8.11 (com.kdt.livecontainer), iOS 15+.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Configuration

static CGFloat const QBTabWidth          = 64.0;   // fixed tongue, never stretches
static CGFloat const QBTabHeight         = 28.0;   // low profile
static CGFloat const QBTabBottomCorner   = 14.0;   // rounded bottom, flat top
static CGFloat const QBCardMaxWidth      = 380.0;  // wide switcher panel
static CGFloat const QBToolbarHeight     = 56.0;   // top bar: back to LC / settings
static CGFloat const QBToolbarInset      = 30.0;   // toolbar items pulled inwards
static CGFloat const QBPanelHeight       = 420.0;  // list page height (4 cards)
static CGFloat const QBCardListInset     = 14.0;   // symmetric row inset (keeps list centered)
static CGFloat const QBCardRowMinHeight  = 64.0;   // never squeeze a row below this
static NSUInteger const QBVisibleRows    = 4;      // apps shown per page (scroll for more)
static NSTimeInterval const QBFadeDelay  = 3.0;
static CGFloat const QBIdleAlpha         = 0.15;
static CGFloat const QBDragThreshold     = 6.0;

static NSString * const QBXRatioKey      = @"QuickBarXRatio";
static NSString * const QBYRatioKey      = @"QuickBarYRatio";
static NSString * const QBDisableKey     = @"QuickBarDisable";

#pragma mark - LC private interfaces (declared locally)

@interface NSUserDefaults (QBPrivate)
+ (BOOL)isLiveProcess;
+ (BOOL)isSideStore;
+ (NSString *)lcAppUrlScheme;
+ (NSString *)lcGuestAppId;
+ (NSUserDefaults *)lcUserDefaults;
+ (NSDictionary *)guestAppInfo;
@end

@interface LCSharedUtils : NSObject
+ (BOOL)launchToGuestAppWithURL:(NSURL *)url;
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode;
+ (NSURL *)appGroupPath;
@end

#pragma mark - Helpers

static BOOL QBIsChinese(void) {
    NSString *lang = [[NSLocale preferredLanguages] firstObject] ?: @"";
    return [lang hasPrefix:@"zh"];
}

// Dynamic colors that follow the system light/dark appearance so text stays
// legible in both modes on the glass surface.
static UIColor *QBDynamicColor(UIColor *light, UIColor *dark) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        }];
    }
    return light;
}

static UIColor *QBTextPrimary(void) {
    return QBDynamicColor([UIColor colorWithWhite:0.10 alpha:1.0],
                          [UIColor colorWithWhite:0.95 alpha:1.0]);
}
static UIColor *QBTextSecondary(void) {
    return QBDynamicColor([UIColor colorWithWhite:0.38 alpha:1.0],
                          [UIColor colorWithWhite:0.72 alpha:1.0]);
}
// Warm accent used by the hero (house) glyph — matches the reference design.
static UIColor *QBAccentOrange(void) {
    return QBDynamicColor([UIColor colorWithRed:0.98 green:0.58 blue:0.16 alpha:1.0],
                          [UIColor colorWithRed:1.00 green:0.69 blue:0.30 alpha:1.0]);
}

// Pastel glass sheets for the two toolbar actions: pale green for "back to
// LiveContainer", pale red for "settings"/"back". Alphas stay low so the
// material still reads as glass rather than paint.
static UIColor *QBGlassGreenFill(void) {
    // Deliberately faint: these are floating sheets, not solid buttons — the
    // game should read through them. 0.50/0.55 read like painted pills.
    return QBDynamicColor([UIColor colorWithRed:0.62 green:0.93 blue:0.72 alpha:0.30],
                          [UIColor colorWithRed:0.20 green:0.50 blue:0.30 alpha:0.36]);
}
static UIColor *QBGlassGreenInk(void) {
    return QBDynamicColor([UIColor colorWithRed:0.06 green:0.40 blue:0.18 alpha:1.0],
                          [UIColor colorWithRed:0.72 green:0.98 blue:0.78 alpha:1.0]);
}
static UIColor *QBGlassRedFill(void) {
    return QBDynamicColor([UIColor colorWithRed:1.00 green:0.73 blue:0.73 alpha:0.30],
                          [UIColor colorWithRed:0.58 green:0.22 blue:0.24 alpha:0.36]);
}
static UIColor *QBGlassRedInk(void) {
    return QBDynamicColor([UIColor colorWithRed:0.60 green:0.09 blue:0.11 alpha:1.0],
                          [UIColor colorWithRed:1.00 green:0.79 blue:0.79 alpha:1.0]);
}
// Same glass sheet in blue — carries the "return to LiveContainer" action now
// that the green was handed over to the launch pill.
static UIColor *QBGlassBlueFill(void) {
    return QBDynamicColor([UIColor colorWithRed:0.36 green:0.62 blue:1.00 alpha:0.30],
                          [UIColor colorWithRed:0.18 green:0.36 blue:0.62 alpha:0.36]);
}
static UIColor *QBGlassBlueInk(void) {
    return QBDynamicColor([UIColor colorWithRed:0.06 green:0.28 blue:0.62 alpha:1.0],
                          [UIColor colorWithRed:0.76 green:0.88 blue:1.00 alpha:1.0]);
}

// Green used for live status, running dots and the memory bar, matching the
// reference design. Slightly different shades keep contrast in both modes.
static UIColor *QBGreen(void) {
    return QBDynamicColor([UIColor colorWithRed:0.16 green:0.66 blue:0.30 alpha:1.0],
                          [UIColor colorWithRed:0.30 green:0.85 blue:0.40 alpha:1.0]);
}

// Match the display's inner corner radius (squircle) so the panel feels like
// a native sheet. displayCornerRadius is a stable UIScreen property; guarded
// by respondsToSelector with a sane fallback.
static CGFloat QBScreenCornerRadius(void) {
    if (@available(iOS 16.0, *)) {
        UIScreen *screen = UIScreen.mainScreen;
        SEL sel = NSSelectorFromString(@"displayCornerRadius");
        if ([screen respondsToSelector:sel]) {
            CGFloat r = ((CGFloat (*)(id, SEL))objc_msgSend)(screen, sel);
            if (r > 12.0 && r < 90.0) return r;
        }
    }
    return 44.0;
}

static NSUserDefaults *QBDefaults(void) {
    if ([NSUserDefaults respondsToSelector:@selector(lcUserDefaults)]) {
        NSUserDefaults *d = [NSUserDefaults lcUserDefaults];
        if (d) return d;
    }
    return NSUserDefaults.standardUserDefaults;
}

// Only show QuickBar inside a real guest app (game/app running under LC).
// LiveContainer uses process-wide flags set at launch:
//   isLiveProcess = YES  -> LC's own host UI / liveprocess
//   isSideStore   = YES  -> built-in SideStore store UI (News/Sources/My Apps)
// Both must be NO for a genuine guest. The store UI had isLiveProcess==NO,
// so checking only that flag let the tab leak onto the store and block taps.
static BOOL QBIsGuestApp(void) {
    if ([NSUserDefaults respondsToSelector:@selector(isSideStore)] &&
        [NSUserDefaults isSideStore]) return NO;
    if ([NSUserDefaults respondsToSelector:@selector(isLiveProcess)] &&
        [NSUserDefaults isLiveProcess]) return NO;
    return YES;
}

static UIWindowScene *QBActiveWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:UIWindowScene.class]) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static NSString *QBCurrentBundleID(void) {
    if ([NSUserDefaults respondsToSelector:@selector(lcGuestAppId)]) {
        NSString *s = [NSUserDefaults lcGuestAppId];
        if (s.length) return s;
    }
    return NSBundle.mainBundle.bundleIdentifier;
}

// Try to resolve a guest app's real icon from its bundle directory. LC keeps
// the extracted bundle (Info.plist) in the same folder, so icons named by
// CFBundleIconFiles / CFBundleIconFile live next to it. Falls back to nil,
// at which point the card draws a letter tile.
static UIImage *QBAppIcon(NSString *dir, NSDictionary *info) {
    if (!dir.length) return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSDictionary *primary = info[@"CFBundlePrimaryIcon"] ?: info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
    NSArray *files = primary[@"CFBundleIconFiles"] ?: info[@"CFBundleIconFiles"];
    if ([files isKindOfClass:NSArray.class]) [names addObjectsFromArray:files];
    NSString *single = primary[@"CFBundleIconFile"] ?: info[@"CFBundleIconFile"];
    if ([single isKindOfClass:NSString.class] && single.length) [names addObject:single];
    [names addObjectsFromArray:@[@"AppIcon", @"AppIcon60x60", @"AppIcon76x76", @"Icon"]];

    NSArray *suffixes = @[@"@3x.png", @"@2x.png", @".png", @"@3x", @"@2x", @""];
    for (NSString *base in names) {
        if (![base isKindOfClass:NSString.class] || !base.length) continue;
        for (NSString *sfx in suffixes) {
            NSString *path = [dir stringByAppendingPathComponent:[base stringByAppendingString:sfx]];
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            if (img) return img;
        }
    }
    return nil;
}

// Path to the current guest app's LCAppInfo.plist — the exact data source
// LC's own "App Settings" page reads and writes. LCBootstrap.m builds it as
// LC_HOME_PATH/Documents/Applications/<selected>, where <selected> is the
// "selected" key of lcUserDefaults (our lcGuestAppId). This lets our settings
// panel stay fully in sync with LC's native App Settings page.
static NSString *QBCurrentAppPlistPath(void) {
    NSString *sel = nil;
    if ([NSUserDefaults respondsToSelector:@selector(lcGuestAppId)]) {
        sel = [NSUserDefaults lcGuestAppId];
    }
    if (!sel.length) {
        Class su = NSClassFromString(@"LCSharedUtils");
        if (su) {
            NSUserDefaults *d = ((id (*)(id, SEL))objc_msgSend)(su, @selector(lcUserDefaults));
            sel = [d stringForKey:@"selected"];
        }
    }
    if (!sel.length) sel = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if (!sel.length) return nil;

    NSMutableArray<NSString *> *bases = [NSMutableArray array];
    const char *lcHome = getenv("LC_HOME_PATH");
    if (lcHome && *lcHome) {
        [bases addObject:[[NSString stringWithUTF8String:lcHome]
            stringByAppendingPathComponent:@"Documents/Applications"]];
    }
    const char *home = getenv("HOME");
    if (home && *home) {
        [bases addObject:[[NSString stringWithUTF8String:home]
            stringByAppendingPathComponent:@"Documents/Applications"]];
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *base in bases) {
        NSString *p = [[base stringByAppendingPathComponent:sel]
            stringByAppendingPathComponent:@"LCAppInfo.plist"];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

// Locate the installed guest apps. Directories under .../Applications are
// named by bundle id and contain Info.plist + LCAppInfo.plist.
static NSArray<NSDictionary *> *QBLoadGuestApps(void) {
    NSMutableArray *result = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSMutableArray<NSString *> *bases = [NSMutableArray array];
    const char *lcHome = getenv("LC_HOME_PATH");
    if (lcHome && *lcHome) {
        NSString *h = [NSString stringWithUTF8String:lcHome];
        [bases addObject:[h stringByAppendingPathComponent:@"Documents/Applications"]];
    }
    const char *home = getenv("HOME");
    if (home && *home) {
        NSString *h = [NSString stringWithUTF8String:home];
        [bases addObject:[h stringByAppendingPathComponent:@"Documents/Applications"]];
        [bases addObject:[h stringByAppendingPathComponent:@"Applications"]];
    }
    Class su = NSClassFromString(@"LCSharedUtils");
    if (su && [su respondsToSelector:@selector(appGroupPath)]) {
        NSURL *g = ((id (*)(id, SEL))objc_msgSend)(su, @selector(appGroupPath));
        if (g) {
            [bases addObject:[g.path stringByAppendingPathComponent:@"LiveContainer/Applications"]];
        }
    }

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *base in bases) {
        NSArray<NSString *> *dirs = [fm contentsOfDirectoryAtPath:base error:nil];
        for (NSString *d in dirs) {
            if ([d hasPrefix:@"."] || [seen containsObject:d]) continue;
            NSString *p = [base stringByAppendingPathComponent:d];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) continue;

            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [p stringByAppendingPathComponent:@"Info.plist"]];
            if (!info) continue;

            NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: d;
            NSDictionary *lcInfo = [NSDictionary dictionaryWithContentsOfFile:
                                    [p stringByAppendingPathComponent:@"LCAppInfo.plist"]];
            NSString *folder = lcInfo[@"LCDataUUID"] ?: @"";
            UIImage *icon = QBAppIcon(p, info);
            // Real, non-fabricated subtitle: the bundle version. LC does not
            // expose game genre/platform, so we never invent those.
            NSString *ver = info[@"CFBundleShortVersionString"] ?: info[@"CFBundleVersion"] ?: @"";

            [seen addObject:d];
            [result addObject:@{ @"bid": d, @"name": name, @"folder": folder,
                                 @"path": p,
                                 @"version": ver ?: @"",
                                 @"icon": icon ?: [NSNull null] }];
        }
    }

    NSString *current = QBCurrentBundleID() ?: @"";
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL ca = [a[@"bid"] isEqualToString:current];
        BOOL cb = [b[@"bid"] isEqualToString:current];
        if (ca != cb) return ca ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
    return result;
}

// Disk footprint of one installed app. LC stores the whole bundle plus its
// data container under Documents/Applications/<bid>/, so a recursive walk of
// that folder is the honest "occupies N" number — never a guess from Info.plist.
// Allocated size (not logical size) is what the device actually spends.
static unsigned long long QBDirectorySize(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *root = [NSURL fileURLWithPath:path isDirectory:YES];
    NSArray<NSURLResourceKey> *keys = @[NSURLIsDirectoryKey,
                                        NSURLFileAllocatedSizeKey,
                                        NSURLFileSizeKey];
    NSDirectoryEnumerator<NSURL *> *en =
        [fm enumeratorAtURL:root
  includingPropertiesForKeys:keys
                     options:0
                errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
    unsigned long long total = 0;
    for (NSURL *u in en) {
        NSNumber *isDir = nil;
        if (![u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil] ||
            isDir.boolValue) continue;
        NSNumber *alloc = nil;
        if ([u getResourceValue:&alloc forKey:NSURLFileAllocatedSizeKey error:nil] && alloc) {
            total += alloc.unsignedLongLongValue;
            continue;
        }
        NSNumber *logical = nil;
        if ([u getResourceValue:&logical forKey:NSURLFileSizeKey error:nil] && logical) {
            total += logical.unsignedLongLongValue;
        }
    }
    return total;
}

static NSString *QBFormatBytes(unsigned long long bytes) {
    if (bytes == 0) return nil;
    static NSString *const units[] = {@"B", @"KB", @"MB", @"GB", @"TB"};
    double v = (double)bytes;
    NSInteger i = 0;
    while (v >= 1024.0 && i < 4) { v /= 1024.0; i++; }
    if (i == 0) return [NSString stringWithFormat:@"%llu B", bytes];
    if (v < 10.0) return [NSString stringWithFormat:@"%.2f %@", v, units[i]];
    if (v < 100.0) return [NSString stringWithFormat:@"%.1f %@", v, units[i]];
    return [NSString stringWithFormat:@"%.0f %@", v, units[i]];
}

// Sizes are cached forever (an app does not change size while the sheet is
// open) and computed one at a time on a background queue, so opening the list
// never blocks on a multi-GB walk.
static NSMutableDictionary<NSString *, NSNumber *> *QBSizeCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static NSMutableSet<NSString *> *QBSizeInFlight(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

#pragma mark - Cover art (fully offline, read from the guest bundle)

static NSMutableDictionary<NSString *, UIImage *> *QBCoverCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}
static NSMutableSet<NSString *> *QBCoverInFlight(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}
static NSString * const QBCoverReadyNote = @"QBHomeCoverReady";

// Synthesise a 16:9 cover from the app icon so every game has artwork even when
// its bundle ships no landscape image: deep blue wash + enlarged faded icon +
// vignette. Cheap enough to run synchronously on the main thread.
static UIImage *QBSynthCover(UIImage *icon) {
    CGSize s = CGSizeMake(640, 360);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:s];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        UIColor *c1 = [UIColor colorWithRed:0.11 green:0.18 blue:0.33 alpha:1.0];
        UIColor *c2 = [UIColor colorWithRed:0.02 green:0.04 blue:0.10 alpha:1.0];
        CGGradientRef lg = CGGradientCreateWithColors(
            cs, (__bridge CFArrayRef)@[(id)c1.CGColor, (id)c2.CGColor], NULL);
        CGContextDrawLinearGradient(c, lg, CGPointMake(0, 0),
                                    CGPointMake(0, s.height), 0);
        CGGradientRelease(lg);
        if (icon) {
            CGFloat side = 236.0;
            CGRect ir = CGRectMake(s.width - side - 24.0, (s.height - side) / 2.0, side, side);
            CGContextSaveGState(c);
            CGContextSetAlpha(c, 0.60);
            [icon drawInRect:ir];
            CGContextRestoreGState(c);
        }
        CGGradientRef vg = CGGradientCreateWithColors(
            cs, (__bridge CFArrayRef)@[
                (id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                (id)[UIColor colorWithWhite:0 alpha:0.70].CGColor], NULL);
        CGContextDrawRadialGradient(c, vg,
            CGPointMake(s.width * 0.42, s.height * 0.45), s.height * 0.16,
            CGPointMake(s.width * 0.42, s.height * 0.45), s.width * 0.74, 0);
        CGGradientRelease(vg);
        CGColorSpaceRelease(cs);
    }];
}

// Look for a real landscape cover inside the guest bundle. Only the top level
// is enumerated (assets live there or are named in Info.plist) so this stays
// fast even for multi-GB games. Assets.car cannot be read without private
// APIs, so when no loose image exists we fall back to the synthesised cover.
static UIImage *QBBundleCoverImage(NSString *path, NSDictionary *info) {
    if (!path.length) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *d in (info[@"UILaunchImages"] ?: @[])) {
        NSString *n = d[@"UILaunchImageName"];
        if ([n isKindOfClass:NSString.class] && n.length) [names addObject:n];
    }
    [names addObjectsFromArray:@[@"iTunesArtwork", @"iTunesArtwork@2x",
        @"LaunchImage", @"LaunchImage@2x", @"Default-Landscape",
        @"Default-Landscape@2x", @"Default", @"Default@2x",
        @"cover", @"Cover", @"artwork", @"Artwork", @"splash", @"Splash"]];
    for (NSString *f in ([fm contentsOfDirectoryAtPath:path error:nil] ?: @[])) {
        NSString *ext = f.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] ||
            [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"webp"]) {
            [names addObject:f];
        }
    }
    UIImage *best = nil;
    CGFloat bestArea = 0;
    NSInteger checked = 0;
    for (NSString *n in names) {
        if (checked++ > 64) break;
        NSArray *tries = @[n,
            [n stringByAppendingPathExtension:@"png"],
            [n stringByAppendingPathExtension:@"jpg"],
            [n stringByAppendingString:@"@2x.png"]];
        for (NSString *t in tries) {
            NSString *p = [path stringByAppendingPathComponent:t];
            UIImage *img = [UIImage imageWithContentsOfFile:p];
            if (!img) continue;
            CGSize sz = img.size;
            if (sz.width < sz.height || sz.width < 400.0) continue; // landscape only
            CGFloat area = sz.width * sz.height;
            if (area > bestArea) { bestArea = area; best = img; }
            break;
        }
    }
    return best;
}

// Return the cached cover immediately; the first call installs a synthesised
// cover so the UI is never blank, then upgrades it from a real bundle image in
// the background and posts QBCoverReadyNote to refresh visible cards.
static UIImage *QBHomeCover(NSDictionary *app) {
    NSString *key = app[@"bid"] ?: app[@"path"];
    if (!key.length) return nil;
    UIImage *cached = QBCoverCache()[key];
    if (cached) return cached;

    UIImage *icon = app[@"icon"];
    UIImage *synth = QBSynthCover([icon isKindOfClass:UIImage.class] ? icon : nil);
    if (synth) QBCoverCache()[key] = synth;

    NSString *path = app[@"path"];
    if (path.length && ![QBCoverInFlight() containsObject:key]) {
        [QBCoverInFlight() addObject:key];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                              [path stringByAppendingPathComponent:@"Info.plist"]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UIImage *real = QBBundleCoverImage(path, info);
            dispatch_async(dispatch_get_main_queue(), ^{
                [QBCoverInFlight() removeObject:key];
                if (real) QBCoverCache()[key] = real;
                [[NSNotificationCenter defaultCenter] postNotificationName:QBCoverReadyNote
                                                                    object:key];
            });
        });
    }
    return synth;
}

// Draw the small gamepad glyph used on the tab.
static UIImage *QBGlyph(UIColor *color) {    CGFloat s = 18.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(s, s)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetStrokeColorWithColor(c, color.CGColor);
        CGContextSetFillColorWithColor(c, color.CGColor);
        UIBezierPath *box = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1.5, 1.5, s - 3, s - 3)
                                                       cornerRadius:4.0];
        box.lineWidth = 1.3;
        [box stroke];
        CGFloat d = 2.4;
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(s * 0.27 - d / 2, s * 0.40 - d / 2, d, d)] fill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(s * 0.73 - d / 2, s * 0.40 - d / 2, d, d)] fill];
        UIBezierPath *smile = [UIBezierPath bezierPath];
        [smile moveToPoint:CGPointMake(s * 0.30, s * 0.64)];
        [smile addQuadCurveToPoint:CGPointMake(s * 0.70, s * 0.64)
                      controlPoint:CGPointMake(s * 0.50, s * 0.88)];
        smile.lineWidth = 1.3;
        [smile stroke];
    }];
}

#pragma mark - Tab view

// Light, tint-free frost for the floating sheets.
// Every public UIBlurEffect style bakes a material tint into the backdrop —
// SystemUltraThinMaterial still milks it, which is why the cards kept reading
// as "not transparent enough" no matter how low the veil went. UIKit's custom
// blur effect exposes the radius directly and lets the tint alpha go to zero,
// so the game shows through while the backdrop stays genuinely blurred.
static UIVisualEffect *QBFrostEffect(CGFloat radius) {
    static Class customClass = Nil;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        customClass = NSClassFromString(@"_UICustomBlurEffect");
    }
    if (customClass) {
        UIVisualEffect *effect = [[customClass alloc] init];
        @try {
            [effect setValue:@(radius) forKey:@"blurRadius"];
            [effect setValue:@(1.0) forKey:@"saturationDeltaFactor"];
            [effect setValue:@(0.0) forKey:@"colorTintAlpha"];
        } @catch (NSException *ex) {
            (void)ex;
            return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
        }
        return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

// Liquid Glass. iOS 26 ships the real thing: UIGlassEffect refracts whatever
// sits behind it and draws its own rim/highlight, which is what the dock and
// the floating sheets are supposed to look like. -effectWithStyle: is a public
// API on the iOS 26 SDK, so no private ivar fiddling is needed. Older systems
// fall back to the tint-free custom blur (same shape, softer look).
static UIVisualEffect *QBGlassEffect(CGFloat radius, BOOL clear) {
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *glass = [UIGlassEffect effectWithStyle:
                                clear ? UIGlassEffectStyleClear : UIGlassEffectStyleRegular];
        glass.tintColor = nil;
        return glass;
    }
    return QBFrostEffect(radius);
}

// (The full-screen backdrop blur was removed: every blur effect view either
// bakes a grey material tint or desaturates in linear space, which turned the
// gameplay monochrome. The sheets are glass on their own.)

@interface QBTabView : UIView
@property(nonatomic, strong) UIImageView *glyph;
@property(nonatomic, strong) UIVisualEffectView *glassView;
@property(nonatomic, strong) UIView *clipView;
@property(nonatomic, assign) BOOL expanded;
/// YES when the tab is docked to the RIGHT edge (portrait): flat against the
/// screen edge on the right, rounded on the left — the top-docked tongue turned
/// 90 degrees, without actually rotating the glyph.
@property(nonatomic, assign) BOOL verticalEdge;
@end

@implementation QBTabView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;

    // Liquid Glass by default on iOS 26 (UIGlassEffect: real refraction and a
    // built-in rim highlight); older systems fall back to the custom
    // ultra-thin frost, which keeps the same silhouette.
    self.glassView = [[UIVisualEffectView alloc] initWithEffect:QBGlassEffect(30.0, NO)];
    self.glassView.frame = self.bounds;
    self.glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.glassView.userInteractionEnabled = NO;
    // "Tongue" shape: square corners on top (flush with the screen edge),
    // rounded on the bottom. A CAShapeLayer mask on the effect view is NOT
    // honoured by UIGlassEffect (the tab shipped with four square corners),
    // so the pill is clipped by a real container view instead: clipsToBounds
    // on a parent always clips the blur/glass subtree.
    self.clipView = [[UIView alloc] init];
    self.clipView.backgroundColor = UIColor.clearColor;
    self.clipView.clipsToBounds = YES;
    self.clipView.userInteractionEnabled = NO;
    [self addSubview:self.clipView];
    [self.clipView addSubview:self.glassView];

    // Frost overlay — a whisper of milk on top of the glass so the glyph stays
    // legible over bright gameplay, without hiding the refraction.
    UIView *frost = [[UIView alloc] init];
    frost.backgroundColor = QBDynamicColor([UIColor colorWithWhite:1.0 alpha:0.10],
                                           [UIColor colorWithWhite:1.0 alpha:0.06]);
    frost.tag = 9910;
    frost.userInteractionEnabled = NO;
    [self.clipView addSubview:frost];

    // Drop shadow shaped like the tongue (square top, rounded bottom). The
    // shadow lives on the container layer so the glass subview can clip itself.
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.35;
    self.layer.shadowRadius = 6.0;
    self.layer.shadowOffset = CGSizeMake(0, 2.0);

    // Glyph follows the appearance (dark ink on the light frosted tab, light
    // ink in dark mode) — a hard-coded white glyph vanished into the frost.
    UIImage *glyphImage = QBGlyph([UIColor blackColor]);
    self.glyph = [[UIImageView alloc]
        initWithImage:[glyphImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    self.glyph.tintColor = QBTextPrimary();
    self.glyph.contentMode = UIViewContentModeCenter;
    CGFloat g = 18.0;
    self.glyph.frame = CGRectMake((frame.size.width - g) / 2.0, (frame.size.height - g) / 2.0, g, g);
    self.glyph.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    self.glyph.userInteractionEnabled = NO;
    // subtle shadow keeps the glyph legible on both light and dark glass
    self.glyph.layer.shadowColor = [UIColor blackColor].CGColor;
    self.glyph.layer.shadowOpacity = 0.18;
    self.glyph.layer.shadowRadius = 1.0;
    self.glyph.layer.shadowOffset = CGSizeMake(0, 0.5);
    [self addSubview:self.glyph];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = QBIsChinese() ? @"应用列表" : @"App list";
    return self;
}

// Expanded only nudges the glyph; geometry is fixed (no stretch).
- (void)setExpanded:(BOOL)expanded {
    if (_expanded == expanded) return;
    _expanded = expanded;
    [UIView animateWithDuration:0.18 animations:^{
        self.glyph.transform = expanded ? CGAffineTransformMakeScale(1.1, 1.1)
                                        : CGAffineTransformIdentity;
    }];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    UIBezierPath *p = [UIBezierPath bezierPath];
    if (self.verticalEdge) {
        // Docked to the right edge: flat on the right, rounded on the left.
        CGFloat r = MIN(QBTabBottomCorner, w / 2.0);
        [p moveToPoint:CGPointMake(w, 0)];
        [p addLineToPoint:CGPointMake(w, h)];
        [p addLineToPoint:CGPointMake(r, h)];
        [p addQuadCurveToPoint:CGPointMake(0, h - r) controlPoint:CGPointMake(0, h)];
        [p addLineToPoint:CGPointMake(0, r)];
        [p addQuadCurveToPoint:CGPointMake(r, 0) controlPoint:CGPointMake(0, 0)];
        [p closePath];
    } else {
        // Shadow path: square top corners, rounded bottom corners.
        [p moveToPoint:CGPointMake(0, 0)];
        [p addLineToPoint:CGPointMake(w, 0)];
        [p addLineToPoint:CGPointMake(w, h - QBTabBottomCorner)];
        [p addQuadCurveToPoint:CGPointMake(w - QBTabBottomCorner, h)
                  controlPoint:CGPointMake(w, h)];
        [p addLineToPoint:CGPointMake(QBTabBottomCorner, h)];
        [p addQuadCurveToPoint:CGPointMake(0, h - QBTabBottomCorner)
                  controlPoint:CGPointMake(0, h)];
        [p closePath];
    }
    self.layer.shadowPath = p.CGPath;
    // Shadow falls away from the screen edge it is docked to.
    self.layer.shadowOffset = self.verticalEdge ? CGSizeMake(-2.0, 0) : CGSizeMake(0, 2.0);

    // Clip the glass (and the shine) with a real container: rounded only away
    // from the screen edge, dead square where it meets the edge.
    self.clipView.frame = self.bounds;
    self.clipView.layer.cornerRadius = MIN(QBTabBottomCorner,
        self.verticalEdge ? w / 2.0 : h / 2.0);
    self.clipView.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipView.layer.maskedCorners = self.verticalEdge
        ? (kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner)
        : (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
    self.glassView.frame = self.clipView.bounds;
    UIView *frost = [self.clipView viewWithTag:9910];
    frost.frame = self.clipView.bounds;
    // Hairline rim instead of a highlight band — keeps the sheet flat.
    BOOL dark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    self.clipView.layer.borderWidth = 0.8;
    self.clipView.layer.borderColor = dark
        ? [UIColor colorWithWhite:1.0 alpha:0.26].CGColor
        : [UIColor colorWithWhite:1.0 alpha:0.52].CGColor;

    CGFloat g = 18.0;
    self.glyph.frame = CGRectMake((self.bounds.size.width - g) / 2.0,
                                  (self.bounds.size.height - g) / 2.0 - 1.0, g, g);
}

@end

#pragma mark - App row cell (card with launch button)

@interface QBAppCell : UITableViewCell
@property(nonatomic, strong) UIView *shadowHost;
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIImageView *appIcon;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *versionPill;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, copy) void (^onLaunch)(void);
// Subtitle = "版本 x.y.z · 12.4 GB". The size half arrives asynchronously, so
// the two halves are kept apart and re-joined by -refreshSubtitle.
@property(nonatomic, copy) NSString *appPath;
@property(nonatomic, copy) NSString *versionText;
@property(nonatomic, copy) NSString *sizeText;
- (void)refreshSubtitle;
@end

@implementation QBAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    // Cells must span the full table width: UIKit otherwise insets content
    // views to the safe area, which in landscape shrank the card and left a
    // huge gap on the right.
    self.layoutMargins = UIEdgeInsetsZero;
    self.contentView.layoutMargins = UIEdgeInsetsZero;

    // The card clips its own blur, so the drop shadow needs its own view.
    self.shadowHost = [[UIView alloc] init];
    self.shadowHost.backgroundColor = UIColor.clearColor;
    self.shadowHost.userInteractionEnabled = NO;
    self.shadowHost.layer.shadowColor = UIColor.blackColor.CGColor;
    self.shadowHost.layer.shadowOpacity = 0.16;
    self.shadowHost.layer.shadowRadius = 10.0;
    self.shadowHost.layer.shadowOffset = CGSizeMake(0, 4.0);
    [self addSubview:self.shadowHost];

    self.card = [[UIView alloc] init];
    self.card.backgroundColor = UIColor.clearColor;
    // Frosted card: blur bed + a light milk veil. The veil is what makes the
    // text readable — a bare translucent color over gameplay was too see-through.
    self.card.clipsToBounds = YES;
    self.card.layer.cornerRadius = 18.0;
    self.card.layer.cornerCurve = kCACornerCurveContinuous;
    self.card.layer.borderWidth = 0.5;
    self.card.layer.borderColor = QBDynamicColor(
        [UIColor colorWithWhite:0.0 alpha:0.05], [UIColor colorWithWhite:1.0 alpha:0.14]).CGColor;

    // SystemMaterial renders as a nearly opaque grey slab over gameplay — the
    // list read as painted grey, not glass. SystemThinMaterial keeps the real
    // backdrop blur (frosted) while letting the game show through, and the milk
    // veil stays faint so it whitens the frost without flattening it.
    // Liquid Glass on iOS 26+ (it reads properly now that the page sits on a
    // blurred, dimmed backdrop instead of raw gameplay). Older systems keep the
    // ultra-thin frosted sheet.
    UIVisualEffectView *frost;
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        glass.interactive = NO;
        frost = [[UIVisualEffectView alloc] initWithEffect:glass];
    } else {
        frost = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    }
    frost.userInteractionEnabled = NO;
    frost.tag = 9801;
    [self.card addSubview:frost];

    UIView *veil = [[UIView alloc] init];
    veil.backgroundColor = QBDynamicColor([UIColor colorWithWhite:1.0 alpha:0.06],
                                          [UIColor colorWithWhite:1.0 alpha:0.03]);
    veil.userInteractionEnabled = NO;
    veil.tag = 9802;
    [self.card addSubview:veil];

    // Parented to the cell itself (not contentView) so its width can never be
    // reduced by safe-area insets — the card then always matches the panel.
    [self addSubview:self.card];

    self.appIcon = [[UIImageView alloc] init];
    self.appIcon.contentMode = UIViewContentModeScaleAspectFill;
    self.appIcon.layer.cornerRadius = 13.0;
    self.appIcon.clipsToBounds = YES;
    [self.card addSubview:self.appIcon];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.nameLabel.textColor = QBTextPrimary();
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.card addSubview:self.nameLabel];

    self.versionPill = [[UILabel alloc] init];
    self.versionPill.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    self.versionPill.textColor = QBTextSecondary();
    self.versionPill.textAlignment = NSTextAlignmentCenter;
    self.versionPill.backgroundColor = QBDynamicColor(
        [UIColor colorWithWhite:0.0 alpha:0.07], [UIColor colorWithWhite:1.0 alpha:0.14]);
    self.versionPill.layer.cornerRadius = 8.0;
    self.versionPill.clipsToBounds = YES;
    // "版本 2.7.7 · 18.4 GB" can get long on narrow cards — shrink instead of
    // truncating, the size number is the whole point of the extra text.
    self.versionPill.adjustsFontSizeToFitWidth = YES;
    self.versionPill.minimumScaleFactor = 0.72;
    self.versionPill.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.card addSubview:self.versionPill];

    // Text-only pill: the little play triangle that used to sit before the
    // label is gone, so the sheet reads as one calm sheet of glass.
    self.launchButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.launchButton setTitle:(QBIsChinese() ? @"启动" : @"Launch")
                      forState:UIControlStateNormal];
    // Green glass — the pale sheet the "back to LC" pill used to carry, now
    // swapped so the launch action owns it.
    [self.launchButton setTitleColor:QBGlassGreenInk() forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.launchButton.backgroundColor = QBGlassGreenFill();
    self.launchButton.layer.cornerRadius = 17.0;
    self.launchButton.layer.borderWidth = 0.7;
    self.launchButton.layer.borderColor = QBDynamicColor(
        [UIColor colorWithRed:0.20 green:0.50 blue:0.30 alpha:0.28],
        [UIColor colorWithRed:0.62 green:0.95 blue:0.72 alpha:0.34]).CGColor;
    [self.launchButton addTarget:self action:@selector(launchTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:self.launchButton];
    return self;
}

- (void)refreshSubtitle {
    NSString *v = self.versionText ?: @"";
    NSString *s = self.sizeText ?: @"";
    if (v.length && s.length) {
        self.versionPill.text = [NSString stringWithFormat:@"%@ · %@", v, s];
    } else {
        self.versionPill.text = v.length ? v : s;
    }
    [self setNeedsLayout];
}

- (void)launchTapped { if (self.onLaunch) self.onLaunch(); }

- (void)layoutSubviews {
    [super layoutSubviews];
    // Take the width from the cell itself, never from contentView — UIKit can
    // inset the content view to the safe area (landscape), which used to shrink
    // the card and leave a wide empty band on the right.
    CGFloat side = QBCardListInset;
    CGFloat cellW = self.bounds.size.width ?: self.contentView.bounds.size.width;
    self.card.frame = CGRectMake(side, 4,
                                 MAX(0, cellW - side * 2.0),
                                 self.bounds.size.height - 8);
    self.shadowHost.frame = self.card.frame;
    self.shadowHost.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:self.shadowHost.bounds
                                   cornerRadius:18.0].CGPath;
    [self.card viewWithTag:9801].frame = self.card.bounds;
    [self.card viewWithTag:9802].frame = self.card.bounds;
    CGFloat h = self.card.bounds.size.height;
    CGFloat iconSide = MIN(52.0, MAX(32.0, h - 16.0));
    self.appIcon.layer.cornerRadius = iconSide * 0.25;
    self.appIcon.frame = CGRectMake(12, (h - iconSide) / 2.0, iconSide, iconSide);

    CGFloat tx = 12 + iconSide + 14.0;
    // Text-only pill now, so it can be narrower than the old icon+label one.
    CGFloat btnW = 72.0;
    self.launchButton.frame = CGRectMake(self.card.bounds.size.width - btnW - 12,
                                         (h - 34) / 2.0, btnW, 34);
    CGFloat textW = MAX(0, self.card.bounds.size.width - tx - btnW - 24.0);

    // Two lines only: app name + version pill (the "LiveContainer 应用"
    // placeholder line was removed).
    self.nameLabel.frame = CGRectMake(tx, (h - 44) / 2.0, textW, 22);
    CGSize ps = [self.versionPill.text sizeWithAttributes:@{NSFontAttributeName:self.versionPill.font}];
    self.versionPill.frame = CGRectMake(tx, (h - 44) / 2.0 + 24, MIN(ps.width + 16, textW), 17);
}

@end

#pragma mark - Glass action button (3D liquid-glass pill)

// Transparent container that only claims touches landing on its buttons.
// The floating toolbars sit on top of the scrolling list, so the empty band
// between the pills must stay draggable (scroll) instead of swallowing taps.
@interface QBHitThroughView : UIView
@end

@implementation QBHitThroughView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *v in self.subviews.reverseObjectEnumerator) {
        if (v.hidden || !v.userInteractionEnabled || v.alpha < 0.05) continue;
        if ([v pointInside:[self convertPoint:point toView:v] withEvent:event]) return YES;
    }
    return NO;
}

@end

// The two toolbar actions are drawn as FLAT frosted-glass sheets: a blurred
// bed + one pastel tint + a hairline rim + a soft shadow. No gloss gradient,
// no specular line, no inner shade — the earlier build stacked those to fake
// depth, and the result read as a refracting lens instead of plain glass.
@interface QBGlassButton : UIControl

@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;

- (instancetype)initWithSymbol:(NSString *)symbol
                         title:(NSString *)title
                     glyphColor:(UIColor *)glyph
                      fillColor:(UIColor *)fill;

@end

@implementation QBGlassButton {
    UIView *_clip;
    UIVisualEffectView *_blur;
    UIView *_tint;
    CGFloat _iconSide;
    BOOL _dark;
    BOOL _darkKnown;
}

- (instancetype)initWithSymbol:(NSString *)symbol
                         title:(NSString *)title
                     glyphColor:(UIColor *)glyph
                      fillColor:(UIColor *)fill {
    self = [super initWithFrame:CGRectMake(0, 0, 200, 40)];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    _iconSide = 19.0;

    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.12;
    self.layer.shadowRadius = 9.0;
    self.layer.shadowOffset = CGSizeMake(0, 3.0);

    _clip = [[UIView alloc] init];
    _clip.backgroundColor = UIColor.clearColor;
    _clip.clipsToBounds = YES;
    _clip.userInteractionEnabled = NO;
    [self addSubview:_clip];

    // Liquid Glass bed by default (iOS 26); older systems get the custom
    // frosted blur. The flat pastel sheet above keeps the label readable.
    _blur = [[UIVisualEffectView alloc] initWithEffect:QBGlassEffect(24.0, NO)];
    _blur.userInteractionEnabled = NO;
    [_clip addSubview:_blur];

    // One flat pastel sheet on top of the blur.
    _tint = [[UIView alloc] init];
    _tint.backgroundColor = fill;
    _tint.userInteractionEnabled = NO;
    [_clip addSubview:_tint];

    _clip.layer.borderWidth = 0.8;

    UIImage *img = nil;
    if (@available(iOS 13.0, *)) img = [UIImage systemImageNamed:symbol];
    _iconView = [[UIImageView alloc] initWithImage:
                 [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.tintColor = glyph;
    _iconView.userInteractionEnabled = NO;
    [self addSubview:_iconView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = title;
    _titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = QBTextPrimary();
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = title;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat r = h / 2.0;
    _clip.frame = self.bounds;
    _clip.layer.cornerRadius = r;
    _clip.layer.cornerCurve = kCACornerCurveContinuous;
    _blur.frame = _clip.bounds;
    _tint.frame = _clip.bounds;

    BOOL dark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    if (!_darkKnown || dark != _dark) {
        _dark = dark;
        _darkKnown = YES;
        _clip.layer.borderColor = dark
            ? [UIColor colorWithWhite:1.0 alpha:0.30].CGColor
            : [UIColor colorWithWhite:1.0 alpha:0.58].CGColor;
    }

    self.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:r].CGPath;

    CGSize ts = [_titleLabel.text length]
        ? [_titleLabel sizeThatFits:CGSizeMake(w, h)] : CGSizeZero;
    CGFloat iconW = _iconSide;
    CGFloat contentW = iconW + (ts.width > 0 ? 7.0 + ts.width : 0);
    CGFloat x = (w - contentW) / 2.0;
    _iconView.frame = CGRectMake(x, (h - iconW) / 2.0, iconW, iconW);
    _titleLabel.frame = CGRectMake(x + iconW + 7.0, 0, ts.width, h);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.alpha = highlighted ? 0.82 : 1.0;
    } completion:nil];
}

@end

#pragma mark - Compact floating dock (small by default, expands on tap)

// Two thumb-sized circles and nothing else. The old bottom bar was a full-width
// strip, which covered the game and read as "stretched"; this dock keeps its
// footprint at 2 x 46pt and only ever grows when a button is actually tapped.

static CGFloat const QBDockButtonSide = 46.0;
static CGFloat const QBDockGap        = 10.0;
static CGFloat const QBDockBottomGap  = 14.0;

@interface QBDockButton : UIControl
@property(nonatomic, strong) UIImageView *iconView;
- (instancetype)initWithSymbol:(NSString *)symbol;
@end

@implementation QBDockButton {
    UIVisualEffectView *_glass;
    UIView *_rimView;
}

- (instancetype)initWithSymbol:(NSString *)symbol {
    self = [super initWithFrame:CGRectMake(0, 0, QBDockButtonSide, QBDockButtonSide)];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.34;
    self.layer.shadowRadius = 10.0;
    self.layer.shadowOffset = CGSizeMake(0, 4.0);

    // The glass is clipped by a real container — a mask on the UIVisualEffectView
    // itself is not honoured by the glass renderer.
    UIView *clip = [[UIView alloc] init];
    clip.tag = 7001;
    clip.backgroundColor = UIColor.clearColor;
    clip.clipsToBounds = YES;
    clip.userInteractionEnabled = NO;
    [self addSubview:clip];

    _glass = [[UIVisualEffectView alloc] initWithEffect:QBGlassEffect(26.0, YES)];
    _glass.userInteractionEnabled = NO;
    [clip addSubview:_glass];

    _rimView = [[UIView alloc] init];
    _rimView.tag = 7002;
    _rimView.backgroundColor = UIColor.clearColor;
    _rimView.userInteractionEnabled = NO;
    _rimView.layer.borderWidth = 1.0;
    _rimView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
    [clip addSubview:_rimView];

    UIImage *img = nil;
    if (@available(iOS 13.0, *)) img = [UIImage systemImageNamed:symbol];
    self.iconView = [[UIImageView alloc] initWithImage:
                     [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    // The dock floats over raw gameplay, so the ink stays light in both
    // appearances (a themed glyph disappeared into dark games).
    self.iconView.tintColor = UIColor.whiteColor;
    self.iconView.userInteractionEnabled = NO;
    self.iconView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.iconView.layer.shadowOpacity = 0.40;
    self.iconView.layer.shadowRadius = 2.0;
    self.iconView.layer.shadowOffset = CGSizeMake(0, 0.5);
    [self addSubview:self.iconView];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat s = MIN(self.bounds.size.width, self.bounds.size.height);
    CGFloat x = (self.bounds.size.width - s) / 2.0;
    CGFloat y = (self.bounds.size.height - s) / 2.0;
    UIView *clip = [self viewWithTag:7001];
    UIView *rim = [self viewWithTag:7002];
    clip.frame = CGRectMake(x, y, s, s);
    clip.layer.cornerRadius = s / 2.0;
    clip.layer.cornerCurve = kCACornerCurveContinuous;
    _glass.frame = clip.bounds;
    rim.frame = clip.bounds;
    rim.layer.cornerRadius = s / 2.0;
    rim.layer.cornerCurve = kCACornerCurveContinuous;

    self.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:clip.frame cornerRadius:s / 2.0].CGPath;

    CGFloat g = s * 0.46;
    self.iconView.frame = CGRectMake((self.bounds.size.width - g) / 2.0,
                                     (self.bounds.size.height - g) / 2.0, g, g);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12 delay:0
         options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.92, 0.92)
                                     : CGAffineTransformIdentity;
        self.alpha = highlighted ? 0.9 : 1.0;
    } completion:nil];
}

@end

@interface QBQuickDock : UIView
@property(nonatomic, strong) QBDockButton *plusButton;
@property(nonatomic, strong) QBDockButton *appsButton;
@property(nonatomic, copy) void (^onPlus)(void);
@property(nonatomic, copy) void (^onApps)(void);
+ (CGSize)compactSize;
@end

@implementation QBQuickDock

+ (CGSize)compactSize {
    return CGSizeMake(QBDockButtonSide * 2.0 + QBDockGap, QBDockButtonSide);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;

    self.plusButton = [[QBDockButton alloc] initWithSymbol:@"plus"];
    self.plusButton.accessibilityLabel = QBIsChinese() ? @"安装应用" : @"Install app";
    [self.plusButton addTarget:self action:@selector(plusTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.plusButton];

    self.appsButton = [[QBDockButton alloc] initWithSymbol:@"gamecontroller.fill"];
    self.appsButton.accessibilityLabel = QBIsChinese() ? @"打开主页" : @"Open home";
    [self.appsButton addTarget:self action:@selector(appsTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.appsButton];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat s = QBDockButtonSide;
    self.plusButton.frame = CGRectMake(0, 0, s, s);
    self.appsButton.frame = CGRectMake(s + QBDockGap, 0, s, s);
}

- (void)plusTapped { if (self.onPlus) self.onPlus(); }
- (void)appsTapped { if (self.onApps) self.onApps(); }

@end

#pragma mark - Install sheet (opens above the dock)

@interface QBInstallPanel : UIView
@property(nonatomic, copy) void (^onPickFile)(void);
@property(nonatomic, copy) void (^onGoLC)(void);
+ (CGFloat)preferredHeightForWidth:(CGFloat)width;
@end

@implementation QBInstallPanel {
    UIVisualEffectView *_glass;
    UIView *_rim;
    UILabel *_title;
    UILabel *_subtitle;
    QBGlassButton *_pickButton;
    QBGlassButton *_lcButton;
}

+ (CGFloat)preferredHeightForWidth:(CGFloat)width { return 176.0; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.32;
    self.layer.shadowRadius = 18.0;
    self.layer.shadowOffset = CGSizeMake(0, 8.0);

    UIView *clip = [[UIView alloc] init];
    clip.tag = 7101;
    clip.backgroundColor = UIColor.clearColor;
    clip.clipsToBounds = YES;
    clip.userInteractionEnabled = NO;
    [self addSubview:clip];

    _glass = [[UIVisualEffectView alloc] initWithEffect:QBGlassEffect(30.0, NO)];
    _glass.userInteractionEnabled = NO;
    [clip addSubview:_glass];

    _rim = [[UIView alloc] init];
    _rim.backgroundColor = UIColor.clearColor;
    _rim.userInteractionEnabled = NO;
    _rim.layer.borderWidth = 1.0;
    _rim.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.34].CGColor;
    [clip addSubview:_rim];

    _title = [[UILabel alloc] init];
    _title.text = QBIsChinese() ? @"安装应用" : @"Install app";
    _title.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightHeavy];
    _title.textColor = UIColor.whiteColor;
    [self addSubview:_title];

    _subtitle = [[UILabel alloc] init];
    _subtitle.text = QBIsChinese() ? @"选择 IPA 文件，或回到 LiveContainer 安装"
                                   : @"Pick an IPA, or install from LiveContainer";
    _subtitle.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    _subtitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    _subtitle.numberOfLines = 2;
    [self addSubview:_subtitle];

    _pickButton = [[QBGlassButton alloc] initWithSymbol:@"arrow.down.doc.fill"
                                                  title:(QBIsChinese() ? @"选择 IPA 文件" : @"Choose IPA file")
                                              glyphColor:UIColor.whiteColor
                                               fillColor:[UIColor colorWithWhite:1.0 alpha:0.10]];
    [_pickButton addTarget:self action:@selector(pickTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_pickButton];

    _lcButton = [[QBGlassButton alloc] initWithSymbol:@"square.grid.2x2.fill"
                                                title:(QBIsChinese() ? @"在 LiveContainer 中安装" : @"Install in LiveContainer")
                                            glyphColor:UIColor.whiteColor
                                             fillColor:[UIColor colorWithWhite:1.0 alpha:0.10]];
    [_lcButton addTarget:self action:@selector(lcTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_lcButton];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    UIView *clip = [self viewWithTag:7101];
    CGFloat r = 26.0;
    clip.frame = self.bounds;
    clip.layer.cornerRadius = r;
    clip.layer.cornerCurve = kCACornerCurveContinuous;
    _glass.frame = clip.bounds;
    _rim.frame = clip.bounds;
    _rim.layer.cornerRadius = r;
    _rim.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:r].CGPath;

    CGFloat pad = 16.0;
    _title.frame = CGRectMake(pad, pad, w - pad * 2.0, 20.0);
    _subtitle.frame = CGRectMake(pad, pad + 22.0, w - pad * 2.0, 28.0);
    CGFloat by = pad + 56.0;
    CGFloat bh = 46.0;
    _pickButton.frame = CGRectMake(pad, by, w - pad * 2.0, bh);
    _lcButton.frame = CGRectMake(pad, by + bh + 10.0, w - pad * 2.0, bh);
    (void)h;
}

- (void)pickTapped { if (self.onPickFile) self.onPickFile(); }
- (void)lcTapped { if (self.onGoLC) self.onGoLC(); }

@end

#pragma mark - Home page (large game cards with cover art)

static NSArray<NSArray<NSString *> *> *QBHomeSlides(void) {
    static NSArray *slides;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        slides = @[
            @[@"玩起来", @"视听盛宴", @"别错过这些精选游戏"],
            @[@"接着玩", @"热血时刻", @"把没打完的战斗继续下去"],
            @[@"随便逛", @"指尖精选", @"总有一款适合现在的心情"],
            @[@"新发现", @"宝藏游戏", @"翻翻那些被忽略的好作品"],
            @[@"一起来", @"好友同乐", @"分享你正在玩的游戏"]];
    });
    return slides;
}

// Version + footprint subtitle, sized by the shared disk scanner. The first
// callback is immediate (cached value or version only); a second one arrives
// after the background walk completes.
static void QBEnsureAppSize(NSDictionary *app, void (^done)(NSString *text)) {
    if (!done) return;
    NSString *path = app[@"path"];
    NSString *ver = app[@"version"];
    NSString *vtxt = ver.length
        ? [NSString stringWithFormat:(QBIsChinese() ? @"版本 %@" : @"v%@"), ver] : @"";
    NSNumber *cached = path.length ? QBSizeCache()[path] : nil;
    NSString *size = cached ? QBFormatBytes(cached.unsignedLongLongValue) : nil;
    done(size.length
         ? [NSString stringWithFormat:@"%@%@%@", vtxt, (vtxt.length ? @" · " : @""), size]
         : vtxt);
    if (cached || !path.length || [QBSizeInFlight() containsObject:path]) return;
    [QBSizeInFlight() addObject:path];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long bytes = QBDirectorySize(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            [QBSizeInFlight() removeObject:path];
            QBSizeCache()[path] = @(bytes);
            NSString *s = QBFormatBytes(bytes);
            done(s.length
                 ? [NSString stringWithFormat:@"%@%@%@", vtxt, (vtxt.length ? @" · " : @""), s]
                 : vtxt);
        });
    });
}

@interface QBBigCard : UIView
@property(nonatomic, strong) NSDictionary *app;
@property(nonatomic, copy) NSString *bid;
@property(nonatomic, copy) void (^onLaunch)(void);
- (void)configure:(NSDictionary *)app;
- (void)refreshCover;
@end

@implementation QBBigCard {
    UIImageView *_cover;
    UIView *_shade;
    UILabel *_coverLabel;
    UIImageView *_icon;
    UILabel *_name;
    UILabel *_meta;
    UIButton *_launch;
    UIVisualEffectView *_frost;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.layer.cornerRadius = 22.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.38;
    self.layer.shadowRadius = 16.0;
    self.layer.shadowOffset = CGSizeMake(0, 9.0);

    _cover = [[UIImageView alloc] init];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    [self addSubview:_cover];

    _shade = [[UIView alloc] init];
    _shade.userInteractionEnabled = NO;
    [self addSubview:_shade];
    CAGradientLayer *gl = [CAGradientLayer layer];
    gl.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.10].CGColor,
                  (id)[UIColor colorWithRed:0.03 green:0.05 blue:0.09 alpha:0.92].CGColor];
    gl.locations = @[@0.0, @1.0];
    [_shade.layer addSublayer:gl];

    _coverLabel = [[UILabel alloc] init];
    _coverLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold];
    _coverLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
    _coverLabel.numberOfLines = 1;
    [self addSubview:_coverLabel];

    if (@available(iOS 13.0, *)) {
        _frost = [[UIVisualEffectView alloc] initWithEffect:
                  [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _frost.userInteractionEnabled = NO;
        [self insertSubview:_frost atIndex:1];
    }

    _icon = [[UIImageView alloc] init];
    _icon.contentMode = UIViewContentModeScaleAspectFill;
    _icon.layer.cornerRadius = 14.0;
    _icon.layer.cornerCurve = kCACornerCurveContinuous;
    _icon.clipsToBounds = YES;
    _icon.layer.borderWidth = 1.0;
    _icon.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    [self addSubview:_icon];

    _name = [[UILabel alloc] init];
    _name.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    _name.textColor = UIColor.whiteColor;
    _name.numberOfLines = 1;
    _name.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_name];

    _meta = [[UILabel alloc] init];
    _meta.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    _meta.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    _meta.numberOfLines = 1;
    _meta.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_meta];

    _launch = [UIButton buttonWithType:UIButtonTypeCustom];
    [_launch setTitle:(QBIsChinese() ? @"启动" : @"Launch") forState:UIControlStateNormal];
    [_launch setTitleColor:[UIColor colorWithRed:0.92 green:1.0 blue:0.94 alpha:1.0]
                  forState:UIControlStateNormal];
    _launch.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
    _launch.backgroundColor = [UIColor colorWithRed:0.62 green:0.93 blue:0.72 alpha:0.30];
    _launch.layer.cornerRadius = 16.0;
    _launch.layer.borderWidth = 0.8;
    _launch.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
    [_launch addTarget:self action:@selector(launchTapped)
      forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_launch];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(coverReady:) name:QBCoverReadyNote object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)coverReady:(NSNotification *)n {
    if ([self.bid isEqualToString:n.object]) [self refreshCover];
}

- (void)configure:(NSDictionary *)app {
    self.app = app;
    self.bid = app[@"bid"] ?: @"";
    _name.text = app[@"name"] ?: app[@"bid"];
    UIImage *ic = app[@"icon"];
    _icon.image = [ic isKindOfClass:UIImage.class] ? ic : nil;
    [self refreshCover];
    __weak typeof(self) weak = self;
    QBEnsureAppSize(app, ^(NSString *text) {
        __strong typeof(weak) strong = weak;
        if (strong) strong->_meta.text = text;
    });
}

- (void)refreshCover {
    _cover.image = QBHomeCover(self.app);
    NSString *size = nil;
    NSNumber *cached = self.app[@"path"] ? QBSizeCache()[self.app[@"path"]] : nil;
    if (cached) size = QBFormatBytes(cached.unsignedLongLongValue);
    _coverLabel.text = size.length
        ? [NSString stringWithFormat:@"%@ · %@", (QBIsChinese() ? @"最近游玩" : @"RECENT"), size]
        : (QBIsChinese() ? @"最近游玩" : @"RECENT");
}

- (void)launchTapped { if (self.onLaunch) self.onLaunch(); }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat coverH = w * 0.52;
    _cover.frame = CGRectMake(0, 0, w, coverH);
    _frost.frame = CGRectMake(0, coverH, w, h - coverH);
    _shade.frame = CGRectMake(0, coverH - 74.0, w, 74.0);
    _shade.layer.sublayers.firstObject.frame = _shade.bounds;
    _coverLabel.frame = CGRectMake(16, coverH - 28.0, w - 32, 18);
    CGFloat iconSide = 54.0;
    _icon.frame = CGRectMake(14, coverH - 22.0, iconSide, iconSide);
    CGFloat tx = 14 + iconSide + 12.0;
    CGFloat btnW = 68.0;
    _launch.frame = CGRectMake(w - btnW - 13, coverH + 24.0, btnW, 32);
    CGFloat textW = MAX(0, w - tx - btnW - 30.0);
    _name.frame = CGRectMake(tx, coverH + 12.0, textW, 22);
    _meta.frame = CGRectMake(tx, coverH + 37.0, textW, 18);
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                       cornerRadius:22.0].CGPath;
}

@end

#pragma mark - App switch card

@interface QBCardView : UIView <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) NSArray<NSDictionary *> *apps;
@property(nonatomic, copy) void (^onSelect)(NSDictionary *app);
@property(nonatomic, copy) void (^onReturn)(void);
@property(nonatomic, copy) void (^onSettings)(void);

// floating glass toolbar (return to LC on the left, settings on the right)
@property(nonatomic, strong) UIView *toolbar;
@property(nonatomic, strong) QBGlassButton *returnButton;
@property(nonatomic, strong) QBGlassButton *settingsButton;

// list
@property(nonatomic, strong) UITableView *tableView;

@property(nonatomic, strong) UIVisualEffectView *glass;
@end

@implementation QBCardView

- (UIImage *)symbol:(NSString *)name fallback:(NSString *)fallback {
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:name];
        if (img) return img;
        return [UIImage systemImageNamed:fallback];
    }
    return nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    // NO backdrop panel any more: the app cards (and the settings modules)
    // float straight over the game, with only the two toolbar pills on top.
    // Nothing is clipped here either, so each card keeps its own shadow.
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;

    // Top toolbar: back-to-LC on the left, settings on the right. The old
    // header (title / count badge / clock / close) and the bottom bar are gone
    // — tapping the tab again (or outside) closes the panel.
    self.toolbar = [[QBHitThroughView alloc] init];
    self.toolbar.backgroundColor = UIColor.clearColor;
    [self addSubview:self.toolbar];

    self.returnButton = [[QBGlassButton alloc]
        initWithSymbol:@"house.fill"
                 title:(QBIsChinese() ? @"返回 LiveContainer" : @"Back to LiveContainer")
            glyphColor:QBGlassBlueInk()
             fillColor:QBGlassBlueFill()];
    [self.returnButton addTarget:self action:@selector(returnTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [self.toolbar addSubview:self.returnButton];

    self.settingsButton = [[QBGlassButton alloc]
        initWithSymbol:@"gearshape.fill"
                 title:(QBIsChinese() ? @"设置" : @"Settings")
            glyphColor:QBGlassRedInk()
             fillColor:QBGlassRedFill()];
    [self.settingsButton addTarget:self action:@selector(settingsTapped)
                  forControlEvents:UIControlEventTouchUpInside];
    [self.toolbar addSubview:self.settingsButton];

    // App list. It spans the WHOLE panel: the floating glass toolbar sits on
    // top of it, so rows slide underneath the buttons and stay visible through
    // the glass — the same "content scrolls under the floating pills" effect
    // as the reference design. The top inset keeps the first row clear of the
    // toolbar when the list is at rest.
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.tableFooterView = [UIView new];
    self.tableView.showsVerticalScrollIndicator = NO;
    // Both of these otherwise inset cells to the safe area — in landscape that
    // shrank every card and pushed it left, leaving a wide gap on the right.
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.tableView.insetsContentViewsToSafeArea = NO;
    self.tableView.preservesSuperviewLayoutMargins = NO;
    [self addSubview:self.tableView];

    // Toolbar must stay above the scrolling rows.
    [self bringSubviewToFront:self.toolbar];

    return self;
}

- (void)setApps:(NSArray<NSDictionary *> *)apps {
    _apps = apps;
    [self.tableView reloadData];
}

/// Row height that makes exactly QBVisibleRows cards fill the space below the
/// floating toolbar, so the same panel height always shows the same number of
/// apps when the list is at rest.
- (CGFloat)rowHeightForGroupTop:(CGFloat)groupTop {
    CGFloat avail = self.bounds.size.height - groupTop - QBToolbarHeight - 8.0;
    if (avail <= 0) return QBCardRowMinHeight;
    return MAX(QBCardRowMinHeight, avail / (CGFloat)QBVisibleRows);
}

/// Only the toolbar and the cards themselves claim touches. The canvas now
/// reaches the screen's top edge, so without this the empty backdrop band above
/// the cards would swallow taps that are supposed to fall through to the scrim
/// and close the panel.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (![super pointInside:point withEvent:event]) return NO;
    if (CGRectContainsPoint(self.toolbar.frame, point)) return YES;
    CGPoint p = [self.tableView convertPoint:point fromView:self];
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if (CGRectContainsPoint(cell.frame, p)) return YES;
    }
    return NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;

    // The canvas is full-height (flush with the screen's top edge) but the
    // toolbar + cards block is anchored to the bottom: the pills sit above the
    // cards, the cards stack under them, and the clipping edge stays at y = 0
    // so rows slide out at the top edge of the display when you scroll.
    CGFloat groupTop = MAX(QBTabHeight + 4.0, h - QBPanelHeight);

    self.toolbar.frame = CGRectMake(0, groupTop, w, QBToolbarHeight);
    CGFloat barH = 40.0;
    CGFloat barY = (QBToolbarHeight - barH) / 2.0;
    CGFloat inset = QBToolbarInset;
    CGFloat rightW = 104.0;
    CGFloat gap = 10.0;
    CGFloat leftW = MAX(130.0, w - inset * 2.0 - rightW - gap);
    self.returnButton.frame = CGRectMake(inset, barY, leftW, barH);
    self.settingsButton.frame = CGRectMake(inset + leftW + gap, barY, rightW, barH);
    [self bringSubviewToFront:self.toolbar];

    // The list owns the full panel; the toolbar height becomes a top inset so
    // the first card starts below the pills but later rows slide under them.
    self.tableView.frame = self.bounds;
    CGFloat rh = [self rowHeightForGroupTop:groupTop];
    CGFloat headerH = groupTop + QBToolbarHeight + 2.0;
    UIView *spacer = self.tableView.tableHeaderView;
    if (!spacer) {
        spacer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, headerH)];
        spacer.backgroundColor = UIColor.clearColor;
        self.tableView.tableHeaderView = spacer;
    } else if (fabs(spacer.bounds.size.width - w) > 0.5 ||
               fabs(spacer.bounds.size.height - headerH) > 0.5) {
        spacer.frame = CGRectMake(0, 0, w, headerH);
        self.tableView.tableHeaderView = spacer;   // re-assign so it re-measures
    }
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 10.0, 0);
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(headerH, 0, 10.0, 0);
    if (fabs(self.tableView.rowHeight - rh) > 0.5) {
        self.tableView.rowHeight = rh;
        [self.tableView reloadData];
    }
}

- (void)returnTapped { if (self.onReturn) self.onReturn(); }
- (void)settingsTapped { if (self.onSettings) self.onSettings(); }

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"QBAppRowCell";
    QBAppCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[QBAppCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:cid];
    NSDictionary *app = self.apps[indexPath.row];
    NSString *name = app[@"name"] ?: app[@"bid"];
    cell.nameLabel.text = name;
    NSString *ver = app[@"version"];
    cell.appPath = app[@"path"];
    cell.versionText = ver.length
        ? [NSString stringWithFormat:(QBIsChinese() ? @"版本 %@" : @"v%@"), ver] : @"";
    NSNumber *cachedSize = cell.appPath.length ? QBSizeCache()[cell.appPath] : nil;
    cell.sizeText = cachedSize ? QBFormatBytes(cachedSize.unsignedLongLongValue) : nil;
    [cell refreshSubtitle];
    if (cell.appPath.length && !cachedSize) [self loadSizeForApp:app];

    UIImage *icon = app[@"icon"];
    if ([icon isKindOfClass:UIImage.class]) {
        cell.appIcon.image = [self scaledIcon:icon to:CGSizeMake(52.0, 52.0)];
    } else {
        NSString *initial = [[name substringToIndex:MIN(1, name.length)] uppercaseString];
        cell.appIcon.image = [self letterTile:initial current:NO size:52.0];
    }

    __weak typeof(self) weakSelf = self;
    cell.onLaunch = ^{
        if (weakSelf.onSelect) weakSelf.onSelect(app);
    };
    [cell setNeedsLayout];
    return cell;
}

/// Walks one app's folder off the main thread and refreshes whatever cells are
/// on screen when the number lands. Cells that scroll in later read the cache.
- (void)loadSizeForApp:(NSDictionary *)app {
    NSString *path = app[@"path"];
    if (!path.length) return;
    if (QBSizeCache()[path] || [QBSizeInFlight() containsObject:path]) return;
    [QBSizeInFlight() addObject:path];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long bytes = QBDirectorySize(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            [QBSizeInFlight() removeObject:path];
            QBSizeCache()[path] = @(bytes);
            [weakSelf refreshVisibleSizes];
        });
    });
}

- (void)refreshVisibleSizes {
    for (QBAppCell *cell in self.tableView.visibleCells) {
        if (![cell isKindOfClass:QBAppCell.class]) continue;
        NSString *p = cell.appPath;
        NSNumber *n = p.length ? QBSizeCache()[p] : nil;
        if (!n) continue;
        cell.sizeText = QBFormatBytes(n.unsignedLongLongValue);
        [cell refreshSubtitle];
    }
}

- (UIImage *)scaledIcon:(UIImage *)image to:(CGSize)size {    if (!image) return nil;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

- (UIImage *)letterTile:(NSString *)letter current:(BOOL)current size:(CGFloat)s {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIColor *bg = current
            ? [UIColor colorWithRed:0.22 green:0.54 blue:0.86 alpha:1.0]
            : [UIColor colorWithWhite:0.68 alpha:1.0];
        [bg setFill];
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s)
                                                     cornerRadius:s * 0.22];
        [p fill];
        UIFont *font = [UIFont systemFontOfSize:s * 0.46 weight:UIFontWeightSemibold];
        CGSize ts = [letter sizeWithAttributes:@{NSFontAttributeName: font}];
        [letter drawAtPoint:CGPointMake((s - ts.width) / 2.0, (s - ts.height) / 2.0)
             withAttributes:@{ NSFontAttributeName: font,
                               NSForegroundColorAttributeName: UIColor.whiteColor }];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *app = self.apps[indexPath.row];
    if ([app[@"bid"] isEqualToString:(QBCurrentBundleID() ?: @"")]) return;
    if (self.onSelect) self.onSelect(app);
}

@end

#pragma mark - Full home page (Hero carousel + icon row + game cards + glass tabs)

@interface QBHomeView : UIView <UIScrollViewDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) NSArray<NSDictionary *> *apps;
@property(nonatomic, copy) void (^onSelect)(NSDictionary *app);
@property(nonatomic, copy) void (^onReturn)(void);
@property(nonatomic, copy) void (^onSettings)(void);
@property(nonatomic, copy) void (^onDismiss)(void);   // swipe down / avatar tap
@end

@implementation QBHomeView {
    UIScrollView *_scroll;
    UIView *_content;
    UIView *_hero;
    UIView *_stack;              // layered cover cards
    NSMutableArray<UIImageView *> *_covers;
    UILabel *_kicker, *_headline, *_subline;
    UIButton *_cta;
    UIView *_dots;
    NSMutableArray<UIView *> *_dotViews;
    UIScrollView *_iconRow;
    NSMutableArray<UIButton *> *_minis;
    NSInteger _current;
    NSInteger _slideCount;
    CGFloat _startX;
    BOOL _heroDragging;
    NSMutableArray<QBBigCard *> *_cards;
    UIView *_tabBar;
    UIVisualEffectView *_tabFrost;
    NSMutableArray<UIButton *> *_tabItems;
    NSInteger _tabIndex;
    BOOL _tabCollapsed;
    CGFloat _lastScrollY;
    CAGradientLayer *_bgGradient;
}

- (UIImage *)symbol:(NSString *)name fallback:(NSString *)fb {
    if (@available(iOS 13.0, *)) {
        UIImage *i = [UIImage systemImageNamed:name] ?: [UIImage systemImageNamed:fb];
        if (i) return [i imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = YES;

    // Deep-space page background, matching the reference design.
    _bgGradient = [CAGradientLayer layer];
    _bgGradient.colors = @[
        (id)[UIColor colorWithRed:0.043 green:0.173 blue:0.388 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.039 green:0.137 blue:0.314 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.027 green:0.090 blue:0.200 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.012 green:0.039 blue:0.090 alpha:1.0].CGColor,
        (id)[UIColor.blackColor CGColor]];
    _bgGradient.locations = @[@0.0, @0.22, @0.46, @0.72, @1.0];
    [self.layer addSublayer:_bgGradient];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.delegate = self;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.preservesSuperviewLayoutMargins = NO;
    [self addSubview:_scroll];

    _content = [[UIView alloc] init];
    _content.backgroundColor = UIColor.clearColor;
    [_scroll addSubview:_content];

    // Page title + avatar.
    UILabel *title = [[UILabel alloc] init];
    title.text = (QBIsChinese() ? @"主页" : @"Home");
    title.font = [UIFont systemFontOfSize:34.0 weight:UIFontWeightHeavy];
    title.textColor = UIColor.whiteColor;
    title.tag = 40;
    [_content addSubview:title];
    UIView *avatar = [[UIView alloc] init];
    avatar.tag = 41;
    avatar.layer.cornerRadius = 23.0;
    avatar.layer.borderWidth = 2.0;
    avatar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
    CAGradientLayer *ag = [CAGradientLayer layer];
    ag.colors = @[(id)[UIColor colorWithRed:1.0 green:0.90 blue:0.66 alpha:1.0].CGColor,
                  (id)[UIColor colorWithRed:0.72 green:0.47 blue:0.86 alpha:1.0].CGColor,
                  (id)[UIColor colorWithRed:0.29 green:0.23 blue:0.53 alpha:1.0].CGColor];
    ag.frame = CGRectMake(0, 0, 46, 46);
    [avatar.layer insertSublayer:ag atIndex:0];
    avatar.clipsToBounds = YES;
    avatar.userInteractionEnabled = YES;
    UITapGestureRecognizer *avatarTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(avatarTapped)];
    [avatar addGestureRecognizer:avatarTap];
    [_content addSubview:avatar];

    // Hero carousel.
    _hero = [[UIView alloc] init];
    _hero.backgroundColor = UIColor.clearColor;
    [_content addSubview:_hero];

    _stack = [[UIView alloc] init];
    _stack.backgroundColor = UIColor.clearColor;
    [_hero addSubview:_stack];
    _covers = [NSMutableArray array];
    NSArray<NSNumber *> *rots = @[@(-11), @2, @13];
    for (int i = 0; i < 3; i++) {
        UIImageView *cv = [[UIImageView alloc] init];
        cv.contentMode = UIViewContentModeScaleAspectFill;
        cv.clipsToBounds = YES;
        cv.layer.cornerRadius = 20.0;
        cv.layer.borderWidth = 1.0;
        cv.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.24].CGColor;
        cv.layer.shadowColor = UIColor.blackColor.CGColor;
        cv.layer.shadowOpacity = 0.55;
        cv.layer.shadowRadius = 14.0;
        cv.layer.shadowOffset = CGSizeMake(0, 12);
        cv.transform = CGAffineTransformMakeRotation(rots[i].floatValue * M_PI / 180.0);
        cv.tag = i;
        [_stack addSubview:cv];
        [_covers addObject:cv];
    }
    // Keep the middle cover on top.
    [_stack bringSubviewToFront:_covers[1]];

    _kicker = [self heroLabel:12.0 weight:UIFontWeightBold
                        color:[UIColor colorWithRed:0.50 green:0.83 blue:1.0 alpha:1.0]];
    _kicker.textAlignment = NSTextAlignmentCenter;
    _headline = [self heroLabel:29.0 weight:UIFontWeightHeavy color:UIColor.whiteColor];
    _headline.textAlignment = NSTextAlignmentCenter;
    _subline = [self heroLabel:12.5 weight:UIFontWeightRegular
                         color:[UIColor colorWithWhite:1.0 alpha:0.62]];
    _subline.textAlignment = NSTextAlignmentCenter;
    [_hero addSubview:_kicker];
    [_hero addSubview:_headline];
    [_hero addSubview:_subline];

    _cta = [UIButton buttonWithType:UIButtonTypeCustom];
    [_cta setTitle:(QBIsChinese() ? @"运行游戏" : @"Play Now") forState:UIControlStateNormal];
    [_cta setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _cta.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    _cta.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    _cta.layer.cornerRadius = 22.0;
    _cta.layer.borderWidth = 1.0;
    _cta.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.26].CGColor;
    [_cta addTarget:self action:@selector(ctaTapped) forControlEvents:UIControlEventTouchUpInside];
    [_hero addSubview:_cta];

    _dots = [[UIView alloc] init];
    _dotViews = [NSMutableArray array];
    [_hero addSubview:_dots];

    UIPanGestureRecognizer *hp = [[UIPanGestureRecognizer alloc]
                                  initWithTarget:self action:@selector(heroPan:)];
    hp.delegate = self;
    [_hero addGestureRecognizer:hp];

    // Icon row (the "continue playing" strip, label intentionally hidden).
    _iconRow = [[UIScrollView alloc] init];
    _iconRow.showsHorizontalScrollIndicator = NO;
    _iconRow.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _minis = [NSMutableArray array];
    [_content addSubview:_iconRow];

    UILabel *section = [[UILabel alloc] init];
    section.text = (QBIsChinese() ? @"我的游戏" : @"My Games");
    section.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightHeavy];
    section.textColor = UIColor.whiteColor;
    section.tag = 42;
    [_content addSubview:section];

    _cards = [NSMutableArray array];

    // Floating glass tab bar.
    _tabBar = [[UIView alloc] init];
    _tabBar.backgroundColor = UIColor.clearColor;
    [self addSubview:_tabBar];
    if (@available(iOS 13.0, *)) {
        // Liquid Glass by default (the shipped look); older systems keep the
        // ultra-thin frosted material as a stand-in.
        _tabFrost = [[UIVisualEffectView alloc] initWithEffect:QBGlassEffect(30.0, NO)];
        _tabFrost.userInteractionEnabled = NO;
        [_tabBar addSubview:_tabFrost];
    }
    UIView *tabRim = [[UIView alloc] init];
    tabRim.tag = 90;
    tabRim.backgroundColor = UIColor.clearColor;
    tabRim.layer.cornerRadius = 32.0;
    tabRim.layer.borderWidth = 1.0;
    tabRim.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    tabRim.userInteractionEnabled = NO;
    [_tabBar insertSubview:tabRim atIndex:0];
    _tabItems = [NSMutableArray array];
    NSArray *tabs = @[@[@"house.fill", @"主页"],
                      @[@"gamecontroller.fill", @"游戏"],
                      @[@"gearshape.fill", @"设置"],
                      @[@"rectangle.portrait.and.arrow.right", @"返回LC"]];
    for (int i = 0; i < (int)tabs.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        b.titleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
        [b setTitle:tabs[i][1] forState:UIControlStateNormal];
        [b setImage:[self symbol:tabs[i][0] fallback:@"circle.fill"]
           forState:UIControlStateNormal];
        [b setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.72] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateSelected];
        [b addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_tabBar addSubview:b];
        [_tabItems addObject:b];
    }
    _tabIndex = 0;
    _tabCollapsed = NO;
    _tabItems[_tabIndex].selected = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(coverReady:) name:QBCoverReadyNote object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UILabel *)heroLabel:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 1;
    return l;
}

- (void)coverReady:(NSNotification *)n {
    // Covers may have upgraded from synth to a real bundle image; refresh the
    // three hero covers + any visible big cards without reloading the page.
    [self applyHeroCovers];
    for (QBBigCard *c in _cards) {
        NSString *bid = c.bid ?: @"";
        if ([bid isEqualToString:n.object]) [c refreshCover];
    }
}

- (void)setApps:(NSArray<NSDictionary *> *)apps {
    // Drop old cards.
    for (QBBigCard *c in _cards) [c removeFromSuperview];
    [_cards removeAllObjects];
    for (UIButton *b in _minis) [b removeFromSuperview];
    [_minis removeAllObjects];
    for (UIView *d in _dotViews) [d removeFromSuperview];
    [_dotViews removeAllObjects];

    _apps = apps;
    _slideCount = MIN((NSInteger)apps.count, 5);
    if (_slideCount < 1) _slideCount = 1;
    if (_current >= _slideCount) _current = 0;

    // Dots.
    for (int i = 0; i < (int)_slideCount; i++) {
        UIView *d = [[UIView alloc] init];
        d.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.32];
        d.layer.cornerRadius = 3.0;
        [_dots addSubview:d];
        [_dotViews addObject:d];
    }
    // Icon row: one mini per app (up to 10 to keep it thumb-friendly).
    NSInteger miniCount = MIN((NSInteger)apps.count, 10);
    for (int i = 0; i < (int)miniCount; i++) {
        NSDictionary *app = apps[i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        b.imageView.contentMode = UIViewContentModeScaleAspectFill;
        b.layer.cornerRadius = 19.0;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.clipsToBounds = YES;
        b.layer.borderWidth = 2.0;
        b.layer.borderColor = UIColor.clearColor.CGColor;
        UIImage *ic = app[@"icon"];
        [b setImage:([ic isKindOfClass:UIImage.class] ? ic : nil) forState:UIControlStateNormal];
        [b addTarget:self action:@selector(miniTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_iconRow addSubview:b];
        [_minis addObject:b];
    }
    // Big cards: every installed app.
    for (NSDictionary *app in apps) {
        QBBigCard *c = [[QBBigCard alloc] init];
        [c configure:app];
        __weak typeof(self) weak = self;
        __weak NSDictionary *wa = app;
        c.onLaunch = ^{
            NSDictionary *a = wa;
            if (a && weak.onSelect) weak.onSelect(a);
        };
        [_content addSubview:c];
        [_cards addObject:c];
    }
    [self goToSlide:0 animated:NO];
    [self setNeedsLayout];
}

- (void)applyHeroCovers {
    for (int slot = 0; slot < 3; slot++) {
        NSInteger idx = _current + (slot - 1);
        UIImage *cover = nil;
        if (_apps.count && idx >= 0 && idx < (NSInteger)_apps.count) {
            cover = QBHomeCover(_apps[idx]);
        }
        UIImageView *cv = _covers[slot];
        cv.image = cover ?: QBSynthCover(nil);
        // Darken the two side covers so the centre reads as selected.
        cv.alpha = (slot == 1) ? 1.0 : 0.62;
    }
}

- (void)goToSlide:(NSInteger)i animated:(BOOL)animated {
    if (_apps.count == 0) return;
    i = ((i % _slideCount) + _slideCount) % _slideCount;
    _current = i;
    NSArray *s = QBHomeSlides()[i % QBHomeSlides().count];
    _kicker.text = s[0];
    _headline.text = s[1];
    _subline.text = s[2];
    [self applyHeroCovers];

    for (int k = 0; k < (int)_dotViews.count; k++) {
        UIView *d = _dotViews[k];
        BOOL on = (k == (int)i);
        d.backgroundColor = on ? [UIColor colorWithWhite:1.0 alpha:0.92]
                               : [UIColor colorWithWhite:1.0 alpha:0.32];
        d.transform = on ? CGAffineTransformMakeScale(2.6, 1.0) : CGAffineTransformIdentity;
    }
    for (int k = 0; k < (int)_minis.count; k++) {
        _minis[k].layer.borderColor = (k == (int)i)
            ? [UIColor colorWithRed:0.95 green:0.77 blue:0.42 alpha:1.0].CGColor
            : UIColor.clearColor.CGColor;
        _minis[k].transform = (k == (int)i)
            ? CGAffineTransformMakeScale(1.12, 1.12) : CGAffineTransformIdentity;
    }
    // Scroll the icon row so the selected mini sits near centre.
    if (_minis.count) {
        NSInteger k = MIN(i, (NSInteger)_minis.count - 1);
        UIButton *b = _minis[k];
        CGFloat target = b.center.x - _iconRow.bounds.size.width / 2.0;
        target = MAX(0, MIN(target, _iconRow.contentSize.width - _iconRow.bounds.size.width));
        [_iconRow setContentOffset:CGPointMake(target, 0) animated:animated];
    }
    if (animated) {
        [UIView animateWithDuration:0.28 delay:0
            options:UIViewAnimationOptionCurveEaseOut animations:^{
            self->_stack.alpha = 0.35;
        } completion:^(BOOL f) {
            [UIView animateWithDuration:0.22 animations:^{ self->_stack.alpha = 1.0; }];
        }];
    }
    // Slide the stacked covers horizontally with the page (like the preview:
    // the stack drifts left as you advance).
    CGFloat shift = (1.0 - (CGFloat)i) * 20.0;
    CGAffineTransform base = CGAffineTransformMakeTranslation(shift, 0);
    void (^apply)(void) = ^{
        for (int slot = 0; slot < 3; slot++) {
            NSArray<NSNumber *> *rots = @[@(-11), @2, @13];
            CGAffineTransform r = CGAffineTransformMakeRotation(rots[slot].floatValue * M_PI / 180.0);
            self->_covers[slot].transform = CGAffineTransformConcat(r, base);
        }
    };
    if (animated) [UIView animateWithDuration:0.3 animations:apply];
    else apply();
}

- (void)miniTapped:(UIButton *)b {
    [self goToSlide:b.tag animated:YES];
}

- (void)heroPan:(UIPanGestureRecognizer *)pan {
    if (_apps.count == 0) return;
    CGPoint t = [pan translationInView:_hero];
    if (pan.state == UIGestureRecognizerStateBegan) {
        _heroDragging = NO;
        _startX = t.x;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        _heroDragging = YES;
        if (fabs(t.x) > 24.0) {
            [pan setTranslation:CGPointZero inView:_hero];
        }
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat dx = t.x - _startX;
        if (_heroDragging && fabs(dx) > 36.0) {
            [self goToSlide:(_current + (dx < 0 ? 1 : -1)) animated:YES];
        }
        _heroDragging = NO;
    }
}

- (void)ctaTapped {
    if (_apps.count == 0) return;
    NSDictionary *app = _apps[MIN((NSInteger)_apps.count - 1, _current)];
    if (self.onSelect) self.onSelect(app);
}

#pragma mark Dismiss

- (void)avatarTapped { if (self.onDismiss) self.onDismiss(); }

// Hero pan must not steal vertical drags from the page scroll. Only claim a
// gesture that is clearly more horizontal than vertical.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:UIPanGestureRecognizer.class]) {
        UIPanGestureRecognizer *p = (UIPanGestureRecognizer *)g;
        CGPoint v = [p velocityInView:_hero];
        return fabs(v.x) > fabs(v.y) * 1.2;
    }
    return YES;
}

#pragma mark Tab bar

- (void)tabTapped:(UIButton *)b {
    if (_tabCollapsed) {
        [self setTabCollapsed:NO];
        return;
    }
    _tabIndex = b.tag;
    for (int i = 0; i < (int)_tabItems.count; i++) {
        _tabItems[i].selected = (i == (int)_tabIndex);
    }
    switch (_tabIndex) {
        case 0: // Home — back to the top.
            [_scroll setContentOffset:CGPointZero animated:YES];
            break;
        case 1: // Games — jump to the card list.
            [self scrollToGames];
            break;
        case 2: // Settings.
            if (self.onSettings) self.onSettings();
            break;
        case 3: // Return to LiveContainer.
            if (self.onReturn) self.onReturn();
            break;
        default: break;
    }
}

- (void)scrollToGames {
    UIView *section = [_content viewWithTag:42];
    if (!section) return;
    CGFloat y = section.frame.origin.y - self.safeAreaInsets.top - 12.0;
    [_scroll setContentOffset:CGPointMake(0, MAX(0, y)) animated:YES];
}

- (void)setTabCollapsed:(BOOL)collapsed {
    if (_tabCollapsed == collapsed) return;
    _tabCollapsed = collapsed;
    [UIView animateWithDuration:0.32 delay:0
        options:UIViewAnimationOptionCurveEaseInOut animations:^{
        for (int i = 0; i < (int)self->_tabItems.count; i++) {
            BOOL show = !collapsed || i == (int)self->_tabIndex;
            self->_tabItems[i].alpha = show ? 1.0 : 0.0;
            self->_tabItems[i].hidden = !show;
        }
        [self layoutTabBar];
        [self layoutIfNeeded];
    } completion:nil];
}

#pragma mark UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != _scroll) return;
    CGFloat y = scrollView.contentOffset.y;
    CGFloat dy = y - _lastScrollY;
    if (y > 90.0 && dy > 4.0) [self setTabCollapsed:YES];
    else if (dy < -4.0 || y < 40.0) [self setTabCollapsed:NO];
    _lastScrollY = y;
}

// Pull down past the top edge to dismiss the page back to the game.
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView != _scroll) return;
    if (scrollView.contentOffset.y < -72.0 && self.onDismiss) self.onDismiss();
}

#pragma mark Layout

- (void)layoutTabBar {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat bottom = self.safeAreaInsets.bottom;
    if (_tabCollapsed) {
        CGFloat s = 58.0;
        _tabBar.frame = CGRectMake(w - s - 20.0, h - bottom - s - 16.0, s, s);
        _tabBar.layer.cornerRadius = s / 2.0;
        _tabBar.layer.cornerCurve = kCACornerCurveContinuous;
        _tabBar.layer.shadowColor = UIColor.blackColor.CGColor;
        _tabBar.layer.shadowOpacity = 0.42;
        _tabBar.layer.shadowRadius = 16.0;
        _tabBar.layer.shadowOffset = CGSizeMake(0, 8);
        for (UIButton *b in _tabItems) {
            b.frame = _tabBar.bounds;
            b.imageEdgeInsets = UIEdgeInsetsMake(-8, 0, 0, 0);
            b.titleEdgeInsets = UIEdgeInsetsMake(20, -b.imageView.image.size.width, -18, 0);
        }
    } else {
        CGFloat s = 66.0;
        CGFloat m = 18.0;
        _tabBar.frame = CGRectMake(m, h - bottom - s - 14.0, w - m * 2.0, s);
        _tabBar.layer.cornerRadius = s / 2.0;
        _tabBar.layer.cornerCurve = kCACornerCurveContinuous;
        _tabBar.layer.shadowColor = UIColor.blackColor.CGColor;
        _tabBar.layer.shadowOpacity = 0.42;
        _tabBar.layer.shadowRadius = 18.0;
        _tabBar.layer.shadowOffset = CGSizeMake(0, 8);
        CGFloat iw = _tabBar.bounds.size.width / (CGFloat)_tabItems.count;
        for (int i = 0; i < (int)_tabItems.count; i++) {
            _tabItems[i].frame = CGRectMake(iw * i, 0, iw, s);
            _tabItems[i].imageEdgeInsets = UIEdgeInsetsMake(-9, 0, 0, 0);
            _tabItems[i].titleEdgeInsets = UIEdgeInsetsMake(16, -_tabItems[i].imageView.image.size.width, -14, 0);
        }
    }
    _tabFrost.frame = _tabBar.bounds;
    _tabFrost.layer.cornerRadius = _tabBar.layer.cornerRadius;
    _tabFrost.clipsToBounds = YES;
    UIView *rim = [_tabBar viewWithTag:90];
    rim.frame = _tabBar.bounds;
    rim.layer.cornerRadius = _tabBar.layer.cornerRadius;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _bgGradient.frame = self.bounds;
    _scroll.frame = self.bounds;

    CGFloat pad = 22.0;
    CGFloat y = self.safeAreaInsets.top + 10.0;

    // Title row.
    UIView *title = [_content viewWithTag:40];
    UIView *avatar = [_content viewWithTag:41];
    title.frame = CGRectMake(pad, y, w - 120.0, 44);
    avatar.frame = CGRectMake(w - pad - 46.0, y - 1.0, 46, 46);
    y += 54.0;

    // Hero.
    CGFloat heroH = 372.0;
    _hero.frame = CGRectMake(0, y, w, heroH);
    CGFloat coverW = 118.0, coverH = 158.0;
    _stack.frame = CGRectMake((w - 320.0) / 2.0, 8.0, 320.0, coverH + 34.0);
    for (int slot = 0; slot < 3; slot++) {
        CGFloat left = slot == 0 ? 12.0 : (slot == 1 ? 100.0 : 190.0);
        CGFloat top = slot == 1 ? 2.0 : (slot == 0 ? 18.0 : 24.0);
        _covers[slot].bounds = CGRectMake(0, 0, coverW, coverH);
        _covers[slot].center = CGPointMake(left + coverW / 2.0, top + coverH / 2.0);
        _covers[slot].layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:_covers[slot].bounds cornerRadius:20.0].CGPath;
    }
    CGFloat cy = 196.0;
    _kicker.frame = CGRectMake(0, cy, w, 18);
    _headline.frame = CGRectMake(0, cy + 22.0, w, 40);
    _subline.frame = CGRectMake(0, cy + 66.0, w, 20);
    _cta.frame = CGRectMake((w - 214.0) / 2.0, cy + 94.0, 214.0, 44);
    _dots.frame = CGRectMake(0, cy + 150.0, w, 12);
    CGFloat totalDotsW = _dotViews.count * 18.0;
    CGFloat dx = (w - totalDotsW) / 2.0;
    for (UIView *d in _dotViews) {
        d.frame = CGRectMake(dx, 4.5, 6, 6);
        dx += 18.0;
    }
    y += heroH + 4.0;

    // Icon row.
    CGFloat mini = 62.0;
    CGFloat rowH = mini + 12.0;
    _iconRow.frame = CGRectMake(0, y, w, rowH);
    CGFloat ix = pad;
    for (UIButton *b in _minis) {
        b.frame = CGRectMake(ix, 2.0, mini, mini);
        ix += mini + 12.0;
    }
    _iconRow.contentSize = CGSizeMake(ix + pad, rowH);
    y += rowH + 8.0;

    // Section title.
    UIView *section = [_content viewWithTag:42];
    section.frame = CGRectMake(pad, y, w - pad * 2.0, 30);
    y += 40.0;

    // Big cards.
    CGFloat cardH = 212.0;
    for (QBBigCard *c in _cards) {
        c.frame = CGRectMake(pad, y, w - pad * 2.0, cardH);
        y += cardH + 14.0;
    }

    CGFloat bottomSpace = self.safeAreaInsets.bottom + 66.0 + 40.0;
    _content.frame = CGRectMake(0, 0, w, y + bottomSpace);
    _scroll.contentSize = CGSizeMake(w, y + bottomSpace);
    [self layoutTabBar];
    if (_minis.count) [self goToSlide:_current animated:NO];
}

@end

#pragma mark - App settings panel (mirrors LC's own App Settings)

// A compact panel that reads/writes the current guest app's LCAppInfo.plist —
// the exact file LiveContainer's native "App Settings" page uses. Toggles here
// are therefore fully in sync with LC. Changes take effect on next app launch.
@interface QBSettingsView : UIView
@property(nonatomic, strong) NSString *plistPath;
@property(nonatomic, strong) NSMutableDictionary *settings;
@property(nonatomic, strong) NSArray<NSDictionary *> *sections; // @{title, rows:[{key,title,sub,inverted}]}
@property(nonatomic, strong) UIView *toolbar;
@property(nonatomic, strong) QBGlassButton *returnButton;  // back to LiveContainer
@property(nonatomic, strong) QBGlassButton *backButton;    // back to the app list
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, assign) CGSize builtSize;   // size used for the current module layout
@property(nonatomic, copy) void (^onBack)(void);
@property(nonatomic, copy) void (^onReturn)(void);

/// Height that shows every module without scrolling, at a comfortable row
/// height (the controller clamps it to the screen).
- (CGFloat)fittedHeight;
@end

@implementation QBSettingsView

- (UIImage *)symbol:(NSString *)name fallback:(NSString *)fallback {
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:name];
        if (img) return img;
        return [UIImage systemImageNamed:fallback];
    }
    return nil;
}

// (clock helpers removed — the settings panel has no header anymore)

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    // Same as the app list: no backdrop panel, the module cards float on the
    // game themselves.
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;

    self.plistPath = QBCurrentAppPlistPath();
    NSDictionary *loaded = self.plistPath
        ? [NSDictionary dictionaryWithContentsOfFile:self.plistPath] : nil;
    self.settings = loaded ? [loaded mutableCopy] : [NSMutableDictionary dictionary];

    // Grouped modules. inverted=YES means the plist key is a negative flag
    // (dont...) so UI ON maps to plist NO.
    self.sections = @[
        @{ @"title": (QBIsChinese() ? @"文件与插件" : @"Files & Tweaks"), @"rows": @[
            @{ @"key": @"fixFilePickerNew", @"title": (QBIsChinese() ? @"修复文件导入" : @"Fix file import"),
               @"sub": (QBIsChinese() ? @"允许 App 访问系统文件 App 中的文件" : @"Access files from the system Files app"), @"inverted": @(NO) },
            @{ @"key": @"dontInjectTweakLoader", @"title": (QBIsChinese() ? @"注入插件加载器" : @"Inject TweakLoader"),
               @"sub": (QBIsChinese() ? @"启动时注入 TweakLoader" : @"Inject TweakLoader at launch"), @"inverted": @(YES) },
            @{ @"key": @"dontLoadTweakLoader", @"title": (QBIsChinese() ? @"加载插件" : @"Load tweaks"),
               @"sub": (QBIsChinese() ? @"加载已安装的插件" : @"Load installed tweaks"), @"inverted": @(YES) },
        ]},
        @{ @"title": (QBIsChinese() ? @"运行" : @"Runtime"), @"rows": @[
            @{ @"key": @"classicMode", @"title": (QBIsChinese() ? @"经典模式" : @"Classic mode"),
               @"sub": (QBIsChinese() ? @"使用传统方式启动应用" : @"Launch apps the classic way"), @"inverted": @(NO) },
            @{ @"key": @"hideLiveContainer", @"title": (QBIsChinese() ? @"隐藏 LiveContainer" : @"Hide LiveContainer"),
               @"sub": (QBIsChinese() ? @"对外隐藏容器信息" : @"Hide container identity from apps"), @"inverted": @(NO) },
            @{ @"key": @"fixLocalNotification", @"title": (QBIsChinese() ? @"修复本地通知" : @"Fix local notifications"),
               @"sub": (QBIsChinese() ? @"修复应用内本地通知" : @"Fix in-app local notifications"), @"inverted": @(NO) },
            @{ @"key": @"helperProcessesSupport", @"title": (QBIsChinese() ? @"辅助进程支持" : @"Helper processes"),
               @"sub": (QBIsChinese() ? @"支持应用辅助进程" : @"Support app helper processes"), @"inverted": @(NO) },
        ]},
    ];

    // Top toolbar — same layout as the app list, except the right-hand button
    // reads "返回" and takes you back to the list (no segmented switcher).
    self.toolbar = [[QBHitThroughView alloc] init];
    self.toolbar.backgroundColor = UIColor.clearColor;
    [self addSubview:self.toolbar];

    self.returnButton = [[QBGlassButton alloc]
        initWithSymbol:@"house.fill"
                 title:(QBIsChinese() ? @"返回 LiveContainer" : @"Back to LiveContainer")
            glyphColor:QBGlassBlueInk()
             fillColor:QBGlassBlueFill()];
    [self.returnButton addTarget:self action:@selector(returnTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [self.toolbar addSubview:self.returnButton];

    self.backButton = [[QBGlassButton alloc]
        initWithSymbol:@"chevron.left"
                 title:(QBIsChinese() ? @"返回" : @"Back")
            glyphColor:QBGlassRedInk()
             fillColor:QBGlassRedFill()];
    [self.backButton addTarget:self action:@selector(backTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [self.toolbar addSubview:self.backButton];

    // Scrollable module cards. Like the app list, they run the full panel
    // height and slide under the floating toolbar.
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.backgroundColor = UIColor.clearColor;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self addSubview:self.scrollView];
    [self bringSubviewToFront:self.toolbar];
    [self buildModules];
    return self;
}

// One row height for every module. 62pt is the "not cramped" size: a 15pt
// title, a 12pt subtitle and breathing room above/below. Only a very short
// screen (landscape) squeezes it, and never below 50pt.
static CGFloat const QBSetRowHeight   = 62.0;
static CGFloat const QBSetHeaderH     = 26.0;
static CGFloat const QBSetSectionGap  = 18.0;

- (CGFloat)fittedHeight {
    NSUInteger totalRows = 0;
    for (NSDictionary *s in self.sections) totalRows += [(NSArray *)s[@"rows"] count];
    return QBToolbarHeight + 2.0      // room for the floating toolbar
        + 12.0                        // top breathing room
        + self.sections.count * (QBSetHeaderH + QBSetSectionGap)
        + totalRows * QBSetRowHeight
        + 12.0;
}

// Build grouped module cards (section header + rounded card of switch rows).
// Cards float directly on the game — there is no backdrop panel any more.
- (void)buildModules {
    for (UIView *v in [self.scrollView.subviews copy]) [v removeFromSuperview];
    CGFloat w = self.bounds.size.width > 0 ? self.bounds.size.width : 340.0;
    CGFloat h = self.bounds.size.height > 0 ? self.bounds.size.height : [self fittedHeight];
    // Content starts BELOW the floating toolbar as a plain coordinate, not as a
    // scroll content inset: an inset shifts everything up by its own height at
    // contentOffset 0, which pushed "文件与插件" behind the pills on open.
    CGFloat y = QBToolbarHeight + 2.0 + 12.0;
    CGFloat moduleSide = 18.0;
    CGFloat innerW = w - moduleSide * 2.0;

    // Fit the row height to the available height, but keep it generous.
    NSUInteger totalRows = 0;
    for (NSDictionary *s in self.sections) totalRows += [(NSArray *)s[@"rows"] count];
    CGFloat available = h - QBToolbarHeight - 12.0 - 12.0;
    CGFloat chrome = self.sections.count * (QBSetHeaderH + QBSetSectionGap);
    CGFloat fitRowH = totalRows ? (available - chrome) / (CGFloat)totalRows : QBSetRowHeight;
    CGFloat rowH = MAX(50.0, MIN(QBSetRowHeight, fitRowH));

    NSInteger sectionIndex = 0;
    for (NSDictionary *section in self.sections) {
        UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(moduleSide + 2, y, innerW, QBSetHeaderH)];
        header.text = section[@"title"];
        header.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
        header.textColor = QBTextSecondary();
        [self.scrollView addSubview:header];
        y += QBSetHeaderH;

        NSArray *rows = section[@"rows"];
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(moduleSide, y, innerW, rows.count * rowH)];
        card.backgroundColor = UIColor.clearColor;
        card.layer.cornerRadius = 20.0;
        card.layer.cornerCurve = kCACornerCurveContinuous;
        card.layer.borderWidth = 0.7;
        card.layer.borderColor = QBDynamicColor(
            [UIColor colorWithWhite:0.0 alpha:0.08], [UIColor colorWithWhite:1.0 alpha:0.22]).CGColor;
        card.layer.shadowColor = UIColor.blackColor.CGColor;
        card.layer.shadowOpacity = 0.14;
        card.layer.shadowRadius = 10.0;
        card.layer.shadowOffset = CGSizeMake(0, 4.0);
        card.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:card.bounds cornerRadius:20.0].CGPath;
        card.clipsToBounds = NO;
        [self.scrollView addSubview:card];

        // Inner surface holds the frosted sheet and clips everything to the
        // rounded corners, while the shadow stays on the outer layer.
        UIView *inner = [[UIView alloc] initWithFrame:card.bounds];
        inner.backgroundColor = UIColor.clearColor;
        inner.layer.cornerRadius = 20.0;
        inner.layer.cornerCurve = kCACornerCurveContinuous;
        inner.clipsToBounds = YES;
        [card addSubview:inner];

        // Frosted glass: real blur + a faint milk veil (same sheet as the app
        // cards, so switching pages doesn't change the material).
        UIVisualEffectView *frost;
        if (@available(iOS 26.0, *)) {
            UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
            glass.interactive = NO;
            frost = [[UIVisualEffectView alloc] initWithEffect:glass];
        } else {
            frost = [[UIVisualEffectView alloc] initWithEffect:
                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
        }
        frost.frame = inner.bounds;
        frost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        frost.userInteractionEnabled = NO;
        [inner addSubview:frost];

        UIView *veil = [[UIView alloc] initWithFrame:inner.bounds];
        veil.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        veil.backgroundColor = QBDynamicColor([UIColor colorWithWhite:1.0 alpha:0.06],
                                              [UIColor colorWithWhite:1.0 alpha:0.03]);
        veil.userInteractionEnabled = NO;
        [inner addSubview:veil];

        for (NSInteger i = 0; i < rows.count; i++) {
            NSDictionary *row = rows[i];
            CGFloat ry = i * rowH;
            if (i > 0) {
                UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(16, ry, innerW - 32, 0.5)];
                sep.backgroundColor = QBDynamicColor(
                    [UIColor colorWithWhite:0.0 alpha:0.07], [UIColor colorWithWhite:1.0 alpha:0.14]);
                [inner addSubview:sep];
            }
            // Title + subtitle are stacked with real breathing room so nothing
            // reads as a wall of cramped text.
            UILabel *title = [[UILabel alloc]
                initWithFrame:CGRectMake(16, ry + 11.0, innerW - 90, 21.0)];
            title.text = row[@"title"];
            title.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
            title.textColor = QBTextPrimary();
            [inner addSubview:title];

            UILabel *sub = [[UILabel alloc]
                initWithFrame:CGRectMake(16, ry + 34.0, innerW - 90, 17.0)];
            sub.text = row[@"sub"];
            sub.font = [UIFont systemFontOfSize:12.0];
            sub.textColor = QBTextSecondary();
            [inner addSubview:sub];

            NSString *key = row[@"key"];
            BOOL inverted = [row[@"inverted"] boolValue];
            BOOL on = [self.settings[key] boolValue];
            if (inverted) on = !on;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = on;
            sw.onTintColor = QBGreen();
            sw.tag = sectionIndex * 100 + i;
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            CGFloat swW = sw.bounds.size.width, swH = sw.bounds.size.height;
            sw.frame = CGRectMake(innerW - swW - 16, ry + (rowH - swH) / 2.0, swW, swH);
            [inner addSubview:sw];
        }
        y += rows.count * rowH + QBSetSectionGap;
        sectionIndex++;
    }
    self.scrollView.contentSize = CGSizeMake(w, y + 12.0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;

    // Floating glass toolbar — same treatment as the app list panel, and the
    // same right-hand width. It used to be 92pt here against 104pt there, and
    // since the pair is right-aligned the 12pt difference moved both pills the
    // moment you opened settings.
    self.toolbar.frame = CGRectMake(0, 0, w, QBToolbarHeight);
    CGFloat barH = 40.0;
    CGFloat barY = (QBToolbarHeight - barH) / 2.0;
    CGFloat inset = QBToolbarInset;
    CGFloat rightW = 104.0;
    CGFloat gap = 10.0;
    CGFloat leftW = MAX(130.0, w - inset * 2.0 - rightW - gap);
    self.returnButton.frame = CGRectMake(inset, barY, leftW, barH);
    self.backButton.frame = CGRectMake(inset + leftW + gap, barY, rightW, barH);

    self.scrollView.frame = self.bounds;
    self.scrollView.contentInset = UIEdgeInsetsMake(0, 0, 10.0, 0);
    self.scrollView.scrollIndicatorInsets = UIEdgeInsetsMake(QBToolbarHeight, 0, 10.0, 0);
    CGSize sz = self.scrollView.bounds.size;
    if (fabs(sz.width - _builtSize.width) > 0.5 || fabs(sz.height - _builtSize.height) > 0.5) {
        _builtSize = sz;
        [self buildModules];
    }
}

- (void)backTapped { if (self.onBack) self.onBack(); }
- (void)returnTapped { if (self.onReturn) self.onReturn(); }

- (NSDictionary *)flatRowAtTag:(NSInteger)tag {
    NSInteger sec = tag / 100, row = tag % 100;
    if (sec < 0 || sec >= (NSInteger)self.sections.count) return nil;
    NSDictionary *section = self.sections[sec];
    NSArray *rows = section[@"rows"];
    if (row < 0 || row >= (NSInteger)rows.count) return nil;
    return rows[row];
}

- (void)switchChanged:(UISwitch *)sender {
    NSDictionary *row = [self flatRowAtTag:sender.tag];
    if (!row) return;
    NSString *key = row[@"key"];
    BOOL inverted = [row[@"inverted"] boolValue];
    BOOL value = sender.on;
    if (inverted) value = !value;
    self.settings[key] = @(value);
    if (self.plistPath) {
        [self.settings writeToFile:self.plistPath atomically:YES];
    }
}

@end

#pragma mark - Overlay window

@interface QBOverlayWindow : UIWindow
@end

@implementation QBOverlayWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *root = self.rootViewController.view;
    if (!root) return NO;
    // BUGFIX: the old code walked self.subviews, which for a UIWindow is the
    // rootViewController.view — a full-screen transparent view. That made this
    // window claim EVERY touch in the guest app (nothing could be tapped).
    // Walk only the root's real children (tab / scrim / card) so touches
    // outside QuickBar fall through to the guest app underneath.
    for (UIView *sub in root.subviews.reverseObjectEnumerator) {
        if (sub.hidden || sub.userInteractionEnabled == NO || sub.alpha < 0.01) continue;
        CGPoint local = [root convertPoint:point toView:sub];
        if ([sub pointInside:local withEvent:event]) return YES;
    }
    return NO;
}
@end

#pragma mark - Overlay controller

@interface QBOverlayController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic, strong) QBTabView *tab;
@property(nonatomic, strong) QBQuickDock *dock;         // small glass dock, bottom centre
@property(nonatomic, strong) QBInstallPanel *installPanel;
@property(nonatomic, strong) QBHomeView *homeView;
@property(nonatomic, strong) UIView *scrim;
@property(nonatomic, strong) QBCardView *card;   // guest-app switcher sheet (v28 layout)
@property(nonatomic, strong) QBSettingsView *settingsView;
@property(nonatomic, strong) NSTimer *fadeTimer;
@property(nonatomic, assign) BOOL dragging;
@property(nonatomic, assign) BOOL menuOpen;
@property(nonatomic, assign) BOOL keepScrim;   // keep the backdrop across a page switch
@property(nonatomic, assign) CGFloat xRatio;
@property(nonatomic, assign) CGFloat yRatio;   // portrait: vertical position
@end

@implementation QBOverlayController

#pragma mark Scrim

/// Tap shield + Control-Center style backdrop (blurred, slightly dimmed game).
/// Reused by both pages so switching list -> settings keeps the same backdrop.
- (UIView *)installScrimWithAction:(SEL)action {
    if (self.scrim) {
        // Page switch: keep the existing blur, only re-target the tap shield so
        // the backdrop doesn't flash while list <-> settings cross-fades.
        for (UIGestureRecognizer *g in [self.scrim.gestureRecognizers copy]) {
            [self.scrim removeGestureRecognizer:g];
        }
        UITapGestureRecognizer *retarget =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:action];
        retarget.cancelsTouchesInView = NO;
        [self.scrim addGestureRecognizer:retarget];
        return self.scrim;
    }
    UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
    scrim.backgroundColor = UIColor.clearColor;
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // NO full-screen blur any more. UIVisualEffectView blurs in linear space and
    // then applies a material tint; on this iOS the private-effect path fell
    // back to a system material, which washed the whole game out into greys
    // ("背景变黑白"). A plain dim keeps every original hue intact — the glass
    // look is carried by the cards themselves, which blur only what is behind
    // them.
    UIView *dim = [[UIView alloc] init];
    dim.frame = scrim.bounds;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = QBDynamicColor([UIColor colorWithWhite:0.0 alpha:0.05],
                                         [UIColor colorWithWhite:0.0 alpha:0.12]);
    dim.userInteractionEnabled = NO;
    [scrim addSubview:dim];

    UITapGestureRecognizer *outside =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:action];
    outside.cancelsTouchesInView = NO;
    [scrim addGestureRecognizer:outside];

    [self.view insertSubview:scrim belowSubview:self.tab];
    scrim.alpha = 0.0;
    [UIView animateWithDuration:0.18 animations:^{ scrim.alpha = 1.0; }];
    self.scrim = scrim;
    return scrim;
}

/// Fades the backdrop out and then tears it down.
- (void)removeScrim {
    UIView *scrim = self.scrim;
    self.scrim = nil;
    if (!scrim) return;
    scrim.userInteractionEnabled = NO;
    [UIView animateWithDuration:0.16 animations:^{
        scrim.alpha = 0.0;
    } completion:^(BOOL finished) {
        [scrim removeFromSuperview];
    }];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    self.tab = [[QBTabView alloc]
        initWithFrame:CGRectMake(0, 0, QBTabWidth, QBTabHeight)];
    [self.view addSubview:self.tab];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tabTapped)];
    [self.tab addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.minimumNumberOfTouches = 1;
    pan.maximumNumberOfTouches = 1;
    [self.tab addGestureRecognizer:pan];

    double saved = [QBDefaults() doubleForKey:QBXRatioKey];
    self.xRatio = saved > 0.0 ? MIN(MAX(saved, 0.0), 1.0) : 0.5;
    double savedY = [QBDefaults() doubleForKey:QBYRatioKey];
    self.yRatio = savedY > 0.0 ? MIN(MAX(savedY, 0.05), 0.95) : 0.42;
    [self layoutTab];
    [self setupDock];
    [self resetFadeTimer];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(geometryChanged)
            name:UIApplicationDidChangeStatusBarOrientationNotification
          object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(geometryChanged)
            name:UIDeviceOrientationDidChangeNotification
          object:nil];
}

- (void)dealloc {
    [self.fadeTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutTab];
    [self layoutDock];
    if (self.installPanel) [self layoutInstallPanel];
    if (self.homeView) self.homeView.frame = self.view.bounds;
    if (self.menuOpen) [self layoutCard];
    if (self.settingsView) [self layoutCardForView:self.settingsView];
}

- (void)geometryChanged {
    [self layoutTab];
    [self layoutDock];
    if (self.installPanel) [self layoutInstallPanel];
    if (self.homeView) self.homeView.frame = self.view.bounds;
    if (self.menuOpen) [self layoutCard];
    if (self.settingsView) [self layoutCardForView:self.settingsView];
}

- (BOOL)isPortraitLayout {
    CGSize s = self.view.bounds.size;
    return s.height > s.width;
}

- (void)layoutTab {
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    if (w <= 0 || h <= 0) return;
    if ([self isPortraitLayout]) {
        // Portrait: the trigger becomes a side handle on the RIGHT edge. Docked
        // to the top edge it sat under the status bar / Dynamic Island, where
        // touches never reached it — the tab was effectively dead there.
        CGFloat thickness = QBTabHeight;   // 28pt proud of the edge
        CGFloat length = QBTabWidth;       // 64pt long
        self.tab.verticalEdge = YES;
        self.tab.bounds = CGRectMake(0, 0, thickness, length);
        CGFloat half = length / 2.0;
        CGFloat lo = self.view.safeAreaInsets.top + half + 12.0;
        CGFloat hi = h - self.view.safeAreaInsets.bottom - half - 12.0;
        CGFloat cy = h * self.yRatio;
        cy = MAX(lo, MIN(cy, MAX(lo, hi)));
        self.tab.center = CGPointMake(w - thickness / 2.0, cy);
    } else {
        self.tab.verticalEdge = NO;
        self.tab.bounds = CGRectMake(0, 0, QBTabWidth, QBTabHeight);
        CGFloat cx = w * self.xRatio;
        cx = MAX(QBTabWidth / 2.0, MIN(cx, w - QBTabWidth / 2.0));
        self.tab.center = CGPointMake(cx, QBTabHeight / 2.0); // glued to y = 0
    }
    [self.tab setNeedsLayout];
}

#pragma mark - Compact dock (bottom centre, 2 x 46pt, never stretches)

- (void)setupDock {
    if (self.dock) return;
    self.dock = [[QBQuickDock alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    self.dock.onPlus = ^{ [weakSelf toggleInstallPanel]; };
    self.dock.onApps = ^{ [weakSelf openHome]; };
    [self.view addSubview:self.dock];
    [self layoutDock];
}

- (void)layoutDock {
    if (!self.dock) return;
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    if (w <= 0 || h <= 0) return;
    CGSize s = [QBQuickDock compactSize];
    CGFloat bottom = self.view.safeAreaInsets.bottom;
    self.dock.frame = CGRectMake((w - s.width) / 2.0,
                                 h - bottom - s.height - QBDockBottomGap,
                                 s.width, s.height);
}

#pragma mark - Install sheet (opened by the ＋ button)

- (void)toggleInstallPanel {
    if (self.installPanel) { [self closeInstallPanel]; return; }
    [self openInstallPanel];
}

- (void)openInstallPanel {
    if (self.installPanel || self.homeView || self.menuOpen || self.settingsView) return;
    [self.fadeTimer invalidate];
    self.tab.alpha = 1.0;

    [self installScrimWithAction:@selector(closeInstallPanel)];
    [self.view bringSubviewToFront:self.dock];   // dock stays tappable to toggle closed

    QBInstallPanel *panel = [[QBInstallPanel alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    panel.onPickFile = ^{ [weakSelf pickIPAPressed]; };
    panel.onGoLC = ^{
        [weakSelf closeInstallPanel];
        [weakSelf returnToLiveContainer];
    };
    [self.view insertSubview:panel aboveSubview:self.scrim];
    self.installPanel = panel;
    [self layoutInstallPanel];

    panel.alpha = 0.0;
    panel.transform = CGAffineTransformMakeTranslation(0, 12.0);
    [UIView animateWithDuration:0.22 delay:0
         options:UIViewAnimationOptionCurveEaseOut animations:^{
        panel.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)layoutInstallPanel {
    if (!self.installPanel) return;
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    if (w <= 0 || h <= 0) return;
    CGFloat pw = MIN(380.0, w - 32.0);
    CGFloat ph = [QBInstallPanel preferredHeightForWidth:pw];
    CGFloat dockTop = self.dock ? CGRectGetMinY(self.dock.frame) : (h - ph - 24.0);
    CGFloat top = MAX(self.view.safeAreaInsets.top + 12.0, dockTop - ph - 12.0);
    self.installPanel.frame = CGRectMake((w - pw) / 2.0, top, pw, ph);
}

- (void)closeInstallPanel {
    QBInstallPanel *panel = self.installPanel;
    self.installPanel = nil;
    if (!panel) return;
    if (self.keepScrim) self.keepScrim = NO; else [self removeScrim];
    [UIView animateWithDuration:0.16 animations:^{
        panel.alpha = 0.0;
        panel.transform = CGAffineTransformMakeTranslation(0, 10.0);
    } completion:^(BOOL finished) {
        [panel removeFromSuperview];
    }];
    [self resetFadeTimer];
}

#pragma mark - IPA picking (guest import -> LiveContainer inbox)

/// LiveContainer's real Documents folder (visible to the host). In a guest,
/// LC_HOME_PATH points at it; the guest process shares LC's sandbox, so this
/// directory is writable here and readable by the host on next launch.
static NSString *QBHostDocumentsPath(void) {
    const char *home = getenv("LC_HOME_PATH");
    if (!home || !*home) return nil;
    return [NSString stringWithFormat:@"%s/Documents", home];
}

- (void)pickIPAPressed {
    UIDocumentPickerViewController *picker;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // The asCopy import mode copies the file into our container before the
    // callback fires, so no security-scope dance is needed afterwards.
    picker = [[UIDocumentPickerViewController alloc]
              initWithDocumentTypes:@[@"public.data"]
                             inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    [controller dismissViewControllerAnimated:YES completion:^{
        if (!url) return;
        [self importIPACopyFromURL:url];
    }];
}

- (void)importIPACopyFromURL:(NSURL *)url {
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"package.ipa";
    if (![name.pathExtension.lowercaseString isEqualToString:@"ipa"]) {
        // Still a normal archive? Ask for a real .ipa once and stop.
        [self showMessage:(QBIsChinese()
            ? @"请选择 .ipa 安装包（不是 zip/其它文件）。"
            : @"Please pick an .ipa package (not a zip or other file).")];
        return;
    }
    NSString *documents = QBHostDocumentsPath();
    if (!documents.length) {
        [self showMessage:(QBIsChinese()
            ? @"无法定位 LiveContainer 目录，请在 LiveContainer 中手动安装。"
            : @"Cannot locate LiveContainer's folder. Please install from LiveContainer.")];
        return;
    }
    NSString *inbox = [documents stringByAppendingPathComponent:@"Inbox"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *err = nil;
    [fm createDirectoryAtPath:inbox withIntermediateDirectories:YES
                   attributes:nil error:&err];
    NSString *dest = [inbox stringByAppendingPathComponent:name];
    [fm removeItemAtPath:dest error:nil];   // overwriting the same IPA is fine
    BOOL ok = [fm copyItemAtPath:url.path toPath:dest error:&err];
    if (!ok) {
        [self showMessage:[NSString stringWithFormat:
            (QBIsChinese() ? @"复制失败：%@" : @"Copy failed: %@"),
            err.localizedDescription ?: @"-"]];
        return;
    }

    NSString *msg = QBIsChinese()
        ? [NSString stringWithFormat:
           @"IPA 已放入 LiveContainer/Inbox\n%@\n\n即将返回 LiveContainer 完成安装。", name]
        : [NSString stringWithFormat:
           @"IPA saved to LiveContainer/Inbox\n%@\n\nReturning to LiveContainer to finish the install.", name];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:(QBIsChinese() ? @"准备安装" : @"Ready to install")
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:(QBIsChinese() ? @"返回 LC 安装" : @"Go install in LC")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf returnToLiveContainer];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:(QBIsChinese() ? @"留在游戏" : @"Stay in game")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMessage:(NSString *)text {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:nil message:text
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Home page (large game cards)

- (void)openHome {
    if (self.homeView) return;
    [self closeInstallPanel];
    [self.fadeTimer invalidate];
    self.tab.alpha = 1.0;

    QBHomeView *home = [[QBHomeView alloc] initWithFrame:self.view.bounds];
    home.apps = QBLoadGuestApps();
    __weak typeof(self) weakSelf = self;
    home.onSelect = ^(NSDictionary *app) {
        [weakSelf closeHome];
        [weakSelf switchToApp:app];
    };
    home.onSettings = ^{
        [weakSelf closeHome];
        [weakSelf openSettings];
    };
    home.onReturn = ^{
        [weakSelf closeHome];
        [weakSelf returnToLiveContainer];
    };
    home.onDismiss = ^{ [weakSelf closeHome]; };
    home.alpha = 0.0;
    [self.view addSubview:home];
    self.homeView = home;
    [UIView animateWithDuration:0.22 animations:^{ home.alpha = 1.0; }];
}

- (void)closeHome {
    QBHomeView *home = self.homeView;
    self.homeView = nil;
    if (!home) return;
    [UIView animateWithDuration:0.18 animations:^{
        home.alpha = 0.0;
    } completion:^(BOOL finished) {
        [home removeFromSuperview];
    }];
    [self resetFadeTimer];
}

- (CGFloat)cardWidth {
    return MIN(QBCardMaxWidth, self.view.bounds.size.width - 32.0);
}

/// One panel height shared by the app list and the settings panel so the
/// background never changes size when you switch between them.
- (CGFloat)panelHeight {
    CGFloat maxH = self.view.bounds.size.height - QBTabHeight - 24.0;
    return MAX(240.0, MIN(QBPanelHeight, maxH));
}

- (void)layoutCard {
    if (!self.card) return;
    [self layoutCardForView:self.card];
}

- (void)layoutCardForView:(UIView *)view {
    CGFloat w = [self cardWidth];
    CGFloat cw = self.view.bounds.size.width;
    CGFloat ch = self.view.bounds.size.height;
    BOOL portrait = [self isPortraitLayout];
    // In portrait the tab is a side handle, so the panel behaves like a normal
    // sheet: centred horizontally, hung below the status bar. In landscape it
    // still hangs off the tab, which sits flush with the top edge.
    // Portrait: the sheet hugs the BOTTOM edge — one-handed thumb reach.
    // Landscape: the sheet is a drawer that comes straight out of the screen
    // edge — flush against the right edge and running all the way down to the
    // bottom edge, no side margin and no empty strip underneath.
    CGFloat bottomGap = portrait ? MAX(self.view.safeAreaInsets.bottom + 12.0, 20.0) : 0.0;
    CGFloat cx = portrait ? cw / 2.0
                          : MAX(w / 2.0, MIN(self.tab.center.x, cw - w / 2.0));

    CGFloat topLimit = portrait ? MAX(self.view.safeAreaInsets.top + 8.0, QBTabHeight + 4.0)
                                : QBTabHeight + 4.0;
    CGFloat maxH = MAX(240.0, ch - topLimit - bottomGap);
    CGFloat h = MAX(240.0, MIN(QBPanelHeight, maxH));
    if ([view isKindOfClass:QBSettingsView.class]) {
        h = MAX(300.0, MIN([(QBSettingsView *)view fittedHeight], maxH));
    }
    CGFloat top = portrait ? (ch - bottomGap - h) : QBTabHeight + 4.0;
    top = MAX(topLimit, top);
    view.frame = CGRectMake(cx - w / 2.0, top, w, h);
    self.scrim.frame = self.view.bounds;
}

#pragma mark Gestures

- (void)tabTapped {
    if (self.settingsView) { [self closeSettings]; return; }
    if (self.menuOpen) { [self closeMenu]; return; }
    [self openMenu];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (self.menuOpen) return;
    BOOL portrait = [self isPortraitLayout];
    CGPoint t = [pan translationInView:self.view];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragging = NO;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (fabs(t.x) > QBDragThreshold || fabs(t.y) > QBDragThreshold) {
            self.dragging = YES;
            [self.fadeTimer invalidate];
            self.tab.alpha = 1.0;
            if (portrait) {
                // Side handle slides up/down the right edge.
                CGFloat h = self.view.bounds.size.height;
                CGFloat half = self.tab.bounds.size.height / 2.0;
                CGFloat cy = self.tab.center.y + t.y;
                cy = MAX(half + 8.0, MIN(cy, h - half - 8.0));
                self.tab.center = CGPointMake(self.tab.center.x, cy);
                self.yRatio = cy / h;
            } else {
                CGFloat cx = self.tab.center.x + t.x;
                CGFloat half = self.tab.bounds.size.width / 2.0;
                cx = MAX(half, MIN(cx, self.view.bounds.size.width - half));
                self.tab.center = CGPointMake(cx, QBTabHeight / 2.0);
                self.xRatio = cx / self.view.bounds.size.width;
            }
            [pan setTranslation:CGPointZero inView:self.view];
        }
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled) {
        if (self.dragging) {
            [QBDefaults() setDouble:self.xRatio forKey:QBXRatioKey];
            [QBDefaults() setDouble:self.yRatio forKey:QBYRatioKey];
            [self resetFadeTimer];
        }
        self.dragging = NO;
    }
}

#pragma mark Menu

- (void)openMenu {
    if (self.menuOpen) return;
    [self closeInstallPanel];
    if (self.homeView) [self closeHome];
    self.menuOpen = YES;
    [self.fadeTimer invalidate];
    self.tab.alpha = 1.0;
    self.tab.expanded = YES;
    [self layoutTab];

    [self installScrimWithAction:@selector(closeMenu)];

    NSArray *apps = QBLoadGuestApps();
    QBCardView *card = [[QBCardView alloc] initWithFrame:CGRectZero];
    card.apps = apps;
    __weak typeof(self) weakSelf = self;
    card.onReturn = ^{
        [weakSelf closeMenu];
        [weakSelf returnToLiveContainer];
    };
    card.onSettings = ^{
        weakSelf.keepScrim = YES;
        [weakSelf closeMenu];
        [weakSelf openSettings];
    };
    card.onSelect = ^(NSDictionary *app) {
        [weakSelf closeMenu];
        [weakSelf switchToApp:app];
    };
    [self.view insertSubview:card aboveSubview:self.scrim];
    self.card = card;
    [self layoutCard];

    CATransition *anim = [CATransition animation];
    anim.type = kCATransitionFade;
    anim.duration = 0.16;
    [card.layer addAnimation:anim forKey:nil];
}

- (void)closeMenu {
    [self.card removeFromSuperview];
    self.card = nil;
    if (self.keepScrim) self.keepScrim = NO; else [self removeScrim];
    self.menuOpen = NO;
    self.tab.expanded = NO;
    [UIView animateWithDuration:0.18 animations:^{ [self layoutTab]; }];
    [self resetFadeTimer];
}

#pragma mark Actions

- (void)switchToApp:(NSDictionary *)app {
    NSString *bid = app[@"bid"];
    if (bid.length == 0) return;

    NSString *scheme = @"livecontainer";
    if ([NSUserDefaults respondsToSelector:@selector(lcAppUrlScheme)]) {
        NSString *s = [NSUserDefaults lcAppUrlScheme];
        if (s.length) scheme = s;
    }
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    NSString *ebid = [bid stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: bid;
    NSString *folder = app[@"folder"] ?: @"";
    NSString *urlString;
    if (folder.length) {
        NSString *ef = [folder stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: folder;
        urlString = [NSString stringWithFormat:
            @"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@",
            scheme, ebid, ef];
    } else {
        urlString = [NSString stringWithFormat:
            @"%@://livecontainer-launch?bundle-name=%@", scheme, ebid];
    }
    NSURL *url = [NSURL URLWithString:urlString];

    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    if (sharedUtils && [sharedUtils respondsToSelector:@selector(launchToGuestAppWithURL:)]) {
        BOOL accepted = ((BOOL (*)(id, SEL, id))objc_msgSend)
            (sharedUtils, @selector(launchToGuestAppWithURL:), url);
        if (accepted) return;
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (void)returnToLiveContainer {
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    SEL launchGuest = NSSelectorFromString(@"launchToGuestAppWithClassicMode:");
    if (sharedUtils && [sharedUtils respondsToSelector:launchGuest]) {
        BOOL accepted = ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)
            (sharedUtils, launchGuest, 0);
        if (accepted) return;
    }
    NSString *scheme = @"livecontainer";
    if ([NSUserDefaults respondsToSelector:@selector(lcAppUrlScheme)]) {
        NSString *s = [NSUserDefaults lcAppUrlScheme];
        if (s.length) scheme = s;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", scheme]];

    UISceneSession *current = self.view.window.windowScene.session;
    for (UISceneSession *session in UIApplication.sharedApplication.openSessions) {
        if ([session.persistentIdentifier isEqualToString:current.persistentIdentifier]) continue;
        [UIApplication.sharedApplication requestSceneSessionActivation:session
                                                          userActivity:nil
                                                                options:nil
                                                           errorHandler:nil];
        break;
    }
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultWorkspace = NSSelectorFromString(@"defaultWorkspace");
    SEL openURL = NSSelectorFromString(@"openURL:");
    if (workspaceClass && [workspaceClass respondsToSelector:defaultWorkspace]) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultWorkspace);
        if (workspace && [workspace respondsToSelector:openURL]) {
            BOOL opened = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openURL, url);
            if (opened) return;
        }
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (void)openSettings {
    // LC's native App Settings page is a private SwiftUI view that a guest
    // process cannot present, and its URL scheme has no hook for it. Its data
    // source is the app's LCAppInfo.plist, so we present an equivalent panel
    // that reads/writes that same file — fully in sync with LC's own page.
    if (self.settingsView) {
        [self closeSettings];
        return;
    }
    [self.fadeTimer invalidate];
    self.tab.alpha = 1.0;

    [self installScrimWithAction:@selector(closeSettings)];

    QBSettingsView *settings = [[QBSettingsView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    // "返回" inside settings pops back to the app list.
    settings.onBack = ^{
        weakSelf.keepScrim = YES;
        [weakSelf closeSettings];
        [weakSelf openMenu];
    };
    settings.onReturn = ^{
        [weakSelf closeSettings];
        [weakSelf returnToLiveContainer];
    };
    [self.view insertSubview:settings aboveSubview:self.scrim];
    self.settingsView = settings;
    [self layoutCardForView:settings];

    CATransition *anim = [CATransition animation];
    anim.type = kCATransitionFade;
    anim.duration = 0.16;
    [settings.layer addAnimation:anim forKey:nil];
}

- (void)closeSettings {
    [self.settingsView removeFromSuperview];
    self.settingsView = nil;
    if (self.keepScrim) self.keepScrim = NO; else [self removeScrim];
    self.tab.expanded = NO;
    [UIView animateWithDuration:0.18 animations:^{ [self layoutTab]; }];
    [self resetFadeTimer];
}

#pragma mark Idle fade

- (void)resetFadeTimer {
    [self.fadeTimer invalidate];
    self.tab.alpha = 1.0;
    __weak typeof(self) weakSelf = self;
    self.fadeTimer = [NSTimer scheduledTimerWithTimeInterval:QBFadeDelay
                                                     repeats:NO
                                                       block:^(NSTimer *timer) {
        if (weakSelf.menuOpen) return;
        [UIView animateWithDuration:0.4 animations:^{
            weakSelf.tab.alpha = QBIdleAlpha;
        }];
    }];
}

@end

#pragma mark - File import fix (default ON)

// Original IMP of +[NSUserDefaults guestAppInfo], captured BEFORE swizzling.
// The replacement must call this IMP directly. Re-sending the guestAppInfo
// selector from inside the replacement recurses forever (that selector now
// maps to the replacement IMP) and crashes at launch — this was the v2 crash.
static NSDictionary *(*QBOrigGuestAppInfo)(id, SEL) = NULL;

@interface QuickBarHook : NSObject
+ (NSDictionary *)qb_guestAppInfo;
@end

@implementation QuickBarHook
+ (NSDictionary *)qb_guestAppInfo {
    NSDictionary *real = QBOrigGuestAppInfo
        ? QBOrigGuestAppInfo(self, @selector(guestAppInfo)) : nil;
    if (!real) return nil;
    if ([real[@"fixFilePickerNew"] boolValue]) return real;
    NSMutableDictionary *patched = [real mutableCopy];
    patched[@"fixFilePickerNew"] = @(YES);
    return patched;
}
@end

// LiveContainer's TweakLoader/DocumentPicker.m enables the document-picker
// host-identifier fix only when guestAppInfo[@"fixFilePickerNew"] is true.
// Newly installed apps default that key to false, so users must toggle it by
// hand every time. We hook +[NSUserDefaults guestAppInfo] and force the key to
// YES. Because this dylib is a dependency of TweakLoader, dyld runs our
// constructor before TweakLoader's own constructors -> the hook is in place
// before DocumentPicker.m reads guestAppInfo.
static void QBInstallFileImportFix(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Only act inside a real guest app, never in LC host or the store.
        if (!QBIsGuestApp()) return;

        Class cls = [NSUserDefaults class];
        Method orig = class_getClassMethod(cls, @selector(guestAppInfo));
        Method repl = class_getClassMethod([QuickBarHook class], @selector(qb_guestAppInfo));
        if (!orig || !repl) return;
        if (!QBOrigGuestAppInfo) {
            QBOrigGuestAppInfo = (NSDictionary *(*)(id, SEL))method_getImplementation(orig);
        }
        method_exchangeImplementations(orig, repl);
    });
}

#pragma mark - Startup

static QBOverlayWindow *qbOverlayWindow = nil;

static void qbInstallOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (qbOverlayWindow) return;
        if (!QBIsGuestApp()) return;
        if ([QBDefaults() boolForKey:QBDisableKey]) return;

        UIWindowScene *scene = QBActiveWindowScene();
        if (!scene) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ qbInstallOverlay(); });
            return;
        }

        QBOverlayController *controller = [QBOverlayController new];
        qbOverlayWindow = [[QBOverlayWindow alloc] initWithWindowScene:scene];
        qbOverlayWindow.rootViewController = controller;
        [controller view];
        qbOverlayWindow.backgroundColor = UIColor.clearColor;
        qbOverlayWindow.windowLevel = UIWindowLevelAlert + 1.0;
        qbOverlayWindow.opaque = NO;
        qbOverlayWindow.userInteractionEnabled = YES;
        qbOverlayWindow.hidden = NO;
        [controller.view setNeedsLayout];
        [controller.view layoutIfNeeded];
    });
}

__attribute__((constructor)) static void qbInit(void) {
    @autoreleasepool {
        // Install the file-import fix synchronously so it is in place before
        // TweakLoader's DocumentPicker constructor reads guestAppInfo.
        QBInstallFileImportFix();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            qbInstallOverlay();
        });
    }
}
