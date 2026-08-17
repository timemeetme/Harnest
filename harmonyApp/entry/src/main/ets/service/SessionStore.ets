import { StorageService } from './StorageService';
import { hilog } from '@kit.PerformanceAnalysisKit';

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
  }

  get(id: string): SessionRecord | null {
    const list = this.loadAll();
    const found = list.find((s: SessionRecord) => s.id === id);
    return found !== undefined ? found : null;
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
