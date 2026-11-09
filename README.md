# Bonsai 2 本地运行环境（RTX 5060 Laptop 8GB）

## 已核实的环境

| 项 | 值 |
|---|---|
| llama.cpp 构建 | `prism-b12128-d7b2896`（PrismML fork） |
| 实际版本串 | `0.7.0-dev (build 12128, commit d7b289683)`，MSVC 19.44 |
| CUDA 构建 | win-cuda-13.3 + cudart 13.3 |
| 显卡 | CUDA0: NVIDIA GeForce RTX 5060 Laptop GPU, 8123 MiB (7043 MiB free) |
| 驱动 | 616.64 / CUDA UMD 13.4 |
| 安装路径 | `<项目根目录>\app\`（扁平目录，无 bin 子目录） |
| 模型目录 | `<项目根目录>\models\` |

**为什么必须是这个 fork**：上游 llama.cpp（b11556+）只认 `Q2_0`，27B 的 Q2_0 是 7.63 GB，8 GB 显存装不下。能塞进 8 GB 的 `PTQ1_0`（5.95 GB）只有 PrismML fork 支持。

已验证该构建内置的量化类型：

```
41  or  Q2_0    :  2.25 bpw quantization (group 64)
141 or  PQ2_0   :  2.13 bpw quantization (group 128, Prism)
143 or  PTQ1_0  :  1.75 bpw ternarization (group 128, Prism)
```

## 选包建议

| 模型 | 包 | 大小 | 8GB 可行性 |
|---|---|---|---|
| 9B | `PQ2_0` | 2.42 GB | 首选，Blackwell 上更快，余量大 |
| 9B | `PTQ1_0` | 2.00 GB | 更小，省 0.42 GB |
| 27B | `PTQ1_0` | 5.95 GB | 唯一可行，剩 ~2 GB 给 KV |
| 27B | `PQ2_0` | 7.21 GB | 装不下 |
| 27B | `Q2_0` | 7.63 GB | 装不下（且需上游 llama.cpp） |

注意：厂商吞吐表显示 Blackwell 上 `PQ2_0` 比 `PTQ1_0` 快约 8%（5090 上 129.9 vs 120.5 tok/s），但 27B 的 PQ2_0 超出 8GB，只能退而用 PTQ1_0。

## 常用命令

```powershell
$app = '<项目根目录>\app'
$m   = '<项目根目录>\models'

# 交互对话（9B，8K 上下文）
& "$app\llama-cli.exe" -m "$m\Ternary-Bonsai-2-9B-PQ2_0.gguf" -ngl 99 -fa on -c 8192 `
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 1.0

# 单次提问
& "$app\llama-cli.exe" -m "$m\Ternary-Bonsai-2-9B-PQ2_0.gguf" -ngl 99 -fa on -c 8192 `
  -n 2048 -p "用三句话解释什么是三元量化"

# OpenAI 兼容服务
& "$app\llama-server.exe" -m "$m\Ternary-Bonsai-2-9B-PQ2_0.gguf" -ngl 99 -fa on -c 8192 --port 8080
```

## 采样参数（官方给出，勿用默认）

- **Thinking 模式（默认）**：`temp=1.0, top_p=0.95, top_k=20, min_p=0, presence_penalty=1.0`
- **非思考模式**：`temp=0.7, top_p=0.80, top_k=20, min_p=0, presence_penalty=1.5`

两个坑：

1. **它是推理模型，默认会思考很久**。简单问题输出上限至少给 8192 token，否则会在思考中途被截断、拿不到答案。
2. **不要用 greedy 解码**（`temp=0`），思考模式下可能卡死在某个推理循环里。

## 显卡相关

- `-ngl 99` 全量卸载到 GPU；`-ngl 0` 纯 CPU 对照
- `-fa on` 开启 flash attention，官方命令都带
- 27B 若 OOM：把 `-c` 从 32768 降到 8192，或加 `--cache-type-k q8_0 --cache-type-v q8_0`

## 已知短板（来自官方逐项基准）

| 类别 | FP16 | Bonsai 2 27B | 变化 |
|---|---|---|---|
| 数学 | 97.06 | 96.57 | −0.5 |
| 代码 | 89.07 | 89.42 | +0.35 |
| 指令遵循 | 81.25 | 82.66 | +1.4 |
| 工具调用 | 76.74 | 74.92 | −1.8 |
| 知识推理 | 85.55 | 79.86 | −5.7 |
| 视觉 | 71.36 | 66.19 | −5.2 |

结论：数学/代码/指令遵循基本无损，百科知识与多模态下降明显。**全部基准为英文，中文能力无数据。**

## 实测结果（2026-11-07，9B PQ2_0）

| 测试 | ctx | 思考 | 生成 tok/s | 预填充 tok/s | 显存峰值 |
|---|---|---|---|---|---|
| 英文简单问答 | 4096 | on | **102.7** | 141.8 | 2610 MiB |
| 中文复杂题 | 16384 | on | 83.5 | 252.6 | 3006 MiB |
| 中文简单问答 | 8192 | off | 79.5 | 206.0 | 2742 MiB |

**显存换算**：KV cache 约 **32 MiB / 1000 token**（由 4K→16K 的 2610→3006 MiB 推算）。

- 32K 上下文 → 约 3.5 GB，宽裕
- 64K 上下文 → 约 4.5 GB，可行
- 128K → 约 6.6 GB，临界
- 27B PTQ1_0（5.67 GB）：8K → 6334 MiB ✅／16K → 6854 MiB ✅／32K → 7832 MiB ⚠️（余量仅 319 MiB）

**质量观察**：

- 英文推理链完整、条理清晰，无乱码 → 三元内核工作正常
- 中文**理解**准确（能正确解析中文指令和约束）
- 中文**表达**流畅自然
- 但**事实准确性有明显问题**：让它介绍杭州，出现了「北宋著名画家苏轼"欲罢不能"而留名后世」「诞生了阿里、马云等科技巨头」这类硬伤，与官方基准里「知识推理 −5.7 分」的短板吻合

**结论**：适合做语言组织、改写、代码、结构化输出；不适合当百科问答用，中文事实类内容需要核对。

**踩过的坑**：

- `-no-cnv` 在 b12128 已废弃，单轮用 `-st / --single-turn`
- `Start-Process -ArgumentList` 传数组时按空格拼接，含空格的 prompt 会被拆碎 → 整串传参并给 prompt 加引号，或改用 `-f prompt.txt`
- 中文 prompt 走命令行会乱码，**必须用 UTF-8 文件 + `-f`**
- 思考模式下 `-n 256` 会卡在思考中途，拿不到答案；至少给 2048+，或 `-rea off` 关掉思考

## 27B 实测（2026-11-07，PTQ1_0）

### 显存与速度

| 上下文 | 峰值显存 | 余量 | 状态 |
|---|---:|---:|---|
| 4K | 6170 MiB | 1981 MiB | ✅ |
| 8K | 6334 MiB | 1817 MiB | ✅ |
| 16K | 6854 MiB | 1297 MiB | ✅ |
| 32K | 7832 MiB | 319 MiB | ⚠️ 能跑，但没余量 |

**真实生成速度 50.7 tok/s**（8K 上下文、`-n 512` 长输出）。

> 注意：`probe-context.ps1` 用 `-n 16` 探测时只报 27 t/s，那是小样本假象——固定开销摊到 16 个 token 上把数字拖低了。**判断速度要看长输出。**

### 质量（与 9B 同一道中文题对比）

| | 9B | 27B |
|---|---|---|
| 杭州介绍 | ❌ 苏轼"欲罢不能"、马云当"科技巨头" | ✅ 省会/西湖/灵隐寺/雷峰塔，无硬伤 |
| 英文三句推理 | 停在第 4 步思考中 | ✅ 精确三句，Rayleigh 散射准确 |

**27B 的中文事实性明显优于 9B**，与官方基准「知识推理 −5.7 分」集中在小尺寸上的判断一致。

---

## 接入 DSH

### 配置（`~/.dsh/profiles/desktop/cordis.patch.yml`）

在 `llm-pi-ai.config.providers` 下有两个 provider，各占一组模型选择入口（与 `ollama` 并列，不混在一起）：

```yaml
bonsai-9b:   baseURL http://127.0.0.1:8080/v1   model bonsai-2-9b   ctx 32768
bonsai-27b:  baseURL http://127.0.0.1:8081/v1   model bonsai-2-27b  ctx 32768
```

`apiKeyEnv` 复用 `OLLAMA_API_KEY`（llama-server 不校验 Authorization）。

### 统一控制台 `llmctl.ps1`

三个旧脚本已合并为一个程序（旧脚本移到 `legacy\` 备查）。

```powershell
.\llmctl.ps1                      # 交互菜单
.\llmctl.ps1 status               # 状态表
.\llmctl.ps1 start 9b             # 启动（默认 32K）
.\llmctl.ps1 start 27b -Ctx 32768 # 指定上下文
.\llmctl.ps1 stop                 # 停止 llama（-All 连 Ollama 一起停）
.\llmctl.ps1 log 9b               # 打开日志
.\llmctl.ps1 ollama start|unload|stop|status
```

返回码：`0` 成功 / `1` 参数错 / `2` 端口冲突 / `3` 启动超时 / `4` 文件缺失 / `5` 已有模型在跑 / `6` 停止不彻底。

模型清单在 `models.json`（端口、上下文、显存预估），缺失时用内置默认。

安全设计：只绑 `127.0.0.1`、`--no-webui`、启动前检查端口与已有进程、按 PID 精确停止。

### 图形界面

```
双击 launch-gui.vbs        # 不弹控制台窗口
# 或
.\llmctl.ps1 gui
```

窗口内含：显存占用条、三张模型卡片（状态点 / PID / 端口 / 上下文下拉 / 显存）、启动-停止-日志按钮、自动刷新。

- 后台 runspace 每 1.5 秒采集一次（三个探针合计约 1.5s，放 UI 线程会卡）
- 启动/停止走命令队列，界面不阻塞
- 关闭窗口时若模型仍在运行，弹窗三选：停止并退出 / 保持运行并退出 / 取消
- 自检模式：`.\llmctl.ps1 gui -SelfTest`（构造窗口 → 跑 6 秒 → 截图 `gui-live-selftest.png` → 退出）

### 日常使用流程（GUI）

| 想用 | GUI 操作 | DSH 里选 |
|---|---|---|
| qwen3 | 看是否「服务在线」，否则点启动；用完可点「卸载模型」 | qwen3:8b (16K ctx) |
| Bonsai 9B | 点「启动」（保持 32K），等 3 秒变绿 | Bonsai 2 9B (三元, 32K) |
| Bonsai 27B | 先停 9B → 上下文选 **32K** → 点「启动」，等约 8 秒 | Bonsai 2 27B (三元, 32K) |

三条规则：

- **同一时刻只能跑一个 Bonsai**，切换要先停再启（GUI 不会自动切换）
- **27B 必须选 32K**，否则与 DSH 配置（`contextWindow: 32768`）不一致，会截断
- 从 qwen3 换到 Bonsai 前，先点「卸载模型」释放 6.1 GB

GUI 回归自检：`.\llmctl.ps1 gui -SelfTest -ClickTest`（结果写入 `logs\gui-selftest.txt`）

### 使用流程

```
① .\llmctl.ps1 start 9b   # 占 3.4GB 显存
② DSH 新建会话 → 选 Bonsai 2 9B → 权限只读起步
③ 对话 / 让它读文件调工具
④ .\llmctl.ps1 stop       # 释放显存
```

### 关键约束

| 约束 | 说明 |
|---|---|
| **同时只能跑一个模型** | 9B 3.5GB + 27B 7.8GB 超 8GB，必须先停再起 |
| **`contextWindow` 必须 ≤ 服务端 `-c`** | 否则 DSH 按配置提前压缩，多余上下文浪费 |
| **DSH 固定 prompt 约 10.4K** | system prompt + 工具定义；32K 里只剩 ~21K 给对话 |
| **27B 用 16K 会截断** | 实测最后一条请求只生成 1 个 token，DSH 报"输出上限"；换 32K 后正常 |
| **27B 要配 `maxTokens: 12288`** | 8192 时思考吃光预算、正文为空；32K 下 `32768 − 12288 − 10400 ≈ 10080` 才是真正的对话空间 |
| **服务与 DSH 独立** | 关 DSH 不会停服务（显存还占着）；停服务后选该模型会连接失败 |

### 实测：9B vs 27B（都在 DSH 里跑同一工具任务）

| | 9B @ 32K | 27B @ 32K |
|---|---|---|
| 首轮 prompt（10.4K） | **4.2s**（2,483 tok/s） | 15.7s（666 tok/s） |
| 生成速度 | **93 tok/s** | 40 tok/s |
| 显存占用 | **3,538 MiB** | 7,876 MiB |
| 完整工具交互 | ~12s | ~31s |
| 工具调用正确率 | 3/3 | 3/3 |

**结论：DSH 日常用 9B，27B 留给命令行做质量优先的短任务。**

---

## 实测发现的缺陷

| 问题 | 表现 | 影响 |
|---|---|---|
| **底座身份泄漏** | 9B 自称「Qwen3.5」、27B 自称「通义千问」 | 对话中误导，可用 system prompt 压制 |
| **9B 中文事实性弱** | 三次测试三处硬伤（苏轼、马云、"六朝古都"指杭州） | 事实类内容必须核对 |
| **空目录被漏报** | 两个模型都说"无子文件夹"，实际有 | **疑似 DSH 的 fs 工具未返回空目录**，非模型问题 |
| **16K 下截断** | 27B 在 DSH 里生成 1 个 token 就停 | 必须 32K |
| **思考吃光输出预算** | 27B 默认档为 `xhigh`，思考可占满整个 `maxTokens`，正文为空 | 上调 `maxTokens` 到 12288 + `--reasoning-budget 6144` |
| **非法档位触发 500** | `minimal`/`high`/`max` 让模板抛异常 | 配 `--reasoning-effort-allow` + `--reasoning-effort-fallback` |

## 上下文档位与思考控制

### 9B 上下文档位（实测）

| 档位 | 峰值显存 | DSH 内净剩 | 适合 |
|---|---:|---:|---|
| 8K | 2,800 MiB | — | 单轮问答（DSH 放不下系统提示） |
| 16K | 3,006 MiB | 5.6K | 短对话 |
| 32K | 3,424 MiB | 21K | 日常对话 + 工具调用 |
| 64K | 4,480 MiB | 53K | 长文档摘要、多文件阅读 |
| **128K** | 6,592 MiB | 117K | 整本手册 / 大代码库（**推荐上限**） |
| 160K | 7,648 MiB | 149K | 极限档，余量仅 503 MiB |

模型原生 262K，但 192K 以上实测速度从 82 掉到 12 tok/s（显存不足），不可用。

`.\llmctl.ps1 tiers 9b` 可随时查看此表；GUI 里切换档位时底部会显示该档用途。

### 思考控制（三层，从粗到细）

Bonsai 是推理模型，思考会占用输出预算。三处可调，粒度从小到大：

| 层 | 位置 | 作用 | 本项目取值 |
|---|---|---|---|
| 输出总预算 | DSH `maxTokens` | 思考 + 正文的总上限 | 27B = `12288` |
| 思考上限 | `--reasoning-budget N` | 思考最多花多少 token，超了自动收尾 | 27B = `6144` |
| 档位 | `--reasoning-effort LEVEL` | 模板内的思考指令 | 不设（=模板默认 `xhigh`） |

配置分散在两处：

```json
// models.json（服务端）
"reasoningBudget": 6144,
"reasoningEffortAllow": "none,low,medium,xhigh",
"reasoningEffortFallback": "medium"
```

启动后命令行会带上：

```
--reasoning-budget 6144 --reasoning-effort-allow none,low,medium,xhigh --reasoning-effort-fallback medium
```

#### 为什么必须有白名单

模板里写死了只接受三档：

```jinja
{%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
{%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
    {{- raise_exception('Unexpected reasoning effort ...') }}
```

客户端发 `minimal`/`high`/`max` 会让模板抛异常 → **HTTP 500**。白名单 + fallback 把非法档位换成 `medium`，实测 `high` 与 `medium` 输出逐字节相同。

关闭思考用 `none`（`off` 不在白名单里，会被回退成 `medium`）。

#### DSH 侧显式声明档位（可选，当前未启用）

`llm-pi-ai` 的模型字段名是 **`reasoningEfforts`（复数）**，值是**字典**，键取自 `off/minimal/low/medium/high/xhigh/max`，值是该档位真正发给服务的拼写：

```yaml
models:
  - id: bonsai-2-27b
    reasoningEfforts:
      off: none
      low: low
      medium: medium
      high: xhigh
```

⚠️ **写成列表会让整个 provider 加载失败**，DSH 的模型选择器直接变空：

```yaml
reasoningEfforts:      # ✗ schema 是 z.dict，不是数组
  - none
  - low
```

`reasoningEffort`（单数）**不是合法字段**，写了不生效。模型的合法字段只有 `id`/`name`/`contextWindow`/`maxTokens`/`input`/`reasoningEfforts`/`compat`。改完用 `tools/check-yaml.js` 校验后再重启 DSH。

另：`llm-pi-ai` 的 `thinkingFormat` 默认 `openai`，即 `reasoning_effort`，与 llama-server 天然一致，不需要额外 `compat`。

#### 27B 在 DSH 的实测（2026-11-09）

| 题 | completion | 思考 ≈ | 正文字符 | 结果 |
|---|---:|---:|---:|---|
| 计数推理（求 242） | 5560 | 5010 | 2129 | ✓ `finish=stop`，答案正确 |
| 代码缺陷分析 | 5347 | 700 | 11065 | ✓ `finish=stop` |

两道题都没碰到 6144 的思考上限，说明预算**不干扰正常推理**，只在病态长思考时才触发优雅收尾。

对话空间算式：`32768 − 12288(maxTokens) − 10400(DSH 固定开销) ≈ 10080`。一个重任务后余量约 2.6K，**连续两轮重任务会越过输入上限**。

## 相关链接

- 模型（27B）：<https://hf-mirror.com/prism-ml/Ternary-Bonsai-2-27B-gguf>
- 模型（9B）：<https://hf-mirror.com/prism-ml/Ternary-Bonsai-2-9B-gguf>
- 文档：<https://docs.prismml.com>
- 二进制来源：<https://github.com/PrismML-Eng/llama.cpp/releases>
- 上游合并 PR 对应版本：llama.cpp `b11556`（2026-10-11，"support for Prism Bonsai 2 27B"）



