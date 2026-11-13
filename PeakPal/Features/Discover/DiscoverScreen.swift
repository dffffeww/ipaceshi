import SwiftUI

/// 发现页（新版布局：轨迹库 + 社区 合并为一个 Tab，页内分段切换）
/// - 轨迹库 = 原 TracksScreen（本地轨迹 + 平台路线库搜索 + GPX/KML/KMZ 导入）
/// - 社区 = 原 CommunityScreen（帖流/点赞/评论/发帖）
/// 两端各自保留自己的 NavigationStack，切换时独立运作
struct DiscoverScreen: View {
    @State private var seg = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("发现", selection: $seg) {
                Text("轨迹库").tag(0)
                Text("社区").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if seg == 0 {
                TracksScreen()
            } else {
                CommunityScreen()
            }
        }
    }
}
