// QBLayoutFix — one job only: make the settings page sit exactly where the app
// list sits, so tapping 设置 and then 返回 never moves the toolbar.
//
// Why this is a separate dylib instead of an edit inside QuickBar.m: the
// QuickBar.dylib that ships is the one that has been on device for days. The
// QuickBar.m in this folder is a later, externally edited copy (it carries four
// classes the shipped binary does not — QBQuickDock, QBInstallPanel,
// QBDockButton, QBSettingsAudio… ), so rebuilding from it would swap the whole
// overlay UI. This file hooks the *shipped* binary at runtime instead and
// touches nothing but geometry.
//
// Two mismatches were moving the pills around:
//   1. panel frame — the settings view got its own height (fittedHeight) while
//      the list used QBPanelHeight, and both hang from a different top;
//   2. toolbar — the list parks its toolbar at groupTop (the panel is anchored
//      to the bottom edge), the settings view pinned it at y = 0;
//   3. right-hand pill width — 104pt on the list, 92pt on settings, and since
//      the pair is right-aligned that 12pt moved both buttons.
// All three are corrected here to the list page's numbers.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Mirrors of the constants in QuickBar.m. Kept local because the shipped
// dylib does not export them.
static CGFloat const QBFixTabHeight    = 28.0;
static CGFloat const QBFixPanelHeight  = 420.0;
static CGFloat const QBFixToolbarHeight = 56.0;
static CGFloat const QBFixRightWidth   = 104.0;   // same pill on both pages
static CGFloat const QBFixMinLeftWidth = 130.0;

static IMP QBOrigSettingsLayout = NULL;
static IMP QBOrigCardLayout = NULL;

static CGFloat QBGroupTop(CGFloat panelHeight) {
    CGFloat v = QBFixTabHeight + 4.0;
    CGFloat bottomAnchored = panelHeight - QBFixPanelHeight;
    return bottomAnchored > v ? bottomAnchored : v;
}

#pragma mark - Settings view

// Runs right after QBSettingsView's own layoutSubviews, so every frame it
// computed is already in place; we only re-place the toolbar and the scroll
// view it owns.
static void QBSettingsLayoutFix(id self_, SEL _cmd) {
    if (QBOrigSettingsLayout) ((void (*)(id, SEL))QBOrigSettingsLayout)(self_, _cmd);
    UIView *self = (UIView *)self_;
    UIView *toolbar = nil, *returnButton = nil, *backButton = nil;
    @try {
        toolbar = [self valueForKey:@"toolbar"];
        returnButton = [self valueForKey:@"returnButton"];
        backButton = [self valueForKey:@"backButton"];
    } @catch (__unused NSException *e) {
        return;
    }
    if (!toolbar || !returnButton || !backButton) return;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat groupTop = QBGroupTop(h);

    // The list page's toolbar rides at groupTop; this one used to be glued to
    // y = 0, which is why the same pill hopped upward when settings opened.
    toolbar.frame = CGRectMake(toolbar.frame.origin.x, groupTop, w, QBFixToolbarHeight);

    // Right-hand pill: same 104pt as the list page, left pill takes the rest.
    CGFloat inset = CGRectGetMinX(returnButton.frame);
    CGFloat gap = CGRectGetMinX(backButton.frame) - CGRectGetMaxX(returnButton.frame);
    if (gap <= 0) gap = 10.0;
    CGFloat barY = CGRectGetMinY(returnButton.frame);
    CGFloat barH = CGRectGetHeight(returnButton.frame) > 0 ? CGRectGetHeight(returnButton.frame) : 40.0;
    CGFloat leftW = MAX(QBFixMinLeftWidth, w - inset * 2.0 - QBFixRightWidth - gap);
    returnButton.frame = CGRectMake(inset, barY, leftW, barH);
    backButton.frame = CGRectMake(inset + leftW + gap, barY, QBFixRightWidth, barH);

    // The modules live in the scroll view, so moving the scroll view moves its
    // contents with it — no rebuild, no re-measuring of rows.
    for (UIView *v in self.subviews) {
        if (![v isKindOfClass:UIScrollView.class]) continue;
        CGRect f = v.frame;
        v.frame = CGRectMake(f.origin.x, groupTop, w, MAX(0, h - groupTop));
        break;
    }
}

#pragma mark - Overlay controller

// The settings panel gets its own height from fittedHeight; the list gets
// QBPanelHeight. Same height, same top, or the two pages can never line up.
static void QBCardLayoutFix(id self_, SEL _cmd, UIView *view) {
    if (QBOrigCardLayout) ((void (*)(id, SEL, UIView *))QBOrigCardLayout)(self_, _cmd, view);
    Class settingsClass = objc_getClass("QBSettingsView");
    if (!settingsClass || !view || ![view isKindOfClass:settingsClass]) return;

    UIView *listView = nil;
    @try { listView = [self_ valueForKey:@"card"]; } @catch (__unused NSException *e) { return; }
    if (!listView || listView == view) return;

    CGRect target = listView.frame;
    // Guard against a not-yet-laid-out list: never shrink the panel below the
    // height its content already occupies.
    if (target.size.height < 240.0) return;
    if (!CGRectEqualToRect(view.frame, target)) view.frame = target;
    [view setNeedsLayout];
}

#pragma mark - Install

/// Swizzle only a method the class implements itself — otherwise
/// class_getInstanceMethod silently hands back the superclass's IMP and the
/// whole app loses its layout.
static BOOL QBSetOwnImplementation(Class cls, SEL sel, IMP replacement, IMP *storage) {
    if (!cls) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owned = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { owned = YES; break; }
    }
    free(methods);
    if (!owned) return NO;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP current = method_getImplementation(m);
    if (current == replacement) return YES;
    if (storage) *storage = method_setImplementation(m, replacement);
    return YES;
}

static void QBInstallHooks(void);

static void QBInstallHooks(void) {
    Class settingsClass = objc_getClass("QBSettingsView");
    Class overlayClass = objc_getClass("QBOverlayController");
    if (!settingsClass || !overlayClass) {
        // QuickBar itself may still be loading; try again shortly.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ QBInstallHooks(); });
        return;
    }
    QBSetOwnImplementation(settingsClass, @selector(layoutSubviews),
                           (IMP)QBSettingsLayoutFix, &QBOrigSettingsLayout);
    QBSetOwnImplementation(overlayClass, @selector(layoutCardForView:),
                           (IMP)QBCardLayoutFix, &QBOrigCardLayout);
}

__attribute__((constructor)) static void QBEntry(void) {
    QBInstallHooks();
}
