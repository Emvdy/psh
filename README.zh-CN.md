# Psh

[English](README.md)

Psh 是一个规划中的、兼容 Windows PowerShell 5.1 的命令兼容层，旨在 Windows 上提供一组常用的 Bash 风格命令。目标平台为 Windows 10/11 的 x64 与 ARM64 架构，同时支持 Windows PowerShell 5.1 和 PowerShell 7。

> [!IMPORTANT]
> Psh 目前正在开发中，`v0.1.0` 尚未发布，当前仓库也没有受支持的安装程序或发布包。下述接口是首个版本的目标范围，并不表示这些功能现在已经可用。

Psh 是命令兼容层，不是 Bash 解释器、通用 `.sh` 运行时或 POSIX 环境。

## v0.1.0 规划范围

首个版本计划提供以下 64 个命令名：

- 文件与搜索：`pwd cd ls mkdir rmdir cp mv rm touch ln realpath basename dirname stat file tree find fd du df mktemp`
- 文本与数据：`cat bat head tail grep rg sed awk jq cut tr sort uniq wc tee xargs printf echo base64`
- 环境与进程：`which env printenv export test ps kill pgrep pkill timeout sleep`
- 网络与归档：`curl wget tar zip unzip gzip gunzip sha256sum md5sum date whoami hostname clear`

计划中的管理接口为：

```text
psh version|doctor|capabilities|commands|config|update|rollback|self-test|uninstall
```

`doctor` 与 `capabilities` 计划支持机器可读的 JSON 输出。Bash 风格命令将输出文本，并采用文档化且稳定的退出码。

### 版本类型

- **Core** 计划作为默认版本，不包含第三方工具可执行文件；`rg`、`fd`、`jq` 和 `bat` 将使用有明确文档的 PowerShell 子集实现。
- **Full** 将增加固定版本的 ripgrep、fd、jq 和 bat 原生构建，其完整参数集由相应原生工具处理。

Full 中的第三方组件保持各自许可证，作为独立聚合组件分发。发布包将保留其原始许可证与声明。

## 安全与安装设计

`v0.1.0` 安装程序的设计目标包括：

- 默认仅为当前用户安装，不需要管理员权限；
- 不修改组策略、PowerShell 执行策略或永久系统 `PATH`；
- 插入带标记的加载区块前备份现有 PowerShell profile；
- 使用 SHA256 校验下载内容与离线产物；
- 提供 Core 与 Full 的在线、离线安装包；
- 不收集遥测数据。

只有发布产物通过规定的 Windows x64 CI 与真实 Windows 11 ARM64 验收后，项目才会公布安装命令和下载链接。Psh 不会推荐 `irm | iex` 安装方式。

[PLAN.md](PLAN.md) 是产品范围和验收门禁的唯一事实来源。

## 参与贡献与安全报告

提交变更前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。如发现疑似安全漏洞，请按 [SECURITY.md](SECURITY.md) 私密报告，不要在公开 Issue 中披露敏感细节。

## 许可证

Psh 自有源码和文档采用 [GNU General Public License v3.0 or later](LICENSE)（`GPL-3.0-or-later`）许可。后续加入的第三方组件将保留各自的许可证正文与声明。
