# AI-gatekeeper

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
