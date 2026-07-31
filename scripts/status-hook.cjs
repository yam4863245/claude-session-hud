// 供 Claude Session HUD 讀取的 per-session 狀態寫入器。
//
// 由 ~/.claude/settings.json 的全域 hooks 呼叫，所以每個專案都會自動生效：
//   UserPromptSubmit          -> working   （開始跑）
//   PreToolUse[AskUserQuestion]  -> asking  （Claude 丟了選項要你選）
//   PostToolUse[AskUserQuestion] -> working （你選完了，繼續跑）
//   Notification              -> waiting   （等你授權等一般提示）
//   Stop                      -> done      （回合結束、還沒回頭看）
//   SessionEnd                -> gone      （刪掉狀態檔）
//
// asking 跟 waiting 分開是刻意的：waiting 多半按個同意就過了，
// asking 是真的要你判斷。HUD 對這兩者用不同顏色，asking 還會出聲。
//
// done 之後的 idle（閒置）不是由 hook 寫的：HUD 偵測到使用者把那個 session
// 切到前景時，才自己把狀態降級成 idle。這裡沒有對應的事件可以掛。
//
// 用法： node status-hook.cjs <working|asking|waiting|done|idle|gone>
// hook 的 JSON payload 由 stdin 進來，其中 session_id 對應
// `claude agents --json` 回傳的 sessionId。

const fs = require('fs');
const path = require('path');
const os = require('os');

const STATUS = process.argv[2] || 'idle';
const DIR = path.join(os.homedir(), '.claude', 'session-status');

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { raw += c; });
process.stdin.on('end', () => {
  let payload = {};
  try { payload = JSON.parse(raw || '{}'); } catch { /* 壞掉的 payload 就當沒發生 */ }

  const id = payload.session_id;
  // session_id 會被拿來組檔名，過濾掉非 UUID 字元避免路徑穿越
  if (!id || !/^[A-Za-z0-9-]+$/.test(id)) return;

  const file = path.join(DIR, id + '.json');
  try {
    if (STATUS === 'gone') {
      fs.rmSync(file, { force: true });
      return;
    }
    fs.mkdirSync(DIR, { recursive: true });
    fs.writeFileSync(file, JSON.stringify({
      status: STATUS,
      cwd: payload.cwd || '',
      ts: Date.now(),
    }));
  } catch { /* HUD 只是裝飾，寫不進去也不該影響 Claude 本身 */ }
});
