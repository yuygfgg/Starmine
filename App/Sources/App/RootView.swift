import Combine
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

private enum MobileRootTab: Hashable {
    case home
    case files
    case library
    case player
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var playbackHost = MPVVideoHostBridge()
    @State private var importerPresented = false
    @State private var subtitleImporterPresented = false
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var pendingSeekPosition: Double?
    @State private var pendingSeekResetTask: Task<Void, Never>?
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var playbackChromeVisible = false
    @State private var playbackChromeAutoHideTask: Task<Void, Never>?
    @State private var workspaceSection: WorkspaceSection = .home
    @State private var jellyfinLibrarySearch = ""
    @State private var hasActivePlayback = false
    @State private var lastObservedPlaybackURL: URL?
    @State private var currentPlaybackTitle = "Starmine"
    @State private var currentPlaybackEpisodeLabel = ""
    @State private var playbackDanmakuEnabled = true
    @State private var playbackIsRemote = false
    @State private var playbackPaused = true
    @State private var playbackVideoAspect = 0.0
    @State private var playbackPreferences = PlaybackPreferences.default
    @State private var selectedAudioTrackTitle: String?
    @State private var selectedSubtitleTrackTitle: String?
    @State private var lastPlaybackSurfaceSize: CGSize = .zero
    @State private var playbackHostRemountTask: Task<Void, Never>?
    @State private var surfaceScrubStartPosition: Double?
    @State private var surfaceLongPressSpeedActive = false
    #if !os(macOS)
        @State private var mobileTab: MobileRootTab = .home
        @State private var isIOSVideoFullscreen = false
        @State private var mobileDanmakuSheetPresented = false
    #endif
    #if os(macOS)
        @State private var isWindowFullscreen = false
        @State private var isVideoFullscreen = false
        @State private var pendingVideoFullscreenEntry = false
        @State private var videoFullscreenOwnsWindowFullscreen = false
        @State private var macDanmakuSheetPresented = false
        @State private var isPresentingMacVideoOpenPanel = false
        @State private var isPresentingMacSubtitleOpenPanel = false
        @State private var splitViewVisibilityBeforeVideoFullscreen:
            NavigationSplitViewVisibility?
    #endif

    private var playback: PlaybackStore { coordinator.playback }
    private var danmaku: DanmakuFeatureStore { coordinator.danmaku }
    private var jellyfin: JellyfinStore { coordinator.jellyfin }
    private var videoImportTypes: [UTType] {
        [
            .movie, .video, .mpeg4Movie, .quickTimeMovie,
        ]
    }
    private var subtitleImportTypes: [UTType] {
        [
            UTType(filenameExtension: "ass"),
            UTType(filenameExtension: "ssa"),
            UTType(filenameExtension: "srt"),
            UTType(filenameExtension: "vtt"),
            UTType(filenameExtension: "sub"),
            UTType(filenameExtension: "ttml"),
        ]
        .compactMap { $0 }
    }

    @ViewBuilder
    private var importAwareRootContent: some View {
        #if os(macOS)
            rootContent
                .onChange(of: importerPresented) { presented in
                    guard presented else { return }
                    presentMacVideoOpenPanelIfNeeded()
                }
                .onChange(of: subtitleImporterPresented) { presented in
                    guard presented else { return }
                    presentMacSubtitleOpenPanelIfNeeded()
                }
        #else
            rootContent
        #endif
    }

    var body: some View {
        importAwareRootContent
            .alert(item: $coordinator.errorState) { errorState in
                Alert(title: Text("请求失败"), message: Text(errorState.message))
            }
            #if os(macOS)
                .sheet(isPresented: $macDanmakuSheetPresented) {
                    macDanmakuSheet
                }
            #endif
            .onReceive(playback.$snapshot.map(\.position).removeDuplicates()) {
                newValue in
                guard !isScrubbing else { return }
                if let pendingSeekPosition {
                    if abs(newValue - pendingSeekPosition) <= 0.75 {
                        clearPendingSeek(syncTo: newValue)
                    }
                }
            }
            .onReceive(playback.$currentVideoURL.removeDuplicates()) {
                newValue in
                let previousValue = lastObservedPlaybackURL
                lastObservedPlaybackURL = newValue
                hasActivePlayback = newValue != nil
                // Ignore repeated current-value emissions when SwiftUI rebuilds the view.
                guard previousValue != newValue else { return }
                resetSurfaceInteractionState(resetPlaybackRate: true)
                clearPendingSeek(syncTo: 0)
                if newValue == nil {
                    #if os(macOS)
                        dismissVideoFullscreenIfNeeded()
                        macDanmakuSheetPresented = false
                    #else
                        setIOSVideoFullscreen(false)
                        mobileDanmakuSheetPresented = false
                    #endif
                    hidePlaybackChrome()
                    if let activeID = coordinator.activeJellyfinAccount?.id {
                        workspaceSection = .library(activeID)
                        #if !os(macOS)
                            mobileTab = .library
                        #endif
                    } else {
                        workspaceSection = .home
                        #if !os(macOS)
                            mobileTab = .home
                        #endif
                    }
                } else {
                    workspaceSection = .player
                    #if !os(macOS)
                        mobileTab = .player
                        showPlaybackChrome()
                        schedulePlaybackChromeAutoHide()
                    #endif
                }
            }
            .onReceive(playback.$currentVideoTitle.removeDuplicates()) {
                newValue in
                currentPlaybackTitle = newValue
            }
            .onChange(of: scenePhase) { newValue in
                guard newValue == .active else { return }
                coordinator.handleJellyfinAppDidBecomeActive()
            }
            .onReceive(playback.$currentEpisodeLabel.removeDuplicates()) {
                newValue in
                currentPlaybackEpisodeLabel = newValue
            }
            .onReceive(playback.$danmakuEnabled.removeDuplicates()) {
                newValue in
                playbackDanmakuEnabled = newValue
            }
            .onReceive(playback.$isPlayingRemote.removeDuplicates()) {
                newValue in
                playbackIsRemote = newValue
            }
            .onReceive(playback.$preferences.removeDuplicates()) { newValue in
                playbackPreferences = newValue
            }
            #if !os(macOS)
                .onAppear {
                    guard !isIOSVideoFullscreen else { return }
                    StarmineiOSOrientationController
                    .restoreDefaultOrientationBehavior()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didBecomeActiveNotification
                    )
                ) { _ in
                    guard !isIOSVideoFullscreen else { return }
                    StarmineiOSOrientationController
                    .restoreDefaultOrientationBehavior()
                }
            #endif
            .onReceive(
                playback.$snapshot.map(PlaybackSurfaceState.init(snapshot:))
                    .removeDuplicates()
            ) { state in
                playbackPaused = state.paused
                playbackVideoAspect = state.videoAspect
            }
            .onReceive(
                playback.$selectedAudioTrackID
                    .combineLatest(playback.$audioTracks)
                    .map { selectedID, tracks in
                        tracks.first(where: { $0.mpvID == selectedID })?.title
                    }
                    .removeDuplicates()
            ) { newValue in
                selectedAudioTrackTitle = newValue
            }
            .onReceive(
                playback.$selectedSubtitleTrackID
                    .combineLatest(playback.$subtitleTracks)
                    .map { selectedID, tracks in
                        tracks.first(where: { $0.mpvID == selectedID })?.title
                    }
                    .removeDuplicates()
            ) { newValue in
                selectedSubtitleTrackTitle = newValue
            }
            .onChange(of: jellyfin.selectedAccountID) { newValue in
                guard !hasActivePlayback else { return }

                switch workspaceSection {
                case .library:
                    if let newValue {
                        workspaceSection = .library(newValue)
                        #if !os(macOS)
                            mobileTab = .library
                        #endif
                    } else {
                        workspaceSection = .home
                        #if !os(macOS)
                            mobileTab = .home
                        #endif
                    }
                default:
                    break
                }
            }
            .onChange(of: jellyfin.selectedLibraryID) { _ in
                jellyfinLibrarySearch = ""
            }
            .onChange(of: workspaceSection) { newValue in
                #if !os(macOS)
                    switch newValue {
                    case .home: mobileTab = .home
                    case .files: mobileTab = .files
                    case .library: mobileTab = .library
                    case .player: mobileTab = .player
                    }
                #endif
            }
            #if !os(macOS)
                .onChange(of: mobileDanmakuSheetPresented) { presented in
                    if presented {
                        playbackHostRemountTask?.cancel()
                        playbackHostRemountTask = nil
                        cancelPlaybackChromeAutoHide()
                    } else if hasActivePlayback {
                        showPlaybackChrome()
                        schedulePlaybackChromeAutoHide()
                    }
                }
                .onChange(of: mobileTab) { newValue in
                    if newValue != .player, isIOSVideoFullscreen {
                        setIOSVideoFullscreen(false)
                    }
                    switch newValue {
                    case .home:
                        workspaceSection = .home
                    case .files:
                        workspaceSection = .files
                    case .library:
                        if let id = coordinator.activeJellyfinAccount?.id {
                            workspaceSection = .library(id)
                        }
                    case .player:
                        workspaceSection = .player
                    }
                }
            #endif
            .onDisappear {
                resetSurfaceInteractionState(resetPlaybackRate: true)
                cancelPlaybackChromeAutoHide()
                pendingSeekResetTask?.cancel()
                pendingSeekResetTask = nil
                playbackHostRemountTask?.cancel()
                playbackHostRemountTask = nil
                #if os(macOS)
                    setPlaybackCursorHidden(false)
                #endif
            }
            #if os(macOS)
                .modifier(
                    WindowToolbarFullscreenBehavior(
                        isVideoFullscreen: isVideoFullscreen
                    )
                )
                .background(
                    PlaybackShortcutMonitor(
                        onTogglePause: {
                            guard hasActivePlayback else { return }
                            coordinator.togglePause()
                        },
                        onToggleDanmaku: {
                            guard hasActivePlayback else { return }
                            notePlaybackInteraction()
                            playback.danmakuEnabled.toggle()
                        },
                        onCaptureScreenshot: {
                            guard hasActivePlayback else { return }
                            captureScreenshotAction()
                        },
                        onToggleFullscreen: {
                            guard hasActivePlayback else { return }
                            toggleVideoFullscreen()
                        },
                        onSeekBackward: {
                            guard hasActivePlayback else { return }
                            beginOptimisticSeek(
                                to: displayedPlaybackPosition
                                    - playbackPreferences.seekInterval
                            )
                        },
                        onSeekForward: {
                            guard hasActivePlayback else { return }
                            beginOptimisticSeek(
                                to: displayedPlaybackPosition
                                    + playbackPreferences.seekInterval
                            )
                        },
                        onWindowWillClose: {
                            coordinator.handleWindowClosing()
                        }
                    )
                )
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.didEnterFullScreenNotification
                    )
                ) { _ in
                    isWindowFullscreen = true
                    playbackHostRemountTask?.cancel()
                    playbackHostRemountTask = nil
                    cancelPlaybackChromeAutoHide()
                    playbackChromeVisible = false
                    setPlaybackCursorHidden(false)
                    if pendingVideoFullscreenEntry {
                        pendingVideoFullscreenEntry = false
                        isVideoFullscreen = true
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.didExitFullScreenNotification
                    )
                ) { _ in
                    isWindowFullscreen = false
                    playbackHostRemountTask?.cancel()
                    playbackHostRemountTask = nil
                    cancelPlaybackChromeAutoHide()
                    playbackChromeVisible = false
                    setPlaybackCursorHidden(false)
                    if pendingVideoFullscreenEntry {
                        pendingVideoFullscreenEntry = false
                        videoFullscreenOwnsWindowFullscreen = false
                        restoreSplitViewVisibilityAfterVideoFullscreen()
                    } else if isVideoFullscreen
                        || videoFullscreenOwnsWindowFullscreen
                    {
                        videoFullscreenOwnsWindowFullscreen = false
                        isVideoFullscreen = false
                        restoreSplitViewVisibilityAfterVideoFullscreen()
                    } else {
                        videoFullscreenOwnsWindowFullscreen = false
                    }
                }
                .onChange(of: isWindowFullscreen) { _ in
                    playbackHost.remountHost()
                }
            #endif
    }

    @ViewBuilder
    private var rootContent: some View {
        #if os(macOS)
            if usesImmersivePlaybackRoot {
                detail
            } else {
                splitViewContent
            }
        #else
            mobileTabContent
        #endif
    }

    #if !os(macOS)
        private var mobileTabContent: some View {
            TabView(selection: $mobileTab) {
                NavigationStack {
                    ZStack {
                        Palette.canvas.ignoresSafeArea()
                        homeScreenPlaceholder
                    }
                    .navigationTitle("主页")
                }
                .fileImporter(
                    isPresented: activeVideoImporterBinding(for: .home),
                    allowedContentTypes: videoImportTypes,
                    allowsMultipleSelection: false,
                    onCompletion: handleVideoImportResult
                )
                .tabItem {
                    Label("主页", systemImage: "house.fill")
                }
                .tag(MobileRootTab.home)

                NavigationStack {
                    FilesWorkspaceView(
                        coordinator: coordinator,
                        jellyfin: jellyfin,
                        importerPresented: $importerPresented,
                        workspaceSection: $workspaceSection,
                        prefersTouchLayout: true
                    )
                    .navigationTitle("文件")
                }
                .fileImporter(
                    isPresented: activeVideoImporterBinding(for: .files),
                    allowedContentTypes: videoImportTypes,
                    allowsMultipleSelection: false,
                    onCompletion: handleVideoImportResult
                )
                .tabItem {
                    Label("文件", systemImage: "folder.fill")
                }
                .tag(MobileRootTab.files)

                NavigationStack {
                    mobileLibraryScreen
                }
                .tabItem {
                    Label(
                        "媒体库",
                        systemImage: "rectangle.stack.badge.play.fill"
                    )
                }
                .tag(MobileRootTab.library)

                NavigationStack {
                    mobilePlayerScreen
                }
                .fileImporter(
                    isPresented: activeVideoImporterBinding(for: .player),
                    allowedContentTypes: videoImportTypes,
                    allowsMultipleSelection: false,
                    onCompletion: handleVideoImportResult
                )
                .fileImporter(
                    isPresented: activeSubtitleImporterBinding(for: .player),
                    allowedContentTypes: subtitleImportTypes,
                    allowsMultipleSelection: false,
                    onCompletion: handleSubtitleImportResult
                )
                .tabItem {
                    Label(
                        "播放器",
                        systemImage: hasActivePlayback
                            ? "play.rectangle.fill" : "play.rectangle"
                    )
                }
                .tag(MobileRootTab.player)
            }
            .tint(Palette.accentDeep)
        }

        private var mobileLibraryScreen: some View {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                LibraryWorkspaceView(
                    coordinator: coordinator,
                    jellyfin: jellyfin,
                    hasActivePlayback: hasActivePlayback,
                    workspaceSection: $workspaceSection,
                    jellyfinLibrarySearch: $jellyfinLibrarySearch,
                    showsInlineSelectionToolbar: true,
                    prefersTouchLayout: true
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .navigationTitle("媒体库")
            .toolbar {
                if hasActivePlayback {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            mobileTab = .player
                        } label: {
                            Image(systemName: "play.rectangle.fill")
                        }
                    }
                }
            }
        }

        private func activeVideoImporterBinding(for tab: MobileRootTab)
            -> Binding<Bool>
        {
            Binding(
                get: {
                    importerPresented && mobileTab == tab
                },
                set: { newValue in
                    if newValue {
                        guard mobileTab == tab else { return }
                        importerPresented = true
                    } else {
                        importerPresented = false
                    }
                }
            )
        }

        private func activeSubtitleImporterBinding(for tab: MobileRootTab)
            -> Binding<Bool>
        {
            Binding(
                get: {
                    subtitleImporterPresented && mobileTab == tab
                },
                set: { newValue in
                    if newValue {
                        guard mobileTab == tab else { return }
                        subtitleImporterPresented = true
                    } else {
                        subtitleImporterPresented = false
                    }
                }
            )
        }

        private var mobilePlayerScreen: some View {
            ZStack {
                (hasActivePlayback ? Color.black : Palette.canvas)
                    .ignoresSafeArea()

                if hasActivePlayback {
                    GeometryReader { proxy in
                        playbackStage(
                            in: proxy.size,
                            isImmersive: isIOSVideoFullscreen
                                || proxy.size.width > proxy.size.height
                        )
                    }
                    .ignoresSafeArea(
                        .container,
                        edges: isIOSVideoFullscreen ? .all : []
                    )
                } else {
                    placeholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 24)
                }
            }
            .navigationTitle("播放器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(
                isIOSVideoFullscreen ? .hidden : .visible,
                for: .navigationBar
            )
            .toolbar(isIOSVideoFullscreen ? .hidden : .visible, for: .tabBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(
                hasActivePlayback ? Color.black.opacity(0.92) : Palette.canvas,
                for: .navigationBar
            )
            .toolbarColorScheme(
                hasActivePlayback ? .dark : .light,
                for: .navigationBar
            )
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if hasActivePlayback {
                        Button {
                            subtitleImporterPresented = true
                        } label: {
                            Image(systemName: "captions.bubble.fill")
                        }

                        Button {
                            showMobileDanmakuSheet()
                        } label: {
                            Image(systemName: "text.magnifyingglass")
                        }
                    }

                    Button {
                        importerPresented = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }

                    if coordinator.activeJellyfinAccount != nil {
                        Button {
                            mobileTab = .library
                        } label: {
                            Image(systemName: "rectangle.stack.badge.play.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $mobileDanmakuSheetPresented) {
                mobileDanmakuSheet
            }
        }

        private var mobileDanmakuSheet: some View {
            NavigationStack {
                ScrollView {
                    if hasActivePlayback {
                        DanmakuPanelView(
                            coordinator: coordinator,
                            playback: playback,
                            danmaku: danmaku,
                            prefersTouchLayout: true
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 28)
                    } else {
                        Text("开始播放后再替换弹幕。")
                            .font(
                                .system(
                                    size: 15,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                }
                .background(Palette.sidebarBackground.ignoresSafeArea())
                .navigationTitle("弹幕")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") {
                            mobileDanmakuSheetPresented = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    #endif

    #if os(macOS)
        private var splitViewContent: some View {
            NavigationSplitView(columnVisibility: $splitViewVisibility) {
                SidebarView(
                    coordinator: coordinator,
                    playback: playback,
                    danmaku: danmaku,
                    jellyfin: jellyfin,
                    importerPresented: $importerPresented,
                    workspaceSection: $workspaceSection
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
        }

        private var macDanmakuSheet: some View {
            NavigationStack {
                ScrollView {
                    if hasActivePlayback {
                        DanmakuPanelView(
                            coordinator: coordinator,
                            playback: playback,
                            danmaku: danmaku,
                            prefersTouchLayout: false
                        )
                        .padding(24)
                    } else {
                        Text("开始播放后再替换弹幕。")
                            .font(
                                .system(
                                    size: 15,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                }
                .background(Palette.sidebarBackground.ignoresSafeArea())
                .navigationTitle("弹幕")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            macDanmakuSheetPresented = false
                        }
                    }
                }
            }
            .frame(
                minWidth: 560,
                idealWidth: 640,
                minHeight: 620,
                idealHeight: 760
            )
        }
    #endif

    private var detail: some View {
        ZStack {
            (usesImmersivePlaybackLayout ? Color.black : Palette.canvas)
                .ignoresSafeArea()

            if usesImmersivePlaybackLayout {
                playbackWorkspace
            } else {
                VStack(spacing: 18) {
                    workspaceHeader
                        .padding(.horizontal, 24)
                        .padding(.top, 20)

                    switch workspaceSection {
                    case .home:
                        homeScreenPlaceholder
                    case .files:
                        FilesWorkspaceView(
                            coordinator: coordinator,
                            jellyfin: jellyfin,
                            importerPresented: $importerPresented,
                            workspaceSection: $workspaceSection,
                            prefersTouchLayout: false
                        )
                    case .library:
                        LibraryWorkspaceView(
                            coordinator: coordinator,
                            jellyfin: jellyfin,
                            hasActivePlayback: hasActivePlayback,
                            workspaceSection: $workspaceSection,
                            jellyfinLibrarySearch: $jellyfinLibrarySearch
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    case .player:
                        playbackWorkspace
                    }
                }
            }
        }
        .toolbar {
            if !usesImmersivePlaybackLayout, workspaceSection == .player {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        importerPresented = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }

                    Button {
                        playback.danmakuEnabled.toggle()
                    } label: {
                        Image(
                            systemName: playbackDanmakuEnabled
                                ? "text.bubble.fill" : "text.bubble"
                        )
                    }

                    #if os(macOS)
                        Button {
                            showMacDanmakuSheet()
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .disabled(!hasActivePlayback)
                    #endif

                    #if os(macOS)
                        Button {
                            toggleVideoFullscreen()
                        } label: {
                            Image(
                                systemName: isVideoFullscreen
                                    ? "arrow.down.right.and.arrow.up.left"
                                    : "arrow.up.left.and.arrow.down.right"
                            )
                        }
                        .disabled(!hasActivePlayback)
                    #endif
                }
            }
        }
    }

    @ViewBuilder
    private var playbackWorkspace: some View {
        if !hasActivePlayback {
            placeholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                playbackStage(
                    in: proxy.size,
                    isImmersive: usesImmersivePlaybackLayout
                )
            }
        }
    }

    private func playbackStage(in containerSize: CGSize, isImmersive: Bool)
        -> some View
    {
        let outerPadding: CGFloat = isImmersive ? 0 : 24
        let cornerRadius: CGFloat = isImmersive ? 0 : 30
        let surfaceSize = CGSize(
            width: max(0, containerSize.width - outerPadding * 2),
            height: max(0, containerSize.height - outerPadding * 2)
        )
        let videoRect = fittedVideoRect(in: surfaceSize)
        let danmakuMetrics: DanmakuLayoutMetrics =
            isImmersive ? .immersivePlayback : .playbackChrome

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)

            MPVVideoHostRepresentable(
                player: playback.player,
                host: playbackHost
            )
            .id(playbackHost.mountToken)
            .frame(width: surfaceSize.width, height: surfaceSize.height)
            .background(Color.black)
            .allowsHitTesting(false)

            if playbackDanmakuEnabled, surfaceSize.width > 0,
                surfaceSize.height > 0
            {
                danmakuOverlay(in: surfaceSize, metrics: danmakuMetrics)
                    .frame(width: surfaceSize.width, height: surfaceSize.height)
                    .clipped()
                    .allowsHitTesting(false)
            }

            #if !os(macOS)
                PlaybackTouchGestureSurface(
                    onSingleTap: {
                        handlePlaybackSurfaceTap()
                    },
                    onDoubleTap: { isLeadingHalf in
                        handlePlaybackSurfaceDoubleTap(
                            isLeadingHalf: isLeadingHalf
                        )
                    },
                    onHorizontalPanBegan: {
                        beginPlaybackSurfaceScrub()
                    },
                    onHorizontalPanChanged: { translationX, width in
                        updatePlaybackSurfaceScrub(
                            translationX: translationX,
                            width: width
                        )
                    },
                    onHorizontalPanEnded: { translationX, width in
                        endPlaybackSurfaceScrub(
                            translationX: translationX,
                            width: width
                        )
                    },
                    onLongPressBegan: {
                        setSurfaceLongPressPlaybackRate(active: true)
                    },
                    onLongPressEnded: {
                        setSurfaceLongPressPlaybackRate(active: false)
                    }
                )
                .frame(width: surfaceSize.width, height: surfaceSize.height)
            #endif

            playbackChromeOverlay(
                in: surfaceSize,
                videoRect: videoRect,
                isImmersive: isImmersive
            )
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height)
        .contentShape(Rectangle())
        .onAppear {
            handlePlaybackSurfaceSizeChange(surfaceSize)
        }
        .onChange(of: surfaceSize) { newValue in
            handlePlaybackSurfaceSizeChange(newValue)
        }
        #if os(macOS)
            .onContinuousHover { phase in
                updatePlaybackChrome(for: phase)
            }
        #endif
        .clipShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                .opacity(isImmersive ? 0 : 1)
        }
        .shadow(
            color: .black.opacity(isImmersive ? 0 : 0.16),
            radius: isImmersive ? 0 : 24,
            x: 0,
            y: isImmersive ? 0 : 10
        )
        .padding(outerPadding)
        #if os(macOS)
            .onTapGesture(count: 2) {
                toggleVideoFullscreen()
            }
        #endif
    }

    private var placeholder: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Palette.accent.opacity(0.18), Palette.selection,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 200, height: 200)
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(Palette.accentDeep)
            }

            Button {
                importerPresented = true
            } label: {
                Text("打开视频")
                    .font(
                        .system(size: 18, weight: .semibold, design: .rounded)
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentDeep)

            if let homeAccountID = coordinator.homeJellyfinAccount?.id {
                Button {
                    coordinator.switchJellyfinAccount(homeAccountID)
                    workspaceSection = .library(homeAccountID)
                } label: {
                    Label("进入媒体库", systemImage: "rectangle.stack.fill")
                        .font(
                            .system(
                                size: 15,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
            }
        }
    }

    private var homeScreenPlaceholder: some View {
        HomeDashboardView(
            coordinator: coordinator,
            jellyfin: jellyfin,
            playback: playback,
            hasActivePlayback: hasActivePlayback,
            currentPlaybackTitle: currentPlaybackTitle,
            currentPlaybackEpisodeLabel: currentPlaybackEpisodeLabel,
            prefersTouchLayout: prefersTouchHomeLayout,
            onOpenFile: {
                importerPresented = true
            },
            onShowLibrary: {
                showHomeLibrary()
            },
            onShowPlayer: {
                workspaceSection = .player
            },
            onRefresh: {
                coordinator.refreshJellyfinHome()
            },
            onSelectHomeItem: { item in
                selectHomeItem(item)
            },
            onOpenHomeItemInLibrary: { item in
                openHomeItemInLibrary(item)
            },
            onSetHomeItemPlayedState: { item, played in
                setHomeItemPlayedState(item, played: played)
            },
            onDownloadHomeItem: { item in
                downloadHomeItem(item)
            },
            onSelectHomeSource: { accountID in
                coordinator.selectHomeJellyfinAccount(accountID)
            }
        )
        .task(id: jellyfin.homeAccountID) {
            coordinator.refreshJellyfinHome()
        }
    }

    private var prefersTouchHomeLayout: Bool {
        #if os(macOS)
            false
        #else
            true
        #endif
    }

    private func showHomeLibrary() {
        guard let homeAccountID = coordinator.homeJellyfinAccount?.id else {
            return
        }
        coordinator.switchJellyfinAccount(homeAccountID)
        workspaceSection = .library(homeAccountID)
    }

    private func handleVideoImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            coordinator.openVideo(url: url)
        case let .failure(error):
            coordinator.errorState = AppErrorState(
                message: error.localizedDescription
            )
        }
    }

    private func handleSubtitleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            coordinator.addExternalSubtitle(url: url)
        case let .failure(error):
            coordinator.errorState = AppErrorState(
                message: error.localizedDescription
            )
        }
    }

    private func selectHomeItem(_ item: JellyfinHomeItem) {
        if item.kind.isPlayable {
            coordinator.playJellyfinHomeItem(item)
            workspaceSection = .player
            return
        }
        openHomeItemInLibrary(item)
    }

    private func openHomeItemInLibrary(_ item: JellyfinHomeItem) {
        guard let homeAccountID = coordinator.homeJellyfinAccount?.id else {
            return
        }
        jellyfinLibrarySearch = ""
        workspaceSection = .library(homeAccountID)
        coordinator.openJellyfinHomeItemInLibrary(item)
    }

    private func setHomeItemPlayedState(_ item: JellyfinHomeItem, played: Bool)
    {
        coordinator.setJellyfinHomeItemPlayedState(item, played: played)
    }

    private func downloadHomeItem(_ item: JellyfinHomeItem) {
        coordinator.downloadJellyfinHomeItem(item)
    }

    private var workspaceHeaderTitle: String {
        switch workspaceSection {
        case .home: return "主页"
        case .files: return "文件"
        case .library: return "媒体库节目"
        case .player: return "播放器"
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 18) {
            if case .library = workspaceSection,
                coordinator.selectedJellyfinItem != nil
            {
                Button {
                    withAnimation(
                        .spring(response: 0.28, dampingFraction: 0.88)
                    ) {
                        coordinator.clearSelectedJellyfinItem()
                    }
                } label: {
                    Image(systemName: "chevron.backward.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(
                            Palette.accentDeep,
                            Palette.accent.opacity(0.18)
                        )
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(workspaceHeaderTitle)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                if !workspaceSummaryText.isEmpty {
                    Text(workspaceSummaryText)
                        .font(
                            .system(size: 13, weight: .medium, design: .rounded)
                        )
                        .foregroundStyle(Palette.ink.opacity(0.58))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            if let account = coordinator.activeJellyfinAccount {
                HeaderCapsule(
                    title: account.username,
                    systemImage: "person.crop.circle.fill"
                )
            }

            if let route = coordinator.activeJellyfinRoute {
                HeaderCapsule(
                    title: route.name,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.78))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.6), lineWidth: 1)
        }
    }

    private var workspaceSummaryText: String {
        switch workspaceSection {
        case .home:
            if hasActivePlayback {
                return currentPlaybackTitle
            }
            if let account = coordinator.activeJellyfinAccount {
                return account.displayTitle
            }
            return ""
        case .files:
            return ""
        case .library:
            if let item = coordinator.selectedJellyfinItem {
                return item.metaLine.isEmpty
                    ? item.name : "\(item.name) · \(item.metaLine)"
            }
            if let library = coordinator.selectedJellyfinLibrary {
                return "\(library.name) · \(library.subtitle)"
            }
            if let account = coordinator.activeJellyfinAccount {
                return account.displayTitle
            }
            return ""
        case .player:
            if hasActivePlayback {
                return currentPlaybackTitle
            }
            return ""
        }
    }

    private var topOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(currentPlaybackTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let selectedAnime = coordinator.selectedAnime {
                        PillLabel(text: selectedAnime.title)
                    }
                    if !currentPlaybackEpisodeLabel.isEmpty {
                        PillLabel(text: currentPlaybackEpisodeLabel)
                    }
                    if playbackIsRemote,
                        let route = coordinator.activeJellyfinRoute?.name
                    {
                        PillLabel(text: route)
                    }
                    if let selectedAudioTrackTitle {
                        PillLabel(text: selectedAudioTrackTitle)
                    }
                    if let selectedSubtitleTrackTitle {
                        PillLabel(text: selectedSubtitleTrackTitle)
                    }
                    if abs(currentPlaybackRate - 1.0) > 0.01 {
                        PillLabel(text: playbackRateText(currentPlaybackRate))
                    }
                    if coordinator.isCapturingScreenshot {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 4)
                    }
                    if let screenshotFeedbackMessage =
                        coordinator.screenshotFeedbackMessage
                    {
                        StatPill(
                            text: screenshotFeedbackMessage,
                            emphasized: true
                        )
                    }
                    if danmaku.isLoadingDanmaku {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.black.opacity(0.84), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 124)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.black.opacity(0.86))
                    .frame(height: 6)
            }
            .offset(y: -3)
        }
    }

    @ViewBuilder
    private func playbackChromeOverlay(
        in surfaceSize: CGSize,
        videoRect: CGRect,
        isImmersive: Bool
    ) -> some View {
        let chromeRect = chromeRect(
            in: surfaceSize,
            videoRect: videoRect,
            isImmersive: isImmersive
        )

        ZStack {
            VStack(spacing: 0) {
                topOverlay
                Spacer()
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()
                controls(width: chromeRect.width)
            }
            .allowsHitTesting(showsPlaybackChrome)
        }
        .frame(width: chromeRect.width, height: chromeRect.height)
        .offset(x: chromeRect.origin.x, y: chromeRect.origin.y)
        .opacity(showsPlaybackChrome ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: showsPlaybackChrome)
    }

    private func controls(width: CGFloat) -> some View {
        let usesCompactLayout = showsCompactPlaybackControls(for: width)

        return VStack(spacing: usesCompactLayout ? 12 : 14) {
            playbackProgressStrip(showsInlineTimeLabels: usesCompactLayout)

            if usesCompactLayout {
                compactPlaybackControls()
            } else {
                regularPlaybackControls(width: width)
            }
        }
        .padding(.horizontal, usesCompactLayout ? 16 : 18)
        .padding(.vertical, usesCompactLayout ? 14 : 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.74))
        )
        .padding(18)
    }

    private func playbackProgressStrip(showsInlineTimeLabels: Bool) -> some View
    {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 120.0,
                paused: playbackPaused || !hasActivePlayback
            )
        ) { context in
            let livePosition = resolvedPlaybackPosition(at: context.date)

            VStack(spacing: showsInlineTimeLabels ? 10 : 0) {
                PlaybackSeekBar(
                    duration: playback.snapshot.duration,
                    position: livePosition,
                    bufferedTint: .white,
                    onScrubStart: {
                        clearPendingSeek(syncTo: livePosition)
                        isScrubbing = true
                        cancelPlaybackChromeAutoHide()
                    },
                    onScrubChange: { value in
                        scrubPosition = value
                    },
                    onScrubEnd: { value in
                        beginOptimisticSeek(to: value)
                    }
                )

                if showsInlineTimeLabels {
                    compactPlaybackTimeLabels
                }
            }
        }
    }

    private var compactPlaybackTimeLabels: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 120.0,
                paused: playbackPaused || !hasActivePlayback
            )
        ) { context in
            let livePosition = resolvedPlaybackPosition(at: context.date)

            HStack {
                playbackTimeText(livePosition)
                Spacer(minLength: 12)
                playbackDurationText
            }
        }
    }

    private func regularPlaybackTimeLabels(width: CGFloat) -> some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 120.0,
                paused: playbackPaused || !hasActivePlayback
            )
        ) { context in
            let livePosition = resolvedPlaybackPosition(at: context.date)

            HStack(spacing: 0) {
                playbackTimeText(livePosition)

                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(width: max(24, width * 0.05), height: 4)
                    .padding(.horizontal, 14)

                playbackDurationText
            }
        }
    }

    private func regularPlaybackControls(width: CGFloat) -> some View {
        HStack(spacing: 14) {
            chromeButton(
                systemName: "backward.end.fill",
                disabled: !playback.canPlayPreviousEpisode
            ) {
                notePlaybackInteraction()
                coordinator.playPreviousEpisode()
            }
            chromeButton(
                systemName: playback.snapshot.paused
                    ? "play.fill" : "pause.fill"
            ) {
                notePlaybackInteraction()
                coordinator.togglePause()
            }
            chromeButton(
                systemName: "forward.end.fill",
                disabled: !playback.canPlayNextEpisode
            ) {
                notePlaybackInteraction()
                coordinator.playNextEpisode()
            }
            chromeButton(systemName: "gobackward") {
                beginOptimisticSeek(
                    to: displayedPlaybackPosition
                        - playbackPreferences.seekInterval
                )
            }
            chromeButton(systemName: "goforward") {
                beginOptimisticSeek(
                    to: displayedPlaybackPosition
                        + playbackPreferences.seekInterval
                )
            }

            regularPlaybackTimeLabels(width: width)

            playbackSettingsMenu

            Spacer(minLength: 12)

            audioTrackMenu

            subtitleTrackMenu

            chromeButton(
                systemName: playbackDanmakuEnabled
                    ? "text.bubble.fill" : "text.bubble"
            ) {
                notePlaybackInteraction()
                playback.danmakuEnabled.toggle()
            }

            chromeButton(
                systemName: "camera",
                disabled: coordinator.isCapturingScreenshot
            ) {
                captureScreenshotAction()
            }

            #if !os(macOS)
                chromeButton(systemName: "text.magnifyingglass") {
                    showMobileDanmakuSheet()
                }

                chromeButton(
                    systemName: isIOSVideoFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                ) {
                    notePlaybackInteraction()
                    toggleIOSVideoFullscreen()
                }
            #endif

            #if os(macOS)
                chromeButton(systemName: "slider.horizontal.3") {
                    showMacDanmakuSheet()
                }

                chromeButton(
                    systemName: isVideoFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                ) {
                    toggleVideoFullscreen()
                }
            #endif

            chromeButton(systemName: "folder") {
                notePlaybackInteraction()
                importerPresented = true
            }
        }
    }

    @ViewBuilder
    private func compactPlaybackControls() -> some View {
        #if !os(macOS)
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    chromeButton(
                        systemName: "backward.end.fill",
                        disabled: !playback.canPlayPreviousEpisode,
                        size: 32
                    ) {
                        notePlaybackInteraction()
                        coordinator.playPreviousEpisode()
                    }
                    chromeButton(
                        systemName: playback.snapshot.paused
                            ? "play.fill" : "pause.fill",
                        size: 44,
                        emphasized: true
                    ) {
                        notePlaybackInteraction()
                        coordinator.togglePause()
                    }
                    chromeButton(systemName: "gobackward", size: 32) {
                        beginOptimisticSeek(
                            to: displayedPlaybackPosition
                                - playbackPreferences.seekInterval
                        )
                    }
                    chromeButton(systemName: "goforward", size: 32) {
                        beginOptimisticSeek(
                            to: displayedPlaybackPosition
                                + playbackPreferences.seekInterval
                        )
                    }
                    chromeButton(
                        systemName: "forward.end.fill",
                        disabled: !playback.canPlayNextEpisode,
                        size: 32
                    ) {
                        notePlaybackInteraction()
                        coordinator.playNextEpisode()
                    }
                    chromeButton(systemName: "text.magnifyingglass", size: 32) {
                        showMobileDanmakuSheet()
                    }
                    chromeButton(
                        systemName: "camera",
                        disabled: coordinator.isCapturingScreenshot,
                        size: 32
                    ) {
                        captureScreenshotAction()
                    }
                    chromeButton(
                        systemName: isIOSVideoFullscreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right",
                        size: 32
                    ) {
                        notePlaybackInteraction()
                        toggleIOSVideoFullscreen()
                    }
                    compactPlaybackActionsMenu
                }
            }
        #else
            EmptyView()
        #endif
    }

    private var playbackSettingsMenu: some View {
        Menu {
            playbackSettingsMenuContent
        } label: {
            MenuChip(
                title: playbackRateText(currentPlaybackRate),
                systemImage: "speedometer"
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var playbackSettingsMenuContent: some View {
        Section("播放") {
            Menu {
                ForEach(PlaybackPreferences.playbackRatePresets, id: \.self) {
                    rate in
                    playbackOptionMenuButton(
                        title: playbackRateText(rate),
                        isSelected: abs(playbackPreferences.playbackRate - rate)
                            < 0.01
                    ) {
                        notePlaybackInteraction()
                        playback.setPlaybackRate(rate)
                    }
                }
            } label: {
                Label(
                    "倍速 \(playbackRateText(currentPlaybackRate))",
                    systemImage: "speedometer"
                )
            }

            Menu {
                ForEach(PlaybackPreferences.seekIntervalPresets, id: \.self) {
                    interval in
                    playbackOptionMenuButton(
                        title: seekIntervalText(interval),
                        isSelected:
                            abs(playbackPreferences.seekInterval - interval)
                            < 0.01
                    ) {
                        notePlaybackInteraction()
                        playback.setSeekInterval(interval)
                    }
                }
            } label: {
                Label(
                    "快进快退 \(seekIntervalText(playbackPreferences.seekInterval))",
                    systemImage: "arrow.left.and.right"
                )
            }
        }
    }

    @ViewBuilder
    private var compactPlaybackActionsMenu: some View {
        #if !os(macOS)
            Menu {
                Section("弹幕") {
                    Button {
                        showMobileDanmakuSheet()
                    } label: {
                        Label("搜索或替换弹幕", systemImage: "text.magnifyingglass")
                    }

                    Button {
                        notePlaybackInteraction()
                        playback.danmakuEnabled.toggle()
                    } label: {
                        Label(
                            playbackDanmakuEnabled ? "关闭弹幕" : "显示弹幕",
                            systemImage: playbackDanmakuEnabled
                                ? "text.bubble.fill" : "text.bubble"
                        )
                    }
                }

                Section("截图") {
                    Button {
                        captureScreenshotAction()
                    } label: {
                        Label("保存截图", systemImage: "camera")
                    }
                    .disabled(coordinator.isCapturingScreenshot)
                }

                playbackSettingsMenuContent

                Section("音轨与字幕") {
                    Menu {
                        audioTrackMenuContent
                    } label: {
                        Label("音轨", systemImage: "music.note")
                    }
                    .disabled(playback.audioTracks.isEmpty)

                    Menu {
                        Button {
                            notePlaybackInteraction()
                            subtitleImporterPresented = true
                        } label: {
                            Label("挂载外挂字幕", systemImage: "plus")
                        }

                        Divider()

                        trackMenuButton(
                            title: "关闭字幕",
                            detail: "",
                            isSelected: playback.selectedSubtitleTrackID == nil
                        ) {
                            notePlaybackInteraction()
                            coordinator.selectSubtitleTrack(id: nil)
                        }

                        ForEach(playback.subtitleTracks) { track in
                            trackMenuButton(
                                title: track.title,
                                detail: track.detail,
                                isSelected: playback.selectedSubtitleTrackID
                                    == track.mpvID
                            ) {
                                notePlaybackInteraction()
                                coordinator.selectSubtitleTrack(id: track.mpvID)
                            }
                        }
                    } label: {
                        Label("字幕", systemImage: "captions.bubble")
                    }
                }

                Section("更多") {
                    Button {
                        notePlaybackInteraction()
                        importerPresented = true
                    } label: {
                        Label("打开视频", systemImage: "folder.badge.plus")
                    }

                    if coordinator.activeJellyfinAccount != nil {
                        Button {
                            notePlaybackInteraction()
                            mobileTab = .library
                        } label: {
                            Label(
                                "前往媒体库",
                                systemImage: "rectangle.stack.badge.play.fill"
                            )
                        }
                    }

                    Button {
                        notePlaybackInteraction()
                        toggleIOSVideoFullscreen()
                    } label: {
                        Label(
                            isIOSVideoFullscreen ? "退出全屏" : "进入全屏",
                            systemImage: isIOSVideoFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.14))
                    )
            }
            .foregroundStyle(.white)
        #else
            EmptyView()
        #endif
    }

    private func showsCompactPlaybackControls(for width: CGFloat) -> Bool {
        #if os(macOS)
            false
        #else
            width < 680
        #endif
    }

    #if !os(macOS)
        private func showMobileDanmakuSheet() {
            notePlaybackInteraction()
            mobileDanmakuSheetPresented = true
        }
    #endif

    #if os(macOS)
        private func showMacDanmakuSheet() {
            notePlaybackInteraction()
            macDanmakuSheetPresented = true
        }
    #endif

    private func chromeRect(
        in surfaceSize: CGSize,
        videoRect: CGRect,
        isImmersive: Bool
    ) -> CGRect {
        guard isImmersive, videoRect.width > 0, videoRect.height > 0 else {
            return CGRect(origin: .zero, size: surfaceSize)
        }
        return videoRect
    }

    private func danmakuOverlay(
        in viewport: CGSize,
        metrics: DanmakuLayoutMetrics
    ) -> some View {
        DanmakuMetalOverlay(
            renderer: danmaku.renderer,
            timebase: playback.timebase,
            viewport: viewport,
            metrics: metrics
        )
    }

    private func fittedVideoRect(in containerSize: CGSize) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let aspect = playbackVideoAspect
        guard aspect > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let containerAspect = containerSize.width / containerSize.height
        if aspect > containerAspect {
            let fittedHeight = containerSize.width / aspect
            return CGRect(
                x: 0,
                y: (containerSize.height - fittedHeight) / 2,
                width: containerSize.width,
                height: fittedHeight
            )
        } else {
            let fittedWidth = containerSize.height * aspect
            return CGRect(
                x: (containerSize.width - fittedWidth) / 2,
                y: 0,
                width: fittedWidth,
                height: containerSize.height
            )
        }
    }

    private var audioTrackMenu: some View {
        Menu {
            audioTrackMenuContent
        } label: {
            MenuChip(
                title: playback.selectedAudioTrack?.title ?? "音轨",
                systemImage: "music.note"
            )
            .opacity(playback.audioTracks.isEmpty ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(playback.audioTracks.isEmpty)
    }

    @ViewBuilder
    private var audioTrackMenuContent: some View {
        if playback.canEnableSpatialAudio {
            Section("空间音频") {
                trackMenuButton(
                    title: "空间音频",
                    detail: playback.selectedSpatialAudioDecoder?.menuDetail
                        ?? "Atmos -> coreaudio_spatial714",
                    isSelected: playback.spatialAudioEnabled
                ) {
                    notePlaybackInteraction()
                    playback.setSpatialAudioEnabled(!playback.spatialAudioEnabled)
                }
            }
        }

        ForEach(playback.audioTracks) { track in
            trackMenuButton(
                title: track.title,
                detail: track.detail,
                isSelected: playback.selectedAudioTrackID == track.mpvID
            ) {
                notePlaybackInteraction()
                coordinator.selectAudioTrack(id: track.mpvID)
            }
        }
    }

    private var subtitleTrackMenu: some View {
        Menu {
            Button {
                notePlaybackInteraction()
                subtitleImporterPresented = true
            } label: {
                Label("挂载外挂字幕", systemImage: "plus")
            }

            Divider()

            trackMenuButton(
                title: "关闭字幕",
                detail: "",
                isSelected: playback.selectedSubtitleTrackID == nil
            ) {
                notePlaybackInteraction()
                coordinator.selectSubtitleTrack(id: nil)
            }

            ForEach(playback.subtitleTracks) { track in
                trackMenuButton(
                    title: track.title,
                    detail: track.detail,
                    isSelected: playback.selectedSubtitleTrackID == track.mpvID
                ) {
                    notePlaybackInteraction()
                    coordinator.selectSubtitleTrack(id: track.mpvID)
                }
            }
        } label: {
            MenuChip(
                title: playback.selectedSubtitleTrack?.title ?? "字幕关闭",
                systemImage: "captions.bubble"
            )
        }
        .buttonStyle(.plain)
    }

    private func trackMenuButton(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func playbackOptionMenuButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func chromeButton(
        systemName: String,
        disabled: Bool = false,
        size: CGFloat = 34,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .bold))
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(
                            emphasized
                                ? Palette.accent.opacity(disabled ? 0.18 : 0.92)
                                : .white.opacity(disabled ? 0.08 : 0.14)
                        )
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
    }

    private func playbackTimeText(_ seconds: Double) -> some View {
        Text(timeString(seconds))
            .font(
                .system(
                    size: 13,
                    weight: .semibold,
                    design: .rounded
                )
            )
            .foregroundStyle(.white.opacity(0.88))
    }

    private var playbackDurationText: some View {
        Text(timeString(playback.snapshot.duration))
            .font(
                .system(
                    size: 13,
                    weight: .semibold,
                    design: .rounded
                )
            )
            .foregroundStyle(.white.opacity(0.62))
    }

    private var currentPlaybackRate: Double {
        let rate =
            playback.snapshot.loaded
            ? playback.snapshot.playbackRate
            : playbackPreferences.playbackRate
        return PlaybackPreferences.clampedPlaybackRate(rate)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func playbackRateText(_ rate: Double) -> String {
        "\(formattedPlaybackValue(rate))x"
    }

    private func seekIntervalText(_ seconds: Double) -> String {
        "\(formattedPlaybackValue(seconds)) 秒"
    }

    private func formattedPlaybackValue(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.2f", value)
        while text.contains(".") && text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    private var showsPlaybackChrome: Bool {
        playbackChromeVisible
    }

    private var displayedPlaybackPosition: Double {
        resolvedPlaybackPosition(at: Date())
    }

    private func resolvedPlaybackPosition(at date: Date) -> Double {
        if isScrubbing {
            return scrubPosition
        }
        if let pendingSeekPosition {
            return pendingSeekPosition
        }
        return playback.timebase.resolvedPosition(at: date)
    }

    private var usesImmersivePlaybackLayout: Bool {
        #if os(macOS)
            isVideoFullscreen
        #else
            false
        #endif
    }

    private var usesImmersivePlaybackRoot: Bool {
        #if os(macOS)
            isVideoFullscreen && hasActivePlayback
        #else
            false
        #endif
    }

    private func notePlaybackInteraction() {
        #if os(macOS)
            guard usesImmersivePlaybackLayout, playbackChromeVisible else {
                return
            }
            setPlaybackCursorHidden(false)
            schedulePlaybackChromeAutoHide()
        #else
            guard playbackChromeVisible else { return }
            schedulePlaybackChromeAutoHide()
        #endif
    }

    private func captureScreenshotAction() {
        notePlaybackInteraction()
        coordinator.captureScreenshot()
    }

    private func showPlaybackChrome() {
        cancelPlaybackChromeAutoHide()
        withAnimation(.easeInOut(duration: 0.18)) {
            playbackChromeVisible = true
        }
        #if os(macOS)
            setPlaybackCursorHidden(false)
        #endif
    }

    private func hidePlaybackChrome(cancelAutoHide: Bool = true) {
        if cancelAutoHide {
            cancelPlaybackChromeAutoHide()
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            playbackChromeVisible = false
        }
        #if os(macOS)
            setPlaybackCursorHidden(usesImmersivePlaybackLayout)
        #endif
    }

    private func cancelPlaybackChromeAutoHide() {
        playbackChromeAutoHideTask?.cancel()
        playbackChromeAutoHideTask = nil
    }

    private func beginOptimisticSeek(to seconds: Double) {
        let target = clampedSeekPosition(seconds)
        clearPendingSeek(syncTo: target)
        scrubPosition = target
        isScrubbing = false
        pendingSeekPosition = target
        notePlaybackInteraction()
        coordinator.seek(to: target)

        pendingSeekResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            clearPendingSeek(syncTo: playback.snapshot.position)
        }
    }

    private func clearPendingSeek(syncTo position: Double? = nil) {
        pendingSeekResetTask?.cancel()
        pendingSeekResetTask = nil
        pendingSeekPosition = nil
        if let position {
            scrubPosition = position
        }
    }

    private func clampedSeekPosition(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let lowerBound = max(0, seconds)
        guard playback.snapshot.duration > 0 else { return lowerBound }
        return min(playback.snapshot.duration, lowerBound)
    }

    private func resetSurfaceInteractionState(resetPlaybackRate: Bool) {
        surfaceScrubStartPosition = nil
        if isScrubbing {
            isScrubbing = false
        }
        if resetPlaybackRate && surfaceLongPressSpeedActive {
            surfaceLongPressSpeedActive = false
            playback.setPlaybackRate(1.0)
        } else if !resetPlaybackRate {
            surfaceLongPressSpeedActive = false
        }
    }

    private func beginPlaybackSurfaceScrub() {
        guard playback.snapshot.duration > 0 else { return }
        let position = displayedPlaybackPosition
        surfaceScrubStartPosition = position
        clearPendingSeek(syncTo: position)
        scrubPosition = position
        isScrubbing = true
        showPlaybackChrome()
    }

    private func updatePlaybackSurfaceScrub(
        translationX: CGFloat,
        width: CGFloat
    ) {
        guard
            let target = playbackSurfaceScrubTarget(
                translationX: translationX,
                width: width
            )
        else {
            return
        }
        scrubPosition = target
    }

    private func endPlaybackSurfaceScrub(
        translationX: CGFloat,
        width: CGFloat
    ) {
        defer {
            surfaceScrubStartPosition = nil
        }
        guard
            let target = playbackSurfaceScrubTarget(
                translationX: translationX,
                width: width
            )
        else {
            clearPendingSeek(syncTo: playback.snapshot.position)
            isScrubbing = false
            return
        }
        beginOptimisticSeek(to: target)
    }

    private func playbackSurfaceScrubTarget(
        translationX: CGFloat,
        width: CGFloat
    ) -> Double? {
        guard playback.snapshot.duration > 0, width > 1 else { return nil }
        let anchorPosition =
            surfaceScrubStartPosition ?? displayedPlaybackPosition
        let progressDelta = Double(translationX / width)
        let deltaSeconds = progressDelta * playback.snapshot.duration
        return clampedSeekPosition(anchorPosition + deltaSeconds)
    }

    private func handlePlaybackSurfaceDoubleTap(isLeadingHalf: Bool) {
        let direction = isLeadingHalf ? -1.0 : 1.0
        showPlaybackChrome()
        beginOptimisticSeek(
            to: displayedPlaybackPosition
                + direction * playbackPreferences.seekInterval
        )
    }

    private func setSurfaceLongPressPlaybackRate(active: Bool) {
        guard surfaceLongPressSpeedActive != active else { return }
        surfaceLongPressSpeedActive = active
        if active {
            showPlaybackChrome()
            playback.setPlaybackRate(2.0)
        } else {
            playback.setPlaybackRate(1.0)
            showPlaybackChrome()
            schedulePlaybackChromeAutoHide()
        }
    }

    private func handlePlaybackSurfaceSizeChange(_ size: CGSize) {
        guard hasActivePlayback else { return }
        guard size.width > 1, size.height > 1 else { return }

        let previousSize = lastPlaybackSurfaceSize
        let widthChanged =
            abs(size.width - previousSize.width) > 0.5
        let heightChanged =
            abs(size.height - previousSize.height) > 0.5
        guard widthChanged || heightChanged else { return }
        lastPlaybackSurfaceSize = size

        #if os(macOS)
            guard !pendingVideoFullscreenEntry else { return }
            playbackHostRemountTask?.cancel()
            playbackHostRemountTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                playbackHost.remountHost()
                playbackHostRemountTask = nil
            }
        #else
            let widthDelta = abs(size.width - previousSize.width)
            let heightDelta = abs(size.height - previousSize.height)
            let previousLandscape = previousSize.width > previousSize.height
            let currentLandscape = size.width > size.height
            let orientationClassChanged =
                previousSize != .zero && previousLandscape != currentLandscape
            let needsHostRemount =
                !mobileDanmakuSheetPresented
                && (orientationClassChanged || widthDelta > 48
                    || heightDelta > 48)

            if needsHostRemount {
                playbackHostRemountTask?.cancel()
                playbackHostRemountTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    playbackHost.remountHost()
                    showPlaybackChrome()
                    schedulePlaybackChromeAutoHide()
                    playbackHostRemountTask = nil
                }
            } else {
                showPlaybackChrome()
                schedulePlaybackChromeAutoHide()
            }
        #endif
    }

    #if os(macOS)
        private func presentMacVideoOpenPanelIfNeeded() {
            guard !isPresentingMacVideoOpenPanel else { return }
            isPresentingMacVideoOpenPanel = true

            Task { @MainActor in
                defer {
                    importerPresented = false
                    isPresentingMacVideoOpenPanel = false
                }

                let panel = NSOpenPanel()
                panel.title = "打开视频"
                panel.message = "选择要播放的本地视频文件。"
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = videoImportTypes

                guard await presentMacOpenPanel(panel) == .OK,
                    let url = panel.urls.first
                else {
                    return
                }

                coordinator.openVideo(url: url)
            }
        }

        private func presentMacSubtitleOpenPanelIfNeeded() {
            guard !isPresentingMacSubtitleOpenPanel else { return }
            isPresentingMacSubtitleOpenPanel = true

            Task { @MainActor in
                defer {
                    subtitleImporterPresented = false
                    isPresentingMacSubtitleOpenPanel = false
                }

                let panel = NSOpenPanel()
                panel.title = "挂载外挂字幕"
                panel.message = "选择要加载的字幕文件。"
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = subtitleImportTypes

                guard await presentMacOpenPanel(panel) == .OK,
                    let url = panel.urls.first
                else {
                    return
                }

                coordinator.addExternalSubtitle(url: url)
            }
        }

        private func presentMacOpenPanel(_ panel: NSOpenPanel) async
            -> NSApplication.ModalResponse
        {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                return panel.runModal()
            }

            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        }

        private func updatePlaybackChrome(for phase: HoverPhase) {
            switch phase {
            case .active(_):
                showPlaybackChrome()
                if usesImmersivePlaybackLayout, !isScrubbing {
                    schedulePlaybackChromeAutoHide()
                }
            case .ended:
                hidePlaybackChrome()
            }
        }

        private func toggleVideoFullscreen() {
            if isVideoFullscreen || pendingVideoFullscreenEntry {
                dismissVideoFullscreenIfNeeded()
                return
            }

            splitViewVisibilityBeforeVideoFullscreen = splitViewVisibility
            splitViewVisibility = .detailOnly
            playbackChromeVisible = false

            if isWindowFullscreen {
                isVideoFullscreen = true
                return
            }

            pendingVideoFullscreenEntry = true
            videoFullscreenOwnsWindowFullscreen = true
            toggleWindowFullscreen()
        }

        private func dismissVideoFullscreenIfNeeded() {
            guard isVideoFullscreen || pendingVideoFullscreenEntry else {
                return
            }

            isVideoFullscreen = false
            pendingVideoFullscreenEntry = false
            playbackChromeVisible = false
            cancelPlaybackChromeAutoHide()
            setPlaybackCursorHidden(false)
            restoreSplitViewVisibilityAfterVideoFullscreen()

            guard videoFullscreenOwnsWindowFullscreen, isWindowFullscreen else {
                videoFullscreenOwnsWindowFullscreen = false
                return
            }

            videoFullscreenOwnsWindowFullscreen = false
            toggleWindowFullscreen()
        }

        private func restoreSplitViewVisibilityAfterVideoFullscreen() {
            splitViewVisibility =
                splitViewVisibilityBeforeVideoFullscreen ?? .all
            splitViewVisibilityBeforeVideoFullscreen = nil
        }

        private func toggleWindowFullscreen() {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                return
            }
            window.toggleFullScreen(nil)
        }

        private func schedulePlaybackChromeAutoHide() {
            playbackChromeAutoHideTask?.cancel()
            playbackChromeAutoHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                guard usesImmersivePlaybackLayout, !isScrubbing else {
                    playbackChromeAutoHideTask = nil
                    return
                }
                hidePlaybackChrome(cancelAutoHide: false)
                playbackChromeAutoHideTask = nil
            }
        }

        private func setPlaybackCursorHidden(_ hidden: Bool) {
            NSCursor.setHiddenUntilMouseMoves(hidden)
        }
    #else
        private func toggleIOSVideoFullscreen() {
            setIOSVideoFullscreen(!isIOSVideoFullscreen)
        }

        private func setIOSVideoFullscreen(_ isFullscreen: Bool) {
            guard isIOSVideoFullscreen != isFullscreen else { return }
            isIOSVideoFullscreen = isFullscreen

            if isFullscreen {
                StarmineiOSOrientationController.enterVideoFullscreen()
            } else {
                StarmineiOSOrientationController.exitVideoFullscreen()
            }

            showPlaybackChrome()
            schedulePlaybackChromeAutoHide()
        }

        private func handlePlaybackSurfaceTap() {
            showPlaybackChrome()
            schedulePlaybackChromeAutoHide()
        }

        private func schedulePlaybackChromeAutoHide() {
            playbackChromeAutoHideTask?.cancel()
            playbackChromeAutoHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    playbackChromeVisible = false
                }
                playbackChromeAutoHideTask = nil
            }
        }
    #endif
}

private struct HomeDashboardMetrics {
    let containerWidth: CGFloat
    let prefersTouchLayout: Bool

    var isCompact: Bool {
        prefersTouchLayout || containerWidth < 860
    }

    var outerPadding: CGFloat { isCompact ? 16 : 24 }
    var verticalPadding: CGFloat { isCompact ? 16 : 24 }
    var sectionSpacing: CGFloat { isCompact ? 18 : 24 }
    var heroCornerRadius: CGFloat { isCompact ? 26 : 30 }
    var heroPosterWidth: CGFloat { isCompact ? 104 : 126 }
    var heroPosterHeight: CGFloat { isCompact ? 156 : 186 }
    var shelfCardWidth: CGFloat {
        isCompact ? min(max(containerWidth - 48, 220), 254) : 286
    }
    var shelfArtworkHeight: CGFloat { isCompact ? 148 : 172 }
}

private enum HomeShelfKind {
    case resume
    case recent
    case nextUp
    case recommended

    var title: String {
        switch self {
        case .resume: return "继续观看"
        case .recent: return "最近观看"
        case .nextUp: return "下一集"
        case .recommended: return "推荐"
        }
    }

    func actionTitle(for item: JellyfinHomeItem) -> String {
        switch self {
        case .resume:
            return item.kind.isPlayable ? "继续" : "查看"
        case .recent:
            return item.kind.isPlayable ? "重播" : "查看"
        case .nextUp:
            return item.kind.isPlayable ? "播放" : "查看"
        case .recommended:
            return item.kind.isPlayable ? "播放" : "查看"
        }
    }
}

private struct HomeDashboardView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var jellyfin: JellyfinStore
    @ObservedObject var playback: PlaybackStore
    let hasActivePlayback: Bool
    let currentPlaybackTitle: String
    let currentPlaybackEpisodeLabel: String
    let prefersTouchLayout: Bool
    let onOpenFile: () -> Void
    let onShowLibrary: () -> Void
    let onShowPlayer: () -> Void
    let onRefresh: () -> Void
    let onSelectHomeItem: (JellyfinHomeItem) -> Void
    let onOpenHomeItemInLibrary: (JellyfinHomeItem) -> Void
    let onSetHomeItemPlayedState: (JellyfinHomeItem, Bool) -> Void
    let onDownloadHomeItem: (JellyfinHomeItem) -> Void
    let onSelectHomeSource: (UUID) -> Void

    private var featuredItem: JellyfinHomeItem? {
        jellyfin.resumeItems.first
            ?? jellyfin.nextUpItems.first
            ?? jellyfin.recommendedItems.first
            ?? jellyfin.recentItems.first
    }

    private var homeSourceAccount: JellyfinAccountProfile? {
        coordinator.homeJellyfinAccount
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = HomeDashboardMetrics(
                containerWidth: max(320, proxy.size.width),
                prefersTouchLayout: prefersTouchLayout
            )

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    hero(metrics: metrics)

                    if !jellyfin.resumeItems.isEmpty {
                        shelf(
                            title: HomeShelfKind.resume.title,
                            items: jellyfin.resumeItems,
                            kind: .resume,
                            metrics: metrics
                        )
                    }

                    if !jellyfin.recentItems.isEmpty {
                        shelf(
                            title: HomeShelfKind.recent.title,
                            items: jellyfin.recentItems,
                            kind: .recent,
                            metrics: metrics
                        )
                    }

                    if !jellyfin.nextUpItems.isEmpty {
                        shelf(
                            title: HomeShelfKind.nextUp.title,
                            items: jellyfin.nextUpItems,
                            kind: .nextUp,
                            metrics: metrics
                        )
                    }

                    if !jellyfin.recommendedItems.isEmpty {
                        shelf(
                            title: HomeShelfKind.recommended.title,
                            items: jellyfin.recommendedItems,
                            kind: .recommended,
                            metrics: metrics
                        )
                    }
                }
                .padding(.horizontal, metrics.outerPadding)
                .padding(.top, metrics.verticalPadding)
                .padding(.bottom, metrics.verticalPadding + 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable {
                onRefresh()
            }
        }
    }

    private func hero(metrics: HomeDashboardMetrics) -> some View {
        let heroTitle = resolvedHeroTitle
        let heroSubtitle = resolvedHeroSubtitle
        let featureBackdrop = featuredItem.flatMap {
            coordinator.jellyfinBackdropURL(
                for: $0,
                width: 1600,
                height: 900
            )
        }
        let featurePoster = featuredItem.flatMap {
            coordinator.jellyfinPosterURL(
                for: $0,
                width: 360,
                height: 540
            )
        }

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(
                cornerRadius: metrics.heroCornerRadius,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.24, green: 0.18, blue: 0.15),
                        Color(red: 0.45, green: 0.24, blue: 0.14),
                        Color(red: 0.78, green: 0.31, blue: 0.12),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            if let featureBackdrop {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    JellyfinArtworkView(
                        url: featureBackdrop,
                        placeholderSystemName: "sparkles.tv.fill",
                        cornerRadius: metrics.heroCornerRadius
                    )
                    .frame(width: min(metrics.containerWidth * 0.48, 420))
                    .mask(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.34), .black],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(0.78)
                }
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.54),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: metrics.heroCornerRadius,
                    style: .continuous
                )
            )

            Group {
                if metrics.isCompact {
                    VStack(alignment: .leading, spacing: 18) {
                        heroTopRow(metrics: metrics)
                        homeSourceSelector(metrics: metrics)
                        heroCopy(title: heroTitle, subtitle: heroSubtitle)
                        if let featuredItem {
                            heroPoster(
                                featuredItem: featuredItem,
                                posterURL: featurePoster,
                                metrics: metrics
                            )
                        }
                        heroStatus(metrics: metrics)
                        heroActions(metrics: metrics)
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 24) {
                        VStack(alignment: .leading, spacing: 18) {
                            heroTopRow(metrics: metrics)
                            homeSourceSelector(metrics: metrics)
                            heroCopy(title: heroTitle, subtitle: heroSubtitle)
                            heroStatus(metrics: metrics)
                            heroActions(metrics: metrics)
                        }
                        Spacer(minLength: 12)
                        if let featuredItem {
                            heroPoster(
                                featuredItem: featuredItem,
                                posterURL: featurePoster,
                                metrics: metrics
                            )
                        }
                    }
                }
            }
            .padding(metrics.isCompact ? 18 : 28)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: metrics.heroCornerRadius,
                style: .continuous
            )
            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
    }

    private func heroTopRow(metrics: HomeDashboardMetrics) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if metrics.isCompact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        heroPills
                    }
                    .padding(.horizontal, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    heroPills
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            heroRefreshButton
        }
    }

    @ViewBuilder
    private func homeSourceSelector(metrics: HomeDashboardMetrics) -> some View
    {
        if let account = homeSourceAccount {
            let label = homeSourceSelectorLabel(
                account: account,
                route: coordinator.homeJellyfinRoute,
                showsSwitcher: jellyfin.accounts.count > 1,
                metrics: metrics
            )

            if jellyfin.accounts.count > 1 {
                Menu {
                    ForEach(jellyfin.accounts) { candidate in
                        Button {
                            onSelectHomeSource(candidate.id)
                        } label: {
                            if candidate.id == jellyfin.homeAccountID {
                                Label(
                                    candidate.displayTitle,
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(candidate.displayTitle)
                            }
                        }
                    }
                } label: {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private func homeSourceSelectorLabel(
        account: JellyfinAccountProfile,
        route: JellyfinRoute?,
        showsSwitcher: Bool,
        metrics: HomeDashboardMetrics
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: metrics.isCompact ? 16 : 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.18))
                .clipShape(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("推荐来源")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                Text(account.displayTitle)
                    .font(
                        .system(
                            size: metrics.isCompact ? 14 : 15,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let routeLine = route?.name.nilIfBlank {
                    Text(routeLine)
                        .font(
                            .system(
                                size: 11,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if showsSwitcher {
                VStack(spacing: 4) {
                    Text("切换")
                        .font(
                            .system(
                                size: 11,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.88))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.13))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func heroCopy(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            if let subtitle = subtitle?.nilIfBlank {
                Text(subtitle)
                    .font(
                        .system(size: 15, weight: .semibold, design: .rounded)
                    )
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(2)
            }
        }
    }

    private func heroPoster(
        featuredItem: JellyfinHomeItem,
        posterURL: URL?,
        metrics: HomeDashboardMetrics
    ) -> some View {
        JellyfinArtworkView(
            url: posterURL,
            placeholderSystemName: featuredItem.kind == .series
                ? "tv.inset.filled" : "film.fill",
            cornerRadius: 24
        )
        .frame(
            width: metrics.heroPosterWidth,
            height: metrics.heroPosterHeight
        )
        .shadow(color: .black.opacity(0.24), radius: 14, x: 0, y: 10)
    }

    @ViewBuilder
    private func heroStatus(metrics: HomeDashboardMetrics) -> some View {
        if hasActivePlayback {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let resolvedPosition = playback.timebase.resolvedPosition(
                    at: context.date
                )
                let duration = max(
                    playback.snapshot.duration,
                    playback.timebase.duration
                )
                let progress =
                    duration > 0
                    ? max(0, min(1, resolvedPosition / duration)) : 0

                VStack(alignment: .leading, spacing: 12) {
                    HomeProgressBar(progress: progress)
                        .frame(height: 5)

                    HStack(spacing: 12) {
                        Text(timeText(resolvedPosition))
                            .font(
                                .system(
                                    size: 13,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(.white.opacity(0.9))
                            .monospacedDigit()

                        Text("/")
                            .foregroundStyle(.white.opacity(0.4))

                        Text(timeText(duration))
                            .font(
                                .system(
                                    size: 13,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(.white.opacity(0.72))
                            .monospacedDigit()
                    }
                }
            }
        } else if let featuredItem {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(featuredItem.detailTitle)
                        .font(
                            .system(
                                size: 13,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)

                    if let runtime = runtimeText(
                        fromTicks: featuredItem.runTimeTicks
                    ) {
                        Text(runtime)
                            .font(
                                .system(
                                    size: 13,
                                    weight: .medium,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(.white.opacity(0.68))
                    }
                }

                if featuredItem.progressFraction > 0 {
                    HomeProgressBar(progress: featuredItem.progressFraction)
                        .frame(height: 5)
                }
            }
        }
    }

    private func heroActions(metrics: HomeDashboardMetrics) -> some View {
        Group {
            if metrics.isCompact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        heroActionButtons
                    }
                    .padding(.horizontal, 1)
                }
            } else {
                HStack(spacing: 12) {
                    heroActionButtons
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var heroPills: some View {
        if hasActivePlayback {
            PillLabel(text: playback.isPlayingRemote ? "Jellyfin" : "本地")
            PillLabel(text: playback.snapshot.paused ? "已暂停" : "播放中")
            if jellyfin.isSyncingPlayback && playback.isPlayingRemote {
                StatPill(text: "已同步", emphasized: true)
            }
        } else if let account = coordinator.homeJellyfinAccount {
            PillLabel(text: account.serverName)
            if let route = coordinator.homeJellyfinRoute?.name {
                PillLabel(text: route)
            }
        } else {
            PillLabel(text: "本地文件")
        }
    }

    private var heroRefreshButton: some View {
        Button {
            onRefresh()
        } label: {
            Group {
                if jellyfin.isRefreshingHome {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .frame(width: 34, height: 34)
            .background(.white.opacity(0.14))
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var heroActionButtons: some View {
        if hasActivePlayback {
            Button {
                onShowPlayer()
            } label: {
                Label("播放器", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentDeep)

            if coordinator.homeJellyfinAccount != nil {
                Button {
                    onShowLibrary()
                } label: {
                    Label("媒体库", systemImage: "rectangle.stack.fill")
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        } else if let featuredItem {
            Button {
                onSelectHomeItem(featuredItem)
            } label: {
                Label(
                    featuredItem.kind.isPlayable ? "继续" : "查看",
                    systemImage: featuredItem.kind.isPlayable
                        ? "play.fill" : "rectangle.stack.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentDeep)

            if canDownloadHomeItem(featuredItem) {
                if let offlineEntry = jellyfin.offlineEntry(
                    forRemoteItemID: featuredItem.id,
                    accountID: jellyfin.homeAccountID
                ), featuredItem.kind.isPlayable {
                    Button {
                        onShowPlayer()
                        coordinator.playDownloadedJellyfinEntry(offlineEntry)
                    } label: {
                        Label(
                            "离线播放",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                } else {
                    Button {
                        onDownloadHomeItem(featuredItem)
                    } label: {
                        Label(
                            homeDownloadButtonTitle(for: featuredItem),
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(
                        jellyfin.isDownloadingOfflineItem(featuredItem.id)
                    )
                }
            }

            if coordinator.homeJellyfinAccount != nil {
                Button {
                    onOpenHomeItemInLibrary(featuredItem)
                } label: {
                    Label("定位到媒体库", systemImage: "rectangle.stack.fill")
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button {
                    onSetHomeItemPlayedState(
                        featuredItem,
                        !featuredItem.isPlayed
                    )
                } label: {
                    Label(
                        featuredItem.isPlayed ? "标为未看" : "标为已看",
                        systemImage: featuredItem.isPlayed
                            ? "arrow.uturn.backward.circle"
                            : "checkmark.circle.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(jellyfin.isUpdatingPlayedState(for: featuredItem.id))

                Button {
                    onShowLibrary()
                } label: {
                    Label("媒体库", systemImage: "rectangle.stack.fill")
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }

        Button {
            onOpenFile()
        } label: {
            Label("打开文件", systemImage: "folder.badge.plus")
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }

    private func shelf(
        title: String,
        items: [JellyfinHomeItem],
        kind: HomeShelfKind,
        metrics: HomeDashboardMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(
                    title: title,
                    systemImage: "sparkles.rectangle.stack"
                )
                Spacer(minLength: 12)
                Text("\(items.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.45))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 12) {
                            ZStack(alignment: .bottomLeading) {
                                JellyfinArtworkView(
                                    url: coordinator.jellyfinPosterURL(
                                        for: item,
                                        width: 420,
                                        height: 630
                                    ),
                                    placeholderSystemName: item.kind == .series
                                        ? "tv.inset.filled" : "film.fill",
                                    cornerRadius: 24
                                )
                                .frame(
                                    width: metrics.shelfCardWidth,
                                    height: metrics.shelfArtworkHeight
                                )

                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.black.opacity(0.1),
                                        Color.black.opacity(0.62),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 24,
                                        style: .continuous
                                    )
                                )

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(item.kind.displayName)
                                            .font(
                                                .system(
                                                    size: 11,
                                                    weight: .bold,
                                                    design: .rounded
                                                )
                                            )
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(
                                                        Color.black.opacity(
                                                            0.42
                                                        )
                                                    )
                                            )

                                        Spacer(minLength: 8)

                                        HStack(spacing: 6) {
                                            if canDownloadHomeItem(item) {
                                                if let offlineEntry =
                                                    jellyfin
                                                    .offlineEntry(
                                                        forRemoteItemID: item
                                                            .id,
                                                        accountID: jellyfin
                                                            .homeAccountID
                                                    ),
                                                    item.kind.isPlayable
                                                {
                                                    homeOverlayIconButton(
                                                        systemName:
                                                            "arrow.down.circle.fill",
                                                        highlighted: true
                                                    ) {
                                                        onShowPlayer()
                                                        coordinator
                                                            .playDownloadedJellyfinEntry(
                                                                offlineEntry
                                                            )
                                                    }
                                                } else {
                                                    homeOverlayIconButton(
                                                        systemName:
                                                            jellyfin
                                                            .isDownloadingOfflineItem(
                                                                item.id
                                                            )
                                                            ? "clock.arrow.circlepath"
                                                            : "arrow.down.circle",
                                                        highlighted:
                                                            jellyfin
                                                            .isDownloadingOfflineItem(
                                                                item.id
                                                            ),
                                                        showsProgress:
                                                            jellyfin
                                                            .isDownloadingOfflineItem(
                                                                item.id
                                                            )
                                                    ) {
                                                        onDownloadHomeItem(item)
                                                    }
                                                }
                                            }

                                            if coordinator.homeJellyfinAccount
                                                != nil
                                            {
                                                homeOverlayIconButton(
                                                    systemName:
                                                        "rectangle.stack.fill"
                                                ) {
                                                    onOpenHomeItemInLibrary(
                                                        item
                                                    )
                                                }

                                                homeOverlayIconButton(
                                                    systemName: item.isPlayed
                                                        ? "arrow.uturn.backward.circle.fill"
                                                        : "checkmark.circle.fill",
                                                    highlighted: item.isPlayed,
                                                    showsProgress:
                                                        jellyfin
                                                        .isUpdatingPlayedState(
                                                            for: item.id
                                                        )
                                                ) {
                                                    onSetHomeItemPlayedState(
                                                        item,
                                                        !item.isPlayed
                                                    )
                                                }
                                            }

                                            Text(kind.actionTitle(for: item))
                                                .font(
                                                    .system(
                                                        size: 11,
                                                        weight: .bold,
                                                        design: .rounded
                                                    )
                                                )
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(
                                                    Capsule(style: .continuous)
                                                        .fill(
                                                            Palette.accentDeep
                                                                .opacity(0.92)
                                                        )
                                                )
                                        }
                                    }

                                    Spacer(minLength: 0)

                                    if item.progressFraction > 0 {
                                        HomeProgressBar(
                                            progress: item.progressFraction
                                        )
                                        .frame(height: 4)
                                    }
                                }
                                .padding(12)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.displayTitle)
                                    .font(
                                        .system(
                                            size: 16,
                                            weight: .bold,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(2)

                                Text(item.detailTitle)
                                    .font(
                                        .system(
                                            size: 12,
                                            weight: .semibold,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(Palette.ink.opacity(0.58))
                                    .lineLimit(2)

                                if let overview = item.overview?.nilIfBlank {
                                    Text(overview)
                                        .font(
                                            .system(
                                                size: 12,
                                                weight: .medium,
                                                design: .rounded
                                            )
                                        )
                                        .foregroundStyle(
                                            Palette.ink.opacity(0.44)
                                        )
                                        .lineLimit(2)
                                }
                            }
                        }
                        .frame(
                            width: metrics.shelfCardWidth,
                            alignment: .leading
                        )
                        .padding(14)
                        .panelStyle(cornerRadius: 28)
                        .contentShape(
                            RoundedRectangle(
                                cornerRadius: 28,
                                style: .continuous
                            )
                        )
                        .onTapGesture {
                            onSelectHomeItem(item)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var resolvedHeroTitle: String {
        if hasActivePlayback {
            return currentPlaybackTitle
        }
        if let featuredItem {
            return featuredItem.displayTitle
        }
        if let account = coordinator.homeJellyfinAccount {
            return account.displayTitle
        }
        return "Starmine"
    }

    private var resolvedHeroSubtitle: String? {
        if hasActivePlayback {
            return currentPlaybackEpisodeLabel.nilIfBlank
                ?? (playback.isPlayingRemote ? "Jellyfin" : "本地文件")
        }
        if let featuredItem {
            return featuredItem.detailTitle
        }
        if let route = coordinator.homeJellyfinRoute?.name {
            return route
        }
        return nil
    }

    private func canDownloadHomeItem(_ item: JellyfinHomeItem) -> Bool {
        switch item.kind {
        case .episode, .movie, .video, .series:
            return true
        default:
            return false
        }
    }

    private func homeDownloadButtonTitle(for item: JellyfinHomeItem) -> String {
        if jellyfin.isDownloadingOfflineItem(item.id) {
            return "下载中"
        }
        if item.kind == .series {
            let downloadedCount = jellyfin.offlineEpisodeCount(
                forSeriesID: item.id,
                accountID: jellyfin.homeAccountID
            )
            if downloadedCount > 0 {
                return "已离线 \(downloadedCount) 集"
            }
            return "下载整部剧"
        }
        if jellyfin.offlineEntry(
            forRemoteItemID: item.id,
            accountID: jellyfin.homeAccountID
        ) != nil {
            return "已下载"
        }
        return "下载"
    }

    private func runtimeText(fromTicks ticks: Double?) -> String? {
        guard let ticks, ticks > 0 else { return nil }
        let totalMinutes = Int((ticks / 10_000_000.0 / 60.0).rounded())
        if totalMinutes >= 60 {
            return "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分钟"
        }
        return "\(totalMinutes) 分钟"
    }

    private func timeText(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }

        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func homeOverlayIconButton(
        systemName: String,
        highlighted: Bool = false,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if showsProgress {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 30, height: 30)
            .background(
                Circle()
                    .fill(
                        highlighted
                            ? Palette.accentDeep.opacity(0.96)
                            : Color.black.opacity(0.42)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(showsProgress)
    }
}

private struct HomeProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let resolvedProgress = max(0, min(1, progress))

            Capsule(style: .continuous)
                .fill(.white.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Palette.accent)
                        .frame(
                            width: max(
                                8,
                                proxy.size.width * resolvedProgress
                            )
                        )
                }
        }
    }
}

private struct PlaybackSurfaceState: Equatable {
    var paused: Bool
    var videoAspect: Double

    init(snapshot: PlaybackSnapshot) {
        paused = snapshot.paused
        videoAspect = snapshot.videoAspect
    }
}
