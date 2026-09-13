import UIKit
import CoreImage

// MARK: - 专辑封面来源解析
//
// 「更好的逐词歌词」的背景：模糊版专辑封面 + 暗化渐变。
//
// 为什么不用 UIBlurEffect 去糊屏幕后面的东西、也不用 Metal shader：
//   1. Spotify 自己那层歌词背景只暴露一个颜色（SPTNowPlayingBackgroundViewModel.color()），
//      没有图也没有模糊视图，所以没有「现成的模糊封面」可以借；
//   2. 实时 UIBlurEffect 会把盖在下面的原生歌词文字一起糊成灰影子，还得额外去隐藏原生视图；
//   3. Apple Music 与 Spotify 的歌词背景本来都不是实时模糊，而是预渲染的封面模糊图 / 算出来的色，
//      每首歌算一次就够，开销可以忽略。
//
// 所以这里走「静态模糊封面」：拉原图 → 缩到小尺寸 → CIGaussianBlur → 存缓存 → 铺满 + 暗化。

/// 从 SPTPlayerTrack 拿专辑封面。
///
/// `metadata()` 的键名在各 Spotify 版本/平台间不统一，所以按候选键逐个试，
/// 并且把成功过的 URL 记下来 —— 只要这首歌曾经取到过，同一首歌的后续调用就有兜底，
/// 不会因为某次 metadata 尚未就绪而闪回纯色背景。
enum LyricsArtworkResolver {
    /// 候选顺序：越可能直接是 URL 的键越靠前。
    private static let urlKeys = [
        "image_url", "imageUrl", "image", "cover_art", "coverArt",
        "cover_url", "coverUrl", "artwork_url", "artwork",
        "album_image_url", "album_art_url", "thumbnail_url", "picture_url"
    ]

    /// 只给 ID 的键：需要自己拼 CDN 地址。
    private static let imageIDKeys = [
        "image_id", "imageId", "image_uri", "cover_art_id", "coverId",
        "image_hex", "imageIdHex"
    ]

    private static let stateQueue = DispatchQueue(label: "com.eevee.lyrics.artwork")
    private static var lastResolved: (trackKey: String, url: URL)?
    private static var didLogMetadataDump = false

    static func artworkURL(for track: SPTPlayerTrack?) -> URL? {
        guard let track else { return nil }

        let metadata = track.metadata()
        let trackKey = track.trackIdentifier

        if !didLogMetadataDump {
            didLogMetadataDump = true
            // 只有第一次 dump，避免刷屏；对不上的时候照这行日志调 urlKeys 就行。
            writeDebugLog("[Artwork] metadata keys: \(metadata.keys.sorted())")
        }

        if let url = urlFromMetadata(metadata) {
            remember(url, for: trackKey)
            return url
        }

        // 取不到时用上次成功的 URL 兜底 —— 但必须限定「同一首歌」，
        // 否则换歌时 metadata 尚未就绪会把上一首的封面贴到新歌上。
        let remembered = stateQueue.sync { lastResolved }
        guard let remembered, remembered.trackKey == trackKey else { return nil }
        return remembered.url
    }

    private static func remember(_ url: URL, for trackKey: String) {
        stateQueue.sync { lastResolved = (trackKey, url) }
    }

    private static func urlFromMetadata(_ metadata: [String: String]) -> URL? {
        for key in urlKeys {
            guard let raw = metadata[key], !raw.isEmpty else { continue }

            // 实测：`image_url` 的值是 `spotify:image:<hex>`，不是 http(s) URL。
            // 所以先走「当 image 标识解析」，再退回「当普通 URL 解析」——
            // 顺序不能反：scheme 是 `spotify`，用 http 校验会把它直接拒掉。
            if let url = urlFromImageID(raw) { return url }

            if let url = URL(string: raw), url.scheme?.hasPrefix("http") == true {
                return url
            }
        }

        for key in imageIDKeys {
            guard let hex = metadata[key], !hex.isEmpty else { continue }
            if let url = urlFromImageID(hex) { return url }
        }

        // URI 有时携带 image 信息（本地文件等场景）。
        if let uriString = metadata["uri"], uriString.hasPrefix("image") {
            return urlFromImageID(uriString)
        }

        return nil
    }

    /// 把 Spotify 的 image 标识转成 CDN 地址。
    ///
    /// 实测 `metadata()["image_url"]` 拿到的是 **`spotify:image:<hex>` URI**，不是 http(s) URL，
    /// 所以不能拿 `URL(string:)` 的 scheme 去判断（scheme 是 `spotify`，会被 http 校验拒掉）。
    /// 这里统一剥掉各种可能的前缀，只留 hex，再拼 `i.scdn.co`。
    private static func urlFromImageID(_ rawID: String) -> URL? {
        var hex = rawID.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["spotify:image:", "image://", "spotify:image", "image:"] {
            if hex.hasPrefix(prefix) {
                hex = String(hex.dropFirst(prefix.count))
                break
            }
        }

        // 兜底：只保留最后一段，防止 `spotify:image://<hex>` 这类多斜杠写法。
        if let last = hex.split(separator: "/").last {
            hex = String(last)
        }
        hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 只接受看起来像 Spotify image hash 的值，避免把任意字符串拼成 URL。
        // 用显式 ASCII 判断，不用 Character.isHexDigit（后者认得非 ASCII 的十六进制字符）。
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard hex.count >= 16,
              hex.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else {
            return nil
        }
        return URL(string: "https://i.scdn.co/image/\(hex)")
    }
}

// MARK: - 背景视图

/// 歌词页背景：模糊专辑封面 + 暗化渐变，外加一层材质（可选）压掉色带。
///
/// 层级（自下而上）：
///   blurredImageView  —— 封面模糊图，aspectFill + 1.12 倍 overscan
///   scrimView         —— UIBlurEffect(.systemUltraThinMaterialDark)，可选
///   gradientLayer     —— 上/中/下三段暗化，中间最透（聚焦行所在区域）
final class LyricsBackdropView: UIView {

    /// 背景的两种用法。
    enum Style {
        /// 卡片式：铺在歌词容器内，上下重、中间轻的暗化渐变 —— 让滚进/滚出的歌词
        /// 在容器边缘有缓冲。用于内嵌预览。
        case card

        /// 舞台式：**溢出到容器之外、铺满整屏**，并且均匀暗化（不做上下渐变）。
        ///
        /// 用于全屏歌词：Spotify 原有的 header / 控件栏是它自己的视图、位于
        /// 歌词容器之外，只有让背景溢出去，"壳"和"肉"才会落在同一块背景上，
        /// 那道"品红壳 / 褐红肉"的割裂才会消失。
        case stage
    }

    private let blurredImageView = UIImageView()
    private let scrimView = UIVisualEffectView(effect: nil)
    private let gradientLayer = CAGradientLayer()

    /// 兜底底色（封面拿不到时整块用它，行为等同于改动前）。
    private var baseColor: UIColor = .black
    /// 暗化渐变的中间透度 —— 决定封面颜色能透出多少。
    ///
    /// 取值偏低是刻意的：兜底色来自 `Color.normalized(0.5)`，本身已经是中灰调，
    /// 如果这里再重压一层，模糊封面会比改动前的纯色底更灰更闷，反而不如原生。
    /// 中间 0.12 让封面颜色透出来，两端 0.42 负责歌词滚进/滚出时的渐隐。
    private let middleScrimAlpha: CGFloat = 0.12
    private let edgeScrimAlpha: CGFloat = 0.42
    /// 舞台式的**均匀**暗化度（默认档）。
    ///
    /// 比卡片的「中间 0.12 / 两端 0.42」整体更暗一点：全屏是"深色舞台 + 白字 +
    /// 白色原生控件"，底越暗，白的图标与文字越清楚。
    private let stageScrimAlpha: CGFloat = 0.30
    /// 舞台式的**全屏暗化度**：压在最上面的那层渐变的 alpha。
    ///
    /// ⚠️ 这个值曾经是 `1.0`，理由是"全屏必须盖住底下的 Spotify 页面"——
    /// **那个理由是错的，而且它正好把封面涂死了**：
    ///
    /// 本视图的图层顺序是
    ///   1. `backgroundColor`（不透明，图片路径下是 `.black`）
    ///   2. `blurredImageView`（模糊封面）
    ///   3. `scrimView`（可选系统材质）
    ///   4. `gradientLayer` ← **盖在最上面**，用的就是这个 alpha
    ///
    /// 也就是说"整块背景透不透"由**第 1 层**决定（那是 `isBackdropOpaque` 开关的事），
    /// 而这一层只是叠在封面**之上**的一层黑纱。alpha = 1.0 等于用一层纯黑把
    /// 封面完全盖掉 —— 全屏就成了死黑一块，预览却正常（预览那档是 0.30）。
    /// 这正是"全屏只有黑背景、预览没问题"的原因。
    ///
    /// 现在 0.55：封面仍透出约 45%（有封面的颜色与层次），整体足够暗，
    /// 白字与白色控件依然清楚。不透明的责任交回第 1 层。
    private let solidStageScrimAlpha: CGFloat = 0.55
    /// 描边 overscan 比例，避免模糊后边缘透出底色。
    private let overscan: CGFloat = 1.12

    /// 背景样式。改动会立即重算渐变与溢出范围。
    var style: Style = .card {
        didSet {
            guard style != oldValue else { return }
            applyStyle()
        }
    }

    /// 是否走"实心"档（目前只有全屏 + 我们真正接管渲染时用）。
    /// 与 `style` 独立：舞台式也有"够不够实"之分。
    var solid: Bool = false {
        didSet {
            guard solid != oldValue else { return }
            applyGradientColors()
        }
    }

    /// 是否完全不透明（全屏 + 我们接管渲染时）。
    ///
    /// ⚠️ 名字里必须带 `backdrop`：**不能叫 `opaque`**。
    /// `UIView` 上本来就有 `opaque`（Swift 里已重命名为 `isOpaque`），
    /// 用那个名字等于在子类里重定义父类属性 —— 既缺 `override`，又用了被弃用的旧名。
    ///
    /// ⚠️ 与 `solid` 的区别，以及为什么必须有这个开关：
    ///
    /// `solid` 只管**封面层内部**那层渐变的暗化度；而"这一整块背景透不透"还取决于
    /// `backgroundColor`。旧 UIKit overlay（逐词歌词关掉时走的那条路）把
    /// `backgroundColor` 设成了**不透明的专辑纯色**，于是它整块盖住了 Spotify 原生
    /// 那一页 —— 标题栏、进度条、播放键全被压掉，屏幕上只剩歌词和一块底色。
    ///
    /// 而那条路的设计意图本来是"**数据不可用就整块透明、交还原生**"
    /// （见 `LyricsWordByWordOverlayView.setCurrentTime` 的 guard）。不透明底色把这个
    /// 退路堵死了。
    ///
    /// 所以：**只有"我们确实替换了原生内容"时才允许不透明**。
    /// Apple Music 层（自己画歌词 + 自绘壳）→ `true`；
    /// 旧 overlay、以及数据不可用的透明状态 → `false`。
    var isBackdropOpaque: Bool = false {
        didSet {
            guard isBackdropOpaque != oldValue else { return }
            applyOpacity()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        isUserInteractionEnabled = false
        clipsToBounds = true

        blurredImageView.contentMode = .scaleAspectFill
        blurredImageView.clipsToBounds = true
        blurredImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blurredImageView)

        scrimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrimView.isHidden = true
        addSubview(scrimView)

        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradientLayer)

        applyGradientColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // overscan：比 bounds 略大并居中，模糊边缘不会露出底色。
        let width = bounds.width * overscan
        let height = bounds.height * overscan
        blurredImageView.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        scrimView.frame = bounds
        gradientLayer.frame = bounds
    }

    // MARK: 对外配置

    /// 每次 rebuild（换歌 / 换数据）调用一次。
    /// - Parameters:
    ///   - baseColor: 兜底底色，来自 CustomLyrics 算好的原生歌词背景色。
    ///   - showsArtwork: 是否使用模糊封面（用户选了静态色 / 原生色时为 false）。
    ///   - material: 是否再叠一层系统材质压色带。
    func configure(
        baseColor color: UIColor,
        showsArtwork: Bool,
        material: Bool
    ) {
        // 左侧的 `self.` 不能省：参数名与属性同名时，不带 self 会解析成参数。
        self.baseColor = color
        applyOpacity()

        showsScrim = showsArtwork && material
        scrimView.isHidden = !isBackdropOpaque || !showsScrim
        if showsArtwork && material {
            // 本工程 deployment target 是 iOS 14，材质系列（.systemUltraThinMaterialDark）
            // 从 iOS 13 起就有，不需要 #available 分支。
            scrimView.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        } else {
            scrimView.effect = nil
        }

        // 溢出范围与渐变都随样式变化，所以这里走 applyStyle 而不是只更新颜色。
        applyStyle()

        guard showsArtwork else {
            blurredImageView.image = nil
            return
        }

        loadArtworkIfNeeded()
    }

    // MARK: 内部

    /// 当前底色的感知亮度（0~1）。供文字层判断该用白字还是黑字。
    var baseColorBrightness: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard baseColor.getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            return 0.5
        }
        return red * 0.299 + green * 0.587 + blue * 0.114
    }

    private var lastLoadedTrackKey: String?
    private var isLoading = false

    /// 系统材质层当前是否应该显示（由 `configure` 的 `showsArtwork && material` 决定）。
    /// 记成状态是因为 `applyOpacity()` 也要用它 —— 材质层的显隐由两个条件共同决定。
    private var showsScrim = false

    /// 底色是否完全不透明。
    ///
    /// `isBackdropOpaque == false` 时整块背景（含封面层与暗化渐变）一起透明 —— 这是
    /// "把屏幕交还给 Spotify 原生界面"的唯一开关，见 `isBackdropOpaque` 的注释。
    private func applyOpacity() {
        backgroundColor = isBackdropOpaque ? baseColor : .clear

        let transparent = !isBackdropOpaque
        blurredImageView.isHidden = transparent
        gradientLayer.isHidden = transparent
        scrimView.isHidden = transparent || !showsScrim

        // 透明时不再铺封面；重新变为不透明时补上（`configure` 之后才切开关的情况）。
        if isBackdropOpaque, blurredImageView.image == nil {
            loadArtworkIfNeeded()
        }
    }

    private func applyGradientColors() {
        if style == .stage {
            // 舞台式：均匀暗化，不做上下渐变。
            //
            // 为什么不要渐变：全屏时这块背景要同时承载歌词**和** Spotify 原有的
            // header / 控件栏。一旦带上"上重下轻"的渐变，歌词区与控件区就会落在
            // 明暗不同的两段上 —— 那正是"壳肉割裂"的成因之一。
            let alpha = solid ? solidStageScrimAlpha : stageScrimAlpha
            gradientLayer.colors = [
                baseColor.withAlphaComponent(alpha).cgColor,
                baseColor.withAlphaComponent(alpha).cgColor
            ]
            gradientLayer.locations = [0.0, 1.0]
            return
        }

        gradientLayer.colors = [
            baseColor.withAlphaComponent(edgeScrimAlpha).cgColor,
            baseColor.withAlphaComponent(middleScrimAlpha).cgColor,
            baseColor.withAlphaComponent(edgeScrimAlpha).cgColor
        ]
        gradientLayer.locations = [0.0, 0.45, 1.0]
    }

    /// 按当前 `style` 重算渐变。
    ///
    /// ⚠️ 这里曾经试图用「负 margin 的 autoresizingMask」让背景溢出到父视图之外，
    /// 铺满整屏。**那是错的**：autoresizing 只在父视图 bounds 内重新分配空间，
    /// 子视图永远不可能超出父视图的 bounds。所以那样写的效果是"什么都没变"。
    ///
    /// 正确的做法在挂载点：全屏时把整层挂到全屏页的**根视图**上（见
    /// `LyricsWordByWordFullscreenModernHostHook`），那时本视图自然就是整屏大小。
    ///
    /// ⚠️ 曾经还有后半句"并隐藏原生的歌词内容容器" —— **那句是错的，已删除**。
    /// 全屏页的根视图里一个子视图都没有（dump 实测），藏任何一个"看起来像歌词容器"
    /// 的视图都会把整页内容一起藏掉。原生视图一个都不能碰：
    /// 要盖住壳，只能靠 `solidStageScrimAlpha` 把背景做够暗。
    private func applyStyle() {
        // 两种样式都只需跟随宿主尺寸。
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        applyGradientColors()
    }

    private func loadArtworkIfNeeded() {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        let trackKey = track?.trackIdentifier ?? "unknown"

        guard !isLoading, lastLoadedTrackKey != trackKey else { return }

        guard let url = LyricsArtworkResolver.artworkURL(for: track) else {
            // 封面拿不到 —— 保持兜底色，不重试（避免每次 rebuild 都白试一遍）。
            lastLoadedTrackKey = trackKey
            writeDebugLog("[Artwork] no artwork URL for \(trackKey) — keeping flat color")
            return
        }

        if let cached = LyricsBackdropImageCache.shared.blurredImage(for: url) {
            lastLoadedTrackKey = trackKey
            blurredImageView.image = cached
            writeDebugLog("[Artwork] cache hit for \(trackKey)")
            return
        }

        isLoading = true
        lastLoadedTrackKey = trackKey
        writeDebugLog("[Artwork] fetching \(url.absoluteString) for \(trackKey)")

        LyricsBackdropImageCache.shared.loadBlurredImage(for: url) { [weak self] image in
            guard let self else { return }
            self.isLoading = false
            guard let image else {
                writeDebugLog("[Artwork] fetch/blur failed for \(trackKey)")
                return
            }
            // 期间可能已经换歌，只在仍是同一首时套用。
            let current = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
            guard (current?.trackIdentifier ?? "unknown") == trackKey else { return }
            self.blurredImageView.image = image
        }
    }
}

// MARK: - 模糊图缓存

/// 每首歌只算一次模糊图，结果缓存在内存里（NSCache，系统可回收）。
final class LyricsBackdropImageCache {

    static let shared = LyricsBackdropImageCache()

    /// 模糊前先缩到这个尺寸：模糊本身会抹掉细节，用大图纯属浪费内存。
    private let downscaleMaxSide: CGFloat = 96
    /// 在「缩小后的图」上应用的模糊半径。
    private let blurRadius: CGFloat = 18
    private let maximumResponseBytes = 16 * 1024 * 1024

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    /// 同一 URL 并发请求合并。
    private var inFlight: [URL: [(UIImage?) -> Void]] = [:]
    private let lock = NSLock()

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
        cache.countLimit = 12
    }

    func blurredImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 回调在主线程；失败时为 nil。
    func loadBlurredImage(for url: URL, completion: @escaping (UIImage?) -> Void) {
        if let cached = blurredImage(for: url) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        lock.lock()
        if inFlight[url] != nil {
            inFlight[url]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[url] = [completion]
        lock.unlock()

        session.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }

            var image: UIImage?
            if let error {
                writeDebugLog("[Artwork] network error: \(error.localizedDescription)")
            } else if let data, !data.isEmpty, data.count <= self.maximumResponseBytes {
                image = self.makeBlurredImage(from: data)
            }

            if let image { self.cache.setObject(image, forKey: url as NSURL) }

            self.lock.lock()
            let waiting = self.inFlight.removeValue(forKey: url) ?? []
            self.lock.unlock()

            // 所有等待者都在主线程回调。
            let result = image
            DispatchQueue.main.async {
                for callback in waiting { callback(result) }
                if waiting.isEmpty { completion(result) }
            }
        }.resume()
    }

    /// 缩图 → 模糊 → 裁回原尺寸（模糊会外扩，不裁会带一圈透明边）。
    private func makeBlurredImage(from data: Data) -> UIImage? {
        guard let source = CIImage(data: data),
              let downscaled = downscale(source, maxSide: downscaleMaxSide) else {
            return nil
        }

        let extent = downscaled.extent
        let clamped = downscaled.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: extent),
              let cgImage = context.createCGImage(output, from: extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private func downscale(_ image: CIImage, maxSide: CGFloat) -> CIImage? {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > 1, longest.isFinite else { return nil }

        let scale = min(1, maxSide / longest)
        guard scale < 1 else { return image }

        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
