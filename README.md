# AI 本地栈控制中心

> ## 这是一个开关总闸。
>
> **你给我路径，我负责开关。**
> **开错了，是你给错了——不是我在自作主张。**
>
> 墙里走的是什么电（Ollama、LM Studio、别的什么引擎），它不关心。
> 插上去的是什么电器（Cline、Open WebUI、随便哪个面板），它也不关心。
>
> 它只做三件事：**通、断、保护。**
> 顺便把电表读数亮给你看。
>
> 它永远不会自作聪明。

---

### 契约

```
我承诺：忠实执行你给的路径，不打折扣、不揣测、不代劳。
你承诺：给对路径。

给错了 -> 如实报错，不猜、不改、不"帮你修好"。
```

**这条契约同时划定了责任边界**——它也解释了为什么
这里没有路径自动搜索、没有引擎类型判断、没有环境变量兜底：
那些都是"自作主张"，是电闸箱不该有的东西。

---

### 关于杀软误报 / On Antivirus Hysteria

> **EN** — Your antivirus will scream. That is the point.
>
> The launcher says `Disabling Windows Defender`. It doesn't.
> It says `Injecting AI_Gatekeeper payload`. It doesn't.
> What it actually does: `Start-Process` an 883-line switch panel.
>
> `payload.bin` → open it in Notepad. It's the README.
> `injector.dll` → open it in Notepad. It's the MIT license.
>
> 883 lines. No binary. No network. No registry. No env vars.
> It writes exactly one file: `paths.json`.

> **中文** — 杀软会报警，那是故意的。
>
> 启动器喊"禁用 Defender"，它没禁。喊"注入载荷"，它没注。
> 它唯一干的事，是拿管理员权限拉起一个 883 行的开关面板。
>
> `payload.bin` 用记事本打开，是 README。
> `injector.dll` 用记事本打开，是开源协议。
>
> 没有二进制，不联网，不写注册表，不改环境变量。
> 它唯一会写的东西，是 `paths.json` 里的路径。

极客看到这里会笑，小白看到这里会报警。**两者都对。**

嫌它吵就直接用本仓库的 `AIzh_v56t.ps1`；
想看热闹就去 Releases 下载那个压缩包。

---

## 它管什么

| 电闸箱 | 本工具 |
|---|---|
| 总闸推上去 | `Start-Process` 拉起引擎 |
| 插座通电 | 拉起对话面板 |
| 分路空开跳闸 | 按程序阻断外网（`-Program $exe`） |
| 强行断开 | Force-kill 引擎进程 |
| 数字电表 | 端口 / VRAM / 内存 只读显示 |

## 它不管什么

| 不该管 | 归属 |
|---|---|
| 跑什么模型、模型存在哪 | 引擎自己的事 |
| 引擎的环境变量、上下文长度 | 系统层或引擎配置，配一次一劳永逸 |
| 对话面板怎么用、参数怎么调 | 面板自己的事 |
| 下载/删除模型 | 只做转发，不代劳 |

---

## 电闸箱判据

**任何新功能，先问一句：电闸箱会干这事吗？**

```
会   -> 做
不会 -> 不做，无论它看起来多有用
```

这条判据已经拦下并移除了：

- ~~`model_dir`~~ —— 电表不关心你家电表箱里放着什么
- ~~`engine_env` 注入~~ —— 电闸箱不会在你开电视时顺手开空调
- ~~多引擎同时运行~~ —— 也顺带确认了：多模型共存是引擎的能力，与开关无关

> **注意**：引入引擎侧概念 = 被它绑定。
> 中间件一旦开始"理解"引擎内部，后续每次改动都要为它让路。

---

## 用法

```powershell
# 管理员身份运行（建防火墙规则需要权限）
.\AIzh_v56d.ps1

# 自检（不改任何状态）
.\AIzh_v56d.ps1 -SelfTest
```

```
引擎      1-3    启动 / 停止 / 启动对话面板
网络控制  4-6    阻断外网 / 恢复 / 测试 API
系统配置  7-10   指定路径 / 校验路径 / 加入 PATH / 打开资源管理器
危险区    A-C    Force-kill / 删除模型 / 拉取模型（需二次确认）
```

**断网只阻断引擎和面板两个程序**，你上网、微信、其他一切完全不受影响。

---

## 配置 `paths.json`

放在脚本同目录。**只有三项是必需的**：

```json
{
  "engine":      ["D:\ollama-windows-amd64\ollama.exe"],
  "engine_args": ["serve"],
  "engine_port": 11434,
  "panel":       ["D:\Microsoft VS Code\code.exe"]
}
```

**端口没有默认值。** 不填就不探测——状态栏显示 `[未配置端口]`（红）。
换引擎时忘了改端口，面板会明确告诉你"没配"，而不是拿旧端口去猜、然后误报引擎坏了。

**`engine_args` 也没有默认值。** 用 ollama 就必须写 `["serve"]`——
`"serve"` 是 ollama 的子命令，属引擎侧知识，中间件不替你猜。
不填就裸启动，起不来就看日志——那是 json 没填对，不是中间件的事。

其余可选：

| 键 | 默认 | 说明 |
|---|---|---|
| `health_endpoint` | `/api/tags` | 健康检查路径 |
| `process_name` | 空 | 为空时改用端口反查 PID |
| `fw_engine_rule` | `AI_Block_Engine` | 引擎阻断规则名 |
| `fw_panel_rule` | `AI_Block_Panel` | 面板阻断规则名 |

没有这个文件时脚本照样能跑，路径为空就如实报"未配置"。
旧键 `ollama` / `vscode` / `api_port` 会在首次启动时自动转为新名，无需重填。

---

## 它不做什么

按 84（电闸箱）+ 85（契约）+ 94（只写 json）：

```
❌ 不改系统环境变量 / 不把引擎加进 PATH
   —— 正常安装时这是安装包该做的事，绿色版你自己决定
❌ 不注入、不读取引擎的环境变量
❌ 不管模型装在哪、有几个、怎么拉
❌ 不猜端口、不猜启动参数
❌ 不做全盘扫描、不做模糊匹配
```

**它唯一会写的东西，是 `paths.json` 里的路径。**
其余一律只读显示，或执行纯粹的开关动作。

---

## 孤儿规则与手工清规则

### 规则存在哪

防火墙规则是**操作系统对象**，存在 Windows 里，不存 json、不存面板进程。
面板进程退出后内存清空，**不残留任何东西**——规则还在，这正是"断网持久"的原理。

面板只按名字去查，查不到即视为未知。**它不持有规则。**

### 删除已是通配符

```powershell
Get-NetFirewallRule -DisplayName "$Prefix*" | Remove-NetFirewallRule
```

带星号，所以**菜单 5（恢复网络）本身就能清掉全部 `AI_Block_` 前缀的规则**，
包括历史遗留。**不需要额外的"强制清空"菜单。**

### 面板外保底脚本

面板不在、面板坏了、或你就是想在外面清：

```powershell
# 清除（管理员 PowerShell）
Get-NetFirewallRule -DisplayName "AI_Block_*" | Remove-NetFirewallRule

# 验证（应无输出）
Get-NetFirewallRule -DisplayName "AI_Block_*" | Select-Object DisplayName, Enabled
```

无输出 = 清干净。

### 前缀锁死（v5.6k 起）

`AI_Block_` 是**常量，不可配置**（json 里已无任何 `fw_*` 键）。

```
AI_Block_1   AI_Block_2   AI_Block_3 ...
```

**规则名归代码，拦谁归你。** `net_rules` 是唯一依据：

```json
"net_rules": [
  "D:\ollama-windows-amd64\ollama.exe",
  "D:\Microsoft VS Code\Code.exe"
]
```

没有 `net_rules` 就按 4 → 报 `[Fatal] net_rules 为空`，不猜、不回退到 `engine`/`panel`。

`AI_Block_*` 同时是三样东西的唯一依据：

```
菜单 5 的删除 / README 手工脚本 / 状态栏计数
```

前缀一旦可改，三者同时失效、孤儿无法找回——所以**不给这个权限**。

菜单 5 现在是「先全清再按需建」：按 5 会清掉**所有** `AI_Block_*`，
连历史遗留和孤儿一起回收，因此不需要额外的"强制清空"菜单。

### ⚠️ 免责声明

> **本工具所有网络规则均以 `AI_Block_` 开头，清理时也是全量清理。**
> **误删了你自己或其他软件同名的 `AI_Block_` 前缀规则，概不负责。**

前缀不可配置（v5.6k 起），无法避开。要用本工具的网络控制，就得接受这个前缀归它。
需要与他人共用前缀的场景，请改用操作系统自带的防火墙设置自行管理。

---

## 版本

```
v5.6t — 883 行（核心路径已实机验证）
```

插件目录 `plugins\` 为可选扩展位，缺失不影响主控台。
