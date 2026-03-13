# Hyperkey

[English](README.md)

一个轻量的 macOS 菜单栏工具，把 Caps Lock 变成 Hyper 键，也就是同时按下 `Cmd + Ctrl + Opt + Shift`。它的目标是作为 Karabiner Elements 的轻量、无依赖替代方案。

## 为什么

Karabiner Elements 依赖 DriverKit 虚拟键盘驱动，而这个方案在 [macOS 26.4 beta](https://github.com/pqrs-org/Karabiner-Elements/issues/4402) 上出现过兼容性问题。Hyperkey 走的是更直接的路径：

1. 用 `hidutil` 在 HID 驱动层把 Caps Lock 重映射成 `F18`
2. 用 `CGEventTap` 拦截 `F18`，并给后续按键附加 Hyper 修饰键
3. 对外接键盘，使用 IOKit HID seizure 进行独占接管，绕过 macOS 26+ 上 `CGEventTap` 看不到外接键盘事件的问题

没有内核扩展，没有虚拟键盘，没有第三方依赖。只有 Swift 和 Apple 自带 API。

## 功能

- **Hyper 键**：`CapsLock + 任意键` 发送 `Cmd + Ctrl + Opt + Shift + 该键`
- **Vim 风格导航**：可选开关，`Hyper + H/J/K/L` 发送方向键 `左/下/上/右`
- **单独点按 CapsLock 发送 Escape**：可选开关，适合 Vim 用户
- **支持外接键盘**：USB 和无线键盘都会自动处理
- **登录自动启动**：菜单栏里一键开关
- **自动检查更新**：检查 GitHub Release，结果会缓存 24 小时
- **菜单栏常驻**：显示当前版本、键盘状态和常用开关，不占 Dock

## 安装

### 下载已发布版本

1. 从 [最新 Release](https://github.com/smallmain/hyperkey/releases/latest) 下载 `Hyperkey.zip`
2. 解压后把 `Hyperkey.app` 拖到 `/Applications`
3. 通过 Spotlight、Raycast 或应用程序文件夹启动
4. 第一次启动时按提示授予“辅助功能”权限
5. 点击菜单栏图标，按需开启 **Launch at Login**

当前发布包没有使用 Developer ID 证书签名，也没有经过 Apple notarization，因此在全新系统上第一次启动时，出现 Gatekeeper 拦截是预期行为。下面的“安装常见问题”里列了处理方法。

### 从源码构建

```bash
git clone https://github.com/smallmain/hyperkey.git
cd hyperkey
make install
```

`make install` 会完成以下动作：

1. 以 release 模式编译
2. 结束已在运行的旧进程
3. 重置辅助功能 TCC 记录，避免本地重编译后权限记录失效
4. 生成 `.app` 包并做 ad-hoc 签名
5. 安装到 `/Applications`
6. 自动启动应用

## 卸载

```bash
make uninstall
```

如果你想彻底清理，还可以手动做这几件事：

1. 在菜单栏退出 Hyperkey
2. 删除 `/Applications/Hyperkey.app`
3. 删除 `~/Library/LaunchAgents/com.smallmain.hyperkey.plist`
4. 在“系统设置 > 隐私与安全性 > 辅助功能”里移除权限项

## 安装常见问题

### 提示“`Hyperkey.app` 已损坏，无法打开。你应该将它移到废纸篓”

这通常不是 ZIP 真的损坏，而是 macOS Gatekeeper 对未 notarize 应用的隔离拦截。

建议按顺序尝试：

1. 删除当前应用，重新下载 `Hyperkey.zip`
2. 用 Finder 解压，并把 `Hyperkey.app` 移到 `/Applications`
3. 在 Finder 里按住 `Control` 点击应用，选择“打开”
4. 如果仍被拦截，进入“系统设置 > 隐私与安全性”，点击“仍要打开”
5. 如果你信任这个二进制，但系统还是拒绝，可手动移除隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/Hyperkey.app
```

如果你不想运行未签名发布包，最稳妥的办法是自行从源码构建：

```bash
git clone https://github.com/smallmain/hyperkey.git
cd hyperkey
make install
```

### 提示“Apple 无法检查它是否包含恶意软件”或“无法验证开发者”

这是未经过 Developer ID notarization 的典型提示，处理方式和上面相同：

1. 先把应用放到 `/Applications`
2. 用 Finder 的“按住 `Control` 点击 -> 打开”放行一次
3. 必要时到“系统设置 > 隐私与安全性”里点击“仍要打开”
4. 最后再考虑执行：

```bash
xattr -dr com.apple.quarantine /Applications/Hyperkey.app
```

### 应用能启动，但没有生效，或者菜单栏一直显示“Waiting for Accessibility permission...”

Hyperkey 只有拿到“辅助功能”权限后才会开始拦截和注入按键。

处理步骤：

1. 打开“系统设置 > 隐私与安全性 > 辅助功能”
2. 确认 `Hyperkey` 已开启
3. 如果已经开启但仍卡住，把它从列表里删除后重新添加，然后重启应用
4. 如果权限记录可能已经失效，重置后再重新授权：

```bash
tccutil reset Accessibility com.smallmain.hyperkey
```

如果你是本地开发构建，`make install` 已经会自动执行这一步。

### 从源码重编译后，系统里明明已经勾选了辅助功能，但 Hyperkey 还是不工作

这是 TCC 和二进制签名哈希不匹配导致的常见问题。每次重新编译，本地二进制的签名哈希都会变化，旧授权可能不再适用。

直接执行：

```bash
make install
```

如果还不行，再手动重置一次：

```bash
tccutil reset Accessibility com.smallmain.hyperkey
```

然后重新打开应用并重新授权。

### Caps Lock 仍然在切换大小写，或者 Hyper 完全没有激活

常见原因：

1. 没有拿到辅助功能权限
2. `hidutil` 没有成功把 Caps Lock 重映射成 `F18`
3. 系统里还有别的按键映射工具也在接管键盘

建议这样排查：

1. 打开 Hyperkey 菜单，看是否出现 `Warning: HID mapping failed`
2. 退出并重新启动 Hyperkey
3. 暂时关闭 Karabiner、BetterTouchTool、Hammerspoon 等同类工具
4. 如果是源码构建，重新执行 `make install`

### 内建键盘能用，但外接键盘不工作

外接键盘这条路径依赖 IOKit HID seizure，也就是独占接管设备。如果别的工具已经抢先占用了键盘，Hyperkey 可能拿不到设备。

建议按顺序处理：

1. 拔掉外接键盘再插回去
2. 打开菜单里的 **Keyboards** 子菜单，确认设备是否被识别
3. 退出其他可能接管键盘的工具
4. 重启 Hyperkey

补充说明：

- 当前只重新注入键盘页 `0x07` 事件，媒体键这类 consumer page 按键可能不会工作
- 如果某个设备无法被独占接管，Hyperkey 会跳过它，以避免重复输入

### 外接键盘按键重复、连发，或者像是被处理了两次

这通常说明还有另一个键盘工具也在处理同一台设备。

1. 退出 Karabiner 和其他全局键盘重映射工具
2. 断开再重新连接键盘
3. 重启 Hyperkey，并重新检查 **Keyboards** 子菜单里的状态

### 把应用移动位置后，`Launch at Login` 不生效了

启用 `Launch at Login` 时，LaunchAgent 会记录当时的可执行文件路径。如果你后来把应用从下载目录挪到别处，旧路径就会失效。

处理方法：

1. 先把 `Hyperkey.app` 放到最终位置，建议就是 `/Applications`
2. 打开 Hyperkey
3. 将 **Launch at Login** 关闭再重新开启一次

如果还不行，可以删掉旧的 LaunchAgent 再重新生成：

```bash
rm -f ~/Library/LaunchAgents/com.smallmain.hyperkey.plist
```

然后再从菜单里重新启用 **Launch at Login**。

### 看不到 Dock 图标

这是正常行为。Hyperkey 是菜单栏应用，不会显示 Dock 图标，只会在 macOS 菜单栏里显示一个 Caps Lock 图标。

### 去哪里看日志

- 如果你从终端直接启动，日志会输出到 stderr
- 如果通过 LaunchAgent 运行，查看 `/tmp/hyperkey.err.log`

## 使用说明

启动后，菜单栏会出现一个 Caps Lock 图标。主要菜单项如下：

- **Keyboards**：显示当前检测到的键盘，以及 `Built-in` / `Seized` 等状态
- **CapsLock alone -> Escape**：单独点按 Caps Lock 时发送 Escape
- **Hyper + HJKL -> Arrows**：把 `Hyper + H/J/K/L` 映射到方向键
- **Launch at Login**：设置登录自动启动
- **Check for Updates**：手动检查新版本

如果还没有授予辅助功能权限，菜单里会显示等待提示；授权后应用会自动开始工作，不需要重启。

## 工作原理

| 层级     | 作用               | 实现方式                                     |
| -------- | ------------------ | -------------------------------------------- |
| HID 层   | Caps Lock -> F18   | `hidutil property --set`                     |
| 事件层   | F18 -> Hyper       | `CGEventTap` 给按键附加 `Cmd+Ctrl+Opt+Shift` |
| 外接键盘 | 独占接管并回注事件 | IOKit HID seizure + CGEvent re-injection     |
| UI 层    | 菜单栏交互         | `NSStatusItem` + 动态菜单                    |

### 双路径键盘架构

**内建键盘**

- `hidutil` 把 Caps Lock 重映射到 `F18`
- `CGEventTap` 拦截 `F18` 的按下和抬起
- 在 Hyper 激活期间，给其他按键附加 Hyper 修饰键

**外接键盘**

- macOS 26+ 下，`CGEventTap` 无法可靠收到外接 USB 键盘事件
- Hyperkey 通过 IOKit HID 检测并独占接管外接键盘
- 收到 HID 输入后，再以 CGEvent 的形式重新注入系统
- Caps Lock 会被当成 Hyper 键，其余按键透明转发

这两条路径共享同一套 Hyper 状态，所以内建键盘和外接键盘的行为保持一致。

## 系统要求

- macOS 13+
- 已授予“辅助功能”权限

## 排查

- **第一次启动看起来没反应**：通常是还没授予辅助功能权限，菜单里会有提示
- **本地重新编译后权限开着但依然不生效**：这是 TCC 记录和新二进制 CDHash 不匹配，重新执行 `make install` 即可
- **外接键盘按键重复输入**：通常和 HID seizure 失败后又继续注册回调有关；当前实现只会在成功独占后才注册回调
- **外接键盘媒体键失效**：当前只处理键盘页 `0x07`，消费页 `0x0C` 的媒体键还没有重新注入
- **想看日志**：直接看 stderr；如果通过 LaunchAgent 运行，可查看 `/tmp/hyperkey.err.log`

## 许可证

MIT
