import { StorageService } from './StorageService';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppConstants } from '../common/Constants';

const TAG = 'SessionStore';
const DOMAIN = 0x0303;

/** 持久化的消息（模型选择按消息粒度记录；role=tool 携带轨迹字段） */
export interface StoredMessage {
  id: string;
  role: string; // 'user' | 'assistant' | 'tool'
  content: string;
  createdAt: number;
  /** 该条消息使用的模型（assistant 消息记录实际应答模型） */
  provider?: string;
  model?: string;
  /** 工具消息：工具名 */
  toolName?: string;
  /** 工具消息状态：running | ok | error */
  toolStatus?: string;
  /** 工具结果预览 */
  toolResult?: string;
  /** todo_write 的整表快照 JSON */
  todosJson?: string;
  /** assistant 消息：本轮响应耗时（毫秒，0/缺省=未记录） */
  durationMs?: number;
  /** assistant 消息：执行轨迹 JSON（思考/工具/待办，空=无） */
  traceJson?: string;
  /** 错误/兜底文案消息（1=是；缺省=否 — 旧数据兼容） */
  isError?: number;
  /** assistant 消息：回合 token 用量（缺省=0 — 旧数据兼容） */
  inTok?: number;
  outTok?: number;
  /** k4：用户消息为 ⚡ 转向注入（1=是；缺省/0=否 — 旧数据兼容） */
  steered?: number;
  /** k6：消息评分 1 赞 / -1 踩 / 0 无（缺省=0 — 旧数据兼容） */
  rating?: number;
}

/** 持久化的会话（模型选择按对话粒度保存） */
export interface SessionRecord {
  id: string;
  title: string;
  provider: string;
  model: string;
  createdAt: number;
  updatedAt: number;
  messages: StoredMessage[];
  /** k1：思考强度（空串=跟随服务端默认；按会话保存；可选=旧数据兼容） */
  effort?: string;
}

interface SessionsFile {
  version: number;
  sessions: SessionRecord[];
}

/**
 * 会话存储（单例）：sessions.json 全量持久化。
 * 会话记录含 provider/model — 模型选择按对话粒度保存。
 */
export class SessionStore {
  private sessions: SessionRecord[] | null = null;
  private static instance: SessionStore | null = null;

  static get(): SessionStore {
    if (SessionStore.instance === null) {
      SessionStore.instance = new SessionStore();
    }
    return SessionStore.instance;
  }

  loadAll(): SessionRecord[] {
    if (this.sessions !== null) {
      return this.sessions;
    }
    const read = StorageService.get().readJson<SessionsFile>(StorageService.get().pathSessions());
    if (read !== null && Array.isArray(read.sessions)) {
      this.sessions = read.sessions;
    } else {
      this.sessions = [];
    }
    return this.sessions;
  }

  saveAll(): void {
    if (this.sessions === null) {
      return;
    }
    const data: SessionsFile = { version: 1, sessions: this.sessions };
    StorageService.get().writeJson(StorageService.get().pathSessions(), data);
  }

  upsert(record: SessionRecord): void {
    const list = this.loadAll();
    const idx = list.findIndex((s: SessionRecord) => s.id === record.id);
    if (idx >= 0) {
      list[idx] = record;
    } else {
      list.unshift(record);
    }
    this.saveAll();
  }

  delete(id: string): void {
    const list = this.loadAll();
    const idx = list.findIndex((s: SessionRecord) => s.id === id);
    if (idx >= 0) {
      list.splice(idx, 1);
      this.saveAll();
    }
    this.deleteLog(id);
  }

  get(id: string): SessionRecord | null {
    const list = this.loadAll();
    const found = list.find((s: SessionRecord) => s.id === id);
    return found !== undefined ? found : null;
  }

  // ── k3b 会话内事件日志（files/sessions/<id>.jsonl — fork 与内核重放的数据源） ──

  /** 日志文件路径（files/HarnessApp/sessions/<id>.jsonl） */
  logPath(sessionId: string): string {
    return StorageService.get().getBaseDir() + '/' + AppConstants.DIR_SESSIONS + '/' + sessionId + '.jsonl';
  }

  /**
   * 内核日志事件入口（LocalEngine log 路由到此）：
   * type='log' → 追加单条事件；type='log-reset' → 全量重写。
   * data 形状：{ type:'log', event:{...} } / { type:'log-reset', events:[...] }
   */
  onKernelLogEvent(sessionId: string, data: object): void {
    const o = data as Record<string, Object>;
    const type = (o['type'] ?? '') as string;
    if (type === 'log') {
      const ev = o['event'];
      if (ev !== undefined) {
        StorageService.get().appendText(this.logPath(sessionId), JSON.stringify(ev) + '\n');
      }
    } else if (type === 'log-reset') {
      const events = o['events'];
      if (events !== undefined) {
        const arr = events as Object[];
        const lines: string[] = [];
        for (const item of arr) {
          lines.push(JSON.stringify(item));
        }
        const text = lines.length > 0 ? lines.join('\n') + '\n' : '';
        StorageService.get().writeText(this.logPath(sessionId), text);
      }
    }
  }

  /** 读取种子事件流（进程重启后 createSession(seedJson=) 重放；无日志/空返回 null） */
  readSeedJson(sessionId: string): string | null {
    const text = StorageService.get().readText(this.logPath(sessionId));
    if (text.trim().length === 0) {
      return null;
    }
    return text;
  }

  /**
   * 截断日志到第 targetUserTurn 个用户回合结束（fork 语义）。
   * 结构计数：turn/start 深度 +1；turn/end 深度 -1 且归零 → 一个完整用户回合。
   * 未命中目标回合（日志不完整/不足）返回 null。
   */
  truncateLogAtUserTurn(sessionId: string, targetUserTurn: number): string | null {
    const text = StorageService.get().readText(this.logPath(sessionId));
    if (text.length === 0) {
      return null;
    }
    const kept: string[] = [];
    let depth = 0;
    let userTurns = 0;
    let done = false;
    const lines = text.split('\n');
    for (const raw of lines) {
      const line = raw.trim();
      if (line.length === 0) {
        continue;
      }
      let type = '';
      try {
        const ev = JSON.parse(line) as Record<string, Object>;
        type = (ev['type'] ?? '') as string;
      } catch (_e) {
        continue;
      }
      kept.push(line);
      if (type === 'turn/start') {
        depth++;
      } else if (type === 'turn/end') {
        depth--;
        if (depth === 0) {
          userTurns++;
          if (userTurns === targetUserTurn) {
            done = true;
            break;
          }
        }
      }
    }
    if (!done || kept.length === 0) {
      return null;
    }
    return kept.join('\n') + '\n';
  }

  /** 复制日志到新会话（fork 起点快照，覆盖写） */
  copyLogTo(fromId: string, toId: string): boolean {
    const seed = this.readSeedJson(fromId);
    if (seed === null) {
      return false;
    }
    return StorageService.get().writeText(this.logPath(toId), seed);
  }

  /** 写入指定种子文本到会话日志（fork 截断快照落盘） */
  writeSeedText(sessionId: string, text: string): boolean {
    return StorageService.get().writeText(this.logPath(sessionId), text);
  }

  /** 删除会话日志（随会话删除） */
  deleteLog(sessionId: string): void {
    StorageService.get().deleteFile(this.logPath(sessionId));
  }

  /** 引擎侧会话恢复（进程重启后 createSession 传同一 sessionId） */
  static newId(): string {
    return 'session-' + Date.now() + '-' + Math.floor(Math.random() * 1e9).toString(36);
  }

  static titleFrom(text: string): string {
    const t = text.trim().replace(/\s+/g, ' ');
    return t.length > 24 ? t.substring(0, 24) : (t.length > 0 ? t : '新会话');
  }
}

hilog.debug(DOMAIN, TAG, 'SessionStore loaded');
