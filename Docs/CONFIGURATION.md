# 构建与服务配置

使用 Xcode 27 打开 `WorkSpace.xcodeproj`，选择 `WorkSpace-iOS`。先使用模拟器构建，无需开发者签名。最低部署版本为 iOS 17；图标和新界面使用现代 Xcode 构建，系统能力按运行版本启用。

```sh
xcodebuild -project WorkSpace.xcodeproj -scheme WorkSpace-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/workspace-ios-build CODE_SIGNING_ALLOWED=NO build
```

## 安装到自己的设备

在 App 与 `DeadlineLiveActivityWidget` 扩展中选择自己的开发团队，分别设置唯一的 Bundle Identifier。不要沿用占位的 `org.example.workspace.ios` 和 `org.example.workspace.ios.widgets` 发布产品。

App 与扩展使用同一个 App Group。在两份 entitlements 和 `Shared/Widgets/WorkspaceWidgetSnapshot.swift` 中同步替换 `group.org.example.workspace`，再在自己的开发者账户中配置对应能力。App Group、推送、关联域名等能力受开发者账户和签名配置约束；源码不附带能力授权或签名材料。原生通行密钥与 APNs 默认关闭，启用前需要自己的服务和签名配置。

## 可选后端

App 目标 Debug / Release 的 Build Settings 包含 `WORKSPACE_SERVICE_URL`。默认是保留域名 `https://example.invalid`，不指向原作者的生产环境。使用兼容服务时，将其改为自己控制的 HTTPS 根地址，再构建客户端。命令行也可传入该构建设置；不要在此字段放令牌或密码。地址必须是 HTTPS，且不含账号、密码、查询、片段或非根路径；无效值回退到 `.invalid`。

构建值经 Info.plist 传入 `WorkspaceConfiguration`，账户 API 与匿名发布内容请求共用同一个服务根地址。这里不包含后端实现、数据库、账户或发布凭据。默认状态下云同步、网页登录和线上课程不可用；本地记录与演示模式可使用，演示模式允许隔离导入课程。普通账户的课程上传/跨设备同步需要登录自己的兼容服务。

服务端课程页面使用 `WORKSHOP-PLAYER/1`，课程文档使用 `WORKSHOP-COURSE/1`。仓库保留客户端数据模型、校验与隔离桥接；服务器渲染页面和 Python/C++ 运行服务不在此仓库。JavaScript 教学运行使用本机隔离容器。不要把传入课程内容当作可信原生代码。

网页登录回调保留 `guangyi-workspace://auth/callback`；这是兼容协议标识，不是账户凭据。自建兼容服务需允许此回调。若改名，应同步修改 Info.plist URL scheme、WebLoginAuthorization 和 WorkspaceCoding 的回调校验。归档格式也保留旧标识，避免破坏格式兼容性。

SwiftPM 的 `Package.swift` 仅用于可移植核心逻辑与测试，不是 App 入口。App、Widget 与 Live Activities 通过 Xcode 工程构建；没有 Mac App 目标、Sparkle 或桌面打包脚本。部分共用源文件保留条件编译分支，这不构成 macOS 产品。
