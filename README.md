# iphctl

在 Mac 上控制已配对 iPhone 的 Swift 命令行工具，依赖官方「iPhone 镜像」。供有视觉能力的 agent 使用：CLI 执行动作，调用方看截图并判断结果。

无需 USB。手机保持锁定，通过官方镜像连接。输入操作会将镜像窗口带到前台，使用 Mac 工作时可通过 `pause` 暂停手机输入。

需要支持 iPhone 镜像的 Mac 和 iPhone，并完成官方配对与首次连接。编译需要 Xcode 命令行工具和 Python 3。输入需要运行环境已有的辅助功能、发送及监听输入权限；截图需要录屏权限。在「系统设置 → 隐私与安全性」中为运行命令的终端或宿主应用授予所需权限。`doctor` 只检查这些权限，不弹出授权申请。

## 构建

```sh
git clone https://github.com/kaerf15/iphctl.git
cd iphctl
make
./iphctl --help
./iphctl capabilities
./iphctl doctor
```

`make` 编译到 `.build/`，以临时签名签署并运行协议和控制层测试，通过后更新本目录的 `iphctl`。不会安装到系统目录。`make test` 只构建和测试，不更新本目录的可执行文件。控制层测试使用模拟系统接口，不操作手机。`iphone_mirror.py` 是兼容启动器。

## 看图与动作

```sh
./iphctl status
./iphctl doctor
./iphctl shot --out /tmp/iphone.png
./iphctl click 320 700
./iphctl home
./iphctl switcher
./iphctl spotlight
./iphctl paste '小红书'
./iphctl key return
./iphctl swipe left --y 1230 --amount 280
./iphctl scroll down --x 318 --y 700 --amount 120
./iphctl connect
./iphctl open '小红书'
```

示例坐标必须用当前截图重新选取。截图原点在镜像窗口左上角；坐标和 `--amount` 的单位都是截图像素。工具根据实际截图比例转换为屏幕点。`swipe` 返回的 `from` 和 `to` 是屏幕点，并标明 `coordinate_space`。

`shot` 按窗口 ID 截图，不拉到前台，也不包含被遮挡处的其他 App。无 `--out` 时返回唯一临时文件路径。`shot` 和 `open` 返回 `snapshot_id`；点击、滑动和滚动可传 `--snapshot 截图ID`，要求匹配最近截图和当前窗口/显示器配置，否则返回 `stale_snapshot`。它检查坐标几何，不证明手机页面内容没有变化。

没有传截图 ID 时，输入会复用 60 秒内、窗口和显示器配置一致的最近截图比例；不符合条件才临时截图获取比例。CLI 和 NDJSON 使用同一参数校验路径。

`open` 只打开聚焦、输入名字、返回截图，不会回车。调用方看图后再执行 `key return` 或 `key escape`。`paste` 实际通过 Unicode 键盘事件直接输入文字。

已验证点击、文字输入、主屏幕、App 切换器等菜单入口，以及主屏幕页面圆点处的左右翻页。左右拖动在其他界面的效果需要看图验证；选在图标上可能进入编辑模式。

上下滚动使用 `scroll up/down --x 截图像素 --y 截图像素 [--amount 截图像素] [--snapshot 截图ID] [--invert]`。`up` 表示查看列表上方，`down` 表示查看下方。`amount` 默认 120，范围大于 0 至 8192；它是滚轮输入量，工具按截图比例换算为屏幕点，再分段发送，不保证页面移动相同距离。换算后小于一个屏幕点会报错。如果在其他环境看图确认方向相反，由调用方明确选择 `--invert`；工具不会识图校准方向。

滚动先移动真实指针并发送鼠标移动事件，让系统选择接收滚轮的窗口，再发送像素滚轮。已在小红书看图验证两个方向；其他 App 和系统设置仍需调用方看图确认。滚动无需管理员认证或额外驱动。

所有手机输入共用执行器：先获取跨进程互斥锁，检查权限和连接状态，使用 AX 确认前台焦点，再检查每个输入事件的窗口身份、几何和目标。事件创建失败会报错；取消时释放已按下的键或鼠标按钮。其他键鼠输入、焦点丢失、窗口变化或断开连接都会取消后续动作。

输入期间短时监听键鼠事件，过滤本进程的合成事件，不读取或记录按键内容。指针只在未受到其他输入干扰且仍停在预期位置时恢复。返回 `events_sent` 表示已发送的手机输入事件总数，`reports` 是其中的滚轮事件数，`cleanup_events` 是取消后的释放事件数。指针定位不计入这些数量。成功和报错均可包含部分执行信息；`verified` 始终为 false。其他 App、系统版本或滚动设置仍须看图验证效果。

`swipe up/down` 仍返回 `unsupported_gesture`，因为垂直鼠标拖动无效；它与滚轮是不同的输入方式。`capabilities` 可在不操作手机的情况下读取这些限制。

`ok` 表示命令执行结果，不是手机页面变化的证明。窗口存在也不代表手机已连接。每次操作后使用 `shot`，由调用方确认画面。

## 与用户操作协调

```sh
./iphctl pause     # 暂停后续手机输入，取消正在执行的动作
./iphctl resume    # 恢复输入
./iphctl cancel    # 只取消正在执行的动作，不持续暂停
```

需要使用 Mac 工作时先 `pause`，完成后 `resume`。暂停期间仍可读取 `status`、`doctor`、`capabilities` 和截图。`status` 返回连接状态、真实前台状态、暂停状态、是否有其他控制进程及权限信息。未知的 Mac 连接界面按 `blocked`/`unknown` 处理，不猜测手机已经连接。

互斥锁和控制状态保存在当前用户的 `~/Library/Caches/iphone-ct/control`，不安装常驻服务。该目录名保留以兼容此前版本。多个进程冲突时返回 `busy`，不发送输入；调用方决定是否重试。需要隔离测试或控制域时可设置 `IPHONE_CT_CONTROL_DIR`，目录必须属于当前用户且权限为 0700；同一镜像的控制进程应使用同一个目录。

监听只覆盖单条动作执行期间，不能撤回已发送的动作，也不提供独立的第二套键鼠。实际输入仍会把镜像拉到前台；长期使用 Mac 时应明确暂停手机输入。

## Agent 协议

```sh
./iphctl agent <<'EOF'
{"id":"features","cmd":"capabilities"}
{"id":"screen","cmd":"shot","out":"/tmp/iphone.png"}
EOF
```

滚动请求示例：`{"id":"move","cmd":"scroll","direction":"down","x":318,"y":700,"amount":120}`。可增加 `snapshot_id` 字段及布尔值 `invert`。`pause`、`resume`、`cancel` 同样可作为 `cmd`。坐标由调用方从当前截图选择。

stdin 和 stdout 都是每行一个 JSON。空行忽略；无效请求返回错误后继续接收下一行。请求可以带 `id`，响应原样带回。单次命令的 stdout 为便于阅读的 JSON；agent 模式的 stdout 为紧凑 NDJSON。

调用顺序通常是 `shot` → 调用方识图 → 动作 → `shot`。CLI 不识图、不自动确认搜索结果。

## 源码结构

`main.swift` 负责 CLI/NDJSON 入口；`Protocol.swift` 校验参数；`Models.swift` 定义状态和结果；`Control.swift` 负责互斥、取消和执行保护；`MacRuntime.swift` 对接公开 macOS API；`Capture.swift` 管理截图比例和 ID；`Actions.swift`、`Scroll.swift` 实现具体动作。测试通过模拟 `MirrorRuntime` 验证失败和清理路径。

## 测试

```sh
make test
```

测试覆盖参数校验、NDJSON 请求恢复、跨进程互斥、暂停与取消、焦点及连接变化、输入中断和释放清理，不需要连接手机或授予输入权限。真实动作效果由调用方看截图验证。

## 致谢与许可

滚轮事件顺序参考了 [phone-harness](https://github.com/ShawnPana/phone-harness/blob/a80f8845e125269545bbf462967fe7b620691422/src/phone_harness/background.py#L225)。

项目采用 [MIT License](LICENSE)。
