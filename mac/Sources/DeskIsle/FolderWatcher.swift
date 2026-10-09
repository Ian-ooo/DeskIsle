import Foundation
import CoreServices
import DeskIsleCore   // PathOwnership（事件归属）/ DirectoryScan（指纹的隐藏项口径）

/// portal 分区的内容变更探测器。
///
/// ## 两级机制
/// **主：FSEvents**（`FSEventStream`，每个 portal 根目录一条**递归**流）。
/// 事件到达 → 立即回报，实测延迟 ≈ 0.2s。递归意味着**子目录里的变化也能被看见**，
/// 这是轮询做不到的（轮询只能 stat 根目录自己的 mtime）。
///
/// **兜底：mtime 轮询**（高频层 + 指纹层）。FSEvents 依赖系统事件守护进程，
/// 在个别卷（网络盘 / 某些外置盘）上可能不投递；轮询保证那时行为与本改动之前完全一致。
/// 正常路径下轮询是**静默**的：事件处理时会把快照刷新掉，轮询看不到差值，自然不回报。
/// 两层周期都随流的健康度切换：流在 = 10s / 120s（几乎只是保险），流不在 = 2s / 30s。
///
/// ## ⚠️ 历史误判的纠正（改这里之前请先读完）
/// 本项目此前在头部注释与 README 里写着「FSEvents 不投递，故只能用轮询」。
/// 那个结论**测的是另一个 API**：当时的最小用例用的是目录级 kevent
/// （`DispatchSourceFileSystemObject`），它在本机确实完全不投递；
/// 但 kevent 与 FSEvents 是两套彼此独立的机制，前者不投递**推不出**后者不投递。
/// 2026-10-01 用独立最小用例复测 FSEvents：根目录新增 / 子目录新增 / 同名文件被
/// 追加写入 / 移入废纸篓，**全部投递**（含递归）。因此改为事件驱动。
///
/// ## 为什么不是「一条流监听所有根目录」
/// 一条流能省一点资源，但事件回来之后仍要按路径反查归属（见 `PathOwnership`），
/// 而每个根目录一条流时归属是**结构上**确定的，且增删分区只需动对应的那条流。
///
/// ## 省电
/// 隐藏屏、已隐藏、已折叠的分区通过 `isActive` 外部裁决后**不参与回报**（与轮询一致）。
/// FSEvents 是事件驱动、不是定时器，空闲时零开销。
final class FolderWatcher {

    /// 某分区内容有变化（主线程回调，调用方负责刷新视图）
    var onChange: ((_ id: String) -> Void)?

    /// 外部裁决：该分区当前是否值得探测。返回 false 则完全跳过（省电）。
    var isActive: ((_ id: String) -> Bool)?

    /// 该分区**当前正在显示的目录**（未进子目录时 = 根目录）。
    ///
    /// 用途是判「这条事件值不值得刷新界面」：递归流会把根目录下任何深度的改动
    /// 都送上来，全靠它把深层噪音（`build/`、`node_modules/`）挡在外面。
    /// 由 AppDelegate 注入（数据源是 `effectiveBrowsePath`），**每次事件现取**，
    /// 所以用户进出子目录不需要重建监听。
    var displayedPath: ((_ id: String) -> String)?

    private struct Watched {
        var path: String
        var dirMtime: Date
        var digest: [String: Int64]?
        var digestAt: Date
    }

    private var watched: [String: Watched] = [:]
    /// id → 根目录。FSEvents 事件按路径反查归属时用（见 `PathOwnership.owner`）。
    private var rootsByID: [String: String] = [:]

    /// **根目录 → 流**。按路径而不是序号索引，是为了能做增量（见 `syncStreams`）。
    private var streams: [String: FSEventStreamRef] = [:]

    private var pending: Set<String> = []
    private var flushScheduled = false
    private var lastFire: [String: Date] = [:]

    private var timer: DispatchSourceTimer?
    private var lastDigestRoundAt = Date.distantPast

    /// 高频层周期（秒）—— 兜底用，FSEvents 正常时它什么都不做。
    ///
    /// ⚠️ 流健康时放宽到 10s：FSEvents 已在 0.15s 延迟内投递，2s 轮询是**纯重复劳动**，
    /// 只贡献每秒 0.5 次唤醒。流建立失败（回退纯轮询）时才恢复 2s，保证行为与改造前一致。
    private var fastInterval: TimeInterval { streams.isEmpty ? 2 : 10 }
    /// 低频层（内容 / 大小指纹）的触发周期（秒）：与 `fastInterval` 解耦，
    /// 免得改一个周期把另一层的节奏也带偏（原来用 `tick % n` 就是这么耦合的）。
    private var digestEverySecs: TimeInterval { streams.isEmpty ? 30 : 120 }
    /// 相邻两次指纹计算的最小间隔（秒）
    private let digestMinGap: TimeInterval = 25
    /// 目录条目数超过此值则放弃指纹（全量 stat 的代价高于收益）
    private let digestEntryLimit = 500
    /// 事件合流窗口（秒）：一次操作往往连着来好几条事件（创建 → 修改 → 改名），
    /// 逐条回报会让同一份列表被重扫好几遍。
    private let eventCoalesce: TimeInterval = 0.2
    /// 同一分区两次回报的最小间隔（秒）：挡住「事件」与「轮询」撞在一起时的重复刷新。
    private let minFireGap: TimeInterval = 0.3

    deinit { stop() }

    /// 重建监听集合。传入全部分区（本类自行过滤 portal）；
    /// `pathProvider` 负责给出某分区的根目录。
    /// 同一 id 且路径未变时**沿用旧快照**，避免整轮重算指纹。
    func update(partitions: [[String: Any]], pathProvider: (_ id: String, _ type: String) -> String) {
        var next: [String: Watched] = [:]
        var roots: [String: String] = [:]
        for p in partitions {
            let type = p["type"] as? String ?? ""
            guard type == "portal" else { continue }
            guard let id = p["id"] as? String else { continue }
            let path = pathProvider(id, type)
            guard !path.isEmpty else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }

            if let old = watched[id], old.path == path, old.digest != nil {
                next[id] = old
            } else {
                next[id] = Watched(path: path,
                                   dirMtime: Self.dirMtime(path),
                                   digest: Self.fingerprint(path, limit: digestEntryLimit),
                                   digestAt: Date())
            }
            roots[id] = path
        }
        watched = next
        rootsByID = roots
        syncStreams()
    }

    func start() {
        syncStreams()
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + fastInterval, repeating: fastInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for (_, s) in streams { dispose(s) }
        streams.removeAll()
        watched.removeAll()
        rootsByID.removeAll()
        pending.removeAll()
        flushScheduled = false
        lastFire.removeAll()
        lastDigestRoundAt = Date.distantPast
    }

    // MARK: - FSEvents

    /// 让流集合跟上当前的 `rootsByID`（**增量**）。
    ///
    /// ## 为什么不能「先全停再全建」
    /// 改之前这里是全量重建。而 `update()` 在**新建 / 删除任何一个 portal 分区**时都会被调用
    /// （`AppDelegate` 的 `createPartition` / `removePartition`），于是每动一次分区，
    /// 其它所有 portal 的流都被连坐销毁重建。
    /// 代价有两笔：① 重建是 stop+invalidate+release+create+start 一串系统调用，N 个分区各来一遍；
    /// ② **更隐蔽也更要紧** —— 新流用 `kFSEventStreamEventIdSinceNow` 订阅，
    /// 意味着「重建这一瞬间之后」才开始收件，窗口期内发生的变化**永久漏掉**。
    /// 轮询兜底最终能捞回来（10s 一次 mtime），但 FSEvents 的低延迟优势在那一刻是失效的。
    ///
    /// 增量之后：只有真正新增 / 失效的根目录会动，路径没变的分区**它的流从头到尾没停过**，
    /// 既没有漏窗，也没有无谓的系统调用。
    ///
    /// 顺带一个副产品：键是路径而不是 id，两个分区映射同一个目录时只会建**一条**流
    /// （原来会建两条重复监听同一路径的流）。
    private func syncStreams() {
        let wanted = Set(rootsByID.values)
        for (path, s) in streams where !wanted.contains(path) {
            dispose(s)
            streams.removeValue(forKey: path)
        }
        for path in wanted where streams[path] == nil {
            if let s = makeStream(root: path) { streams[path] = s }
        }
    }

    private func dispose(_ s: FSEventStreamRef) {
        // ⚠️ `FSEventStreamRelease` 之前必须先 Stop + Invalidate，否则回调可能落在没人持有的对象上
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    private func makeStream(root: String) -> FSEventStreamRef? {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil,
                                           release: nil,
                                           copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)   // 路径以字符串数组给到回调
            | UInt32(kFSEventStreamCreateFlagFileEvents)         // 要文件级事件，而不只是「这个目录变了」
            | UInt32(kFSEventStreamCreateFlagNoDefer)            // 别为凑延迟窗口而攒着
            | UInt32(kFSEventStreamCreateFlagWatchRoot)          // 根目录被改名 / 删掉也要知道
        guard let s = FSEventStreamCreate(kCFAllocatorDefault,
                                          folderWatcherFSEventCallback,
                                          &context,
                                          [root] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.15,
                                          FSEventStreamCreateFlags(flags)) else {
            NSLog("[DeskIsle] FSEvents 创建失败：%@（回退为轮询探测）", root)
            return nil
        }
        // 送回主线程：本类全部状态（watched / pending）都在主线程上访问，
        // 换到别的队列就必须加锁，而这里每条事件的工作量本来就微不足道。
        FSEventStreamSetDispatchQueue(s, .main)
        guard FSEventStreamStart(s) else {
            NSLog("[DeskIsle] FSEvents 启动失败：%@（回退为轮询探测）", root)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return nil
        }
        return s
    }

    /// FSEvents 回调（主队列）。只做「归谁 + 相不相关 + 攒起来」，真正的刷新在合流后。
    fileprivate func handle(eventPaths: [String]) {
        for p in eventPaths {
            guard let id = PathOwnership.owner(of: p, roots: rootsByID) else { continue }
            if let active = isActive, !active(id) { continue }
            guard let w = watched[id] else { continue }
            let shown = displayedPath?(id) ?? ""
            let display = shown.isEmpty ? w.path : shown
            guard PathOwnership.affectsListing(eventPath: p, shownDirectory: display) else { continue }
            pending.insert(id)
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !pending.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + eventCoalesce) { [weak self] in
            self?.flush()
        }
    }

    /// 合流窗口结束：刷新快照 + 回报。
    ///
    /// 刷新快照是必须的 —— 它把「这次变化已经处理过了」写回去，
    /// 轮询随后 stat 时就看不到差值，不会为同一次变化再报一遍。
    ///
    /// ⚠️ 这里**刻意不重算指纹**：事件流已经证明「目录变了」，再 stat 一遍整个目录
    /// （≤500 项）纯属重复劳动。真实代价出现在大目录 + 持续写入（下载、编译输出）时：
    /// 每来一批事件就全量 stat 一次，形成肉眼可见的 CPU 尖峰。
    /// 指纹是「探测不改 mtime 的内容 / 大小变化」用的 —— 那是低频层的职责，
    /// 这里只把它的检查时点往后推（`digestAt = now`），避免刚报完又被指纹再报一次。
    private func flush() {
        flushScheduled = false
        let ids = pending
        pending.removeAll()
        let now = Date()
        for id in ids {
            guard var w = watched[id] else { continue }
            w.dirMtime = Self.dirMtime(w.path)
            w.digestAt = now
            watched[id] = w
            fire(id, now)
        }
    }

    private func fire(_ id: String, _ now: Date) {
        if let last = lastFire[id], now.timeIntervalSince(last) < minFireGap { return }
        lastFire[id] = now
        onChange?(id)
    }

    // MARK: - 轮询（兜底）

    private func poll() {
        let now = Date()
        let digestRound = now.timeIntervalSince(lastDigestRoundAt) >= digestEverySecs
        if digestRound { lastDigestRoundAt = now }

        for (id, w) in watched {
            if let active = isActive, !active(id) { continue }

            // 高频层：目录 mtime 变化 = 条目增删 / 改名
            //
            // ⚠️ 与 `flush()` 同理，这里也不重算指纹：mtime 变了已经证明要报，
            // 全量 stat 一遍只是给低频层省一次活，不值当（见 flush 的注释）。
            let m = Self.dirMtime(w.path)
            if m != w.dirMtime {
                watched[id]?.dirMtime = m
                watched[id]?.digestAt = now
                fire(id, now)
                continue
            }

            // 低频层：内容 / 大小变化（不改目录 mtime）
            guard digestRound, now.timeIntervalSince(w.digestAt) >= digestMinGap else { continue }
            watched[id]?.digestAt = now
            guard let fresh = Self.fingerprint(w.path, limit: digestEntryLimit) else { continue }
            if fresh != w.digest {
                watched[id]?.digest = fresh
                fire(id, now)
            }
        }
    }

    // MARK: - 探测原语

    static func dirMtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            ?? Date.distantPast
    }

    /// 目录内容的轻量指纹：条目名 → 文件大小。
    /// 条目数超过 `limit`（或目录读不出来）时返回 nil，表示放弃指纹 ——
    /// 此时该目录退化为纯 mtime 探测，不会误报。隐藏文件跳过（与视图的展示规则一致）。
    static func fingerprint(_ path: String, limit: Int) -> [String: Int64]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path),
              names.count <= limit else { return nil }
        var digest: [String: Int64] = [:]
        digest.reserveCapacity(names.count)
        for name in names where DirectoryScan.isVisible(name) {
            let full = (path as NSString).appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: full)
            digest[name] = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return digest
    }
}

/// FSEvents 的回调必须是 C 函数指针，不能捕获上下文 —— 因此做成文件作用域的常量，
/// 靠 `context.info` 把 `FolderWatcher` 实例带回来。
private let folderWatcherFSEventCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
    guard let info, numEvents > 0 else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    // 带 `kFSEventStreamCreateFlagUseCFTypes` 时 eventPaths 就是 CFArray<CFString>
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    watcher.handle(eventPaths: paths)
}
