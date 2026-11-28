//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers
import CoreImage
import ImageIO
import PhotosUI

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    @State var installProgressPercentage : Float = 0.0
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject var downloadHelper: DownloadHelper
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    @State private var isViewAppeared = false

    // QuickBar home gallery: defaults ON. Toggle off in Settings to restore
    // the classic compact list at any time (safety valve).
    @AppStorage("LCUseGalleryHome", store: LCUtils.appGroupUserDefault) private var useGalleryHome = true

    // Portrait folds the plus bead away while the list is read downwards, and
    // brings it back the moment the finger reverses. Declared up here because
    // the bead lives in the navigation bar, one view up.
    @State private var topBeadHidden = false

    // Landscape owns the full screen: no pill, no tab bar there.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    // Gallery card context-menu uninstall target + confirmation.
    @State private var galleryUninstallApp: LCAppModel?
    @State private var galleryUninstallShow = false
    @State private var galleryUninstallRemoveData = false
    @State private var galleryIconExportURL: URL?
    @State private var galleryIconExportShow = false

    @ObservedObject var searchContext: SearchContext = SearchContext()
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    init() {
        _installOptions = State(initialValue: [])
    }
    
    // New body: big-card home gallery by default, classic list via toggle.
    var body: some View {
        Group {
            if useGalleryHome {
                // Keep the gallery inside the same NavigationView as the original
                // app list, so the native install / SideStore / link / sort toolbar
                // items are present and use the existing, proven actions.
                withGalleryOverlays(
                    NavigationView {
                        ZStack {
                            // Native push link used by openNavigationView(). The gallery
                            // previously lacked this, so the context-menu "Settings"
                            // action set isNavigationActive but nothing ever pushed.
                            NavigationLink(
                                destination: navigateTo,
                                isActive: $isNavigationActive,
                                label: { EmptyView() }
                            )
                            .hidden()
                            LCHomeGalleryView(
                                searchContext: searchContext,
                                apps: sortedApps,
                                hiddenApps: sortedHiddenApps,
                                topBeadHidden: $topBeadHidden,
                                onLaunch: { app in
                                    Task { @MainActor in
                                        do { try await app.runApp() }
                                        catch { self.errorInfo = error.localizedDescription; self.errorShow = true }
                                    }
                                },
                                onOpenSettings: { app in
                                    self.openNavigationView(view: AnyView(LCAppSettingsView(model: app)))
                                },
                                onUninstall: { app in
                                    self.requestGalleryUninstall(app: app)
                                },
                                onSaveIcon: { app in
                                    Task { await self.gallerySaveIcon(app: app) }
                                },
                                onCreateAppClip: { app in
                                    Task { await self.galleryCreateAppClip(app: app) }
                                },
                                onTab: { tab in
                                    sharedModel.selectedTab = tab
                                },
                                onInstallIPA: { choosingIPA = true },
                                onInstallURL: { Task { await startInstallFromUrl() } },
                                onOpenSideStoreOrHelp: {
                                    if UserDefaults.sideStoreExist() {
                                        LCUtils.openSideStore(delegate: self)
                                    } else {
                                        helpPresent = true
                                    }
                                },
                                sideStoreIcon: UserDefaults.sideStoreExist() ? BuiltInSideStoreAppInfo.shared.iconIsDarkIcon(darkModeIcon) : nil,
                                canInstall: sharedModel.multiLCStatus != 2,
                                isInstalling: installprogressVisible,
                                onOpenLink: { Task { await onOpenWebViewTapped() } },
                                sortType: sharedAppSortManager.appSortType,
                                onSortChange: { sharedAppSortManager.appSortType = $0 },
                                onCustomSort: { customSortViewPresent = true }
                            )
                            .navigationTitle("")
                            .navigationBarTitleDisplayMode(.inline)
                            // The bar itself is gone on this page: the bead is
                            // the only control here and it lives in an
                            // overlay, not in the toolbar. A toolbar button
                            // drags the system's own glass plate along with it,
                            // and that plate was the second disc inside the
                            // bead.
                            .toolbar(.hidden, for: .navigationBar)
                            // Tab bar off here, and only here — the pages left
                            // and right keep theirs. Declared on the page, not
                            // on the TabView: from above it kept coming back
                            // after a rotation.
                            .toolbar(.hidden, for: .tabBar)
                            // The same hide, made to stick. UIKit re-shows the
                            // bar on relayout and after a turn.
                            .background(LCTabBarHider())
                            .modifier(GalleryNavBarClear())
                            // Sliding the bead away must not leave a hole: off
                            // the bar it can float, so it leaves with the bar
                            // instead of fading into reserved space.
                            .overlay(alignment: .bottomTrailing) {
                                // Portrait only. In landscape the showcase is
                                // the whole screen — the bead floats over the
                                // first poster and there is nothing to scroll
                                // it away with, so it simply isn't there.
                                //
                                // The gallery page now owns its own dock with a
                                // plus button, so this legacy floating bead is
                                // hidden — it used to sit ON TOP of the new
                                // deck as a second, redundant pink "+" in the
                                // bottom-right corner.
                                EmptyView()
                            }
                        }
                        }
                        .navigationViewStyle(StackNavigationViewStyle())
                    )
                .modifier(GalleryNavBarClear())
                // The page no longer folds the bar itself. In portrait the
                // native bar is simply there — that is what makes the bottom
                // edge swipes (and a plain tab tap) a reliable way to leave
                // this page, with no expand animation to get right. Landscape
                // is still owned by LCTabView, which hides the bar outright.
            } else {
                legacyBody
            }
        }
    }

    // Shared sheets/alerts/importers for the gallery branch. The classic list
    // keeps its own existing modifiers; this makes every native LC action
    // (install, SideStore, link, sorting, JIT, deep links) work on the new home.
    @ViewBuilder
    private func withGalleryOverlays<V: View>(_ content: V) -> some View {
        content
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {})
            Button("lc.common.copy".loc, action: { copyError() })
        } message: {
            Text(errorInfo)
        }
        .alert("lc.appBanner.confirmUninstallTitle".loc, isPresented: $galleryUninstallShow) {
            Button("lc.common.cancel".loc, role: .cancel) {
                galleryUninstallApp = nil
            }
            Button("lc.appBanner.uninstall".loc, role: .destructive) {
                if let target = galleryUninstallApp {
                    performGalleryUninstall(app: target, removeData: galleryUninstallRemoveData)
                }
                galleryUninstallApp = nil
            }
        } message: {
            Text("lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(
                galleryUninstallApp?.appInfo.displayName() ?? galleryUninstallApp?.displayName ?? ""))
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button { generatedIconStyleSelector.close(result: .Light) } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button { generatedIconStyleSelector.close(result: .Dark) } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button { generatedIconStyleSelector.close(result: .Original) } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title: "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in webViewUrlInput.close(result: newText) },
            actionCancel: { _ in webViewUrlInput.close(result: nil) }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title: "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in installUrlInput.close(result: newText) },
            actionCancel: { _ in installUrlInput.close(result: nil) }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $galleryIconExportShow, onDismiss: {
            if let url = galleryIconExportURL {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            galleryIconExportURL = nil
        }) {
            GalleryIconExportSheet(fileURL: galleryIconExportURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .onAppear {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                Task { await installFromUrl(urlStr: installUrl.absoluteString) }
            }
        }
    }

    // Original compact list, kept intact as a fallback.
    @ViewBuilder
    var legacyBody: some View {
        NavigationView {
            ScrollView {
                NavigationLink(
                    destination: navigateTo,
                    isActive: $isNavigationActive,
                    label: {
                        EmptyView()
                })
                .hidden()
                
                LazyVStack {
                    ForEach(filteredApps, id: \.self) { app in
                        LCAppBanner(appModel: app, delegate: self)
                    }
                    .transition(.scale)
                }
                .padding()
                .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredApps)

                VStack {
                    if LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                        if sharedModel.isHiddenAppUnlocked {
                            LazyVStack {
                                HStack {
                                    Text("lc.appList.hiddenApps".loc)
                                        .font(.system(.title2).bold())
                                    Spacer()
                                }
                                
                                ForEach(filteredHiddenApps, id: \.self) { app in
                                    LCAppBanner(appModel: app, delegate: self)
                                }
                                .transition(.scale)
                                
                            }
                            .padding()
                            .transition(.opacity)
                            .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                            
                            if sharedModel.hiddenApps.count == 0 {
                                Text("lc.appList.hideAppTip".loc)
                                    .foregroundStyle(.gray)
                            }
                        }
                    } else if sharedModel.hiddenApps.count > 0 {
                        LazyVStack {
                            HStack {
                                Text("lc.appList.hiddenApps".loc)
                                    .font(.system(.title2).bold())
                                Spacer()
                            }
                            ForEach(filteredHiddenApps, id: \.self) { app in
                                if sharedModel.isHiddenAppUnlocked {
                                    LCAppBanner(appModel: app, delegate: self)
                                } else {
                                    LCAppSkeletonBanner()
                                }
                            }
                            .animation(.easeInOut, value: sharedModel.isHiddenAppUnlocked)
                            .onTapGesture {
                                Task { await authenticateUser() }
                            }
                        }
                        .padding()
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                    }

                    let appCount = sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count
                    Text(appCount > 0 || searchContext.debouncedQuery != "" ? "lc.appList.appCounter %lld".localizeWithFormat(appCount) : (sharedModel.multiLCStatus == 2 ? "lc.appList.convertToSharedToShowInLC2".loc : "lc.appList.installTip".loc))
                        .padding(.horizontal)
                        .foregroundStyle(.gray)
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: appCount)
                        .onTapGesture(count: 3) {
                            Task { await authenticateUser() }
                        }
                }.animation(searchContext.isTyping ? nil : .easeInOut, value: LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding"))

                if sharedModel.multiLCStatus == 2 {
                    Text("lc.appList.manageInPrimaryTip".loc).foregroundStyle(.gray).padding()
                }

            }
            .navigationBarProgressBar(show:$installprogressVisible, progress: $installProgressPercentage)
            .coordinateSpace(name: "scroll")
            .onAppear {
                if !didAppear {
                    onAppear()
                }
            }
            
            .navigationTitle("lc.appList.myApps".loc)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if sharedModel.multiLCStatus != 2 {
                        if !installprogressVisible {
                            Menu {
                                
                                Button("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus", action: {
                                    choosingIPA = true
                                })
                                Button("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus", action: {
                                    Task{ await startInstallFromUrl() }
                                })
                            } label: {
                                Label("add", systemImage: "plus")
                            }
                            
                        } else {
                            ProgressView().progressViewStyle(.circular).padding(.horizontal, 8)
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if(UserDefaults.sideStoreExist()) {
                        Button {
                            LCUtils.openSideStore(delegate: self)
                        } label: {
                            IconImageView(icon: BuiltInSideStoreAppInfo.shared.iconIsDarkIcon(darkModeIcon))
                                .frame(width: UIFont.preferredFont(forTextStyle: .body).lineHeight, height: UIFont.preferredFont(forTextStyle: .body).lineHeight)

                        }
                    } else {
                        Button("Help", systemImage: "questionmark") {
                            helpPresent = true
                        }
                    }
                    

                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.appList.openLink".loc, systemImage: "link", action: {
                        Task { await onOpenWebViewTapped() }
                    })
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sharedAppSortManager.appSortType) {
                            ForEach(AppSortType.allCases, id: \.self) { sortType in
                                Label(sortType.displayName, systemImage: sortType.systemImage)
                                    .tag(sortType)
                            }
                        }
                        .onChange(of: sharedAppSortManager.appSortType) { newValue in
                            if sharedAppSortManager.appSortType == .custom {
                                customSortViewPresent = true
                            }
                        }
                        if sharedAppSortManager.appSortType == .custom {
                            Divider()
                            
                            Button {
                                customSortViewPresent = true
                            } label: {
                                Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                            }
                        }
                    } label: {
                        Label("Sort by", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                Task { await installFromUrl(urlStr: installUrl.absoluteString) }
            }
        }
        .searchable(text: $searchContext.query)

    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }


    
    func startInstallApp(_ fileUrl:URL) async {
        do {
            self.installprogressVisible = true
            try await installIpaFile(fileUrl)
            try FileManager.default.removeItem(at: fileUrl)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    func installIpaFile(_ url:URL) async throws {
        let fm = FileManager()
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        self.installProgressPercentage = 0.0
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                self.installProgressPercentage = Float(p.fractionCompleted)
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }
        
        // decompress
        guard await decompress(url.path, fm.temporaryDirectory.path, decompressProgress) == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName : String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        self.installprogressVisible = false
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
            }
            
        }
        
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"
            
            self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
            
            for app in sameBundleIdApp {
                self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
            }

            guard let installOptionChosen = await installReplaceAlert.open() else {
                // user cancelled
                self.installprogressVisible = false
                try fm.removeItem(at: payloadPath)
                return
            }
            
            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            if installOptionChosen.isReplace {
                try fm.removeItem(at: outputFolder)
            }
        }
        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            return
        }
        
        // patch and sign it
        var signError : String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })
        
        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            LCAppModel.copy(fromApp: appToReplace, toAppInfo: finalNewApp)
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now
        
        DispatchQueue.main.async {
            if let appToReplace {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }

            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
                
                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }

            self.installprogressVisible = false
        }
    }
    
    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String) async {
        // ignore any install request if we are installing another app
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard var installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        self.installprogressVisible = true
        defer {
            self.installprogressVisible = false
        }
        
        if installUrl.isFileURL {
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    errorInfo =  "Failed to resolve shared IPA bookmark: \(error.localizedDescription)"
                    errorShow = true
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                try await installIpaFile(installUrl)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            do {
                // delete ipa if it's in inbox
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    shouldDelete = installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        
        do {
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            try await downloadHelper.download(url: installUrl, to: destinationURL)
            if downloadHelper.cancelled {
                return
            }
            try await installIpaFile(destinationURL)
            try fileManager.removeItem(at: destinationURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            
        }
    }

    // MARK: Gallery uninstall (context menu)
    func requestGalleryUninstall(app: LCAppModel) {
        galleryUninstallApp = app
        // Offer to delete the container data too when the app owns containers.
        galleryUninstallRemoveData = !app.appInfo.containers.isEmpty
        galleryUninstallShow = true
    }

    func performGalleryUninstall(app: LCAppModel, removeData: Bool) {
        let appInfo = app.appInfo
        do {
            guard let bundlePath = appInfo.bundlePath() else {
                throw CocoaError(.fileNoSuchFile)
            }
            let fm = FileManager.default
            try fm.removeItem(atPath: bundlePath)
            removeApp(app: app)

            if removeData {
                for container in appInfo.containers {
                    let dataUUID = container.folderName
                    try? fm.removeItem(at: LCPath.dataPath.appendingPathComponent(dataUUID))
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    DataManager.shared.model.appDataFolderNames.removeAll { $0 == dataUUID }
                }
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func galleryCreateAppClip(app: LCAppModel) async {
        guard let style = await promptForGeneratedIconStyle() else { return }
        do {
            guard let profile = app.appInfo.generateWebClipConfig(
                withContainerId: app.uiSelectedContainer?.folderName,
                iconStyle: style
            ) else {
                throw CocoaError(.propertyListWriteInvalid)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            installMdm(data: data)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    // Everything the old three-glyph pill could do, folded into one bead.
    // It floats over the page in an overlay instead of sitting in the toolbar:
    // a toolbar item brings the system's own glass plate along, and that plate
    // is what turned the bead into two discs stacked on each other.
    private var installBeadMenu: some View {
        Menu {
            Button("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus") {
                choosingIPA = true
            }
            if sharedModel.multiLCStatus != 2 {
                Button("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus") {
                    Task { await startInstallFromUrl() }
                }
            }
            Divider()
            if UserDefaults.sideStoreExist() {
                Button {
                    LCUtils.openSideStore(delegate: self)
                } label: {
                    Label("SideStore", systemImage: "app.badge")
                }
            } else {
                Button("Help", systemImage: "questionmark") {
                    helpPresent = true
                }
            }
            Button("lc.appList.openLink".loc, systemImage: "link") {
                Task { await onOpenWebViewTapped() }
            }
            Divider()
            Menu {
                Picker("Sort by", selection: $sharedAppSortManager.appSortType) {
                    ForEach(AppSortType.allCases, id: \.self) { sortType in
                        Label(sortType.displayName, systemImage: sortType.systemImage)
                            .tag(sortType)
                    }
                }
                .onChange(of: sharedAppSortManager.appSortType) { newValue in
                    if newValue == .custom { customSortViewPresent = true }
                }
                if sharedAppSortManager.appSortType == .custom {
                    Divider()
                    Button {
                        customSortViewPresent = true
                    } label: {
                        Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                    }
                }
            } label: {
                Label("Sort by", systemImage: "line.3.horizontal.decrease.circle")
            }
        } label: {
            installBeadLabel
        } primaryAction: {
            // Tap adds a game — the old + behaviour. Everything else is one
            // long press away.
            choosingIPA = true
        }
        // Free of the bar the bead can actually leave: from the bottom corner
        // it drops out over the lower edge instead of shrinking in place, so
        // nothing is left behind as an empty slot the way a faded toolbar item
        // was. Same rule as before — scrolling down tucks it away, scrolling
        // back up brings it in.
        .offset(y: topBeadHidden ? 88 : 0)
        .opacity(topBeadHidden ? 0 : 1)
        .scaleEffect(topBeadHidden ? 0.9 : 1, anchor: .bottom)
        .animation(.easeInOut(duration: 0.24), value: topBeadHidden)
        .allowsHitTesting(!topBeadHidden)
        .padding(.trailing, 20)
        .padding(.bottom, 22)
    }

    // The single liquid-glass bead that replaced the old three-glyph pill:
    // one pane of glass with a plus on top of it. One plate and one glyph — no
    // second ring, no inner disc. Bigger than before, and tinted a soft pink
    // red so it reads as its own control instead of another piece of chrome.
    @ViewBuilder
    private var installBeadLabel: some View {
        if installprogressVisible {
            ProgressView()
                .progressViewStyle(.circular)
                .frame(width: 48, height: 48)
                .lcGlassCircle()
        } else {
            Image(systemName: "plus")
                .font(.system(size: 23, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                // Same single pane of glass, tinted. `tint` colours the glass
                // body itself, so the plate stays translucent — it is not a
                // flat pink disc sitting under a glyph.
                .glassEffect(.regular.tint(Color(red: 1.0, green: 0.52, blue: 0.52).opacity(0.55)),
                             in: Circle())
                .shadow(color: Color(red: 1.0, green: 0.38, blue: 0.38).opacity(0.34),
                        radius: 12, y: 4)
        }
    }

    func gallerySaveIcon(app: LCAppModel) async {
        guard let style = await promptForGeneratedIconStyle() else { return }
        do {
            guard let image = app.appInfo.generateLiveContainerWrappedIcon(with: style),
                  let imageData = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let rawName = app.appInfo.displayName() ?? app.displayName
            let safeName = rawName.replacingOccurrences(of: "/", with: "_")
            let fileURL = tempDir.appendingPathComponent("\(safeName) Icon.png")
            try imageData.write(to: fileURL, options: .atomic)
            galleryIconExportURL = fileURL
            galleryIconExportShow = true
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                var urlStr: String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    } else if queryItem.name == "open-url" {
                        if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                           let decodedUrl = String(data: decodedData, encoding: .utf8) {
                            urlStr = decodedUrl
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, urlStr: urlStr, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}


// ===== Inlined online cover store =====
//
//  Tries official art from Steam (portrait library poster first) and the App
//  Store. Any downloaded image is cached in memory and reused by the whole
//  gallery; misses fall through to the local-bundle / frosted-icon path.

private struct LCSteamSearchResponse: Codable {
    let items: [LCSteamSearchItem]?
}

private struct LCSteamSearchItem: Codable {
    let id: Int
    let name: String
}

private struct LCITunesSearchResponse: Codable {
    let results: [LCITunesResult]?
}

private struct LCITunesResult: Codable {
    let trackName: String?
    let artworkUrl100: String?
    let screenshotUrls: [String]?
    let description: String?
    // "2019-08-29T07:00:00Z" — the store's own release date. Only the year is
    // used, for the landscape detail card.
    let releaseDate: String?
}

// Everything the landscape detail panel says about a game: the official short
// intro plus the storefront's own spec table (platform, languages, publisher,
// genre, rating) and the release year.
struct LCGalleryGameMeta: Codable, Equatable {
    var intro: String
    var year: String?
    var platform: String?
    var languages: String?
    var publisher: String?
    var genre: String?
    var rating: String?
    // 1 once the spec table has been looked up. Entries written before the
    // specs existed have no marker, so they get one silent re-fetch instead of
    // showing an empty panel forever.
    var specVersion: Int?
}

// Building a query string by hand and then handing it to `URL(string:)` is a
// trap that cost a whole round of dead-end debugging: `%` is legal inside a URL
// string, so an already-encoded "塞尔达…" silently becomes "%25E5…" on the wire
// and the service answers by echoing the encoded blob back. `URLComponents`
// encodes exactly once. Every query URL in this file goes through here.
private func lcMakeURL(_ base: String, _ items: [String: String]) -> URL? {
    guard var components = URLComponents(string: base) else { return nil }
    // Sorted so the same query always yields the same URL — these end up in
    // request caches further down the stack.
    components.queryItems = items.sorted { $0.key < $1.key }
        .map { URLQueryItem(name: $0.key, value: $0.value) }
    return components.url
}

final class LCGalleryOnlineCoverStore {
    static let shared = LCGalleryOnlineCoverStore()

    // Two slots per app. `cache` holds portrait-friendly posters (Steam library
    // art, App Store icon) for the portrait hero and the list rows; `wideCache`
    // holds the 16:9 key art from Nintendo's storefront for the landscape
    // poster wall. They differ in aspect, so they cannot share one image.
    private var cache: [String: UIImage] = [:]
    private var wideCache: [String: UIImage] = [:]
    private var inFlight: Set<String> = []

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    func cover(for app: LCAppModel, wide: Bool) -> UIImage? {
        let key = Self.key(for: app)
        if let hit = (wide ? wideCache[key] : cache[key]) { return hit }
        // Resolved in an earlier launch: read the file that was written back
        // then. No translation, no storefront query, no image download.
        if let stored = Self.coverFromDisk(key, wide: wide) {
            if wide { wideCache[key] = stored } else { cache[key] = stored }
            return stored
        }
        request(name: app.displayName, key: key, wide: wide)
        return nil
    }

    private func request(name: String, key: String, wide: Bool) {
        let slot = wide ? "w-\(key)" : "p-\(key)"
        guard !inFlight.contains(slot) else { return }
        inFlight.insert(slot)
        Task.detached(priority: .utility) {
            let image = await Self.fetchCover(forName: name, wide: wide)
            await MainActor.run {
                self.inFlight.remove(slot)
                if let image {
                    if wide { self.wideCache[key] = image } else { self.cache[key] = image }
                    // Remember it across launches. Without this the whole
                    // lookup chain re-ran on every cold start even though the
                    // official poster had already been found.
                    Self.storeCoverOnDisk(image, key: key, wide: wide)
                    NotificationCenter.default.post(
                        name: LCGalleryCoverStore.coverReady,
                        object: key
                    )
                }
            }
        }
    }

    // MARK: - Persisted covers

    // Caches/LCGalleryOnlineCovers/<p|w>-<hash>.img. One file per app and per
    // aspect, written once, read back on every later launch.
    private static let diskQueue = DispatchQueue(label: "lc.gallery.online.cover.disk",
                                                 qos: .utility)

    private static let diskDirectory: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("LCGalleryOnlineCovers", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    // A key can carry a relative bundle path ("online-Documents/…"), which is
    // not a legal file name, so the file name is a hash of the key instead.
    private static func diskURL(for key: String, wide: Bool) -> URL? {
        guard let dir = diskDirectory else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        let name = String(format: "%@-%016llx.img", wide ? "w" : "p", hash)
        return dir.appendingPathComponent(name)
    }

    private static func coverFromDisk(_ key: String, wide: Bool) -> UIImage? {
        guard let url = diskURL(for: key, wide: wide) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private static func storeCoverOnDisk(_ image: UIImage, key: String, wide: Bool) {
        guard let url = diskURL(for: key, wide: wide),
              let data = image.jpegData(compressionQuality: 0.95) else { return }
        diskQueue.async { try? data.write(to: url, options: .atomic) }
    }

    private static func key(for app: LCAppModel) -> String {
        if let bid = app.appInfo.bundleIdentifier(), !bid.isEmpty { return "online-\(bid)" }
        if let rel = app.appInfo.relativeBundlePath, !rel.isEmpty { return "online-\(rel)" }
        return "online-\(ObjectIdentifier(app).hashValue)"
    }

    // Aspect decides the source order. The landscape wall shows a 16:9 card, so
    // it asks Nintendo's storefront first — every hit there carries the wide key
    // art (1000×562), which needs no cropping. The portrait hero is roughly 3:5,
    // so it keeps the tall Steam library poster first and only reaches for the
    // wide key art when nothing portrait-shaped exists at all.
    private static func fetchCover(forName name: String, wide: Bool) async -> UIImage? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if wide {
            if let art = await fetchNintendo(name: name) { return art }
            if !query.isEmpty, let steam = await fetchSteam(name: name, query: query) { return steam }
            if !query.isEmpty, let store = await fetchAppStore(name: name, query: query) { return store }
            return nil
        }
        if !query.isEmpty, let steam = await fetchSteam(name: name, query: query) { return steam }
        if !query.isEmpty, let store = await fetchAppStore(name: name, query: query) { return store }
        return await fetchNintendo(name: name)
    }

    // MARK: - Nintendo AU storefront (wide key art)

    // nintendo.com/au/games/all is a thin client over an Algolia index of the
    // eShop catalogue. Querying that index directly is what "fetch the cover
    // from the official site" means here: the returned `image` is the game's own
    // key art on Nintendo's CDN, 16:9, no watermark, no blog crop.
    private struct LCNintendoHit: Codable {
        let title: String?
        let image: String?
        let console: String?
    }

    private struct LCNintendoResponse: Codable {
        let hits: [LCNintendoHit]?
    }

    private static let nintendoSearchURL =
        URL(string: "https://FMW57F6ERV-dsn.algolia.net/1/indexes/prod_games/query")!
    private static let nintendoAppId = "FMW57F6ERV"
    private static let nintendoSearchKey = "c8e4e9f60190ef785d167da77ba0b4fe"

    // The AU catalogue is English-only, so a Chinese display name has to be
    // translated before the search can hit anything. Small table, big payoff:
    // these are the titles a Switch library actually contains.
    private static let nintendoAliases: [(zh: String, en: String)] = [
        ("尼尔机械纪元", "NieR:Automata"),
        ("巫师", "The Witcher 3: Wild Hunt"),
        ("暗黑破坏神", "Diablo III"),
        ("消逝的光芒", "Dying Light"),
        ("上古卷轴", "The Elder Scrolls V: Skyrim"),
        ("生化危机", "Resident Evil"),
        ("赛博朋克", "Cyberpunk 2077"),
        ("荒野大镖客", "Red Dead Redemption"),
        ("塞尔达传说", "The Legend of Zelda"),
        ("塞尔达", "The Legend of Zelda"),
        ("马力欧卡丁车", "Mario Kart"),
        ("马力欧赛车", "Mario Kart"),
        ("马力欧", "Super Mario"),
        ("超级马力欧", "Super Mario"),
        ("宝可梦", "Pokémon"),
        ("精灵宝可梦", "Pokémon"),
        ("动物森友会", "Animal Crossing"),
        ("动森", "Animal Crossing"),
        ("空洞骑士", "Hollow Knight"),
        ("哈迪斯", "Hades"),
        ("死亡细胞", "Dead Cells"),
        ("星露谷", "Stardew Valley"),
        ("泰拉瑞亚", "Terraria"),
        ("我的世界", "Minecraft"),
        ("异度神剑", "Xenoblade Chronicles"),
        ("火焰纹章", "Fire Emblem"),
        ("女神异闻录", "Persona"),
        ("最终幻想", "Final Fantasy"),
        ("勇者斗恶龙", "Dragon Quest"),
        ("歧路旅人", "Octopath Traveler"),
        ("怪物猎人", "Monster Hunter"),
        ("黑暗之魂", "Dark Souls"),
        ("只狼", "Sekiro"),
        ("艾尔登法环", "Elden Ring"),
        ("鬼泣", "Devil May Cry"),
        ("刺客信条", "Assassin's Creed"),
        ("古墓丽影", "Tomb Raider"),
        ("无主之地", "Borderlands"),
        ("孤岛惊魂", "Far Cry"),
        ("使命召唤", "Call of Duty"),
        ("死亡搁浅", "Death Stranding"),
        ("层层恐惧", "Layers of Fear"),
        ("小小梦魇", "Little Nightmares"),
        ("中土世界", "Middle-earth"),
        ("火影忍者", "Naruto"),
        ("双人成行", "It Takes Two"),
        ("胡闹厨房", "Overcooked"),
        ("茶杯头", "Cuphead"),
        ("蔚蓝", "Celeste")
    ]

    private static func fetchNintendo(name: String) async -> UIImage? {
        var seen = Set<String>()
        for query in await nintendoQueries(for: name) {
            guard let hits = await nintendoSearch(query: query) else { continue }
            let ranked = hits
                .compactMap { hit -> (score: Double, title: String, image: String)? in
                    guard let title = hit.title, let raw = hit.image, !raw.isEmpty else { return nil }
                    var score = matchScore(query, title)
                    // A title existing on both consoles is one game; nudge the
                    // Switch listing up so the artwork matches the newest SKU.
                    if let console = hit.console, console.contains("Switch") { score += 0.05 }
                    return (score, title, raw)
                }
                // Only a hit whose title equals or contains the query is
                // allowed through. The old 0.40 floor was character-set
                // overlap, which let an unrelated title in the catalogue
                // ("Dying Light" → "Hotshot Racing", 0.50) wear the poster.
                // A containment hit (0.9) is still a COUSIN unless its title
                // stays close to the query — that distance gate is what keeps
                // the thin alias "Naruto" from wearing CONNECTIONS' key art
                // when the named game simply is not in the catalogue. No hit is
                // a better answer than the wrong game: the portrait path falls
                // through to Steam and the App Store instead.
                .filter { entry in
                    entry.score >= 0.999
                        || (entry.score >= 0.85 && abs(entry.title.count - query.count) <= 24)
                }
                // Containment ties (a generic "Monster Hunter" query matches
                // every game in the family at 0.9) break three ways: the plain
                // release beats a "— Remastered / Ultimate Edition / Sunbreak"
                // variant, a matching sequel number beats a mismatched one,
                // and whatever is left goes to the closest length.
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    let lhsEdition = isEditionVariant(lhs.title, of: query)
                    let rhsEdition = isEditionVariant(rhs.title, of: query)
                    if lhsEdition != rhsEdition { return !lhsEdition }
                    if let number = trailingSuffixNumber(query) {
                        let lhsMatch = trailingSuffixNumber(lhs.title) == number
                        let rhsMatch = trailingSuffixNumber(rhs.title) == number
                        if lhsMatch != rhsMatch { return lhsMatch }
                    }
                    return abs(lhs.title.count - query.count) < abs(rhs.title.count - query.count)
                }

            for entry in ranked.prefix(3) where seen.insert(entry.image).inserted {
                guard let image = await download(nintendoLargeArt(entry.image)),
                      image.size.width >= 480 else { continue }
                return image
            }
        }
        return nil
    }

    // The AU catalogue is English-only, so the search runs on the game's
    // ENGLISH name — that is the default now, not an afterthought. Queries are
    // tried in order until one returns a ranked hit:
    //   1) a translation-memory lookup, the only step that resolves a subtitle;
    //   2) the curated alias table, for titles the memory mangles;
    //   3) the name as typed, whenever it already carries Latin letters.
    // A pure-CJK name is never sent to the index on its own: it can only ever
    // return zero hits, and the round trip delays the fallback by seconds.
    // Exposed for the meta store: it queries the same storefront for the game
    // specs, and the alias table that turns a Chinese title into an English
    // query already lives here.
    static func nintendoQueriesOpen(for name: String) async -> [String] {
        await nintendoQueries(for: name)
    }

    private static func nintendoQueries(for name: String) async -> [String] {
        let latin = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var queries: [String] = []
        // The full title through the translation memory first, because it
        // resolves the SUBTITLE too: "塞尔达传说 王国之泪" becomes "The Legend
        // of Zelda: Tears of the Kingdom" — the exact entry — where a franchise
        // alias stops at "...of Zelda" and pulls a cousin's poster.
        if let english = await englishTitle(for: name) { queries.append(english) }
        // Translation memory is not a game database and does mangle the odd
        // title ("双人成行" comes back as "Buddy Shopping"). The alias is a
        // curated mapping, so it gets the second attempt rather than being
        // ignored whenever the translation happened to return something.
        let norm = normalized(name)
        if let alias = nintendoAliases.first(where: { !norm.isEmpty && norm.contains(normalized($0.zh)) })?.en,
           !queries.contains(alias) {
            // The table maps FRANCHISES, so it drops the number the display
            // name carries: "歧路旅人 2" would query "Octopath Traveler" and
            // fetch the FIRST game's key art. Carry the number across, but keep
            // the plain alias behind it as a fallback ("Octopath Traveler 2"
            // still resolves, in the index, to OCTOPATH TRAVELER II).
            if let number = trailingNumber(in: name), !alias.contains(number) {
                queries.append("\(alias) \(number)")
            }
            queries.append(alias)
        }
        // Mixed names ("巫师 3: Wild Hunt") still rank better as typed.
        if name.rangeOfCharacter(from: latin) != nil, !queries.contains(name) {
            queries.append(name)
        }
        return queries
    }

    // MARK: - English title resolution

    // One resolved title per display name, kept for the session: the hero, the
    // list and the landscape wall all ask for the same game.
    private static var englishTitles: [String: String] = [:]
    private static let englishTitlesLock = NSLock()

    private static func cachedEnglishTitle(for name: String) -> String? {
        englishTitlesLock.lock()
        defer { englishTitlesLock.unlock() }
        return englishTitles[name]
    }

    private static func storeEnglishTitle(_ title: String, for name: String) {
        englishTitlesLock.lock()
        englishTitles[name] = title
        englishTitlesLock.unlock()
    }

    private static func englishTitle(for name: String) async -> String? {
        let latin = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let hasLatin = name.rangeOfCharacter(from: latin) != nil
        let hasCJK = name.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) })
        // Already an English (or English-with-subtitle) name: search as typed.
        if hasLatin && !hasCJK { return name }

        if let cached = cachedEnglishTitle(for: name) { return cached }
        // Translation memory first: it is the only step that resolves a
        // subtitle, and the realistic failure mode is "no translation", not a
        // bad one — `nintendoQueries` retries the curated alias whenever the
        // translated query comes back empty-handed.
        if let translated = await translateToEnglish(name) {
            storeEnglishTitle(translated, for: name)
            return translated
        }
        return hasLatin ? name : nil
    }

    // A translation memory rather than a translation engine: famous game
    // titles are in its memory verbatim ("巫师 3：狂猎" → "The Witcher 3: Wild
    // Hunt"), so this resolves far more than it mangles. Whatever comes back
    // is still ranked by `matchScore` before an image is downloaded, so a bad
    // translation ends as "no hit", never as the wrong poster.
    private static func translateToEnglish(_ text: String) async -> String? {
        guard let url = lcMakeURL("https://api.mymemory.translated.net/get",
                                  ["q": text, "langpair": "zh-CN|en"]),
              let (data, _) = try? await session.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseData = object["responseData"] as? [String: Any],
              let translated = responseData["translatedText"] as? String
        else { return nil }

        // The service occasionally answers with a percent-encoded string
        // ("%E5%A1%9E..."), which is useless as a query — decode before use.
        let trimmed = (translated.removingPercentEncoding ?? translated)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The service answers 200 with a warning string when rate-limited or
        // when it cannot translate; those must not become search queries.
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(text) != .orderedSame,
              !trimmed.uppercased().contains("MYMEMORY"),
              !trimmed.uppercased().contains("PLEASE SELECT"),
              !trimmed.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil
        else { return nil }
        return trimmed
    }

    private static func nintendoSearch(query: String) async -> [LCNintendoHit]? {
        var request = URLRequest(url: nintendoSearchURL, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue(nintendoAppId, forHTTPHeaderField: "X-Algolia-Application-Id")
        request.setValue(nintendoSearchKey, forHTTPHeaderField: "X-Algolia-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "hitsPerPage": 6])
        guard let (data, _) = try? await session.data(for: request),
              let response = try? JSONDecoder().decode(LCNintendoResponse.self, from: data) else {
            return nil
        }
        return response.hits
    }

    // The index stores thumbnails (`?w=10` on the eShop CDN, `,w_320` on the
    // asset CDN). Ask the same URL for a poster-sized copy instead.
    // "歧路旅人 2" / "火影忍者 终极风暴 4" — the trailing number is part of the
    // title, and dropping it silently swaps the poster for the first game's.
    private static func trailingNumber(in name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "[0-9]+\\s*$", options: .regularExpression) else { return nil }
        return trimmed[range].trimmingCharacters(in: .whitespaces)
    }

    // The catalogue writes sequels both ways — "OCTOPATH TRAVELER 0" and
    // "OCTOPATH TRAVELER II" sit side by side — and character-set scoring cannot
    // tell "2" from "0" from "II". Reading the suffix as a number can.
    private static let romanSuffixNumbers: [(String, Int)] = [
        ("xiii", 13), ("xii", 12), ("xi", 11), ("x", 10), ("ix", 9), ("viii", 8),
        ("vii", 7), ("vi", 6), ("v", 5), ("iv", 4), ("iii", 3), ("ii", 2), ("i", 1)
    ]

    private static func trailingSuffixNumber(_ title: String) -> Int? {
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = lower.range(of: "[0-9]+$", options: .regularExpression), let value = Int(lower[range]) {
            return value
        }
        guard let last = lower.split(whereSeparator: { !$0.isLetter }).last.map(String.init) else { return nil }
        return romanSuffixNumbers.first { $0.0 == last }?.1
    }

    // "The Witcher 3: Wild Hunt" and "...— Remastered" both score 0.9 against
    // the query, so the storefront's re-release used to win on length alone.
    // A marker the query does not itself carry means the hit is a variant, and
    // variants yield to the plain release — unless the plain release is simply
    // not in the catalogue, in which case the variant is still the right art.
    private static let editionMarkers = ["remastered", "remake", "complete edition", "ultimate edition",
                                         "deluxe", "definitive", "intergrade", "goty",
                                         "game of the year", "collection", "expansion pass"]

    private static func isEditionVariant(_ title: String, of query: String) -> Bool {
        let t = normalized(title)
        let q = normalized(query)
        guard t != q else { return false }
        return editionMarkers.contains { marker in
            let m = normalized(marker)
            return t.contains(m) && !q.contains(m)
        }
    }

    private static func nintendoLargeArt(_ url: String) -> String {
        url.replacingOccurrences(of: "([?&])w=\\d+", with: "$1w=1000", options: .regularExpression)
            .replacingOccurrences(of: "w_\\d+", with: "w_1000", options: .regularExpression)
    }

    private static func fetchSteam(name: String, query: String) async -> UIImage? {
        guard let url = lcMakeURL("https://store.steampowered.com/api/storesearch/",
                                  ["term": query, "l": "schinese", "cc": "cn"]),
              let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(LCSteamSearchResponse.self, from: data),
              let items = response.items else { return nil }

        let ranked = items
            .map { (score: matchScore(name, $0.name), item: $0) }
            .filter { $0.score >= 0.45 }
            .sorted { $0.score > $1.score }

        guard let appId = ranked.first?.item.id else { return nil }
        for suffix in ["library_600x900.jpg", "header.jpg"] {
            let poster = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/\(suffix)"
            if let image = await download(poster) { return image }
        }
        return nil
    }

    private static func fetchAppStore(name: String, query: String) async -> UIImage? {
        for country in ["cn", "us"] {
            guard let url = lcMakeURL("https://itunes.apple.com/search",
                                      ["term": query, "entity": "software", "country": country, "limit": "8"]),
                  let (data, _) = try? await session.data(from: url),
                  let response = try? JSONDecoder().decode(LCITunesSearchResponse.self, from: data),
                  let results = response.results else { continue }

            let ranked = results
                .map { (score: matchScore(name, $0.trackName ?? ""), item: $0) }
                .filter { $0.score >= 0.45 }
                .sorted { $0.score > $1.score }

            for entry in ranked.prefix(2) {
                // The official icon/artwork comes first: gameplay screenshots
                // used to win and ended up as the poster.
                var urls: [String] = []
                if let art = entry.item.artworkUrl100 {
                    urls.append(art.replacingOccurrences(of: "100x100bb", with: "1024x1024bb"))
                }
                if let shot = entry.item.screenshotUrls?.first { urls.append(shot) }
                for u in urls.prefix(3) {
                    if let image = await download(u), image.size.width >= 400, image.size.height >= 400 {
                        return image
                    }
                }
            }
        }
        return nil
    }

    private static func download(_ urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString),
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    // Exposed for the inlined meta store's name matching.
    static func matchScoreOpen(_ lhs: String, _ rhs: String) -> Double {
        matchScore(lhs, rhs)
    }

    private static func matchScore(_ lhs: String, _ rhs: String) -> Double {
        let a = normalized(lhs)
        let b = normalized(rhs)
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) { return 0.9 }
        let setA = Set(a)
        let setB = Set(b)
        let overlap = setA.intersection(setB).count
        return Double(overlap) / Double(max(setA.count, setB.count))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\u4e00-\\u9fff]+",
                                  with: "",
                                  options: .regularExpression)
    }
}


// ===== Inlined gallery meta store (one-line game intro) =====
//
//  Fetches a short, one-line game intro for the hero title. Priority:
//    1) Steam appdetails short_description for the best name match
//    2) iTunes Search description, trimmed to its first line/sentence
//    3) Local Info.plist description fields, else a generic fallback
//  Results are cached and announced with metaReady so the hero refreshes.

final class LCGalleryMetaStore {
    static let shared = LCGalleryMetaStore()
    static let metaReady = Notification.Name("LCGalleryMetaReady")

    private var cache: [String: LCGalleryGameMeta] = [:]
    private var inFlight: Set<String> = []
    private var diskLoaded = false
    private static let fallback = "一款值得一玩的精选游戏，点击即可开始"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    func intro(for app: LCAppModel) -> String {
        gameMeta(for: app).intro
    }

    // The landscape detail panel asks for this. Resolution order is memory →
    // disk → the store, so a game that has been described once is described
    // instantly on every later launch, exactly like the covers.
    func gameMeta(for app: LCAppModel) -> LCGalleryGameMeta {
        let key = Self.key(for: app)
        if let hit = cache[key] {
            // Written before the spec table was part of the panel: keep showing
            // what we have and quietly upgrade it in the background.
            if hit.specVersion == nil { request(name: app.displayName, key: key) }
            return hit
        }
        loadDiskIfNeeded()
        if let stored = cache[key] {
            if stored.specVersion == nil { request(name: app.displayName, key: key) }
            return stored
        }
        let local = Self.localIntro(for: app)
        request(name: app.displayName, key: key)
        return LCGalleryGameMeta(intro: local.isEmpty ? Self.fallback : local, year: nil)
    }

    private func request(name: String, key: String) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let meta = await Self.fetchMeta(forName: name)
            await MainActor.run {
                self.inFlight.remove(key)
                if let meta = meta, !meta.intro.isEmpty || meta.platform != nil {
                    self.cache[key] = meta
                    self.persist()
                    NotificationCenter.default.post(name: Self.metaReady, object: key)
                }
            }
        }
    }

    // MARK: - Persisted meta

    // Caches/LCGalleryGameMeta.json — one dictionary for the whole library.
    private static let diskQueue = DispatchQueue(label: "lc.gallery.meta.disk",
                                                 qos: .utility)

    private static let diskURL: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent("LCGalleryGameMeta.json")
    }()

    private func loadDiskIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        guard let url = Self.diskURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: LCGalleryGameMeta].self, from: data)
        else { return }
        // Anything already fetched in this session wins over what was on disk.
        cache.merge(stored) { current, _ in current }
    }

    private func persist() {
        let snapshot = cache
        Self.diskQueue.async {
            guard let url = Self.diskURL,
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func key(for app: LCAppModel) -> String {
        if let bid = app.appInfo.bundleIdentifier(), !bid.isEmpty { return "meta-\(bid)" }
        if let rel = app.appInfo.relativeBundlePath, !rel.isEmpty { return "meta-\(rel)" }
        return "meta-\(ObjectIdentifier(app).hashValue)"
    }

    private static func localIntro(for app: LCAppModel) -> String {
        guard let path = app.appInfo.bundlePath() else { return "" }
        let info = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Info.plist"))
        for field in ["LCGameDescription", "GameDescription", "ITSAppUsesNonExemptEncryptionDescription"] {
            if let s = info?[field] as? String, !s.isEmpty { return oneLine(s) }
        }
        return ""
    }

    // Two sources, in parallel: the Chinese short intro from the App Store
    // lookup, and the spec table from Nintendo's own storefront — the same
    // index the poster already comes from. Either one may come back empty.
    private static func fetchMeta(forName name: String) async -> LCGalleryGameMeta? {
        async let introPart = fetchIntro(forName: name)
        async let specPart = fetchSpecs(forName: name)
        let intro = await introPart
        let specs = await specPart
        guard intro != nil || specs != nil else { return nil }
        var meta = LCGalleryGameMeta(intro: intro ?? "")
        meta.specVersion = 1
        if let specs {
            meta.year = specs.year
            meta.platform = specs.platform
            meta.languages = specs.languages
            meta.publisher = specs.publisher
            meta.genre = specs.genre
            meta.rating = specs.rating
        }
        return meta
    }

    // MARK: - Official spec table (Nintendo storefront)

    private struct LCSpecs {
        var year: String?
        var platform: String?
        var languages: String?
        var publisher: String?
        var genre: String?
        var rating: String?
    }

    private struct LCNintendoDateTag: Codable {
        let day: Int?
        let month: Int?
        let year: Int?
    }

    private struct LCNintendoGame: Codable {
        let title: String?
        let console: String?
        let publisher: String?
        let genre: [String]?
        let classification: String?
        let fullURL: String?
        let dateTag: LCNintendoDateTag?
    }

    private struct LCNintendoGameResponse: Codable {
        let hits: [LCNintendoGame]?
    }

    private static let nintendoURL =
        URL(string: "https://FMW57F6ERV-dsn.algolia.net/1/indexes/prod_games/query")!
    private static let nintendoPageBase = "https://www.nintendo.com/au"

    private static func fetchSpecs(forName name: String) async -> LCSpecs? {
        for query in await LCGalleryOnlineCoverStore.nintendoQueriesOpen(for: name) {
            guard let hit = await nintendoGame(query: query, name: name) else { continue }
            var specs = LCSpecs()
            // "Nintendo Switch 2" → "任天堂 Switch 2": the row is read at a
            // glance next to Chinese labels, so the brand is localised. Every
            // other value is printed exactly as the store prints it.
            specs.platform = hit.console?
                .replacingOccurrences(of: "Nintendo Switch", with: "任天堂 Switch")
            specs.publisher = hit.publisher
            specs.rating = hit.classification
            if let year = hit.dateTag?.year, year > 1970 { specs.year = String(year) }
            if let genre = hit.genre, !genre.isEmpty {
                specs.genre = genre.map { genreNames[$0] ?? $0.capitalized }
                    .joined(separator: "、")
            }
            // The storefront's own spec table is the only place the language
            // list lives; the search index does not carry it.
            if let url = hit.fullURL.flatMap({ URL(string: nintendoPageBase + $0) }),
               let html = await page(url) {
                if let raw = specValue(html, "Supported languages") {
                    specs.languages = localizeLanguages(raw)
                }
                if specs.publisher == nil { specs.publisher = specValue(html, "Publisher") }
            }
            return specs
        }
        return nil
    }

    private static func nintendoGame(query: String, name: String) async -> LCNintendoGame? {
        guard let url = URL(string: nintendoURL.absoluteString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("FMW57F6ERV", forHTTPHeaderField: "X-Algolia-Application-Id")
        request.setValue("c8e4e9f60190ef785d167da77ba0b4fe", forHTTPHeaderField: "X-Algolia-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query, "hitsPerPage": 6
        ])
        guard let (data, _) = try? await session.data(for: request),
              let response = try? JSONDecoder().decode(LCNintendoGameResponse.self, from: data),
              let hits = response.hits else { return nil }
        let ranked = hits
            .map { (score: LCGalleryOnlineCoverStore.matchScoreOpen(name, $0.title ?? ""), hit: $0) }
            .filter { $0.score >= 0.5 }
            .sorted { $0.score > $1.score }
        return ranked.first?.hit
    }

    private static func page(_ url: URL) async -> String? {
        guard let (data, _) = try? await session.data(from: url),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return html
    }

    // The spec table is a two-column list of divs; the label cell is the one
    // carrying `md:tw-w-[296px]`, its value is the cell right after it. Matching
    // on that pair is far steadier than trying to walk the DOM.
    private static func specValue(_ html: String, _ label: String) -> String? {
        let pattern = "md:tw-w-\\[296px\\][^>]*>\\s*"
            + NSRegularExpression.escapedPattern(for: label)
            + "\\s*</div>\\s*<div[^>]*text-fixed-body-16[^>]*>(.*?)</div>"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = rx.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let text = String(html[range])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // The storefront is the AU one, so its language names are English.
    private static let languageNames: [String: String] = [
        "english": "英语", "japanese": "日语", "french": "法语", "german": "德语",
        "italian": "意大利语", "spanish": "西班牙语", "korean": "韩语",
        "portuguese": "葡萄牙语", "russian": "俄语", "dutch": "荷兰语",
        "polish": "波兰语", "turkish": "土耳其语", "arabic": "阿拉伯语",
        "thai": "泰语", "vietnamese": "越南语", "indonesian": "印尼语",
        "ukrainian": "乌克兰语", "czech": "捷克语", "hungarian": "匈牙利语",
        "greek": "希腊语", "romanian": "罗马尼亚语", "swedish": "瑞典语",
        "norwegian": "挪威语", "danish": "丹麦语", "finnish": "芬兰语",
        "chinese (simplified)": "简体中文", "chinese (traditional)": "繁体中文",
        "simplified chinese": "简体中文", "traditional chinese": "繁体中文"
    ]

    private static func localizeLanguages(_ raw: String) -> String? {
        let parts = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { languageNames[$0.lowercased()] ?? $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }

    // eShop genre codes → the names the Chinese storefront prints.
    private static let genreNames: [String: String] = [
        "ACTION": "动作", "ADVENTURE": "冒险", "RPG": "角色扮演",
        "PLATFORMERS": "平台", "RACING": "竞速", "PARTY": "派对",
        "PUZZLE": "益智", "SPORTS": "体育", "FIGHTING": "格斗",
        "SHOOTING": "射击", "SIMULATION": "模拟", "STRATEGY": "策略",
        "MUSIC": "音乐", "ARCADE": "街机", "BOARD_GAME": "桌游",
        "EDUCATION": "教育", "FITNESS": "健身", "TRAINING": "训练",
        "LIFESTYLE": "生活", "OTHER": "其他", "BEAT_'EM_UP": "格斗"
    ]

    private static func fetchIntro(forName name: String) async -> String? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        for country in ["cn", "us"] {
            guard let url = lcMakeURL("https://itunes.apple.com/search",
                                      ["term": query, "entity": "software", "country": country, "limit": "8"]),
                  let (data, _) = try? await session.data(from: url),
                  let response = try? JSONDecoder().decode(LCITunesSearchResponse.self, from: data),
                  let results = response.results else { continue }
            let ranked = results
                .map { (score: LCGalleryOnlineCoverStore.matchScoreOpen(name, $0.trackName ?? ""), item: $0) }
                .filter { $0.score >= 0.45 }
                .sorted { $0.score > $1.score }
            guard let best = ranked.first?.item else { continue }
            // 39 characters: the panel shows a short blurb, not a paragraph.
            let intro = oneLine(best.description ?? "", limit: 39)
            guard !intro.isEmpty else { continue }
            return intro
        }
        return nil
    }

    // Collapse to readable text, strip HTML, cap length.
    private static func oneLine(_ raw: String, limit: Int = 28) -> String {
        var text = raw
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the short variants are cut back to one sentence; anything longer
        // keeps its own punctuation.
        if limit <= 48 {
            if let stop = text.range(of: "。") { text = String(text[..<stop.upperBound]) }
            if let stop = text.range(of: ". ") { text = String(text[..<stop.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text
    }
}

// ===== Inlined gallery cover store =====
//
//  LCGalleryCover.swift
//  Offline cover-art extraction for the LiveContainer home gallery.
//
//  Reads a cover image from an installed guest app's bundle — no network.
//  Priority:
//    1) launch images / iTunesArtwork / common landscape names at bundle root
//    2) CFBundleIcons large icon
//    3) fallback: synthesise a 16:9 cover from the app icon (blur + tint + vignette)
//
//  Results are cached in memory and delivered on the main queue. Heavy bundle
//  scanning runs on a background queue so opening the home page never blocks.
//


// User-chosen hero posters ("long-press the cover → pick from Photos").
// Stored as JPEGs inside the app's Documents folder so they survive relaunches,
// and consulted before every automatic source (online poster, bundle artwork).
final class LCGalleryCustomCoverStore {
    static let shared = LCGalleryCustomCoverStore()

    private var cache: [String: UIImage] = [:]
    private let lock = NSLock()

    private var directory: URL {
        let base = LCPath.docPath.appendingPathComponent("GalleryCustomCovers", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    func key(for app: LCAppModel) -> String {
        let raw = app.appInfo.bundleIdentifier()
            ?? app.appInfo.relativeBundlePath
            ?? app.displayName
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return raw.unicodeScalars
            .map { allowed.contains($0) ? String(Character($0)) : "_" }
            .joined()
    }

    func image(for app: LCAppModel) -> UIImage? {
        let key = key(for: app)
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }

        let url = directory.appendingPathComponent(key + ".jpg")
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }

    // Cheap check for the "restore default cover" menu item.
    func hasCustomCover(for app: LCAppModel) -> Bool {
        if image(for: app) != nil { return true }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(key(for: app) + ".jpg").path)
    }

    @discardableResult
    func save(_ image: UIImage, for app: LCAppModel) -> Bool {
        let key = key(for: app)
        let prepared = Self.downscale(image, maxSide: 1800)
        guard let data = prepared.jpegData(compressionQuality: 0.92) else { return false }
        do {
            try data.write(to: directory.appendingPathComponent(key + ".jpg"), options: .atomic)
        } catch {
            return false
        }
        lock.lock()
        cache[key] = prepared
        lock.unlock()
        // Repaint every surface that shows this game's artwork.
        LCGalleryCoverStore.shared.invalidate(key)
        NotificationCenter.default.post(name: LCGalleryCoverStore.coverReady, object: key)
        return true
    }

    func remove(for app: LCAppModel) {
        let key = key(for: app)
        lock.lock()
        cache.removeValue(forKey: key)
        lock.unlock()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".jpg"))
        NotificationCenter.default.post(name: LCGalleryCoverStore.coverReady, object: key)
    }

    private static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

final class LCGalleryCoverStore {
    static let shared = LCGalleryCoverStore()

    private var cache: [String: UIImage] = [:]
    private let lock = NSLock()
    static let coverReady = Notification.Name("LCGalleryCoverReady")

    func cover(for app: LCAppModel, wide: Bool = false) -> UIImage {
        // A poster the user picked by hand outranks every automatic source.
        if let custom = LCGalleryCustomCoverStore.shared.image(for: app) { return custom }
        // Official box art / key art next. The first call also kicks off the
        // lookup, so a miss simply falls through to the icon below for a frame.
        if let online = LCGalleryOnlineCoverStore.shared.cover(for: app, wide: wide) { return online }
        // A wide slot with nothing of its own yet: a portrait poster cropped
        // still beats the blurred icon while the key art downloads.
        if wide, let portrait = LCGalleryOnlineCoverStore.shared.cover(for: app, wide: false) {
            return portrait
        }
        let key = app.appInfo.bundleIdentifier() ?? app.appInfo.relativeBundlePath ?? UUID().uuidString
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }
        // No artwork yet: enlarge the app icon. Nothing is scanned out of the
        // game bundle any more — that used to surface random splash screens and
        // textures as if they were covers.
        let synth = LCGalleryCoverStore.synthesise(from: app.appInfo.iconIsDarkIcon(false))
        lock.lock()
        if cache[key] == nil { cache[key] = synth }
        lock.unlock()
        return synth
    }

    func invalidate(_ key: String) {
        lock.lock()
        cache.removeValue(forKey: key)
        lock.unlock()
    }

    // MARK: - Enlarged-icon fallback

    // What a game without official artwork looks like: its own icon, large and
    // sharp, sitting on a blurred copy of itself. Square stickers and stray
    // in-game assets are exactly what this replaces.
    static func synthesise(from icon: UIImage?) -> UIImage {
        let w: CGFloat = 900, h: CGFloat = 1350
        let size = CGSize(width: w, height: h)
        let tint = icon.flatMap(averageColor(of:)) ?? UIColor(red: 0.05, green: 0.19, blue: 0.42, alpha: 1)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = true
        fmt.scale = 1

        let raw = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            tint.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let icon {
                icon.draw(in: coverRect(for: icon, in: CGRect(x: -w * 0.30, y: -h * 0.10,
                                                              width: w * 1.60, height: h * 1.20)))
            }
        }

        var frosted = raw
        if let ci = CIImage(image: raw)?.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 70]),
           let cg = CIContext(options: nil).createCGImage(ci, from: CGRect(origin: .zero, size: size)) {
            frosted = UIImage(cgImage: cg)
        }

        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            frosted.draw(in: CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            // Scrim so the caption and buttons stay readable over any icon.
            let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [UIColor.black.withAlphaComponent(0.14).cgColor,
                                            UIColor.black.withAlphaComponent(0.24).cgColor,
                                            UIColor.black.withAlphaComponent(0.74).cgColor] as CFArray,
                                   locations: [0.0, 0.55, 1.0])!
            cg.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: h), options: [])

            guard let icon else { return }
            // The icon itself, large, with a light rim and a soft drop shadow.
            let side = w * 0.46
            let rect = CGRect(x: (w - side) / 2, y: h * 0.30, width: side, height: side)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: side * 0.235)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 22), blur: 44,
                         color: UIColor.black.withAlphaComponent(0.55).cgColor)
            UIColor.white.withAlphaComponent(0.92).setFill()
            path.fill()
            cg.restoreGState()

            cg.saveGState()
            path.addClip()
            icon.draw(in: rect)
            cg.restoreGState()
        }
    }

    private static func coverRect(for image: UIImage, in target: CGRect) -> CGRect {
        let imageRatio = image.size.width / max(1, image.size.height)
        let targetRatio = target.width / max(1, target.height)
        if imageRatio > targetRatio {
            let height = target.height
            let width = height * imageRatio
            return CGRect(x: target.midX - width / 2, y: target.minY, width: width, height: height)
        }
        let width = target.width
        let height = width / imageRatio
        return CGRect(x: target.minX, y: target.midY - height / 2, width: width, height: height)
    }

    private static func averageColor(of image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self)
        return UIColor(red: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255,
                       blue: CGFloat(p[2]) / 255, alpha: 1)
    }
}


// ===== Inlined gallery size store =====
//
//  Shows each guest app's real on-disk footprint (bundle + internal containers)
//  instead of its bundle identifier. Sizing runs off the main queue and is cached.

final class LCGallerySizeStore {
    static let shared = LCGallerySizeStore()
    static let sizeReady = Notification.Name("LCGallerySizeReady")

    private var cache: [String: String] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "lc.gallery.size", qos: .utility, attributes: .concurrent)

    func sizeText(for app: LCAppModel) -> String {
        let key = Self.key(for: app)
        if let hit = cache[key] { return hit }
        requestSize(for: app, key: key)
        return "计算中…"
    }

    private func requestSize(for app: LCAppModel, key: String) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        queue.async {
            let text = Self.computeSizeText(for: app)
            DispatchQueue.main.async {
                self.inFlight.remove(key)
                self.cache[key] = text
                NotificationCenter.default.post(name: Self.sizeReady, object: key)
            }
        }
    }

    private static func key(for app: LCAppModel) -> String {
        if let bid = app.appInfo.bundleIdentifier(), !bid.isEmpty { return bid }
        if let rel = app.appInfo.relativeBundlePath, !rel.isEmpty { return rel }
        return "app-\(ObjectIdentifier(app).hashValue)"
    }

    nonisolated private static func computeSizeText(for app: LCAppModel) -> String {
        var total: Int64 = 0
        if let bundlePath = app.appInfo.bundlePath() {
            total += directorySize(URL(fileURLWithPath: bundlePath))
        }
        for container in app.uiContainers {
            // External containers are not stored inside LC, so they are not part
            // of the app's LC footprint (matches LC's own storage breakdown).
            if container.storageBookMark != nil { continue }
            let started = container.bookmarkResolved && container.containerURL.startAccessingSecurityScopedResource()
            total += directorySize(container.containerURL)
            if started { container.containerURL.stopAccessingSecurityScopedResource() }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}


// ===== Inlined home gallery view =====
//
//  LCHomeGalleryView.swift
//  Big-card home gallery for LiveContainer's App tab.
//
//  Keeps LC's own data source (LCAppModel) and launch path untouched. It only
//  replaces the visual presentation: a Hero carousel of stacked covers, an icon
//  rail that tracks the Hero, a scrollable list of large cover cards, and a
//  liquid-glass tab bar (Home/Sources/Tweaks/Settings) that collapses to a
//  single round button while scrolling down.
//


// Makes the navigation bar transparent so the hero poster can fill all the way
// to the top edge, while the native toolbar buttons stay visible on top.
// A single app card in the gallery. This is a standalone View with `app` as a
// stored property (not a @ViewBuilder function capturing a loop parameter), so
// LazyVGrid cell reuse always shows the correct app's cover, run action and
// context menu. Background layers are non-interactive so the Run button and
// long-press always reach the intended target.
struct GalleryCardView: View {
    let app: LCAppModel
    let compact: Bool
    let coverTick: Int
    let sizeTick: Int
    var onLaunch: (LCAppModel) -> Void
    var onOpenSettings: (LCAppModel) -> Void
    var onUninstall: (LCAppModel) -> Void
    var onSaveIcon: (LCAppModel) -> Void
    var onCreateAppClip: (LCAppModel) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let appName = app.displayName
        let cover = LCGalleryCoverStore.shared.cover(for: app)
        let tint = LCGalleryColorStore.shared.color(for: app)
        let containers = app.uiContainers
        let selectedContainer = app.uiSelectedContainer
        let isShared = app.uiIsShared
        let multitask = app.shouldLaunchInMultitaskMode
        let relative = app.appInfo.relativeBundlePath ?? ""
        // Same anatomy as a landscape poster: a liquid-glass plate, the artwork
        // inset inside it, and the title strip as the bottom edge of that same
        // plate — name on the left, round controller button on the right.
        let plateRadius: CGFloat = 22
        let inset: CGFloat = 7
        let innerRadius: CGFloat = plateRadius - inset
        let stripHeight: CGFloat = 42

        VStack(spacing: 0) {
            // 16:9 cover. `Color.clear` + aspectRatio is what makes the height
            // follow the grid column's width without measuring anything.
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.30), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .id("card-cover-\(appName)-\(coverTick)")
                .padding(.horizontal, inset)
                .padding(.top, inset)

            HStack(spacing: 8) {
                Text(appName)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .shadow(color: .black.opacity(0.50), radius: 2.5, y: 1)
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 2)
                Spacer(minLength: 4)
                Button {
                    onLaunch(app)
                } label: {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .lcTintedGlassCapsule(tint: tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("运行 \(appName)")
            }
            .padding(.horizontal, inset + 5)
            .frame(height: stripHeight)
        }
        .frame(maxWidth: .infinity)
        .lcGlassCard(cornerRadius: plateRadius)
        .clipShape(RoundedRectangle(cornerRadius: plateRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: plateRadius, style: .continuous)
                .stroke(
                    LinearGradient(colors: [
                        Color.white.opacity(0.46),
                        Color.white.opacity(0.14),
                        Color.white.opacity(0.28)
                    ], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.32), radius: 14, y: 8)
        .contentShape(Rectangle())
        .contextMenu {
            // Full native-equivalent menu, matching LCAppBannerViewController.makeContextMenu().
            if containers.count > 1 {
                Section {
                    ForEach(Array(containers.enumerated()), id: \.offset) { _, container in
                        Button {
                            app.uiSelectedContainer = container
                        } label: {
                            Label(container.name,
                                  systemImage: container == app.uiSelectedContainer ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            if !isShared, selectedContainer != nil {
                Button {
                    if let folderName = selectedContainer?.folderName,
                       let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folderName)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("lc.appBanner.openDataFolder".loc, systemImage: "folder")
                }
            }
            if #available(iOS 16.0, *) {
                Button {
                    Task { try? await app.runApp(multitask: !multitask) }
                } label: {
                    Label(multitask ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
                          systemImage: multitask ? "play.fill" : "macwindow.badge.plus")
                }
            }
            Menu {
                Button {
                    if let folderName = selectedContainer?.folderName {
                        UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relative)&container-folder-name=\(folderName)"
                    } else {
                        UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relative)"
                    }
                } label: {
                    Label("lc.appBanner.copyLaunchUrl".loc, systemImage: "link")
                }
                Button { onSaveIcon(app) } label: {
                    Label("lc.appBanner.saveAppIcon".loc, systemImage: "square.and.arrow.down")
                }
                Button { onCreateAppClip(app) } label: {
                    Label("lc.appBanner.createAppClip".loc, systemImage: "appclip")
                }
            } label: {
                Label("lc.appBanner.addToHomeScreen".loc, systemImage: "plus.app")
            }
            Button {
                onOpenSettings(app)
            } label: {
                Label("lc.tabView.settings".loc, systemImage: "gear")
            }
            if !isShared {
                Button(role: .destructive) {
                    onUninstall(app)
                } label: {
                    Label("lc.appBanner.uninstall".loc, systemImage: "trash")
                }
            }
        }
    }
}

// Exports the generated app icon through the native iOS document picker.
struct GalleryIconExportSheet: UIViewControllerRepresentable {
    var fileURL: URL?

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let url = fileURL ?? FileManager.default.temporaryDirectory
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

// Photo picker used by "long-press the poster → choose a new cover". UIKit's
// PHPicker runs out-of-process (no photo-library permission prompt) and, unlike
// SwiftUI's PhotosPicker, needs no extra availability dance.
struct GalleryPhotoPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: GalleryPhotoPicker

        init(_ parent: GalleryPhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                parent.dismiss()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                DispatchQueue.main.async {
                    if let image { self.parent.onPick(image) }
                    self.parent.dismiss()
                }
            }
        }
    }
}

// Picks an image out of Files / iCloud Drive for the poster. The document
// picker already renders the system UI, so nothing here needs styling.
struct GalleryFileImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: GalleryFileImagePicker

        init(_ parent: GalleryFileImagePicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.dismiss()
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                parent.onPick(image)
            }
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

// One search result: a poster URL for the grid and an ordered list of full-size
// URLs to try when the user taps it (Steam's portrait art can be missing, so
// the wide header is kept as a fallback).
struct GalleryCoverHit: Identifiable, Equatable {
    let id: String
    let title: String
    let thumb: URL
    let full: [URL]
}

enum GalleryCoverSearch {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    static func search(term: String) async -> [GalleryCoverHit] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed

        // Three keyless sources run in parallel: Steam for PC artwork, the App
        // Store for mobile releases, and a web image search for everything the
        // two catalogues simply do not carry (regional releases, fan key art,
        // games delisted from either store).
        async let steam = steamHits(query: q)
        async let store = appStoreHits(query: q)
        async let web = bingHits(query: q)
        // Everything in parallel, but the grid stays browsable: Steam first (its
        // posters are the best key art), then store icons, then the web.
        let merged = await steam + Array(store.prefix(80)) + Array(web.prefix(60))

        var seen = Set<String>()
        return merged.filter { seen.insert($0.full.first?.absoluteString ?? $0.id).inserted }
    }

    private static func steamHits(query: String) async -> [GalleryCoverHit] {
        guard let url = lcMakeURL("https://store.steampowered.com/api/storesearch/",
                                  ["term": query, "l": "schinese", "cc": "cn"]),
              let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(LCSteamSearchResponse.self, from: data),
              let items = response.items else { return [] }

        return items.compactMap { item in
            let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(item.id)/"
            guard let poster = URL(string: base + "library_600x900.jpg"),
                  let header = URL(string: base + "header.jpg") else { return nil }
            return GalleryCoverHit(id: "steam-\(item.id)", title: item.name,
                                   thumb: poster, full: [poster, header])
        }
    }

    // Every storefront is asked, not just cn/us: a game that only shipped in
    // Japan or Hong Kong has artwork nowhere else. 50 per country, one request
    // each, all in flight together.
    private static func appStoreHits(query: String) async -> [GalleryCoverHit] {
        let storefronts = ["cn", "us", "jp", "hk", "tw", "gb", "kr"]

        return await withTaskGroup(of: [GalleryCoverHit].self) { group in
            for country in storefronts {
                group.addTask {
                    guard let url = lcMakeURL("https://itunes.apple.com/search",
                                              ["term": query, "entity": "software",
                                               "media": "software", "limit": "50", "country": country]),
                          let (data, _) = try? await session.data(from: url),
                          let response = try? JSONDecoder().decode(LCITunesSearchResponse.self, from: data),
                          let results = response.results else { return [] }
                    return results.compactMap { result in
                        guard let art = result.artworkUrl100 else { return nil }
                        let big = art.replacingOccurrences(of: "100x100bb", with: "1024x1024bb")
                        guard let thumb = URL(string: art.replacingOccurrences(of: "100x100bb", with: "512x512bb")),
                              let full = URL(string: big) else { return nil }
                        return GalleryCoverHit(id: "itunes-\(big)",
                                               title: result.trackName ?? "",
                                               thumb: thumb, full: [full])
                    }
                }
            }
            var hits: [GalleryCoverHit] = []
            for await batch in group { hits += batch }
            return hits
        }
    }

    // Web image search. Bing's async image endpoint answers with an HTML
    // fragment whose results each carry their source URL inside an escaped JSON
    // `m=` attribute — no key, no scraping of a rendered page. Two markets are
    // asked because a Chinese title and its English title return different
    // artwork, and `filterui:aspect-tall` keeps the grid from filling up with
    // 16:9 screenshots that get cropped into unreadable slabs.
    private static func bingHits(query: String) async -> [GalleryCoverHit] {
        var hits: [GalleryCoverHit] = []
        for market in ["zh-CN", "en-US"] {
            guard let url = lcMakeURL("https://www.bing.com/images/async",
                                      ["q": query, "first": "0", "count": "40", "mkt": market,
                                       "adlt": "off", "qft": " filterui:aspect-tall"]) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
                             + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                             + "Version/18.0 Mobile/15E148 Safari/604.1",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            guard let (data, _) = try? await session.data(for: request),
                  let html = String(data: data, encoding: .utf8) else { continue }

            let fulls = matches(in: html, pattern: "&quot;murl&quot;:&quot;(.*?)&quot;")
            let thumbs = matches(in: html, pattern: "&quot;turl&quot;:&quot;(.*?)&quot;")
            for (index, raw) in fulls.enumerated() {
                let decoded = decodeEntities(raw)
                guard let full = URL(string: decoded),
                      let scheme = full.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }
                // turl is Bing's resized copy of the same picture: cheap to
                // render in the grid, identical when it matters.
                let thumbString = index < thumbs.count ? decodeEntities(thumbs[index]) : decoded
                hits.append(GalleryCoverHit(id: "web-\(decoded)",
                                            title: query,
                                            thumb: URL(string: thumbString) ?? full,
                                            full: [full]))
            }
        }
        return hits
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let slice = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[slice])
        }
    }

    // The attribute is HTML-escaped once and JSON-escaped inside that, so both
    // layers have to come off before the string is a URL again.
    private static func decodeEntities(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#47;", with: "/")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func download(_ hit: GalleryCoverHit) async -> UIImage? {
        for candidate in hit.full {
            guard let (data, response) = try? await session.data(from: candidate),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data),
                  image.size.width >= 200, image.size.height >= 200 else { continue }
            return image
        }
        return nil
    }
}

// Sheet for "search an online cover". Results come from Steam's public store
// search, every App Store storefront, and a web image search — all keyless.
struct GalleryCoverSearchView: View {
    let appName: String
    let onPick: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var hits: [GalleryCoverHit] = []
    @State private var loading = false
    @State private var message: String?
    @State private var applyingID: String?

    init(appName: String, onPick: @escaping (UIImage) -> Void) {
        self.appName = appName
        self.onPick = onPick
        _query = State(initialValue: appName)
    }

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("游戏名", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await runSearch() } }
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if loading && hits.isEmpty {
                        ProgressView("搜索中…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else if hits.isEmpty {
                        Text(message ?? "没有找到封面，换个关键词试试")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(hits) { hit in
                                Button {
                                    Task { await apply(hit) }
                                } label: {
                                    cell(hit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if loading {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 4)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("搜索封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await runSearch() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await runSearch() }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func cell(_ hit: GalleryCoverHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(Color(.tertiarySystemFill))
                AsyncImage(url: hit.thumb) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                if applyingID == hit.id {
                    Color.black.opacity(0.4)
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )

            Text(hit.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @MainActor
    private func runSearch() async {
        loading = true
        message = nil
        let found = await GalleryCoverSearch.search(term: query)
        hits = found
        message = found.isEmpty ? "没有找到封面，换个关键词试试" : nil
        loading = false
    }

    @MainActor
    private func apply(_ hit: GalleryCoverHit) async {
        applyingID = hit.id
        if let image = await GalleryCoverSearch.download(hit) {
            onPick(image)
            dismiss()
        } else {
            message = "这张封面下载失败，换一张试试"
        }
        applyingID = nil
    }
}

struct GalleryNavBarClear: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}

// SwiftUI's own `.toolbar(.hidden, for: .tabBar)` is a request, not a promise:
// UIKit puts the bar back on every relayout and again after each rotation,
// which is exactly how the home page kept ending up with the tab bar under it.
// This view holds the real thing — the UITabBar instance — down while the page
// it is attached to is on screen, and lets it go the moment the page leaves.
struct LCTabBarHider: UIViewRepresentable {
    func makeUIView(context: Context) -> LCTabBarHiderView {
        LCTabBarHiderView()
    }

    func updateUIView(_ uiView: LCTabBarHiderView, context: Context) {
        uiView.syncWithHierarchy()
    }
}

final class LCTabBarHiderView: UIView {
    private weak var heldBar: UITabBar?
    private var pulse: Timer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncWithHierarchy()
    }

    deinit {
        pulse?.invalidate()
    }

    // Attached → keep it down (and keep it down after UIKit re-lays the
    // hierarchy). Detached → the page is gone, hand the bar back so the other
    // tabs still have one.
    func syncWithHierarchy() {
        guard window != nil,
              let controller = Self.tabBarController(in: window?.rootViewController) else {
            release()
            return
        }
        heldBar = controller.tabBar
        controller.tabBar.isHidden = true
        if pulse == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let bar = self.heldBar, !bar.isHidden else { return }
                bar.isHidden = true
            }
            RunLoop.main.add(timer, forMode: .common)
            pulse = timer
        }
    }

    private func release() {
        pulse?.invalidate()
        pulse = nil
        heldBar?.isHidden = false
        heldBar = nil
    }

    private static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tab = controller as? UITabBarController { return tab }
        if let tab = controller.tabBarController { return tab }
        if let tab = tabBarController(in: controller.presentedViewController) { return tab }
        for child in controller.children {
            if let tab = tabBarController(in: child) { return tab }
        }
        return nil
    }
}

// Liquid glass only. The app targets iOS 26+, so there is no material fallback
// to maintain any more.
private extension View {
    func lcGlassCapsule() -> some View {
        glassEffect(.regular, in: Capsule())
    }

    func lcGlassCircle() -> some View {
        glassEffect(.regular, in: Circle())
    }

    func lcGlassCard(cornerRadius: CGFloat) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // Glass tinted with a game's own dominant colour: a faint wash of the icon's
    // palette (淡淡的主色调) behind white text, with a bright glass rim.
    func lcTintedGlassCapsule(tint: Color) -> some View {
        self
            .glassEffect(.regular.tint(tint.opacity(0.55)), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(colors: [
                            Color.white.opacity(0.55),
                            tint.opacity(0.45),
                            Color.white.opacity(0.12)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: tint.opacity(0.28), radius: 9, y: 3)
    }
}

// Dominant colour of the artwork a game is showing. Run buttons use it so each
// CTA carries that game's palette — and, crucially, it is read from the poster
// (custom photo / official cover / enlarged icon), so replacing the picture
// re-tints the button instead of leaving it stuck on the icon's colours.
final class LCGalleryColorStore {
    static let shared = LCGalleryColorStore()

    private var cache: [String: UIColor] = [:]
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: LCGalleryCoverStore.coverReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateAll()
        }
    }

    func invalidateAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    func color(for app: LCAppModel) -> Color {
        let key = app.appInfo.bundleIdentifier()
            ?? app.appInfo.relativeBundlePath
            ?? app.displayName
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return Color(cached) }

        let cover = LCGalleryCoverStore.shared.cover(for: app)
        let value = Self.dominantColor(of: cover) ?? UIColor(white: 0.90, alpha: 1)
        lock.lock()
        cache[key] = value
        lock.unlock()
        return Color(value)
    }

    // Downscale the icon to a 12×12 block (which averages it), then lift the
    // saturation so the result reads as the icon's "main colour" rather than the
    // muddy grey an unweighted average usually produces.
    static func dominantColor(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255.0
            if alpha < 0.4 { continue }
            r += Double(pixels[i]) * alpha
            g += Double(pixels[i + 1]) * alpha
            b += Double(pixels[i + 2]) * alpha
            weight += alpha
        }
        guard weight > 0 else { return nil }

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 1
        UIColor(red: CGFloat(r / weight / 255.0),
                green: CGFloat(g / weight / 255.0),
                blue: CGFloat(b / weight / 255.0),
                alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Keep it light and desaturated enough that white text stays readable.
        return UIColor(hue: hue,
                       saturation: min(0.66, max(0.30, saturation * 1.7)),
                       brightness: min(0.80, max(0.46, brightness * 1.05)),
                       alpha: 1)
    }
}

struct LCHomeGalleryView: View {
    @ObservedObject var searchContext: SearchContext
    var apps: [LCAppModel]
    var hiddenApps: [LCAppModel]
    // Owned by the navigation bar's host, written from the scroll observer
    // below: direction of the list decides whether the plus bead is showing.
    @Binding var topBeadHidden: Bool
    var onLaunch: (LCAppModel) -> Void
    var onOpenSettings: (LCAppModel) -> Void
    var onUninstall: (LCAppModel) -> Void
    var onSaveIcon: (LCAppModel) -> Void
    var onCreateAppClip: (LCAppModel) -> Void
    var onTab: (LCTabIdentifier) -> Void

    // Native LC home toolbar actions, kept intact on the redesigned page.
    var onInstallIPA: () -> Void
    var onInstallURL: () -> Void
    var onOpenSideStoreOrHelp: () -> Void
    var sideStoreIcon: UIImage?
    var canInstall: Bool
    var isInstalling: Bool
    var onOpenLink: () -> Void
    var sortType: AppSortType
    var onSortChange: (AppSortType) -> Void
    var onCustomSort: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var current = 0
    // Overscroll at the very top (positive when the page is pulled down). The
    // hero uses it to grow and fill the gap instead of exposing the backdrop.
    @State private var pullDown: CGFloat = 0
    @State private var coverTick = 0
    @State private var sizeTick = 0
    @State private var metaTick = 0
    @State private var searchExpanded = false
    // The poster no longer rotates by itself. It used to advance every five
    // seconds, which meant the game under the "运行游戏" button could change
    // while the user was reaching for it. Switching is now only ever the user's
    // own gesture: swipe the poster, or tap an icon in the rail.
    // Poster actions: long-press opens a menu, then one of these sheets runs.
    @State private var coverTarget: LCAppModel?
    @State private var coverMenuShown = false
    @State private var coverPickerShown = false
    @State private var coverFilePickerShown = false
    @State private var coverSearchShown = false
    // Last scroll offset, used only for direction. NaN until the first
    // callback so the opening frame cannot read as a huge downward flick.
    @State private var lastScrollY: CGFloat = .nan
    // Live finger offset of the landscape row. The pager owns its own
    // translation now (see landscapeSwipe), so a drag can never be swallowed by
    // a scroll view writing the index back mid-gesture.
    @State private var dragX: CGFloat = 0
    // How far the portrait list has covered the pinned poster: 0 = poster fully
    // visible, 1 = list at the top and the poster receded behind it.
    @State private var heroFade: CGFloat = 0

    // Every installed app takes part in the hero carousel. It used to be capped
    // at five, which made the sixth icon in the rail jump back to the first
    // poster (and anything past the tenth icon unreachable).
    private var slideCount: Int { apps.count }

    var body: some View {
        ZStack {
            // Ambient page colour: the current poster itself, heavily blurred,
            // so the whole app carries the game's palette instead of a fixed
            // navy gradient that never matched the hero above it.
            galleryBackdrop

            ZStack {
                if verticalSizeClass == .compact {
                    // Landscape reads its size straight from the layout proposal.
                    // A cached measurement was always one rotation behind, which
                    // is why the row first showed up tiny and only became right
                    // after rotating a second time.
                    GeometryReader { geo in
                        landscapeShowcase(in: geo.size)
                    }
                    .id("gallery-landscape")
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                } else {
                    portraitPage
                        .id("gallery-portrait")
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            // Swapping trees is what keeps stale geometry from leaking across
            // orientations. It used to cross-fade BOTH trees at once, so for a
            // third of a second the blurred hero, the blurred backdrop and
            // every poster were all being composited together — that was the
            // stutter on every turn. The outgoing tree now leaves on the spot
            // (it sits over the shared backdrop, so there is no hole to hide)
            // and only the incoming one fades, over a shorter beat. One tree to
            // render instead of two is most of the smoothness.
            .animation(.easeOut(duration: 0.2), value: verticalSizeClass)

        }
        .onReceive(NotificationCenter.default.publisher(for: LCGalleryCoverStore.coverReady)) { _ in
            coverTick += 1
        }
        .onChange(of: apps.count) { count in
            // Uninstalling can shrink the list under the current index.
            if count == 0 {
                current = 0
            } else if current >= count {
                current = count - 1
            }
        }
        .onChange(of: verticalSizeClass) { _ in
            // A turn mid-drag would otherwise leave the row parked off-centre.
            dragX = 0
            topBeadHidden = false
        }
        .onAppear {
            topBeadHidden = false
            restoreHeroSelection()
        }
        // Leaving the page (settings, the games tab) or launching a game only
        // HIDES the hero: nothing is torn down and nothing is looked up again,
        // and the poster that was selected is the one that comes back.
        .onChange(of: current) { _ in
            rememberHeroSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: LCGallerySizeStore.sizeReady)) { _ in
            sizeTick += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: LCGalleryMetaStore.metaReady)) { _ in
            metaTick += 1
        }
        .overlay {
            if searchExpanded { searchPanel }
        }
        // Long-press the poster → choose where the new artwork comes from.
        .confirmationDialog("更换封面", isPresented: $coverMenuShown, titleVisibility: .visible) {
            Button("从相册选择", systemImage: "photo.on.rectangle") { coverPickerShown = true }
            Button("从文件选择", systemImage: "folder") { coverFilePickerShown = true }
            Button("在线搜索封面", systemImage: "magnifyingglass") { coverSearchShown = true }
            if let app = coverTarget, LCGalleryCustomCoverStore.shared.hasCustomCover(for: app) {
                Button("恢复默认封面", systemImage: "arrow.counterclockwise", role: .destructive) {
                    restoreDefaultCover()
                }
            }
        } message: {
            Text(coverTarget?.displayName ?? "")
        }
        .sheet(isPresented: $coverPickerShown) {
            GalleryPhotoPicker { image in
                applyCustomCover(image)
            }
        }
        .sheet(isPresented: $coverFilePickerShown) {
            GalleryFileImagePicker { image in
                applyCustomCover(image)
            }
        }
        .sheet(isPresented: $coverSearchShown) {
            if let app = coverTarget {
                GalleryCoverSearchView(appName: app.displayName) { image in
                    applyCustomCover(image)
                }
            }
        }
    }

    // MARK: Portrait page

    // Kept as its own view so rotation swaps whole trees instead of mutating
    // one that was laid out for the other orientation. Mutating it left the
    // grid with stale geometry after rotating back — the list showed up empty.
    private var portraitPage: some View {
        // Cover-Flow deck, built on the v79 baseline. See LCFanDeckView.swift:
        // one fixed canvas, one progress value, no drawingGroup under 3D.
        LCFanDeckView(
            apps: apps,
            sortType: sortType,
            revision: coverTick &+ sizeTick &+ metaTick,
            sideStoreIcon: sideStoreIcon,
            onLaunch: onLaunch,
            onOpenSettings: onOpenSettings,
            onUninstall: onUninstall,
            onSortChange: onSortChange,
            onCustomSort: onCustomSort,
            onInstallIPA: onInstallIPA,
            onInstallURL: onInstallURL,
            onOpenLink: onOpenLink,
            onOpenSideStore: onOpenSideStoreOrHelp,
            onRequestCover: { app in
                coverTarget = app
                coverMenuShown = true
            },
            topBeadHidden: $topBeadHidden
        )
    }

    // MARK: Pinned poster (portrait)

    // The night ink the list is painted in. Same value as the ambient backdrop,
    // so the surface and the page never disagree.
    private var nightInk: Color { Color(red: 0.02, green: 0.05, blue: 0.11) }

    // Sharp poster, with a pre-blurred twin fading in over it. Animating the
    // blur radius itself would re-run a 26pt gaussian pass on every scroll
    // frame; cross-fading two static layers costs one composite.
    //
    // The frosted copy is masked off over the top of the poster, so the status
    // bar area — and the strip of artwork behind it — never goes soft, not even
    // once the list is fully scrolled up. The dimming veil stops at the same
    // line for the same reason: the clock and the notch stay legible.
    private var pinnedHero: some View {
        ZStack(alignment: .top) {
            portraitHero
            portraitHero
                .blur(radius: 26)
                .opacity(heroFade)
                .mask(heroTopExclusion)
                .allowsHitTesting(false)
            nightInk
                .opacity(heroFade * 0.66)
                .mask(heroTopExclusion)
                .allowsHitTesting(false)
        }
        .frame(width: pageWidth, height: heroHeight, alignment: .top)
    }

    // Everything below ~11% of the poster's height, nothing above it.
    private var heroTopExclusion: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .clear, location: 0.11),
            .init(color: .black, location: 0.25)
        ], startPoint: .top, endPoint: .bottom)
    }

    // The list's own surface. Transparent at its top edge, solid 56pt below it.
    // Not fully opaque on purpose: the poster keeps showing through as it dims,
    // so the list reads as a sheet laid over it rather than a black wall.
    private var listSurface: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [nightInk.opacity(0), nightInk.opacity(0.74)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
            nightInk.opacity(0.74)
        }
    }

    private var heroCaption: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            heroText(compact: false)
            runButton(compact: false)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
            // Keeps the CTA off the fade at the bottom of the artwork.
            Spacer().frame(height: 38)
        }
        .frame(width: pageWidth, height: heroHeight)
        .opacity(max(0, 1 - heroFade * 1.5))
        .allowsHitTesting(heroFade < 0.12)
        // The page pins the dark scheme (see portraitPage); this view sits
        // outside the scroll view now, so it has to carry the same pin for the
        // frosted run pill.
        .environment(\.colorScheme, .dark)
    }

    // MARK: Poster ownership

    private func applyCustomCover(_ image: UIImage) {
        guard let app = coverTarget else { return }
        if LCGalleryCustomCoverStore.shared.save(image, for: app) {
            coverTick += 1
        }
        coverTarget = nil
    }

    private func restoreDefaultCover() {
        guard let app = coverTarget else { return }
        LCGalleryCustomCoverStore.shared.remove(for: app)
        // The poster goes back to the official artwork, and the button colour
        // has to leave the old picture's palette at the same time.
        LCGalleryColorStore.shared.invalidateAll()
        coverTick += 1
        coverTarget = nil
    }

    // MARK: Page metrics

    // Same rhythm as the system's own page margins.
    private var sideMargin: CGFloat { 18 }

    // MARK: Ambient backdrop

    // Full-screen blurred poster. Sharp hero on top, this ambient colour below,
    // so the list reads as one continuous surface instead of a hard navy block.
    @ViewBuilder
    private var galleryBackdrop: some View {
        // Always the night backdrop, in both orientations. Portrait pins its
        // list dark on purpose; landscape was asked to stay exactly as it is,
        // so the turn never repaints the page. Only the glass the posters are
        // framed in follows the system, and it does that by itself — it is a
        // live glass material and nothing pins its scheme.
        GeometryReader { geo in
            ZStack {
                Color(red: 0.02, green: 0.05, blue: 0.11)
                if current < apps.count {
                    let app = apps[current]
                    Image(uiImage: LCGalleryCoverStore.shared.cover(for: app))
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width * 1.3, height: geo.size.height * 1.3)
                        .blur(radius: 42)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.5))
                        .id("backdrop-\(app.appInfo.bundleIdentifier() ?? "\(current)")-\(coverTick)")
                        .transition(.opacity)
                }
                LinearGradient(colors: [
                    Color.black.opacity(0.10),
                    Color.black.opacity(0.28),
                    Color.black.opacity(0.55)
                ], startPoint: .top, endPoint: .bottom)
            }
            // The frosted backdrop changes with the poster, and the page is
            // almost entirely this colour. Swapping it on the pager's own 0.42s
            // spring meant the whole screen changed hue in under half a second —
            // a flash on every swipe. It dissolves on its own slow curve now,
            // independently of how fast the row moves.
            .animation(.easeInOut(duration: 1.15), value: current)
            .animation(.easeInOut(duration: 1.15), value: coverTick)
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    // "主页" title removed: the poster starts at the very top edge, so a page
    // title would either collide with the clock or eat hero height.

    // Original LC app-list toolbar, restyled as two frosted capsules.
    private var topMenus: some View {
        HStack(alignment: .top) {
            HStack(spacing: 8) {
                if canInstall {
                    if isInstalling {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .frame(width: 28, height: 28)
                    } else {
                        Menu {
                            Button("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus", action: onInstallIPA)
                            Button("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus", action: onInstallURL)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                    }
                }
                Button(action: onOpenSideStoreOrHelp) {
                    if let sideStoreIcon {
                        Image(uiImage: sideStoreIcon)
                            .resizable().scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 20))
                            .frame(width: 28, height: 28)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button(action: onOpenLink) {
                    Image(systemName: "link")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                Menu {
                    Picker("Sort by", selection: Binding(
                        get: { sortType },
                        set: { onSortChange($0) }
                    )) {
                        ForEach(AppSortType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .onChange(of: sortType) { newValue in
                        if newValue == .custom { onCustomSort() }
                    }
                    if sortType == .custom {
                        Divider()
                        Button {
                            onCustomSort()
                        } label: {
                            Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .foregroundStyle(Color.black.opacity(0.86))
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    // MARK: Hero carousel — full-bleed official poster, iOS 27 style

    // Portrait width. There are no horizontal safe-area insets in portrait, so
    // the screen width is exactly the page width — and unlike a cached
    // measurement it can never be one rotation behind. Landscape takes its own
    // width from the live GeometryReader instead.
    private var pageWidth: CGFloat { UIScreen.main.bounds.width }

    private var heroHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.66, 620)
    }

    private var portraitHero: some View {
        let width = pageWidth
        let height = heroHeight
        // Artwork only. The name and the run button used to be stacked on top
        // of it here, but the poster is pinned now and the list slides over it,
        // so type living inside this layer would be buried by the scroll view.
        // They are drawn above the list instead — see heroCaption.
        return heroBackground(width: width, height: height)
            // Bottom-aligned so the taller stretched background grows upwards
            // and keeps its bottom edge glued to the hero. Not clipped on
            // purpose: clipping here would cut exactly that fill.
            .frame(width: width, height: height, alignment: .bottom)
    }

    // MARK: Landscape showcase — three posters per page, hand-swiped

    private func landscapeCardSize(in viewport: CGSize) -> CGSize {
        let sideMargin = landscapeCardSideMargin
        let spacing = landscapeCardGap
        let topGap: CGFloat = 8
        let bottomGap: CGFloat = 8

        let availW = max(240, viewport.width - 2 * sideMargin)
        let availH = max(180, viewport.height - topGap - bottomGap)

        // The card is a glass panel with the cover inset inside it, so the card
        // has to be a little wider than the artwork it holds. Two and a half
        // posters share a page: one full card plus a slice of each neighbour.
        // Three per page forced the card down to ~266pt and the inset panel
        // then shrank the cover again — this is the only way for the poster to
        // read large on an 874pt-wide screen.
        let perPage = landscapeCardsPerPage
        let cardW = (availW - spacing * (perPage - 1)) / perPage
        let inset = landscapeCardInset
        let stripH = landscapeStripHeight
        let artH = max(40, (cardW - inset * 2) * 9 / 16)

        // The mirror under the card is 24% of its height (capped at 100pt), so
        // card + reflection together have to fit the free height.
        let reflShare: CGFloat = 0.24
        // The middle card is the one that has to fit, not the flat one. The
        // focus scale is applied around the card's centre, so whatever it gains
        // it gains half upwards and half downwards — budget the card at the
        // SELECTED size and the row can no longer poke out of the screen.
        let selectedScale = landscapeFocusScale(1)
        let maxCardH = (availH - 14) / ((1 + reflShare) * selectedScale)
        // Glass padding on top, the 16:9 cover, then the title strip — the
        // strip is the bottom edge of the panel, so it carries no padding.
        let natural = inset + artH + stripH
        return CGSize(width: cardW,
                      height: max(min(natural, maxCardH), inset + stripH + 60))
    }

    // How many posters share one page. 2.4 = one full card plus a cropped
    // slice of each neighbour.
    private var landscapeCardsPerPage: CGFloat { 2.4 }

    private var landscapeCardSideMargin: CGFloat { 14 }

    // Gap between two posters. Wide enough that the enlarged centred card keeps
    // a clean ~20pt to its neighbours.
    private var landscapeCardGap: CGFloat { 16 }

    // Padding between the glass panel's edge and the artwork inside it. This is
    // what makes the panel read as a plate the poster sits on.
    private var landscapeCardInset: CGFloat { 8 }

    // Height of the title strip: game name on the left, round run button on the
    // right. Deliberately short — the panel should not grow a second poster's
    // worth of empty glass underneath.
    private var landscapeStripHeight: CGFloat { 46 }

    // Corner radius of the glass panel; the artwork inside is inset from it.
    private var landscapeCardRadius: CGFloat { 24 }

    // Height of the mirrored copy below a card of the given height. A touch
    // taller than before (24%, capped at 100pt): the reflection needs enough
    // of a fade to melt, and 20% ended it in a visible line.
    private func landscapeReflectionHeight(for cardHeight: CGFloat) -> CGFloat {
        min(100, cardHeight * 0.24)
    }

    // Scale a landscape poster by how centred it is. The selected card is the
    // one that has to fit on screen, so `landscapeCardSize` budgets for
    // `landscapeFocusScale(1)` — see there.
    private func landscapeFocusScale(_ focus: CGFloat) -> CGFloat {
        // 1.10 when centred, 0.88 for the two beside it. The base card is much
        // larger now (343 vs 266), so the selected one is bigger in absolute
        // terms even though it is scaled less — and the stage, not the halo,
        // is what really marks it.
        0.88 + 0.22 * focus
    }

    // Landscape is its own screen: exactly three posters per page with their
    // mirror image puddling underneath, no auto-advance, no dock. Width decides
    // the card — a third of the safe width minus the two gaps — and only then
    // is the height whatever the mirrored copy leaves.
    private func landscapeShowcase(in viewport: CGSize) -> some View {
        let size = landscapeCardSize(in: viewport)
        let spacing = landscapeCardGap
        let reflH = landscapeReflectionHeight(for: size.height)
        // Index 0 already sits centred, so every step further along the row is
        // exactly one card-width plus one gap.
        let step = size.width + spacing
        // Half a screen of side padding is what lets the FIRST and the LAST
        // poster reach the middle; it matches exactly half the leftover width.
        let sidePad = max(16, (viewport.width - size.width) / 2)
        let count = max(apps.count, 1)
        let index = min(max(current, 0), count - 1)

        // Paging used to be handed to a snapping ScrollView, and swiping right
        // kept dying on it: the scroll-position binding wrote back into
        // `current` while the finger was still down, so the row fought the
        // drag. The offset is owned outright here, which makes both directions
        // plain arithmetic — and lets the drag rubber-band at the two ends.
        let rowX = -CGFloat(index) * step + dragX

        return ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                HStack(spacing: spacing) {
                    landscapeCards(size: size, spacing: spacing)
                }
                .padding(.horizontal, sidePad)
                .frame(width: viewport.width, alignment: .leading)
                .offset(x: rowX)
                .frame(width: viewport.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(landscapeSwipe(step: step, count: count))
                // Room for the mirror, so the composition (card + reflection) is
                // what ends up centred on the screen.
                Spacer(minLength: reflH + 10)
            }
            .frame(width: viewport.width, height: viewport.height)
        }
        .frame(width: viewport.width, height: viewport.height)
    }

    // Hand-rolled paging: follow the finger, then commit to whichever
    // neighbour it was already heading towards. Velocity (the predicted end)
    // decides, like the system pager, so even a short flick turns the page.
    private func landscapeSwipe(step: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                var t = value.translation.width
                // Rubber band at both ends, so the row has stops instead of
                // sliding the posters off into nothing.
                if (current <= 0 && t > 0) || (current >= count - 1 && t < 0) {
                    t *= 0.24
                }
                // Written with an animation-free transaction on purpose. An
                // implicit animation living on an ancestor interpolates every
                // one of these per-frame writes, so the row trails the finger by
                // a frame or two — felt as a hitch at the start of every swipe,
                // and as a row that keeps drifting after the finger stops.
                var tx = Transaction()
                tx.animation = nil
                withTransaction(tx) { dragX = t }
            }
            .onEnded { value in
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                // A mostly vertical drag belongs to the page, not the row.
                guard abs(dx) > abs(value.translation.height)
                        || abs(predicted) > abs(value.predictedEndTranslation.height) else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { dragX = 0 }
                    return
                }
                // A quarter of a card is enough, and the predicted end makes a
                // short flick count as a full page.
                let trigger = max(14, step * 0.2)
                var target = current
                if predicted < -trigger || dx < -trigger { target += 1 }
                else if predicted > trigger || dx > trigger { target -= 1 }
                target = min(max(0, target), count - 1)
                withAnimation(.interpolatingSpring(stiffness: 300, damping: 30)) {
                    current = target
                    dragX = 0
                }
            }
    }

    @ViewBuilder
    private func landscapeCards(size: CGSize, spacing: CGFloat) -> some View {
        // Focus is continuous, not binary. A card's scale and opacity are
        // derived from how far it currently sits from the middle of the
        // viewport, offset included — so while the finger is down the posters
        // breathe with it instead of waiting for the page to commit. That is
        // what makes the swipe read as one motion.
        let step = max(1, size.width + spacing)
        let pos = CGFloat(current) - dragX / step
        ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
            let distance = abs(CGFloat(index) - pos)
            let focus = max(0, 1 - distance)
            landscapePosterCard(app: app, width: size.width, height: size.height,
                                isCurrent: index == current)
                .scaleEffect(landscapeFocusScale(focus), anchor: .center)
                .opacity(0.62 + 0.38 * focus)
                // Ordering is a discrete decision, not a continuous one. A
                // floating zIndex re-sorts the layer stack on every frame of a
                // drag; the centred card simply stays on top and the neighbours
                // never reorder at all.
                .zIndex(index == current ? 1 : 0)
                .contentShape(RoundedRectangle(cornerRadius: landscapeCardRadius, style: .continuous))
                // Tapping any poster walks it to the middle — the row is a
                // picker, not a slideshow that only a swipe can drive.
                .onTapGesture {
                    guard index != current else { return }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        current = index
                        dragX = 0
                    }
                }
                .id(index)
        }
    }

    // One 16:9 poster with the icon, name and 运行 on their own glass strip
    // underneath. `isCurrent` drives the selection — the card the page is
    // centred on is scaled up, the others stay put and dim.
    private func landscapePosterCard(app: LCAppModel, width: CGFloat, height: CGFloat,
                                     isCurrent: Bool) -> some View {
        let key = app.appInfo.bundleIdentifier() ?? app.displayName
        // The wall has its own slot. It asks for the official channel first —
        // Nintendo's own key art — because that is where the posters are meant
        // to come from now; see `LCGalleryOnlineCoverStore.fetchCover`.
        let cover = LCGalleryCoverStore.shared.cover(for: app, wide: true)
        let tint = LCGalleryColorStore.shared.color(for: app)
        // The card is a liquid-glass plate: the cover sits inset inside it and
        // the title strip is the bottom of that same plate, not a second bar
        // glued underneath.
        let radius = landscapeCardRadius
        let reflH = landscapeReflectionHeight(for: height)

        return ZStack(alignment: .bottom) {
            landscapeCardArt(cover: cover, key: key,
                             size: CGSize(width: width, height: height),
                             radius: radius,
                             inset: landscapeCardInset,
                             stripHeight: landscapeStripHeight)

            // Game name on the glass, round run button on the right. No icon and
            // no second background — the panel behind it already is the glass.
            landscapeInfoBar(app: app, width: width, height: landscapeStripHeight,
                             tint: tint)
                .environment(\.colorScheme, .dark)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.42), radius: 18, y: 10)
        // No halo on the selected card any more: a glowing white bloom around
        // the poster read as an outline stuck onto the artwork. Selection is
        // carried by size, brightness of the card itself and the fact that the
        // stage lifts it out of the row.
        .overlay(alignment: .bottom) {
            if reflH > 4 {
                landscapeMirror(cover: cover, key: key,
                                size: CGSize(width: width, height: height),
                                radius: radius, height: reflH)
                    // Flush against the card: the mirrored edge starts exactly
                    // where the real one ends, like a floor mirror.
                    .offset(y: reflH)
            }
        }
        .animation(.easeInOut(duration: 0.26), value: isCurrent)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.55) {
            coverTarget = app
            coverMenuShown = true
        }
    }

    // The bottom of the glass plate: game name on the left, round controller
    // button on the right. No icon (the cover already says what the game is)
    // and no background of its own — it is drawn straight onto the panel.
    private func landscapeInfoBar(app: LCAppModel, width: CGFloat, height: CGFloat,
                                  tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(app.displayName)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                // Two shadows instead of a dark wash under the strip: a tight
                // one that gives the glyphs an edge on light glass and a wide
                // one that separates them from the backdrop. Invisible on its
                // own — which is the point.
                .shadow(color: .black.opacity(0.50), radius: 2.5, y: 1)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 2)
            Spacer(minLength: 6)
            // Round, icon-only CTA: a controller glyph in the game's own tint.
            Button {
                onLaunch(app)
            } label: {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .lcTintedGlassCapsule(tint: tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("运行 \(app.displayName)")
        }
        .padding(.horizontal, landscapeCardInset + 6)
        .frame(width: width, height: height)
    }

    // The plate: liquid glass panel with the artwork inset inside it, plus the
    // strip's footprint at the bottom. Kept as its own view because the mirror
    // reflects exactly the same object. In the mirror the live glass is a flat
    // translucent stand-in — it is blurred and faded down there anyway, and a
    // second real glass render only costs GPU time.
    private func landscapeCardArt(cover: UIImage, key: String, size: CGSize,
                                  radius: CGFloat, inset: CGFloat,
                                  stripHeight: CGFloat,
                                  mirror: Bool = false) -> some View {
        let innerW = max(1, size.width - inset * 2)
        let artH = max(1, size.height - stripHeight - inset)
        let innerRadius = max(6, radius - inset)

        return ZStack(alignment: .topLeading) {
            // The plate itself.
            if mirror {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.20))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Color.white.opacity(0.42), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius,
                                                               style: .continuous))
                    // The bright rim a real glass plate wears. Thin on purpose:
                    // the earlier 8pt frame read as a box drawn around the art.
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(
                                LinearGradient(colors: [
                                    Color.white.opacity(0.46),
                                    Color.white.opacity(0.14),
                                    Color.white.opacity(0.28)
                                ], startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                            .allowsHitTesting(false)
                    )
            }

            // The cover, inset so the plate shows all the way round.
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .frame(width: innerW, height: artH)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                        .stroke(Color.white.opacity(mirror ? 0.26 : 0.30), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .offset(x: inset, y: inset)
                .id("poster-\(key)-\(coverTick)\(mirror ? "-mirror" : "")")

            // Footprint of the title strip. On the card the live glass shows
            // through; in the mirror it is a flat band, so the reflection ends
            // on the strip instead of on the artwork.
            Rectangle()
                .fill(mirror ? Color.black.opacity(0.26) : Color.clear)
                .frame(width: size.width, height: stripHeight)
                .offset(y: size.height - stripHeight)

            // No scrim over the strip. A darkening gradient lived here so white
            // type survived pale artwork, but any wash strong enough to read as
            // legible turned the bottom of the plate into a black band — the
            // clean glass the plate is made of was gone. Legibility is carried
            // by the label's own shadow now (see landscapeInfoBar), which costs
            // the panel nothing.
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    // Mirror floor under a card: the card's own bottom edge — corners and all —
    // flipped and faded out into the backdrop. The view is flipped around its
    // centre and then cropped to its top band, which after the flip is the
    // original bottom edge: exactly where a real reflection starts.
    private func landscapeMirror(cover: UIImage, key: String, size: CGSize,
                                 radius: CGFloat, height: CGFloat) -> some View {
        landscapeCardArt(cover: cover, key: key, size: size,
                         radius: radius, inset: landscapeCardInset,
                         stripHeight: landscapeStripHeight, mirror: true)
            .scaleEffect(x: 1, y: -1, anchor: .center)
            .frame(width: size.width, height: height, alignment: .top)
            .clipped()
            // The contact shadow that belongs under any object resting on a
            // surface. It lives INSIDE the mask now. Drawn on top of the masked
            // band, it was an unmasked full-width rectangle: its top edge sat
            // flush under the card's bottom edge and filled the notch beside
            // the card's two rounded corners, so the silhouette ended in two
            // hard 90° tips — the "right angle under the poster". Inside the
            // mask it is cut by the same rounded silhouette as the reflection.
            .overlay(alignment: .top) {
                LinearGradient(colors: [
                    Color.black.opacity(0.34),
                    Color.black.opacity(0.10),
                    Color.clear
                ], startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: max(10, height * 0.30))
                .allowsHitTesting(false)
            }
            // Silhouette and fade in a single mask. The band begins exactly on
            // the card's own rounded bottom corners — same radius, same width —
            // so no square tips poke out beside them, and it has faded to
            // nothing well before its own bottom edge, so the square end of the
            // crop can never show either.
            .mask(alignment: .top) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black.opacity(0.70), location: 0.14),
                            .init(color: .black.opacity(0.44), location: 0.30),
                            .init(color: .black.opacity(0.22), location: 0.50),
                            .init(color: .black.opacity(0.07), location: 0.68),
                            .init(color: .clear, location: 0.84)
                        ], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: size.width, height: height)
            }
            // A floor is not a mirror: the near band keeps the artwork's
            // structure, the far band is gone.
            .blur(radius: 5)
            .opacity(0.5)
            .allowsHitTesting(false)
            .animation(nil, value: coverTick)
    }

    @ViewBuilder
    private func heroBackground(width: CGFloat, height: CGFloat) -> some View {
        // While the page is pulled down, the artwork grows by the pull amount.
        // The hero's ZStack is bottom-aligned, so the extra height goes upwards
        // and the bottom edge stays put: the poster zooms slightly and fills the
        // elastic gap at the top, instead of exposing the blurred backdrop.
        let stretch = min(max(pullDown, 0), 340)
        let artHeight = height + stretch

        ZStack {
            if current < apps.count {
                let image = LCGalleryCoverStore.shared.cover(for: apps[current])
                let key = apps[current].appInfo.bundleIdentifier() ?? "\(current)"
                // Sharp, edge-to-edge poster. It used to be blurred for
                // non-portrait covers, which fogged the status bar area too.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: artHeight)
                    .clipped()
                    // Dissolve the bottom of the artwork into the blurred page
                    // colour, so hero and list read as one continuous surface.
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.66),
                            .init(color: .black.opacity(0.86), location: 0.84),
                            .init(color: .clear, location: 1.0)
                        ], startPoint: .top, endPoint: .bottom)
                    )
                    .id("bg-\(key)-\(coverTick)")
            } else {
                LinearGradient(colors: [
                    Color(red: 0.09, green: 0.36, blue: 0.72),
                    Color(red: 0.02, green: 0.08, blue: 0.18)
                ], startPoint: .top, endPoint: .bottom)
            }

            // Scrim only where the caption sits: nothing on top, so the status
            // bar and upper artwork stay crisp. It also fades out at the very
            // bottom to match the artwork mask.
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.46),
                .init(color: Color.black.opacity(0.22), location: 0.70),
                .init(color: Color.black.opacity(0.56), location: 0.87),
                .init(color: .clear, location: 1.0)
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: width, height: artHeight)
        .clipped()
    }

    @ViewBuilder
    private func heroText(compact: Bool) -> some View {
        let _ = metaTick
        if current < apps.count {
            // Name only. The one-line intro used to sit right under it and just
            // doubled the amount of type stacked on the artwork.
            Text(apps[current].displayName)
                .font(.system(size: compact ? 22 : 31, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
        }
    }

    // MARK: Custom poster (long-press the hero)

    private func requestCustomCover() {
        guard current < apps.count else { return }
        coverTarget = apps[current]
        coverMenuShown = true
    }

    // Compact liquid-glass CTA: sized by its own text instead of a fixed
    // 250×46 slab, tinted with the current game's icon colour.
    private func runButton(compact: Bool) -> some View {
        let tint = current < apps.count
            ? LCGalleryColorStore.shared.color(for: apps[current])
            : Color.white
        return Button {
            if current < apps.count { onLaunch(apps[current]) }
        } label: {
            Text("运行游戏")
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 20 : 26)
                .padding(.vertical, compact ? 8 : 10)
                .lcTintedGlassCapsule(tint: tint)
        }
        .buttonStyle(.plain)
    }

    private var heroGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { v in
                // Only while the poster is still on screen. Once the list has
                // covered it, a horizontal drag belongs to whatever is under
                // the finger, not to the carousel — and the gesture is
                // attached to the scroll view now, so it would otherwise fire
                // from anywhere on the page.
                guard heroFade < 0.2 else { return }
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                if v.translation.width < -36 { goSlide(current + 1) }
                else if v.translation.width > 36 { goSlide(current - 1) }
            }
    }

    // MARK: Icon rail

    private var iconRail: some View {
        // Every installed app, not just the first ten: the rail scrolls, and
        // tapping any icon — including ones that start off-screen — drives the
        // poster. The rail also follows the poster when it changes by itself.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                        if let ic = app.appInfo.iconIsDarkIcon(false) {
                            Image(uiImage: ic)
                                .resizable().scaledToFill()
                                .frame(width: 62, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                                    .stroke(index == current ? Color.yellow : Color.clear, lineWidth: 2))
                                .scaleEffect(index == current ? 1.12 : 1)
                                .id(index)
                                .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                                .onTapGesture { goSlide(index) }
                        }
                    }
                }
                // Room for the selected icon's 1.12 scale and its 2pt ring:
                // without this the first and last icons were sliced by the
                // scroll view's own bounds the moment they were highlighted.
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            // Let the enlarged icon overflow the scroll bounds instead of
            // being clipped by them: the rail then has no hard edge at all.
            .scrollClipDisabled()
            .onChange(of: current) { value in
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(value, anchor: .center)
                }
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: Cards

    private var visibleApps: [LCAppModel] {
        let q = searchContext.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return apps }
        return apps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(q) ||
            app.bundleIdentifier.localizedCaseInsensitiveContains(q)
        }
    }

    private var cardColumns: [GridItem] {
        if verticalSizeClass == .compact {
            return [GridItem(.flexible(minimum: 0), spacing: 12),
                    GridItem(.flexible(minimum: 0), spacing: 12)]
        }
        return [GridItem(.flexible(minimum: 0), spacing: 12)]
    }

    private var cardsSection: some View {
        VStack(spacing: 14) {
            HStack {
                Text("全部应用").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text("\(visibleApps.count)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
            LazyVGrid(columns: cardColumns, spacing: 12) {
                ForEach(visibleApps, id: \.self) { app in
                    GalleryCardView(
                        app: app,
                        compact: verticalSizeClass == .compact,
                        coverTick: coverTick,
                        sizeTick: sizeTick,
                        onLaunch: onLaunch,
                        onOpenSettings: onOpenSettings,
                        onUninstall: onUninstall,
                        onSaveIcon: onSaveIcon,
                        onCreateAppClip: onCreateAppClip
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func galleryCard(_ app: LCAppModel) -> some View {
        let key = app.appInfo.bundleIdentifier() ?? UUID().uuidString
        let _ = coverTick
        let _ = sizeTick
        // Cover art stays as a frosted full-bleed backdrop; the row itself is a
        // horizontal layout: icon (left), name + version/size (middle), run (right).
        ZStack {
            Image(uiImage: LCGalleryCoverStore.shared.cover(for: app))
                .resizable().scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 18)
                .scaleEffect(1.15)
                .clipped()
                .id("card-\(key)-\(coverTick)")
            Color.black.opacity(0.42)

            HStack(spacing: 12) {
                if let ic = app.appInfo.iconIsDarkIcon(false) {
                    Image(uiImage: ic).resizable().scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(Color.white.opacity(0.4), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(app.version)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.32), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.6))
                        Text(LCGallerySizeStore.shared.sizeText(for: app))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.32), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.6))
                    }
                }
                Spacer(minLength: 0)
                Button { onLaunch(app) } label: {
                    Text("运行")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 34)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.42), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
        }
        .frame(height: verticalSizeClass == .compact ? 86 : 92)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.white.opacity(0.16), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        .contextMenu {
            // Full native-equivalent menu, matching LCAppBannerViewController.makeContextMenu().
            // 1) Containers picker
            if app.uiContainers.count > 1 {
                Section {
                    ForEach(Array(app.uiContainers.enumerated()), id: \.offset) { _, container in
                        Button {
                            app.uiSelectedContainer = container
                        } label: {
                            Label(container.name,
                                  systemImage: container == app.uiSelectedContainer ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            // 2) Open data folder
            if !app.uiIsShared, app.uiSelectedContainer != nil {
                Button {
                    if let folderName = app.uiSelectedContainer?.folderName,
                       let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folderName)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("lc.appBanner.openDataFolder".loc, systemImage: "folder")
                }
            }
            // 3) Run / Multitask toggle
            if #available(iOS 16.0, *) {
                Button {
                    Task { try? await app.runApp(multitask: !app.shouldLaunchInMultitaskMode) }
                } label: {
                    Label(app.shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
                          systemImage: app.shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus")
                }
            }
            // 4) Add to Home Screen submenu
            Menu {
                Button {
                    let relative = app.appInfo.relativeBundlePath ?? ""
                    if let folderName = app.uiSelectedContainer?.folderName {
                        UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relative)&container-folder-name=\(folderName)"
                    } else {
                        UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relative)"
                    }
                } label: {
                    Label("lc.appBanner.copyLaunchUrl".loc, systemImage: "link")
                }
                Button { onSaveIcon(app) } label: {
                    Label("lc.appBanner.saveAppIcon".loc, systemImage: "square.and.arrow.down")
                }
                Button { onCreateAppClip(app) } label: {
                    Label("lc.appBanner.createAppClip".loc, systemImage: "appclip")
                }
            } label: {
                Label("lc.appBanner.addToHomeScreen".loc, systemImage: "plus.app")
            }
            // 5) Settings
            Button {
                onOpenSettings(app)
            } label: {
                Label("lc.tabView.settings".loc, systemImage: "gear")
            }
            // 6) Uninstall (destructive), matching native visibility rule
            if !app.uiIsShared {
                Button(role: .destructive) {
                    onUninstall(app)
                } label: {
                    Label("lc.appBanner.uninstall".loc, systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var hiddenSection: some View {
        if !hiddenApps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("隐藏的应用").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                ForEach(hiddenApps, id: \.self) { app in
                    HStack {
                        if let ic = app.appInfo.iconIsDarkIcon(false) {
                            Image(uiImage: ic).resizable().scaledToFit().frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        Text(app.displayName).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var searchPanel: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { closeSearch() }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.85))
                    TextField("搜索游戏", text: $searchContext.query)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .submitLabel(.done)
                    if !searchContext.query.isEmpty {
                        Button { searchContext.query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    Button("取消") { closeSearch() }
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.32), lineWidth: 1))

                if !searchContext.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if visibleApps.isEmpty {
                                Text("没有找到游戏")
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            } else {
                                ForEach(visibleApps.prefix(20), id: \.self) { app in
                                    Button {
                                        closeSearch()
                                        onLaunch(app)
                                    } label: {
                                        HStack(spacing: 10) {
                                            if let icon = app.appInfo.iconIsDarkIcon(false) {
                                                Image(uiImage: icon).resizable().scaledToFill()
                                                    .frame(width: 34, height: 34)
                                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            }
                                            Text(app.displayName)
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "arrow.up.right")
                                                .foregroundStyle(.white.opacity(0.6))
                                        }
                                        .padding(.horizontal, 12)
                                        .frame(height: 50)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 280)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.26), lineWidth: 1))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 66)
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private func closeSearch() {
        searchExpanded = false
        searchContext.query = ""
    }

    // MARK: Selected poster memory

    // Keyed by bundle id rather than by index: sorting, installing or removing
    // an app shifts indices, a bundle id follows the game.
    private static let heroSelectionKey = "LCGalleryHeroSelectedBundleID"

    private func restoreHeroSelection() {
        guard let bid = UserDefaults.standard.string(forKey: Self.heroSelectionKey),
              !bid.isEmpty,
              let index = apps.firstIndex(where: { $0.bundleIdentifier == bid }),
              index != current else { return }
        current = index
    }

    private func rememberHeroSelection() {
        guard current >= 0, current < apps.count else { return }
        UserDefaults.standard.set(apps[current].bundleIdentifier,
                                  forKey: Self.heroSelectionKey)
    }

    private func goSlide(_ i: Int) {
        let n = slideCount
        guard n > 0 else { return }
        current = ((i % n) + n) % n
    }
}

// MARK: - Scroll offset reader

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct GalleryOffsetReader: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ScrollOffsetKey.self, value: -geo.frame(in: .named("galleryScroll")).minY)
        }
    }
}
