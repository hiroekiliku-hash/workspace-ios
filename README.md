# 工作坊 / WorkSpace

WorkSpace 是面向 iPhone 的开源客户端，用于管理项目与子组、任务与截止时间，并在时间线上查看安排。本仓库是公开版本的 iOS 客户端工程。

仓库只包含 iOS 客户端。没有 Mac 目标，也没有服务端源码。客户端不附带云服务器，也不附带 Python 或 C++ 执行环境。

## 许可

本项目以 MIT 许可证发布。全文见 [LICENSE](LICENSE)。

## 环境

当前 Icon Composer 与 Liquid Glass 相关源码需要 Xcode 27。部署目标为 iOS 17。依赖更高系统版本的界面仅在系统可用时启用；不依赖这些能力的功能仍以 iOS 17 为下限。

仓库不包含 Apple 签名身份、证书、描述文件或其他凭证。签名由使用者在本机配置。

## 打开与安装

1. 打开 `WorkSpace.xcodeproj`。
2. 选择 scheme `WorkSpace-iOS`。
3. 选择一台 iOS 模拟器，或准备安装到自己的设备。
4. 安装到自己的设备时，选择自己的 Team。
5. 为主体 App 与扩展分别填写互不冲突的 Bundle ID，并填写与这些 ID 匹配的同一个 App Group。

公开版本的 Build Settings 中，`WORKSPACE_SERVICE_URL` 默认为 `https://example.invalid`。该默认值不指向可用服务。保持默认时，离线本地数据与演示模式可以工作。云同步与在线课程需要使用者自行提供兼容部署，并将该设置改为自己的服务地址。

Bundle ID、App Group 与服务地址的说明见 [Docs/CONFIGURATION.md](Docs/CONFIGURATION.md)。

## 功能

- 项目与子组：按项目组织内容，并在项目下划分子组。
- 任务与截止时间：记录任务及其截止日期。
- 时间线：按时间查看任务安排。
- 本地通知：在设备本地提醒截止时间。
- 小组件与 Live Activities：在系统提供的小组件与 Live Activity 界面中查看事项。相关界面是否可用取决于系统版本。
- 演示模式：在没有自有数据时查看示例内容。
- JSON 课程导入：粘贴或读取课程文档；演示模式在本机体验，正常账户上传到兼容后端。
- 结构化提问：以固定结构组织问题。
- 可选云同步：连接到使用者提供的兼容后端后同步数据。
- 可选的服务端渲染课程：由兼容后端渲染课程，客户端负责展示。

未配置兼容后端时，云同步与在线课程不可用。本地项目、任务与时间线可以离线使用；演示模式支持隔离的 JSON 课程导入。正常账户中的课程上传需要登录兼容后端。

## 目录

- `Shared/`：App 与扩展共用的代码。
- `LiveActivityWidget/`：小组件与 Live Activities 扩展。
- `Config/`：客户端构建与配置。
- `Docs/`：配置说明与隐私说明。

## 文档

- 配置：[Docs/CONFIGURATION.md](Docs/CONFIGURATION.md)
- 隐私：[Docs/PRIVACY.md](Docs/PRIVACY.md)
- 许可证：[LICENSE](LICENSE)

[Docs/PRIVACY.md](Docs/PRIVACY.md) 说明本地保存的数据，以及启用云同步或在线课程后会发往使用者自行配置的后端的内容。
