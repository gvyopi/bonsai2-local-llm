# Bonsai 2 本地部署工具包

在 **8 GB 显存的笔记本（RTX 5060 Laptop）** 上运行 Bonsai 2 三元量化模型（9B / 27B），并提供统一控制台接入 DeepSeek Harness（DSH）。

## 这是什么

一套已经在实机验证过的工具与配置：

| 文件 | 作用 |
|---|---|
| `llmctl-core.ps1` | 核心层：配置加载 + 12 个函数，零输出，可被 CLI/GUI 复用 |
| `llmctl.ps1` | 命令行入口：`status` / `start` / `stop` / `tiers` / `log` / `ollama` |
| `llmctl-gui.ps1` | WinForms 图形界面（后台线程采集，不卡顿） |
| `launch-gui.vbs` | 双击启动 GUI，不弹控制台 |
| `models.example.json` | 示例模型清单（改名为 `models.json` 即用，合法 JSON，无注释语法） |
| `probe-context.ps1` | 自动探测显卡能承载的最大上下文 |
| `tools/bench-speed.ps1` | 带**预热 + 时钟检查**的测速脚本，读数口径见风险清单 6.4 |
| `使用说明.md` | llama.cpp 调参方法论（显存公式、定参四步法、思考模式） |
| `本地模型风险清单.md` | 26 条风险 + 分级 + 事故处理 Runbook |
| `tools/check-yaml.js` | DSH 配置校验器：能抓出非法字段名与 `reasoningEfforts` 类型错误 |
| `tools/validate-patch.py` | DSH 配置 YAML 校验（改配置前必跑） |

## 核心数据（RTX 5060 Laptop 8 GB 实测）

### Bonsai 2 9B（PQ2_0，2.25 GB）

| 上下文 | 峰值显存 | 生成速度 | 适合 |
|---|---:|---:|---|
| 32K | 3,424 MiB | 79 tok/s | 日常对话 + 工具调用 |
| 64K | 4,480 MiB | 81 tok/s | 长文档摘要 |
| **128K** | 6,592 MiB | 76 tok/s | 整本手册 / 大代码库 |
| 160K | 7,648 MiB | 82 tok/s | 极限档，余量仅 503 MiB |
| 192K+ | 7,828 MiB | **11.8 tok/s** | ❌ 名义能跑，实际不可用 |

### Bonsai 2 27B（PTQ1_0，5.54 GB）

| 上下文 | 峰值显存 | 生成速度 |
|---|---:|---:|
| 8K | 6,334 MiB | 50 tok/s |
| 16K | 6,854 MiB | 50 tok/s |
| 32K | 7,832 MiB | 50 tok/s（余量仅 319 MiB） |

> **读数口径**：上面两张表的 tok/s 是**未预热**读数，**属于偏低估计**——GPU 空闲时核心时钟只有
> ~210 MHz（上限 3090），模型刚加载完就计时会明显偏低。预热到时钟 92% 后重测 9B@128K 得
> **110.7 tok/s**（表内记的是 76）。**尚未系统性重测**，横向比较请只用同一批数据；
> 要自己标定就跑 `tools\bench-speed.ps1`（口径见风险清单 §6.4）。

### 中文事实性（同一道题：介绍杭州）

- **qwen3:8b**：✅ 全对，含"古称临安"
- **Bonsai 27B**：✅ 无硬伤
- **Bonsai 9B**：❌ 三处硬伤（"六朝古都"指杭州、苏轼"欲罢不能"、马云当"科技巨头"）

**结论：Bonsai 适合语言组织、代码、结构化输出；中文事实类内容用 qwen3 或人工核对。**

## 运行环境

| 项 | 要求 | 说明 |
|---|---|---|
| Shell | **PowerShell 7（`pwsh.exe`）** | 所有 `.ps1` 首行是 `#requires -Version 7.0`。用 Windows 自带的 PowerShell 5.1 运行会立即报 `ScriptRequiresUnmatchedPSVersion` 并退出——**那是版本守卫，不是脚本损坏** |
| 调用方式 | `pwsh -NoProfile -File .\llmctl.ps1 status` | 不要用 `powershell.exe -File`；双击 `.ps1` 默认是用记事本打开，不会执行 |
| 显卡驱动 | 支持你显卡的 CUDA 版本 | **不需要装 CUDA Toolkit**，运行时库随 llama.cpp 压缩包一起解压 |
| 系统 | Windows 10/11 x64 | 路径尽量不带中文：原生 exe 对非 ASCII 路径支持不稳（编码问题会伪装成"模型输出乱码"） |

## 快速开始

### 1. 准备环境

```powershell
# 1) 下载 PrismML 的 llama.cpp fork（必须用 fork，上游不支持 PTQ1_0）
#    https://github.com/PrismML-Eng/llama.cpp/releases
#    选 win-cuda-<你的版本>-x64.zip + 对应的 cudart 包，一起解压到 .\app

# 2) 下载模型（放 .\models 目录）
#    9B  : https://hf-mirror.com/prism-ml/Ternary-Bonsai-2-9B-gguf
#    27B : https://hf-mirror.com/prism-ml/Ternary-Bonsai-2-27B-gguf
#    9B 用 PQ2_0（2.42 GB）；27B 用 PTQ1_0（5.54 GB，PQ2_0 装不下）
```

### 2. 验证

```powershell
.\llmctl.ps1 status        # 应能看到三个模型
.\llmctl.ps1 tiers 9b      # 查看上下文档位表
.\probe-context.ps1        # 探测你这张卡的真实上限
```

### 3. 启动

```powershell
.\llmctl.ps1 start 9b              # 默认 128K
.\llmctl.ps1 start 27b -Ctx 32768  # 27B 必须 32K，否则 DSH 会截断
.\llmctl.ps1 stop                  # 释放显存
```

或双击 `launch-gui.vbs` 用图形界面。

## 接入 DSH

在 `~/.dsh/profiles/<profile>/cordis.patch.yml` 的 `llm-pi-ai.config.providers` 下添加：

```yaml
bonsai-9b:
  apiKeyEnv: OLLAMA_API_KEY      # 任意已配置的 key，llama-server 不校验
  api: openai-completions
  baseURL: http://127.0.0.1:8080/v1
  models:
    - id: bonsai-2-9b
      name: Bonsai 2 9B (三元, 128K)
      contextWindow: 131072
      maxTokens: 8192
      input:
        - text
```

**四个必须知道的约束**：

1. **DSH 固定 prompt 约 10.4K token**（system prompt + 工具定义），32K 上下文里只剩 21K 可用
2. **27B 用 16K 会被截断**：实测最后一条请求只生成 1 个 token，必须 32K
3. **27B 要配 `maxTokens: 12288`**：8192 时思考会吃光预算、正文为空。32K 下 `32768 − 12288 − 10400 ≈ 10080` 才是真正的对话空间，连续两轮重任务会越界
4. **`contextWindow` 必须 ≤ 服务端 `-c`**，否则 DSH 按错误值提前压缩

## 关键坑（避坑指南）

| 现象 | 原因 | 解决 |
|---|---|---|
| 输出乱码但无报错 | 引擎认得 Q2_0 但不认识 Bonsai 的 Hadamard 变换 | 用 PrismML fork，检查日志 `ftype` 行 |
| 速度掉到 <10 tok/s 但无报错 | 显存不足，静默降级到 CPU | 查日志 `offloaded X/Y`，X 必须等于 Y |
| 中文 prompt 乱码 | Windows 命令行编码 | 用 UTF-8 文件 + `-f` |
| 答案只有半句 / 正文为空 | 思考 token 吃掉了输出预算 | 服务端配 `--reasoning-budget`；或 `-n` 给 2048+ |
| 客户端发 `high`/`max` 报 HTTP 500 | 模板只认 `xhigh`/`medium`/`low`，其余 `raise_exception` | 加 `--reasoning-effort-allow` + `--reasoning-effort-fallback` |
| DSH 模型列表突然全空 | `reasoningEfforts` 写成了列表，或用了不存在的 `reasoningEffort` | 改成字典形式，改完先跑 `tools/check-yaml.js` |
| `invalid stoi argument` | PowerShell 里 `'a'+'b' -f x` 只格式化最后一段 | 改用双引号插值 |
| GUI 点按钮没反应 | `.GetNewClosure()` 会让 `$script:` 失效 | 用 `$sender.Tag` 定位 |
| `.vbs` 报"未结束的字符串常量" | wscript 按 ANSI 读取 UTF-8 中文 | 文件保持纯 ASCII，用 `Chr(34)` 拼引号 |

## 显存预算公式

```
可用上下文 ≈ (总显存 − 权重 − 线性注意力状态 − 计算缓冲 − 安全余量) / 每 token 开销
```

Bonsai 9B 实测：权重 2305 MiB，KV 约 32 MiB/1000 token，固定开销约 650 MiB。

## 思考控制（27B 的默认档是 `xhigh`）

模板里写死 `reasoning_effort|default('xhigh')`，且只接受 `xhigh`/`medium`/`low`。三处可调，粒度从小到大：

| 层 | 参数 | 本项目取值 |
|---|---|---|
| 输出总预算 | DSH `maxTokens` | 27B = `12288` |
| 思考上限 | `--reasoning-budget` | 27B = `6144` |
| 档位 | `--reasoning-effort` | 不设（=模板默认 `xhigh`） |

`models.json` 里对应三个可选字段：`reasoningBudget` / `reasoningEffortAllow` / `reasoningEffortFallback`，启动器会自动拼进命令行；字段缺失时行为与旧版一致。

**降档不等于缩短思考。** 同一道题 `temp=0` 实测：`low` 想了 3976 字符还答错，`xhigh` 只 2068 字符且答对。想省预算靠 `--reasoning-budget`，不靠调档位。

**关闭思考用 `none`，不是 `off`。** `off` 不在白名单里，会被回退成 `medium`。

## 许可证

- 工具脚本：MIT
- 模型：Apache 2.0（Bonsai 2 / Qwen 底座），分发前请自行确认底座条款
- **本仓库不含模型权重**，请按上面的链接自行下载

## 相关链接

- Bonsai 2 文档：<https://docs.prismml.com>
- PrismML llama.cpp：<https://github.com/PrismML-Eng/llama.cpp/releases>
- 上游合并版本：llama.cpp `b11556`
- DeepSeek Harness：<https://github.com/deepseek-ai/deepseek-harness>