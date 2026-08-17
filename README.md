# 🎮 L4D2 v2 投票菜单（键盘操作 · 游戏内聚合投票）

> 求生之路 2（Left 4 Dead 2）SourceMod 插件：**长按 R 键呼出三级投票菜单**，勾选选项 → 游戏内聚合投票 → 通过后自动执行配置。
> 配置驱动（`vote_manager.cfg`），最多支持 **12 分类 / 44 子分类 / 540+ 选项**，无需改代码即可定制自己的服务器菜单。

![version](https://img.shields.io/badge/version-3.1.3-blue)
![sourcemod](https://img.shields.io/badge/SourceMod-1.12%2B-orange)
![game](https://img.shields.io/badge/Game-L4D2-darkgreen)
![license](https://img.shields.io/badge/license-MIT-lightgrey)

---

## ✨ 特性

| 特性 | 说明 |
|------|------|
| ⌨️ **键盘呼出** | 长按 **R 键 3 秒**弹出菜单（时长可编译期自定义，防换弹误触） |
| 🗂️ **三级菜单** | 一级分类 → 二级子分类 → 叶子选项，树状结构一目了然 |
| 🗳️ **游戏内聚合投票** | 基于 `l4d2_nativevote` 原生投票界面，20 秒投票期、多数通过即生效 |
| 📦 **超大容量** | 单配置支持 1000+ 选项（`MAX_MENU_ITEMS 1024`），按页翻页浏览 |
| 🔄 **热重载** | 管理员 `sm_v2reload` 重读配置并重建菜单，**无需重启服务器** |
| 🧩 **配置驱动** | 所有分类/选项由 `vote_manager.cfg` 定义，纯文本编辑，零代码定制 |
| ⚡ **多选合并执行** | 一次投票可执行多个选项（友伤/火伤/反伤类自动归并到末尾覆盖执行） |
| 🕒 **30 秒自动关闭** | 菜单无操作自动关闭，不干扰游戏 |
| 🔌 **低依赖** | 仅依赖 2 个插件（随包附带），与绝大多数服务器插件可共存 |

---

## 🚀 快速开始（3 步）

### 1️⃣ 复制文件
把本仓库的 `addons/` 和 `cfg/` 目录**合并**到你的 L4D2 服务器根目录（与 `left4dead2/` 平级）：

```
你的服务器根目录/
├── left4dead2/
│   ├── addons/      ← 合并进来（plugins/configs/scripting/gamedata）
│   └── cfg/         ← 合并进来（vote/ 示例选项）
```

### 2️⃣ 加载插件
```bash
# 控制台 / RCON：
sm plugins load server_settings_v2
sm plugins load l4d2_nativevote
sm plugins load simple-chatcolors2
```
> 三个插件放在 `plugins/` 目录后**默认随服自动加载**，此步骤可省略。

### 3️⃣ 进游戏测试
- 玩家**长按 R 键 3 秒** → 呼出 v2 菜单
- `1-5` 选择选项、`6` 发起投票、`7` 返回上级、`8/9` 翻页
- 投票通过后配置立即生效 🎉

---

## 🧰 环境要求

| 项目 | 要求 | 说明 |
|------|------|------|
| **SourceMod** | **1.12 及以上** | 包内 smx 用 SM 1.12 编译；**SM ≤ 1.11 需用源码重编译**（见下文） |
| **Metamod** | 1.11+ | SourceMod 前置 |
| **L4D2** | 任意发行版 | 仅依赖引擎事件与 SourceMod API |
| **依赖插件** | 随包附带 | `l4d2_nativevote`（投票 API）+ `simple-chatcolors2`（彩色消息） |

> 💡 不确定 SM 版本？控制台执行 `sm version` 看首行。

---

## 🗂️ 目录结构

```
l4d2-v2-vote-menu/
├── README.md
├── addons/sourcemod/
│   ├── plugins/
│   │   ├── server_settings_v2.smx      # 主插件
│   │   ├── l4d2_nativevote.smx         # 依赖：原生投票 API
│   │   └── simple-chatcolors2.smx      # 依赖：彩色聊天消息
│   ├── scripting/
│   │   ├── server_settings_v2.sp       # 主插件源码
│   │   └── include/                    # 编译头文件
│   ├── configs/
│   │   ├── vote_manager.cfg            # 菜单配置（默认最小示例，装即用）
│   │   ├── vote_manager.full.example.cfg # 完整版配置示例（12分类/44子分类/540选项结构参考）
│   │   └── simple-chatcolors.cfg       # 颜色主题（可选）
│   └── gamedata/
│       └── smlib_colors.games.txt      # simple-chatcolors2 签名数据（必装）
└── cfg/vote/
    └── demo_*.cfg                      # 示例选项执行文件
```

---

## ⚙️ 菜单配置（vote_manager.cfg）

### 三级结构语法

```
"VoteMenu"                ← 固定根节点
{
    "一级分类"            ← 2 个引号 = 分类名
    {
        "二级子分类"       ← 可选层级
        {
            "选项名" "exec 路径/文件.cfg"    ← 4 个引号 = 叶子选项
        }
        "直接选项" "exec 路径/文件.cfg"      ← 一级分类也可直接挂选项
    }
}
```

### 规则速查

| 规则 | 说明 |
|------|------|
| 分类名 | **≤ 63 字节**（中文约 21 字），不能含 `/` `\` |
| 选项名 | ≤ 127 字节，显示在投票菜单 |
| 执行路径 | `exec` 后路径**相对游戏 `cfg/` 目录**，目标文件必须真实存在 |
| 层级 | 最多三级（分类 → 子分类 → 选项），`{` `}` 必须成对 |
| 混排 | 一级分类下可同时有子分类和直接选项 |
| 修改生效 | 管理员 `sm_v2reload` 热重载，无需重启 |

### 包内自带两个配置
1. **`vote_manager.cfg`**（默认示例）：2 分类 / 2 子分类 / 9 选项，全部指向包内 `cfg/vote/demo_*.cfg`，装完即可测试
2. **`vote_manager.full.example.cfg`**：完整版配置（12 分类 / 44 子分类 / 540 选项）**结构参考**——注意它引用的执行文件（`vote/rm.cfg`、`ndxz/jd.cfg` 等数百个）是原服务器特有配置，**未包含在本仓库**，直接使用前需自行补齐对应 cfg

---

## ⌨️ 按键操作

| 按键 | 功能 |
|------|------|
| **长按 R（3 秒）** | 呼出 v2 菜单 |
| `1` ~ `5` | 选择选项 |
| `6` | 发起投票 |
| `7` | 返回上级菜单 |
| `8` / `9` | 上一页 / 下一页 |
| （30 秒无操作） | 自动关闭菜单 |

**调整长按时长**：编辑 `server_settings_v2.sp` 第 12 行 `#define RELOAD_HOLD_TIME 3.0` 后重编译。

---

## 🛠️ 从源码编译

**SM 1.12 环境**直接使用包内 smx 即可。**SM ≤ 1.11 环境**需重编译：

1. 下载对应版本的 SourceMod，使用其 `spcomp64.exe`
2. 将 `scripting/include/` 下的 `l4d2_nativevote.inc`、`colors.inc` 放入编译器的 `include/` 目录
3. 编译：
   ```bash
   cd addons/sourcemod/scripting
   spcomp64 server_settings_v2.sp -o=server_settings_v2.smx
   ```
4. 覆盖 `plugins/server_settings_v2.smx` 即可

> ⚠️ SM 1.11 存在 methodmap 析构 bug，官方建议直接升级 SM 1.12。

---

## ❓ 常见问题（FAQ）

<details>
<summary><b>Q1：插件加载失败 / 列表显示 bad load？</b></summary>

看控制台完整报错：
- `dependency "l4d2_nativevote" not found` → 未装 l4d2_nativevote（或其自身加载失败）
- `dependency "colors" not found` → 未装 colors 类插件
- `Error(s) detected parsing` → SM 版本过旧，用源码重编译

先确认依赖：`sm plugins list` 中 l4d2_nativevote / simple-chatcolors2 是否 loaded。
</details>

<details>
<summary><b>Q2：插件加载了但长按 R 没反应？</b></summary>

- 确认没有其他插件抢占 R 键长按（部分插件监听 `IN_RELOAD`）
- 确认菜单已构建（加载时控制台应有"解析完成 / 菜单构建完成"日志）
- 用 `sm_v2` 手动打开测试：能开说明插件正常，只是 R 键被抢
</details>

<details>
<summary><b>Q3：投票通过了但什么都没变？</b></summary>

- 控制台若报 `Couldn't exec "xxx.cfg"` → 执行文件不存在，检查 vote_manager.cfg 中的路径是否对应服务器 `cfg/` 下真实文件
- 检查 `cfg/vote/` 目录**可写**（插件运行时需写入 `v2_integrated.cfg`）
</details>

<details>
<summary><b>Q4：某分类/子分类显示为空？</b></summary>

- 该分类下没有选项，或选项行格式错误（必须是 4 个引号且含 `exec`）
- `{` `}` 配对错误导致选项挂错层级
</details>

<details>
<summary><b>Q5：与其他投票插件冲突？</b></summary>

v2 菜单使用 `l4d2_nativevote`（原生投票函数库），与 `nativevotes`（另一投票实现）**不是同一个库**，一般可共存。
</details>

---

## 📦 升级与卸载

**升级**：备份旧 smx → 覆盖 `plugins/server_settings_v2.smx` → `sm plugins reload server_settings_v2`（热载，不影响在线玩家）→ 控制台确认 `Version: 3.1.3`。

**卸载**：`sm plugins unload server_settings_v2`，删除 smx（及可选清理 `configs/vote_manager.cfg`、`cfg/vote/v2_integrated.cfg`）。

---

## 📜 版本历史

| 版本 | 变更 |
|------|------|
| 3.1.3 | 长按 R 呼出时间 0.4s → **3s**（防换弹误触） |
| 3.1.2 | 修复投票后菜单消失（投票期间暂停超时计时）；修复翻译短语缺失（改硬编码中文） |
| 3.1.0 | 三级菜单解析修复：`}` 按实际层级闭合，修复子分类丢失；兼容"子分类+直接叶子"混排 |

## 🙏 致谢

- [L4D2NativeVote](https://github.com/Lysergid/l4d2_nativevote)（Powerlord / fdxx）：原生投票函数库
- [Simple Chat Colors 2](https://forums.alliedmods.net/showthread.php?t=336641)（Silvers）：彩色聊天消息
- [Multi-Colors](https://forums.alliedmods.net/showthread.php?t=238637)：`colors.inc` 来源

---

*维护：kimika1234 · 本仓库为 L4D2 服务器运维工具开源项目*
