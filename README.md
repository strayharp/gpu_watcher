# GPU Watcher

macOS 菜单栏小工具：通过 SSH 同时监控多台 Linux 服务器的 GPU，以及每块 GPU 上正在跑的进程（谁、什么命令、占多少显存、跑了多久）。

- 服务器端 **不需要安装任何东西**，只要有 `nvidia-smi`。
- 菜单栏显示 `忙碌 GPU 数 / 总数`，点开是每台机器的明细。
- 自己的进程高亮；点击某一行可展开完整命令、工作目录和 PID。

## 构建与运行

只需要 Command Line Tools（不需要 Xcode）：

```bash
./scripts/bundle.sh
open build/GPUWatcher.app
```

第一次打开会显示服务器列表（读取自 `~/.ssh/config`），勾选要监控的机器即可。

### 换一个 SSH config 文件

设置页顶部的 **SSH config file** 可以直接填路径（支持 `~`）、点 **Choose…** 选文件，或点 **Reset** 回到默认。

- 选了自定义文件后，服务器列表从它读取，所有连接也都用它（相当于 `ssh -F <文件>`），此时 `~/.ssh/config` 不再生效。
- 列表只读取文件里直接写的 `Host` 条目；通过 `Include` 引入的主机连接时有效，但需要在下面的输入框手动添加。

## SSH 登录方式

App 用系统自带的 `ssh`，以非交互方式连接，所以每台机器需要满足其一：

1. **免密登录（推荐）**：`ssh-copy-id <host>` 配一次公钥，之后永久有效。
2. **保存密码**：在面板里那台机器下面输入密码，点 **Save & log in**。密码存在 macOS 钥匙串里
   （不写入任何文件），之后连接断开（休眠、断网、重启）时 App 会自动用它重连。
   - 只回答普通的密码提示；主机指纹确认、私钥口令、2FA 验证码一律不自动回答。
   - 保存的密码如果被服务器拒绝，只尝试一次就停下，等你重新输入，不会反复重试导致账号被锁。
   - 设置页里每台机器旁有 **Forget password**；取消勾选一台机器也会删除它的密码。
   - 重新构建 App 后签名会变，macOS 会对每台机器问一次是否允许读取钥匙串，选"始终允许"即可。
3. **Terminal 登录**：点 **Terminal…**，在 Terminal 里输一次密码（适合需要 2FA 或不想保存密码的情况）；
   连接留在后台被 App 复用，断开后需要重新登录。

没有可用登录方式的机器不会被反复重试，避免触发服务器的 fail2ban。

## 工作原理

每隔 N 秒对每台机器执行一次只读脚本（见 `Sources/GPUWatcher/Probe.swift`）：

| 数据 | 来源 |
| --- | --- |
| GPU 利用率 / 显存 / 温度 / 功耗 | `nvidia-smi --query-gpu` |
| 每块 GPU 上的进程和显存 | `nvidia-smi --query-compute-apps` |
| 每个进程的 GPU 利用率 | `nvidia-smi pmon` |
| 用户、命令行、运行时长、CPU、内存 | `ps -p <pids>` |
| 工作目录（仅自己的进程可读） | `/proc/<pid>/cwd` |

连接通过 `ControlMaster` 复用，套接字放在 `/tmp/gpuwatcher-<uid>/`。

## 调试

```bash
build/GPUWatcher.app/Contents/MacOS/GPUWatcher --probe <host>      # 打印 App 对这台机器看到的内容
build/GPUWatcher.app/Contents/MacOS/GPUWatcher --demo              # 用内置假数据运行
build/GPUWatcher.app/Contents/MacOS/GPUWatcher --render out.png    # 把假数据面板渲染成图片
```
