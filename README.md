# PeakPal 爱徒步 · iOS 原生版

从安卓版（Java，约 90 个文件 / 3.3 万行）1:1 复刻的 **Swift + SwiftUI 原生工程**。
后端完全复用安卓端服务器，**安卓与 iOS 用户可直接互通**（同一队伍码互见位置、实时对讲同协议）。

## 目录结构

```
苹果ios原生版/
├── project.yml                  # XcodeGen 工程定义（含全部权限声明 + http 自建服务器例外）
├── PeakPal/
│   ├── App/
│   │   └── PeakPalApp.swift     # 入口 + 主 Tab（地图/轨迹/队伍/社区/我的）
│   ├── Core/                    # 纯逻辑层，与安卓逐文件对应
│   │   ├── Coord.swift          # ← Coord.java        WGS84↔GCJ02 火星坐标
│   │   ├── TrackMath.swift      # ← TrackMath.java    haversine/投影/爬升/Tobler 预计
│   │   ├── TrackPt.swift        # ← TrackPt+Track.java 数据结构（字段一致）
│   │   ├── Gpx.swift            # ← Gpx.java          GPX/KML轨迹/KML路径 导出
│   │   ├── ApiClient.swift      # ← ApiClient.java    401续登/断线重试/4MB限制
│   │   ├── Session.swift        # ← Session.java      登录会话（Keychain 存凭据）
│   │   ├── TeamState.swift      # ← TeamState+TeamService 协议部分  成员快照/pos上报/get兜底
│   │   ├── Db.swift             # ← Db.java           SQLite（表结构同安卓，含 team_msg）
│   │   ├── Map3DStyle.swift     # ← Map3DStyle.java   天地图/Esri影像+terrarium DEM
│   │   └── LocationKit.swift    # ← TrackService.java 定位/后台轨迹记录
│   └── Features/
│       ├── Login/LoginView.swift
│       ├── Map3D/Map3DScreen.swift     # ← Map3DActivity+TeamOverlay（队友实时图层）
│       ├── Tracks/TracksScreen.swift   # ← TracksFragment+TrackDetail
│       ├── Tracks/NavigateScreen.swift # ← NavigateActivity（循迹导航+偏航语音+转弯指引）
│       ├── Team/TeamScreen.swift       # ← TeamActivity（成员列表+对讲+波纹胶囊）
│       ├── Team/TalkStreamer.swift     # ← TeamTalk.java（AAC 流式对讲发送）
│       ├── Team/TalkPlayer.swift       # ← TeamService.TalkPlayer（流式对讲接收播放）
│       ├── Team/TeamChatSync.swift     # ← TeamService chatLoop+SSE（聊天轮询/接收）
│       ├── Community/CommunityClient.swift # ← CommunityClient+Post+Comment
│       ├── Community/CommunityScreen.swift # ← 帖子列表/详情/评论/点赞/关注/发帖
│       └── Me/MeScreen.swift
```

## 在 Mac 上构建

1. **安装 Xcode 15+** 和 **XcodeGen**（`brew install xcodegen`）
2. 本目录执行：
   ```bash
   xcodegen generate
   open PeakPal.xcodeproj
   ```
3. 在 Xcode 里：Signing & Capabilities 选你的开发者账号（免费账号可真机调试 7 天）
4. 选真机（定位/麦克风必须真机），`Cmd+R` 运行

> 本工程在 Windows 上开发，无法编译验证。首次在 Mac 打开时若有少量编译错误，多为 API 拼写级小问题，按提示修复即可。

## 云端构建测试包（无需 Mac，免费）

已内置 `.github/workflows/ios-build.yml`：用 GitHub Actions 免费的 macOS 机器，自动构建 **真机测试包（未签名 ipa）** 和 **模拟器包**。

**使用步骤（约 5 分钟）：**

1. 注册/登录 [github.com](https://github.com)，点右上角 `+` → **New repository** 新建一个**私有**仓库（名字随意，如 `peakpal-ios`）。
2. 把 `苹果ios原生版` 这个目录单独推上去（已在目录内建好 git，不要带外面的 apk/日志）：
   ```bash
   cd "D:/手机编程/安卓两步路软件/苹果ios原生版"
   git init
   git add .
   git commit -m "PeakPal iOS 复刻版"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/peakpal-ios.git
   git push -u origin main
   ```
3. 推送后自动触发；打开仓库页面的 **Actions** 标签即可看构建结果。绿勾 = 构建成功；红叉 = 有编译错误，点进去展开 `编译真机 Release 包` 步骤能看到具体报错（构建日志也会作为 artifact 归档）。
4. 构建成功后，在该次运行页面底部 **Artifacts** 下载两个包：
   - `PeakPal-iOS-未签名ipa` —— 真机测试包（`PeakPal-unsigned.ipa`）
   - `PeakPal-iOS-模拟器包` —— 模拟器包（有 Mac 的话直接拖进模拟器运行）

**真机安装（未签名 ipa → 装到 iPhone）：**

- 用 **爱思助手**（Windows，最简单）：数据线连 iPhone → 应用游戏 → 自制/共享应用 → 添加本地应用选 `PeakPal-unsigned.ipa` → 用自己的 Apple ID 签名安装。免费账号 7 天有效期，到期重新签一次即可。
- 或用 **Sideloadly**（Windows/Mac）：连 iPhone → 拖入 ipa → 输入 Apple ID → Start。同样 7 天有效。
- 首次安装后需在 iPhone 上信任证书：设置 → 通用 → VPN 与设备管理 → 找到你的 Apple ID 开发者证书 → 信任。

> 若始终卡在「解析 Swift 包依赖」（MapLibre 仓库下载），多为网络问题，重新跑一次（`Re-run jobs`）即可。

## 与安卓端的互通（关键设计）

| 互通点 | 说明 |
|---|---|
| 后端 | 同一服务器，同一套 `/api/*` 接口（join/leave/pos/get/chat 全部对齐安卓路径与字段） |
| 对讲协议 | `"🎙对讲\|seqId\|idx\|s/m/e"` + base64(ADTS AAC 16k 24kbps)，**逐字节一致** |
| 对讲接收 | 说话人会话排队（同 seq 连播、e 片/2.5s 超时切人）+ msg id 去重 + 解码器复用 + 3dB 增益，与安卓 TalkPlayer 行为一致 |
| 聊天接收 | 轮询（2s 常规 / 250ms 对讲热聊期快车道）+ SSE 长连接双通道，按消息 id 游标幂等（与安卓 v7.75 一致） |
| 分片节奏 | 首片 2 帧 / 后续 4 帧，与安卓 v7.95 延迟优化一致 |
| 坐标 | 本地一律 WGS84 存储，显示层 GCJ02 纠偏（算法同安卓） |
| 数据库 | SQLite 表结构/字段名与安卓一致（team_msg 同款），便于未来云同步 |
| 3D 样式 | 同一 style JSON 生成逻辑：天地图/Esri 影像 + terrarium DEM + 山体阴影 + 地形夸张 |
| 导航算法 | 轨迹投影吸附（80m 防锁死 + 10m 迟滞）、偏航三级判定（连续 3 次确认）、坡度/转弯语音、Tobler 预计，全部同安卓 |
| 社区接口 | posts/comments/likes/follows 全套同安卓 CommunityClient |

## 已完成 / 待迭代

**已完整实现**：登录注册、3D 影像地图（MapLibre 地形+山体阴影+夸张调节）、轨迹记录（后台定位）、轨迹列表/详情/删除、GPX/KML 导出分享、加入/退出队伍、位置上报（pos 上报+get 兜底+隐身看队）、队友实时位置图层（绿点呼吸+名字胶囊+成员列表）、对讲双向（发送+接收播放，与安卓互通）、队伍聊天（文字/图片发送+气泡列表+语音回听+大图查看，与安卓 TeamChatActivity 对应）、队伍聊天接收（轮询+SSE）、循迹导航（轨迹吸附/偏航三级判定/坡度+转弯语音/Tobler 预计/已走段虚线）、社区（帖子列表/详情/评论/点赞/关注/发帖，分类筛选+搜索）。

**v7.108 同步更新（对齐安卓最新版）**：
- **默认服务器直连安卓生产后端**（`http://111.170.49.138:8765`，与安卓 Session.DEFAULT_SERVER 一致）：首次打开无需手输地址，登录即可与安卓用户互通（同一队伍码互见、聊天/社区同一套接口、同一 SQLite 表结构）
- **本地库补 poi 表**（与安卓 Db.java poi 表逐字段一致）：poisForTrack（轨迹绑定+全局）/trackPois/insertPoi/deletePoi 全套
- **导航页标注点显示**：轨迹绑定标注点+全局兴趣点 → 发光红点数字编号，点击弹详情（类型/海拔/WGS84/备注，与安卓 v7.107 同款）
- **里程碑徽章**：每满 1km 黑色数字徽章（与安卓 v7.108 同算法），导航页与详情页地图都显示
- **详情页新增地图**：轨迹线+起终点发光徽章+里程碑+标注点气泡（对齐安卓 TrackDetailActivity 地图）
- **修复地图系统性偏移 bug**：此前 iOS 把轨迹/定位/队友位置做 GCJ 纠偏后画到 WGS84 影像底图上，偏移几百米；现改为 WGS84 直投（与安卓端一致）

**v7.111 服务器数据接入（对齐安卓接入方式）**：
- **平台路线库搜索/下载**（对应安卓 v7.8/v7.69 pubtracks 接入，服务器 v153 新仓库）：轨迹页搜索框直连——本地结果 + 平台路线（AI 轨迹/GPX 全量/三批两步路 KMZ，带「城市 - 路线名」），点击下载 → 解析入库；展示名清洗与安卓 pubLabel 一致（去扩展名/序号前缀/尾段城市）
- **轨迹文件导入**（对应安卓 TrackImport）：GPX/KML/KMZ/XMZ 全支持——内置 GPX/KML 状态机解析（trk/trkseg/trkpt/rte/wpt、LineString/gx:Track 多段/标注点 Placemark）+ 自研极简 zip 读取器（中央目录 + zlib raw inflate，只解 .kml/.gpx 条目）；多段去重拼接、标注点入 poi 表、导入上限与安卓一致（30 万点/300MB/120MB）
- **云端轨迹上传**（对应安卓 TracksFragment 云上传）：POST tracks（字段 name/start/end/distance/dur/asc/maxalt/points 与安卓逐字段一致）+ GPX 同步到平台路线库（待审核）；成功回写 cloud_id
- **崩溃上报**（对应安卓 CrashGuard/MainActivity 链路）：未捕获异常+致命信号落盘 crash-*.txt（保留 5 份）→ 下次冷启动 POST /api/crash/report（device/android/version/content 字段与安卓一致，服务器统一入库并落盘日志目录）

**质量验证（超强度测试）**：
- 静态体检：26 个 Swift 文件括号平衡/未闭合字符串/iOS17 专有 API/已知错误模式扫描全绿
- 协议核对：对讲协议、chat/pos/join/leave 请求字段、SSE 格式、team_msg 表结构 15 项逐字节一致
- **黄金值比对：用安卓真实 Java 源码编译运行生成 284 组基准值（10 城市坐标纠偏、100 组 haversine、80 点轨迹投影/累计/难度/格式化），Python 逐行镜像 Swift 算法比对 —— 284/284 全通过（坐标差 <1e-9 度、距离差 <0.1 毫米）**，证明核心算法与安卓端数值完全等价。

**待迭代（对照安卓端尚未移植）**：
- [ ] 帖子图片上传/浏览、视频发帖、结伴报名（安卓 CreatePostActivity 完整版）
- [ ] 私信/客服会话（对应 ConversationsFragment/ChatActivity 一族）
- [ ] 天地图 tk 设置页、离线瓦片（对应 OfflineManager）
- [ ] 3D 轨迹飞行巡游（对应 Map3DActivity 的 tour）
- [ ] KMZ 导出（需 zip 写入库）、海拔探针精确 DEM 取值
- [ ] 标注点拍摄/语音落点的「新增」入口（显示已就绪，新增待移植 NavigateActivity wpMarkers）
- [ ] 天气、勋章、守护模式（GuardService）、AOD、3D 视频/轨迹海报等次级功能
