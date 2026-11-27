//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UIKit

struct LCTabView: View {
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""
    
    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    @StateObject var downloadHelper = DownloadHelper()

    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    
    var body: some View {
        TabView(selection: $sharedModel.selectedTab) {
            if DataManager.shared.model.multiLCStatus != 2 {
                LCSourcesView()
                    .tabItem {
                        Label("lc.tabView.sources".loc, systemImage: "books.vertical")
                    }
                    .tag(LCTabIdentifier.sources)
            }
            LCAppListView()
                .tabItem {
                    Label("lc.tabView.apps".loc, systemImage: "square.stack.3d.up.fill")
                }
                .tag(LCTabIdentifier.apps)
            if DataManager.shared.model.multiLCStatus != 2 {
                LCTweaksView()
                    .tabItem{
                        Label("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver")
                    }
                    .tag(LCTabIdentifier.tweaks)
            }
            
            LCSettingsView()
                .tabItem {
                    Label("lc.tabView.settings".loc, systemImage: "gearshape.fill")
                }
                .tag(LCTabIdentifier.settings)
        }
        // The bar is gone on every page, in both orientations: the gallery is
        // the app. Pages are walked with a two-finger horizontal swipe instead
        // (see the window-level catcher below), so there is nothing left for
        // the system to minimise or reveal.
        .tabBarMinimizeBehavior(.never)
        .toolbar(.hidden, for: .tabBar)
        // Window-level two-finger pan: SwiftUI's own gestures are all
        // single-touch, and a per-page overlay would have to steal taps from
        // the list beneath it. A recogniser on the window sees every touch
        // without consuming any of them.
        .background(
            LCTwoFingerSwipeInstaller { shift in
                shiftTab(shift)
            }
        )
        .downloadAlert(helper: downloadHelper)
        .environmentObject(downloadHelper)
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $crashReportShow) {
            NavigationView {
                ScrollView {
                    Text(errorInfo)
                        .font(.system(size: 12).monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if #available(iOS 16.0, *) {
                            if let log = UserDefaults.lcShared().url(forKey: "LC32BitTranslationLayerLogFile") {
                                ShareLink(item: log)
                            } else {
                                ShareLink(item: errorInfo)
                            }
                        } else {
                            Button("lc.common.copy".loc) {
                                copyError()
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error".loc)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            closeDuplicatedWindow()
            checkLastLaunchError()
            checkTeamId()
            checkAndSaveBundleId()
            checkGetTaskAllow()
            checkPrivateContainerBookmark()
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
        // Nothing to restore here any more: tab-bar visibility belongs to the
        // page that hides it (.toolbar(.hidden/.visible, for: .tabBar)), so the
        // other tabs always get their own bar back automatically.
    }
    
    // MARK: Two-finger page switching

    // Same order the TabView itself is built in.
    private var tabOrder: [LCTabIdentifier] {
        var order: [LCTabIdentifier] = []
        if DataManager.shared.model.multiLCStatus != 2 { order.append(.sources) }
        order.append(.apps)
        if DataManager.shared.model.multiLCStatus != 2 { order.append(.tweaks) }
        order.append(.settings)
        return order
    }

    // +1 = finger travelled leftwards = next page, -1 = the other way.
    private func shiftTab(_ shift: Int) {
        let order = tabOrder
        guard let index = order.firstIndex(of: sharedModel.selectedTab) else { return }
        let target = index + shift
        guard order.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            sharedModel.selectedTab = order[target]
        }
    }

    func dispatchURL(url: URL) {
        repeat {
            if url.isFileURL {
                sharedModel.selectedTab = .apps
                break
            }
            if url.scheme?.lowercased() == "sidestore" {
                sharedModel.selectedTab = .apps
                break
            }
            
            guard let host = url.host?.lowercased() else {
                return
            }
            
            switch host {
            case "livecontainer-launch", "install", "open-web-page", "open-url":
                sharedModel.selectedTab = .apps
            case "certificate":
                sharedModel.selectedTab = .settings
            case "source":
                sharedModel.selectedTab = .sources
            default:
                return
            }
            
        } while(false)

        sharedModel.deepLink = url
    }
    
    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }
    
    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")
        
        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }
        
        guard let errorStr else {
            return
        }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }
            
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }
        
        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }
        
        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }
    
    func checkAndSaveBundleId() {
#if targetEnvironment(simulator)
        // Simulator builds have no application-identifier entitlement, so this
        // device-only integrity check cannot resolve and only blocks preview.
        return
#endif
        if DataManager.shared.model.multiLCStatus == 2 {
            let scheme = UserDefaults.lcAppUrlScheme() ?? ""
            LCUtils.appGroupUserDefault.set(Bundle.main.bundleIdentifier, forKey: "LCBundleID.\(scheme)")
        }
        
        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }
        
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil), let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "Unable to determine application-identifier"
            errorShow = true
            return
        }
        
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }
        
        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }
        
        if(bundleId != correctBundleId) {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
            errorShow = true
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }
    
    func checkGetTaskAllow() {
#if targetEnvironment(simulator)
        // Simulator builds are unsigned ad-hoc; the warning is a device-only
        // gate and would block local layout review behind a modal alert.
        return
#endif
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil), (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }
    
    func checkPrivateContainerBookmark() {
        if sharedModel.multiLCStatus == 2 {
            return
        }
        if LCUtils.appGroupUserDefault.object(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil {
            return
        }
        
        guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else {
            errorInfo = "Failed to create bookmark for Documents folder?"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}


// MARK: - Two-finger swipe catcher

// Invisible: it exists only to hang a recogniser on the window. Being a
// representable keeps its lifetime tied to the TabView, and installing it on
// the window (not on the view itself) is what lets single-finger taps and
// scrolls go through untouched.
struct LCTwoFingerSwipeInstaller: UIViewRepresentable {
    let onShift: (Int) -> Void

    func makeUIView(context: Context) -> LCTwoFingerSwipeView {
        let view = LCTwoFingerSwipeView()
        view.onShift = onShift
        return view
    }

    func updateUIView(_ uiView: LCTwoFingerSwipeView, context: Context) {
        uiView.onShift = onShift
    }
}

final class LCTwoFingerSwipeView: UIView, UIGestureRecognizerDelegate {
    var onShift: ((Int) -> Void)?

    private let pan = UIPanGestureRecognizer()
    private weak var host: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // Transparent to the touch system: only the window recogniser matters.
        isUserInteractionEnabled = false
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        // Never swallow a touch, never delay one: the list keeps every drag.
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delegate = self
        pan.addTarget(self, action: #selector(handle(_:)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        // Re-home on rotation: the old window can be torn down with its scene.
        if host !== window {
            host?.removeGestureRecognizer(pan)
            window.addGestureRecognizer(pan)
            host = window
        }
    }

    // The card row and the scrolling list keep their own pans; a two-finger
    // drag is an extra signal on top of them, not a replacement.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let translation = recognizer.translation(in: recognizer.view)
        let velocity = recognizer.velocity(in: recognizer.view)
        // A two-finger drag that mostly went up or down stays a scroll.
        guard abs(translation.x) > abs(translation.y) * 1.2
                || abs(velocity.x) > abs(velocity.y) * 1.2 else { return }

        let forward = translation.x <= -70 || velocity.x <= -450
        let backward = translation.x >= 70 || velocity.x >= 450
        if forward {
            onShift?(1)
        } else if backward {
            onShift?(-1)
        }
    }
}
