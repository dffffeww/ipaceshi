import SwiftUI
import UIKit

/// 社区共享组件（对应安卓 NetImg 图片加载 + FullImageDialog 全屏查看器）：
/// - AvatarView：真图头像（data: base64 / /img 路径 / http 全链路），无图回退首字
/// - RemoteImg：帖子图片（同上）
/// - ImageViewer：全屏分页浏览（缩放手势）
/// - ImageUploadKit：发帖图片压缩成 data URL（≤1.5MB，与安卓 CreatePostActivity 同规格）

// MARK: - 图片视图（data URL / 服务器路径 / http）

struct RemoteImg: View {
    let src: String

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        let s = src.trimmingCharacters(in: .whitespaces)
        if s.isEmpty {
            placeholder
        } else if s.hasPrefix("data:") {
            if let ui = Self.decodeDataURL(s) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                placeholder
            }
        } else if s.hasPrefix("http") {
            AsyncImage(url: URL(string: s)) { phase in
                if let img = phase.image { img.resizable().scaledToFill() }
                else if phase.error != nil { placeholder }
                else { Color(.systemGray5) }
            }
        } else if s.hasPrefix("/") {
            AsyncImage(url: URL(string: Session.shared.server + s)) { phase in
                if let img = phase.image { img.resizable().scaledToFill() }
                else if phase.error != nil { placeholder }
                else { Color(.systemGray5) }
            }
        } else {
            // 非 URL（表情字符等）——由调用方处理，这里给占位
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(.systemGray5)
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }

    static func decodeDataURL(_ s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let d = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: d)
    }
}

/// 头像（真图 + 首字/表情回退，对应安卓 NetImg.loadRound）
struct AvatarView: View {
    let src: String       // avatar 字段原文（可能是路径/dataURL/表情字符）
    var size: CGFloat = 34

    private var isImage: Bool {
        let s = src.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("/") || s.hasPrefix("http") || s.hasPrefix("data:")
    }

    var body: some View {
        if isImage {
            RemoteImg(src: src)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(Color.green.opacity(0.18))
                Text(src.isEmpty ? "🥾" : src)
                    .font(.system(size: size * 0.45))
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - 全屏图片查看器（对应安卓 FullImageDialog：点击放大/滑动切换）

struct ImageViewer: View {
    let images: [String]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, src in
                    ZoomableImg(src: src)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(16)
        }
    }

    /// 单张可捏合缩放
    struct ZoomableImg: View {
        let src: String
        @State private var scale: CGFloat = 1

        var body: some View {
            RemoteImg(src: src)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale = max(1, min($0, 4)) }
                        .onEnded { _ in withAnimation { scale = 1 } }
                )
        }
    }
}

// MARK: - 发帖图片压缩（对应安卓 CreatePostActivity：最长边 1280 JPEG，≤1.5MB）

enum ImageUploadKit {

    /// UIImage -> data URL（data:image/jpeg;base64,...），超限自动降质，失败返回 nil
    static func dataURL(_ image: UIImage) -> String? {
        let scaled = downscale(image, maxDim: 1280)
        for q in [0.7, 0.55, 0.4, 0.28] {
            guard let d = scaled.jpegData(compressionQuality: q) else { continue }
            if d.count <= 1_500_000 {
                return "data:image/jpeg;base64," + d.base64EncodedString()
            }
        }
        // 全部超限：用最低质量（服务端会拒 >1.5MB，这里尽力压小）
        guard let d = scaled.jpegData(compressionQuality: 0.2), d.count <= 1_500_000 else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }

    private static func downscale(_ image: UIImage, maxDim: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let long = max(w, h)
        guard long > maxDim, long > 0 else { return image }
        let ratio = maxDim / long
        let size = CGSize(width: w * ratio, height: h * ratio)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
