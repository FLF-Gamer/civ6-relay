# 3.2.1 客户端修复与验证

日期：2026-10-30。组网后端仍为 2.6.4-civ6.2，本次只修改 Windows 包装脚本、界面和导出版本。

## 修复

- 端口标签原宽度与输入框位置重叠 30 像素。输入区改为 TableLayoutPanel 独立单元格，标签自动宽度，按 DPI 缩放。昵称、服务器 IP 和端口仍由玩家填写并保存在本机。
- 状态 JSON 的数组显式逐项展开，适配 Windows PowerShell 5.1 和 PowerShell 7 的不同输出行为。原流程在数组整体作为单个管道对象输出时，会把路由列表误当成一条路由并失败。兼容行为依据：[PowerShell 上游问题记录](https://github.com/PowerShell/PowerShell/issues/3424)；用于回归模拟的 `-NoEnumerate` 见 [微软文档](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertfrom-json?view=powershell-7.5)。
- 状态查询使用 UTF-8 读取后台输出，保留中文昵称。查询失败显示具体原因，包括本机 RPC 未就绪、实例不匹配或组件无法启动；不回显原始配置或后台错误正文。
- “检查组件”比较源文件和已安装文件，只替换缺失或损坏的文件。内容相同的 WinDivert 驱动不重写；连接期间文件完整时可只读检查。确需修复时先断开；若不同版本的驱动仍被系统占用，提示重启后再检查。
- 实际需要替换驱动时先尝试驱动，避免驱动被占用后才发现其他组件已经被替换。常规重连仍只比较小型版本清单，不新增持续哈希、网络扫描或按包脚本。

## 已执行

- 服务端 8 项单元测试通过，覆盖通用包复用、不同电脑身份、导出和原有服务管理行为。
- `tests/client.Tests.ps1` 通过：空白初始输入、中文昵称、通用接入信息与本机身份、DHCP 配置、仅游戏网段路由、实际路径显示、重连不重装组件、脚本解析和内嵌 C# 编译。
- `tests/client-repair.Tests.ps1` 通过：模拟 WinDivert 驱动被占用，完整组件检查零复制；连接期间只读检查；缺失 CLI 时只修复 CLI；连接期间禁止实际修复；需要替换但被占用的驱动在其他组件写入前失败。
- `tests/client-status.Tests.ps1` 通过：使用发布包相同的 Linux 后端和 CLI，启动三个真实进程，在隔离容器的回环网络建立协调节点和两个玩家；真实 CLI/RPC 返回本机 IP、中文昵称、无虚拟 IP 的协调节点和 2 跳玩家路由，界面状态与玩家列表转换通过。
- 上述真实 RPC 测试也在模拟 PowerShell 5.1 数组输出语义下通过；同时复现旧解析流程的嵌套数组错误。覆盖空、单条和多条路由，以及实例不匹配、RPC 不可用、CLI 缺失和无效 JSON 的错误提示。
- 界面字段布局、UTF-8 BOM 和 CRLF 静态检查通过。

测试使用 PowerShell 7.5 的 Linux 容器；5.1 数组输出语义和驱动占用通过定向模拟验证。未执行真实 Windows 11 的 GUI 显示、内核驱动加载或文明6对局，不能据此声称这些实机验证通过。已有六人网络测试仍见 [通用客户端验证](common-client.md)，此次没有更改后端或重新执行该套测试。

## 复现

在 PowerShell 7.5 容器中挂载仓库为 `/workspace`，工作目录为 `/workspace`，网络设置 `--network none`：

```powershell
pwsh -NoProfile -File tests/client.Tests.ps1
pwsh -NoProfile -File tests/client-repair.Tests.ps1
pwsh -NoProfile -File tests/client-status.Tests.ps1
```

服务端导出更新无需重启组网进程，也不需要改端口、防火墙或安全防护。
