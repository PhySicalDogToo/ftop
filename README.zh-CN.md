<p align="center"><img src="docs/media/icon.png" width="112" alt="ftop 图标：一只闭着眼的雪鸮"></p>
<h1 align="center">ftop</h1>
<p align="center">给 Apple Silicon Mac 用的一个小而安静的系统监视器。<br>一块浮动的玻璃面板，任何尺寸都能用。</p>
<p align="center">
  <a href="README.md">English</a> ·
  <a href="https://github.com/Nongfsq/ftop/releases/latest">下载</a> ·
  <a href="#安装">安装</a>
</p>
<p align="center"><a href="https://trendshift.io/repositories/290349?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-290349" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/290349/daily?language=Swift" alt="Nongfsq%2Fftop | Trendshift" width="250" height="55"/></a></p>

<p align="center"><img src="docs/media/live.gif" width="760" alt="面板的几秒钟：核心柱平滑地跟到每一次新读数"></p>

ftop 用来替代你常年开在终端标签页里的监视工具，换成一个可以放在桌面任何位置的原生
窗口。它为机器正在使劲干活的时刻而做：本地模型在跑、AI 代理在编译、一次很长的构建。
这时你想一眼看清各个核心、内存和网络的状态，以及是哪个应用在占用。

它只显示当前状态：没有历史曲线，没有磁盘面板。

## 一块面板，各种尺寸

拖动任何一条边，ftop 选出合适的布局，窗口随即贴合过去，所以内容不会被裁掉，也不会
留空白。小窗口只留要点；大窗口显示更多内容，而不是把字放大。

![同一块面板的六种尺寸](docs/media/sizes.png)

## 它显示什么

每个数字前面都是同一种小圆标，带圆弧的圆标是一个量表。颜色说明它属于谁，几乎没有
需要读的文字。

| | |
| --- | --- |
| **核心** | 每个核心一根柱子，芯片有几种核心就分几组，最快的在前。柱子高度是占用，小横线是该核心当前的频率。 |
| **内存** | 已用和总量、压缩、交换，以及系统自己给出的内存压力。 |
| **网络** | 当前的下载和上传速度。 |
| **GPU** | 在核心旁边有自己的一根柱子，读法和核心一样：柱子高度是占用，小横线是当前频率。已用显存和它的功耗在下方。悬停可看温度。 |
| **功耗** | 整机功耗，单位瓦。 |
| **温度** | 只有一个数字，并标明它实际来自哪一级传感器。 |
| **进程** | 最忙的应用，带它们自己的图标，帮助进程并到所属应用里。应用的 CPU 是占整台机器的比例，和上方的总占用同一个单位，所以不会超过 100%（活动监视器以单个核心为 100%）。 |

硬件不提供的读数显示为“不可用”，绝不显示成 0。

![大窗口](docs/media/large.png)

## 手感

- **柱子跟着读数走。** 每个核心平滑地移到新值，并在下一次读数到来时到位，所以面板是
  连续在动，而不是每秒跳一下。
- **会停下来的列表。** 进程一变忙就立刻到位，安静下来后慢慢退下；两个应用只差一个点
  地交替领先时不会来回换位。越过相邻一行的行滑过去；走得更远的行在原地翻转，所以不会
  有行横穿整个列表。
- **按一下进程。** 这一行会在指针下微微凹下去，旁边浮出一张卡片：CPU、内存、下载、上传，
  以及这个应用里的帮助进程。宽窗口上方的四个圆标可切换排行；小窗口也能从
  **更多 → 进程排序**选择 CPU、内存、下载或上传。速率单位为 KB/s、MB/s 等。
- **不看的时候几乎不花资源。** 隐藏或被完全遮住时，除了菜单栏上那一个数字，其他读数
  全部停止。

在 macOS 里打开“减弱动态效果”后，以上动作都变成简单的淡入淡出。

## 设置

在面板或菜单栏数字上点右键。所有设置都在这一块里：显示哪些内容、面板的行为、配色，
以及**更多**里几项有数值的设置。

进程网络排行按 macOS 报告的 TCP／UDP 连接活动计算，包含本地和代理连接。进程模块
开启且浮窗可见时，切换到网络排行会开始采样；首次等待期间显示**“数据读取中”**。
切到 CPU 或内存排行后继续采集 20 秒，期间切回下载或上传排行可复用正在采集的数据；
CPU／内存之间切换不会延长这 20 秒。隐藏浮窗、浮窗被完全遮住或关闭进程模块时立即停止。

使用系统代理或隧道时，原应用与代理可能分别计数，排行合计不代表物理网卡吞吐，也不会自动
将代理流量归给其他应用。其他专用用户态协议的数据可能不可用。真实错误、过期读数
以及未采到的 CPU／内存仍显示不可用，不会改成加载或零。
`ftop doctor --network` 检查原生采样，`ftop probe --network --json` 输出同一数据源的诊断。

在 **更多 → Wi-Fi DNS 规则** 上悬停鼠标，可以查看当前系统 DNS 地址和来源；
点击后直接打开 Wi-Fi DNS 规则窗口。悬停信息只读，`ftop dns --json`
可以不打开浮窗输出同一份系统快照。ftop 不再提供“编辑当前网络服务”；
一次性手动修改请使用 macOS 的网络设置。

浮窗也会显示 DNS 徽标与当前系统默认地址，位于机器读数之后、进程列表之前。长地址会
缩略，多地址显示剩余数量，悬停可看完整地址和来源；最小窗口只保留徽标。各尺寸使用
固定布局，不随 DNS 内容改变大小。DNS 开关可隐藏此项；读取与网络变化同步，不修改配置。

在 **Wi-Fi DNS 规则** 中可把精确的 Wi-Fi 名称与“自动获取”或自定义 DNS 关联。
默认 DNS 作为一条单独且无法删除的规则：精确 Wi-Fi 规则优先，其他可识别 Wi-Fi
全部使用默认规则。
保存时会校验所有地址、持久化规则、请求后续自动修改所需的系统授权，并立即对
当前 Wi-Fi 应用匹配规则。后续只响应 Wi-Fi 连接、名称变化和唤醒事件，不轮询。
填写两个自定义 DNS 时，第一行为首选，第二行为备用；macOS 仍可能选择任一
可用解析器，因此不保证严格的主备切换。以太网、Wi-Fi 断开或无法读取名称时保持现状。定位权限只用于
读取当前 Wi-Fi 名称；ftop 仍只通过同一套有事务保护的原生写入修改当前物理服务的
`ServerAddresses`。如果检测到外部 DNS 变更或写入结果不确定，当次连接会停止自动重试，
不会反复覆盖。
ftop 不检测代理软件，也不读取、修改其配置文件或调用其控制接口。
代理软件可能保留自身的解析状态，ftop 不负责强制刷新，也不保证其立即采用系统 DNS。

<p align="center"><img src="docs/media/settings.png" width="620" alt="设置：一块圆形开关，以及展开“更多”后的同一块"></p>

监控面板的设置也保存在纯文本文件 `~/.config/ftop/config.json5`（可以写注释的 JSON）。
文件与控制块保持一致，保存后立即生效。DNS 修改则保存在 macOS 网络设置中。

## 开销

在一台 14 核 Apple Silicon Mac 上用 `scripts/perf.sh` 测得，每秒更新一次：

| 状态 | CPU | 内存 |
| --- | --- | --- |
| 小尺寸和中等尺寸 | 低于单核的 0.8% | 低于 30 MB |
| 最大的面板，32 行进程 | 约 0.9% | 约 52 MB |
| 隐藏或被完全遮住 | 0.0–0.1% | 同上 |

授权读取系统进程后（见下文），列出进程的辅助程序另占约 0.5%。

加入 DNS 行的本地版本，在本机常规 300×420 窗口的五次采样为单核 CPU 1.1–1.8%、
内存 41 MB，超过低于 1% 的参考 CPU 目标。未做同一会话下关闭 DNS 的对照，不能将
差异归因于 DNS。详情见 [验证记录](docs/evidence/2026-10-19-floating-dns/README.md)。


2026-10-20 的进程网络版本另做了测量，使用常规 332×505 浮窗，包含辅助进程：
每秒刷新时，CPU 排行占单核 **0.3–0.7%**，下载、上传排行占 **1.0–1.5%**，
网络模式的 `top MEM` 合计约 **39–40 MiB**，仍超过低于 1% 的 CPU 参考目标。
0.5 秒刷新时，无额外测试流量也出现 **12.8%** 短峰值；连接更替对照的峰值为 12.2%。
短时顺序测量不能单独确定原因或证明最坏上限。本轮未可靠验证隐藏状态的开销。
详情见 [网络排行验证记录](docs/evidence/2026-10-19-process-network/README.md)。

## 安装

要求：Apple Silicon Mac，macOS 15 或更新。

**用发布包。** 在[发布页](https://github.com/Nongfsq/ftop/releases/latest)下载
`Ftop-<版本>-arm64.zip`，解压后把 `Ftop.app` 移到 `~/Applications`。然后把命令链接到
`PATH` 里的某个目录：

```bash
mkdir -p ~/.local/bin && ln -sfn ~/Applications/Ftop.app/Contents/MacOS/ftop ~/.local/bin/ftop
```

从 0.2.6 起，应用用 Developer ID 签名并经过苹果公证，下载后可以像普通应用一样直接打开。

**从源码构建。** 需要 Xcode（用 Xcode 27 构建和测试）。

```bash
git clone https://github.com/Nongfsq/ftop.git
```

```bash
cd ftop && scripts/bundle.sh && scripts/install.sh
```

这会把 `Ftop.app` 放进 `~/Applications`，并把 `ftop` 链接到 `~/.local/bin`。

> **还在用 0.1.0？** 这一版不会自己更新。请按上面的步骤手动装一次最新版本；从 0.1.1
> 起 ftop 会自动保持最新。

## 使用

```bash
ftop            # 打开面板
ftop toggle     # 隐藏或显示
ftop quit       # 关闭
ftop doctor     # 这台 Mac 上哪些读数可用，不可用的原因是什么
```

- 拖动面板可以移动它；拖动边缘可以改变大小。
- 把指针移到面板顶部会出现两个按钮：置顶和隐藏。
- 菜单栏显示一项读数，一个图标加它的数字：默认是 CPU，也可以换成内存、GPU、下载、
  上传或功耗（在设置的「更多」里）。点一下可以显示或隐藏面板。
- 指针停在某个核心、内存条或 GPU 上，会显示详细信息；点一个进程会浮出它的卡片。
- 点右键打开设置。

### 更新

ftop 每天检查一次有没有新版本，有就自动安装：从本仓库下载发布包，校验后替换
`Ftop.app`，再重新打开面板。在**更多 → 更新**里可以改成"仅提示"（新版本会出现在那里）
或"不检查"（ftop 完全不联网）。`ftop update` 立即检查，`ftop version` 显示已安装的
版本。

更新不会改动 `sudo ftop grant` 安装的那个辅助程序。新版本需要更新它时，`ftop doctor`
会提示，再授权一次即可。

### 系统进程

没有额外权限时，macOS 只让 ftop 看到你自己的进程。要把 `WindowServer` 这类系统进程也
列出来，授权一次即可：

```bash
sudo ftop grant
```

这会把应用里的一个小辅助程序标记为以 root 身份运行。它不接受参数，不读环境变量，不写
文件，只输出进程表；源码在 `Sources/ftop-helper/main.swift`。

## 限制

- 只支持 Apple Silicon。核心分组和每核频率依赖它。
- 每核频率、温度、GPU 和功耗来自 macOS 的私有接口（IOReport、HID 传感器服务和 SMC），可能随系统更新
  而变化；读不到的数值会显示为不可用，绝不显示成零。也因为这一点，ftop 不能上架
  Mac App Store。
- 界面有英文和中文。

## 开发

`scripts/check.sh` 是提交前的检查：格式、无警告构建、测试。本页的图片由 ftop 自己的
绘制代码配合示例数据生成（`scripts/readme-media.sh`），放在一张替代的壁纸上；真实
窗口用的是 macOS 的玻璃材质，背景会随它后面的内容变化。产品决定在
[docs/product/](docs/product/)，架构在 [docs/architecture/](docs/architecture/)，
给编码代理的规则在 [AGENTS.md](AGENTS.md)。

ftop 最初是 [btop](https://github.com/aristocratos/btop) 的一个分支，之后从头重写，
与它不共享任何代码。

## 反馈与贡献

报告问题或提建议，请用[议题页](https://github.com/Nongfsq/ftop/issues/new/choose)上的表单；
报告问题需要附上 `ftop doctor` 的输出。项目不接受外部的 pull request。规则见
[CONTRIBUTING.md](CONTRIBUTING.md)。

## 支持

ftop 免费且开源。如果它在你的桌面上留了下来，可以
请我喝杯咖啡。

<a href="https://buymeacoffee.com/frankmenger"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="44"></a>

## 许可证

[MIT](LICENSE)
