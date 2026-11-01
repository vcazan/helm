import SwiftUI

/// An image on the Mac: a path, and the folder a relative path is in.
struct ImageRef: Identifiable, Hashable {
    var path: String
    var root: String?
    var id: String { (root ?? "") + "|" + path }
    var name: String { (path as NSString).lastPathComponent }

    static func isImage(_ path: String) -> Bool {
        let ext = (path.components(separatedBy: "?").first.map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
    }
}

/// Images open in the full-screen viewer, and which one is showing.
struct ImageGallery: Identifiable, Hashable {
    var images: [ImageRef]
    var index: Int
    var id: String { images.map(\.id).joined(separator: ",") + "#\(index)" }
}

/// Loads an image from the Mac (or the web) at roughly the size it'll be drawn.
struct HubImage: View {
    var ref: ImageRef
    /// Points across the image will be drawn; the hub scales it down to match.
    var width: CGFloat
    var contentMode: ContentMode = .fill
    var onAspect: ((CGFloat) -> Void)? = nil
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var failure: String?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else if let failure {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 17, weight: .medium))
                    Text(failure).font(.inter(11)).multilineTextAlignment(.center).lineLimit(3)
                }
                .foregroundStyle(BUI.ink3)
                .padding(10)
                .transition(.opacity)
            } else {
                Rectangle().fill(BUI.inset).overlay { ProgressView().controlSize(.small).tint(BUI.ink3) }.transition(.opacity)
            }
        }
        .animation(BUI.easeOutStrong, value: image != nil)
        .animation(BUI.easeOutStrong, value: failure)
        .task(id: ref.id + "\(Int(width))") {
            guard image == nil, let model else { return }
            do {
                let img = try await model.image(ref, pixels: width * scale)
                image = img
                if img.size.height > 0 { onAspect?(img.size.width / img.size.height) }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Thumbnails of the images a run of tool calls made or looked at; tapping one opens the viewer.
struct ImageStrip: View {
    var images: [ImageRef]
    @Namespace private var zoom
    @State private var gallery: ImageGallery?
    @State private var aspects: [String: CGFloat] = [:]
    @State private var taps = 0

    private var single: Bool { images.count == 1 }
    private var height: CGFloat { single ? 220 : 132 }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.element.id) { i, ref in
                    thumb(ref, index: i)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .fullScreenCover(item: $gallery) { g in
            ImageViewer(gallery: g).navigationTransition(.zoom(sourceID: g.images[g.index].id, in: zoom))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }

    private func thumb(_ ref: ImageRef, index: Int) -> some View {
        let aspect = aspects[ref.id] ?? (single ? 1.5 : 0.75)
        let w = min(single ? 320 : 240, max(single ? 120 : 72, height * aspect))
        return Button {
            taps += 1
            gallery = ImageGallery(images: images, index: index)
        } label: {
            HubImage(ref: ref, width: w, onAspect: { a in withAnimation(BUI.easeOutStrong) { aspects[ref.id] = a } })
                .frame(width: w, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BUI.line, lineWidth: 1))
                .overlay(alignment: .bottomLeading) {
                    if single {
                        Text(ref.name).font(.inter(11, .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(8)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .matchedTransitionSource(id: ref.id, in: zoom)
        .accessibilityLabel("Image \(ref.name)")
    }
}

/// Full-screen images: swipe between them, pinch or double-tap to zoom, share or save.
struct ImageViewer: View {
    var gallery: ImageGallery
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var loaded: [String: UIImage] = [:]
    @State private var chrome = true

    private var current: ImageRef { gallery.images[min(index, gallery.images.count - 1)] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(gallery.images.enumerated()), id: \.element.id) { i, ref in
                    ZoomableImage(ref: ref, onLoad: { loaded[ref.id] = $0 }, onTap: { withAnimation(BUI.easeOutFast) { chrome.toggle() } })
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chrome {
                VStack {
                    HStack(spacing: 12) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Close")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(current.name).font(.inter(14, .semibold)).lineLimit(1).truncationMode(.middle)
                                .contentTransition(.interpolate)
                            if gallery.images.count > 1 {
                                Text("\(index + 1) of \(gallery.images.count)").font(.inter(12)).monospacedDigit().opacity(0.7)
                                    .contentTransition(.numericText(value: Double(index)))
                            }
                        }
                        .foregroundStyle(.white)
                        Spacer(minLength: 8)
                        if let img = loaded[current.id] {
                            ShareLink(item: Image(uiImage: img), preview: SharePreview(current.name, image: Image(uiImage: img))) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 44)
                    .background(alignment: .top) {
                        LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.55), location: 0.55), .init(color: .black.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                    }
                    Spacer()
                }
                .tint(.white)
                .transition(.opacity)
            }
        }
        .animation(BUI.easeOutStrong, value: index)
        .animation(BUI.easeOutStrong, value: loaded.keys.contains(current.id))
        .statusBarHidden(!chrome)
        .preferredColorScheme(.dark)
        .onAppear { index = gallery.index }
    }
}

/// One image in the viewer, pinch- and double-tap-zoomable.
struct ZoomableImage: View {
    var ref: ImageRef
    /// An image that's already in hand (a drawn diagram), so nothing is fetched from the Mac.
    var preset: UIImage? = nil
    var onLoad: (UIImage) -> Void
    var onTap: () -> Void
    @Environment(AppModel.self) private var model: AppModel?
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .gesture(magnify(geo.size))
                        .simultaneousGesture(pan(geo.size, image.size), isEnabled: scale > 1)
                        .onTapGesture(count: 2) { location in
                            withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                                if scale > 1 { reset() } else {
                                    scale = 2.5; base = 2.5
                                    offset = CGSize(width: (geo.size.width / 2 - location.x) * 1.5, height: (geo.size.height / 2 - location.y) * 1.5)
                                    baseOffset = offset
                                }
                            }
                        }
                        .onTapGesture { onTap() }
                        .transition(.opacity)
                } else if let failure {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 26))
                        Text(failure).font(.inter(14)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(40)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(BUI.easeOutStrong, value: image != nil)
        .task(id: ref.id) {
            if let preset { image = preset; onLoad(preset); return }
            guard image == nil, let model else { return }
            do {
                let img = try await model.image(ref, pixels: 2400)
                image = img
                onLoad(img)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func reset() {
        scale = 1; base = 1; offset = .zero; baseOffset = .zero
    }

    private func magnify(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in scale = min(6, max(0.8, base * v.magnification)) }
            .onEnded { _ in
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                    if scale <= 1 { reset() } else { base = scale }
                }
            }
    }

    private func pan(_ size: CGSize, _ img: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in offset = CGSize(width: baseOffset.width + v.translation.width, height: baseOffset.height + v.translation.height) }
            .onEnded { _ in
                let fit = min(size.width / max(img.width, 1), size.height / max(img.height, 1))
                let maxX = max(0, (img.width * fit * scale - size.width) / 2)
                let maxY = max(0, (img.height * fit * scale - size.height) / 2)
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                    offset = CGSize(width: min(maxX, max(-maxX, offset.width)), height: min(maxY, max(-maxY, offset.height)))
                    baseOffset = offset
                }
            }
    }
}
