# ReplayCloud：在 iPad / iPhone 上使用 Replay（自签 IPA 客户端）

> 背景：Weights 团队已加入 OpenAI，**官方云端网页全部关闭**。
> 但其桌面版推理服务端与模型 CDN 目前仍可用（已实测）。
> 本工程 = **云主机运行官方 linux-x64 推理服务端** + **原生 iOS 客户端（IPA）**。
> 整个方案不依赖 weights.com 在线服务。

## 架构

```
iPad/iPhone（ReplayCloud.ipa，自签）
      │  HTTP + 访问令牌
      ▼
云主机（必须 x86_64）
 ├─ replay-inference：官方推理服务端，127.0.0.1:62362（不对外）
 └─ replay-gateway ：自建 FastAPI 网关，0.0.0.0:8080（鉴权/模型/上传/产物）
```

为什么不是把 Mac 安装包直接转成 IPA：Electron 依赖 iOS 禁止的 JIT，
且官方推理服务端只有 windows/mac/linux-x64 四种闭源包，无法在手机本地运行。
本工程客户端为原生 SwiftUI 重写，只负责交互；推理仍在 x86_64 服务器上。

## 一、部署云服务器（一次性，约 10–40 分钟）

要求：Ubuntu 22.04/24.04，**x86_64**，root。有无 GPU 均可（GPU 快，CPU 慢）。
建议磁盘 ≥ 60 GB（官方服务端组件压缩包约 4.8 GB），内存 ≥ 8 GB。

把 `server/` 目录上传到主机（本地打包上传，或用 git）：

```bash
cd server
bash deploy.sh --token 你的复杂令牌            # 全量权重，约 3.4 GB
# 或节省下载量（仅推理核心 + 分离模型，约 0.5 GB）：
bash deploy.sh --token 你的复杂令牌 --lite
```

完成后会打印：`http://服务器IP:8080` 和令牌。
记得在云厂商安全组放行 TCP 8080。

常用维护：

```bash
journalctl -u replay-inference -f   # 推理日志（首次启动加载模型较慢）
journalctl -u replay-gateway -f     # 网关日志
systemctl restart replay-inference replay-gateway
```

**请尽快备份 `/opt/replay/server` 与 `/opt/replay/weights`**：
它们是公司关停后遗留的资源，CDN 随时可能失效。
`tar -czf replay-backup.tar.gz -C /opt replay` 后转存到你自己的存储。

### 添加声音模型（RVC .pth，建议 zip 打包含 .index）

方式 A（在服务器上操作）：直接把模型目录/文件放进 `/opt/replay/models/`。

方式 B（HTTP 上传，任何设备均可）：

```bash
curl -H "Authorization: Bearer 你的令牌" \
     -F "file=@你的模型.zip" http://服务器IP:8080/upload_model
```

## 二、云编译 IPA（无需 Mac）

1. 在 GitHub 新建私有仓库，把本工程整个目录推送上去。
2. 仓库 **Actions → Build unsigned IPA → Run workflow**。
3. 等待编译结束，在 Artifacts 下载 `ReplayCloud-unsigned-ipa`，
   里面就是 `ReplayCloud-unsigned.ipa`。

（如果你有 Mac，也可以 `brew install xcodegen` 后在 `ios/` 下
`xcodegen generate`，再用 Xcode 打开工程直接编译签名。）

## 三、自签安装到 iPad

- 用 **AltStore / SideStore**（或你惯用的自签工具）安装该 IPA；
  工具会在安装时自动完成签名。若某工具要求已签名包，先用其签名功能签一次。
- 免费 Apple ID 签名的应用 **7 天到期需重签**；付费开发者账号有效期一年。
- 首次打开：输入 `http://服务器IP:8080` 与令牌 → 「测试连接」显示 ✅ 即可使用。

## 客户端功能

- 模型列表（含是否带索引）、刷新
- 本地音频选择上传 / 在线链接输入
- 变调、音高算法（RMVPE/CREPE 等）、索引比例、去回声、输出格式
- 提交生成 → 任务进度轮询 → 在线播放 / 保存分享 / 停止任务

## 已做的真实验证（非纸面推断）

- 从官方 CDN 实际下载 3 个服务端组件：zip 内路径与 manifest 一致，SHA1 全部匹配；
- 完整下载 `other.zip` 对应 asset（168 MB，30686 个文件，含主程序
  `replay-server-linux`），并据此修正了解压逻辑（它是完整内容包，不是 zip 套 zip）；
- 实测 CDN 会拒绝 Python 默认 UA，下载脚本已统一使用自定义 UA；
- 部署/网关/下载脚本通过 Python、Bash 语法检查；
- iOS 全部 Swift 源码通过词法级结构检查（括号/字符串/注释/插值）。

## 已知限制与说明

- **iOS 工程未经 Xcode 编译**：本沙盒为 32 位 Linux，无法运行 Swift/Xcode 工具链。
  云编译若报错，把 Actions 日志发我即可继续修。
- 训练新模型、社区分享、官方账号体系未包含（官方云端已关闭）。
- 在线链接（YouTube 等）由服务端 yt-dlp 处理，版本较旧，失败时改用本地上传。
- 默认 HTTP + 令牌，仅建议个人使用；有域名可在网关前加 HTTPS 反代。
- 音频上传在客户端一次性读入内存，建议单文件 < 100 MB。
