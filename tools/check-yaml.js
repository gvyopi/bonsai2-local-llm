// llm-pi-ai 配置校验器：对照 DSH 内置 schema 检查 models 字段
// 依据 app.asar 中的 modelFields = { name, contextWindow, maxTokens, input, reasoningEfforts, compat }
//
// 用法：node tools/check-yaml.js [配置文件路径]
//   省略路径时默认读 %USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml
const fs = require('fs');
const os = require('os');
const path = require('path');

const PATCH = process.argv[2] ||
    path.join(os.homedir(), '.dsh', 'profiles', 'desktop', 'cordis.patch.yml');

// DSH 源码：const THINKING_LEVELS = Object.keys({ off, minimal, low, medium, high, xhigh, max })
const THINKING_LEVELS = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
const MODEL_FIELDS = ['id', 'name', 'contextWindow', 'maxTokens', 'input', 'reasoningEfforts', 'compat'];
const MODALITIES = ['text', 'image'];

let raw;
try {
    raw = fs.readFileSync(PATCH, 'utf8');
} catch (e) {
    console.error(`读不到配置文件: ${PATCH}`);
    console.error(`原因: ${e.code || e.message}`);
    console.error('用法: node tools/check-yaml.js [配置文件路径]');
    process.exit(2);
}
const lines = raw.split(/\r?\n/);

const errors = [];
const warnings = [];

// ---------- 通用结构校验 ----------
const blockKeys = new Map();
const stack = [{ indent: -1, id: 'root' }];
let listCounter = 0;

function findParent(indent) {
  while (stack.length > 1 && stack[stack.length - 1].indent >= indent) stack.pop();
  return stack[stack.length - 1];
}

for (let i = 0; i < lines.length; i++) {
  const line = lines[i], ln = i + 1;
  if (/^\s*$/.test(line) || /^\s*#/.test(line)) continue;
  if (line.includes('\t')) errors.push(`L${ln}: 含 TAB`);
  const indent = line.match(/^ */)[0].length;
  const t = line.trim();
  const parent = findParent(indent);

  if (t === '-' || t.startsWith('- ')) {
    const rest = t.slice(1).trim();
    if (rest.includes(':')) {
      const id = `${parent.id}/[${listCounter++}]`;
      stack.push({ indent, id });
      blockKeys.set(id, new Set());
      const km = rest.match(/^([A-Za-z0-9_\-.]+):/);
      if (km) blockKeys.get(id).add(km[1]);
    }
    continue;
  }

  const m = t.match(/^([A-Za-z0-9_\-".\/]+):(\s*)(.*)$/);
  if (!m) { errors.push(`L${ln}: 无法识别 -> ${t.slice(0, 50)}`); continue; }
  const key = m[1];
  const hasVal = m[3].trim().length > 0;

  if (!blockKeys.has(parent.id)) blockKeys.set(parent.id, new Set());
  const s = blockKeys.get(parent.id);
  if (s.has(key)) errors.push(`L${ln}: 重复键 '${key}'`);
  s.add(key);

  if (!hasVal) {
    const childId = `${parent.id}/${key}`;
    stack.push({ indent, id: childId });
    blockKeys.set(childId, new Set());
  }
}

// ---------- 解析出 llm-pi-ai 的 models 块（基于缩进的轻量解析） ----------
function parseModelBlocks() {
  const out = []; // { provider, id, fields: {name: [ln, value]}, lineStart }
  let curProvider = null, curModel = null;

  for (let i = 0; i < lines.length; i++) {
    const ln = i + 1;
    const line = lines[i];
    if (/^\s*#/.test(line) || /^\s*$/.test(line)) continue;
    const indent = line.match(/^ */)[0].length;
    const t = line.trim();

    // provider 名：6 空格 + xxx:
    if (indent === 6 && /^[A-Za-z0-9_\-]+:\s*$/.test(t)) {
      curProvider = t.slice(0, -1);
      curModel = null;
      continue;
    }
    // models: 之后
    if (indent === 8 && t === 'models:') continue;

    // 模型列表项：10 空格 + "- id: xxx"
    const mm = t.match(/^- id:\s*(.+)$/);
    if (mm && indent === 10) {
      curModel = { provider: curProvider, id: mm[1].trim(), fields: {}, lineStart: ln };
      out.push(curModel);
      continue;
    }
    // 模型字段：12 空格
    if (curModel && indent === 12) {
      const fm = t.match(/^([A-Za-z_]+):(\s*)(.*)$/);
      if (fm) curModel.fields[fm[1]] = { ln, value: fm[3].trim(), hasVal: fm[3].trim().length > 0 };
      continue;
    }
  }
  return out;
}

const models = parseModelBlocks();

// ---------- 字段白名单校验 ----------
for (const mo of models) {
  for (const [k, v] of Object.entries(mo.fields)) {
    if (!MODEL_FIELDS.includes(k)) {
      errors.push(`L${v.ln}: ${mo.provider}/${mo.id} 出现非法字段 '${k}'（允许: ${MODEL_FIELDS.join(', ')}）`);
    }
  }
  // maxTokens / contextWindow 必须是正整数
  for (const nk of ['maxTokens', 'contextWindow']) {
    if (mo.fields[nk]) {
      const val = mo.fields[nk].value;
      if (!/^\d+$/.test(val)) errors.push(`L${mo.fields[nk].ln}: ${mo.provider}/${mo.id} ${nk} 不是整数: ${val}`);
      else if (Number(val) < 1) errors.push(`L${mo.fields[nk].ln}: ${mo.provider}/${mo.id} ${nk} 小于 1`);
    }
  }
  // reasoningEfforts 必须是 dict 或 false —— 列表是常见错误
  if (mo.fields['reasoningEfforts']) {
    const rl = mo.fields['reasoningEfforts'].ln;
    const nextLine = lines[rl] ? lines[rl].trim() : ''; // 下一行（0-based = ln）
    if (/^-\s/.test(nextLine)) {
      errors.push(`L${rl}: ${mo.provider}/${mo.id} reasoningEfforts 写成了列表；schema 要求字典 { 档位: 协议值 } 或 false`);
    } else if (mo.fields['reasoningEfforts'].value && mo.fields['reasoningEfforts'].value !== 'false') {
      errors.push(`L${rl}: ${mo.provider}/${mo.id} reasoningEfforts 标量值只能是 false`);
    }
  }
  for (const md of Object.keys(mo.fields)) {
    if (md === 'input') continue;
  }
}

// ---------- 结果 ----------
console.log('=== 结构校验 ===');
if (!errors.length) console.log('✓ 无 TAB / 缩进合法 / 无重复键 / 字段均合法');
else errors.forEach(e => console.log('✗ ' + e));

console.log('\n=== 解析到的模型 ===');
for (const mo of models) {
  const mt = mo.fields.maxTokens ? mo.fields.maxTokens.value : '-';
  const cx = mo.fields.contextWindow ? mo.fields.contextWindow.value : '-';
  const rf = mo.fields.reasoningEfforts ? 'reasoningEfforts已声明' : '无reasoning';
  console.log(`  ${mo.provider.padEnd(22)} ${mo.id.padEnd(28)} ctx=${cx.padEnd(8)} max=${mt.padEnd(6)} ${rf}`);
}
console.log(`\n共 ${models.length} 个模型`);