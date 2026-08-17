import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppConstants } from '../common/Constants';

const TAG = 'StorageService';
const DOMAIN = 0x0301;

/**
 * 本地存储服务（单例，EMM 式）。
 * 数据写入应用沙箱 filesDir 下 HarnessApp 目录。
 */
export class StorageService {
  private baseDir: string = '';
  private static instance: StorageService | null = null;

  static get(): StorageService {
    if (StorageService.instance === null) {
      StorageService.instance = new StorageService();
    }
    return StorageService.instance;
  }

  /** 由 EntryAbility 启动时调用 */
  init(filesDir: string): void {
    this.baseDir = filesDir + '/' + AppConstants.APP_DIR;
    this.ensureDir(this.baseDir);
    this.ensureDir(this.baseDir + '/' + AppConstants.DIR_SESSIONS);
    hilog.info(DOMAIN, TAG, 'storage baseDir=%{public}s', this.baseDir);
  }

  getBaseDir(): string {
    return this.baseDir;
  }

  ensureDir(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        return;
      }
    } catch (_e) {
      // 不存在则继续创建
    }
    const segs: string[] = path.replace(/\\+/g, '/').split('/').filter((s: string) => s.length > 0);
    let cur = path.startsWith('/') ? '/' : '';
    for (const seg of segs) {
      cur = cur.length > 0 ? cur + '/' + seg : seg;
      try {
        if (!fileIo.accessSync(cur)) {
          fileIo.mkdirSync(cur);
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'mkdir fail %{public}s err=%{public}s', cur, JSON.stringify(e));
      }
    }
  }

  writeText(path: string, text: string): boolean {
    try {
      const idx = path.lastIndexOf('/');
      if (idx > 0) {
        this.ensureDir(path.substring(0, idx));
      }
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'writeText fail %{public}s err=%{public}s', path, JSON.stringify(e));
      return false;
    }
  }

  readText(path: string): string {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const st = fileIo.statSync(path);
      const buf = new ArrayBuffer(st.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeWithStream(new Uint8Array(buf));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'readText fail %{public}s err=%{public}s', path, JSON.stringify(e));
      return '';
    }
  }

  readJson<T>(path: string): T | null {
    const txt = this.readText(path);
    if (txt.length === 0) {
      return null;
    }
    try {
      return JSON.parse(txt) as T;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'json parse fail %{public}s err=%{public}s', path, JSON.stringify(e));
      return null;
    }
  }

  writeJson(path: string, obj: Object): boolean {
    return this.writeText(path, JSON.stringify(obj, null, 2));
  }

  exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_e) {
      return false;
    }
  }

  deleteFile(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'delete fail %{public}s err=%{public}s', path, JSON.stringify(e));
    }
  }

  /** 核心文件路径 */
  pathApiConfig(): string {
    return this.baseDir + '/' + AppConstants.FILE_API_CONFIG;
  }

  pathSessions(): string {
    return this.baseDir + '/' + AppConstants.FILE_SESSIONS;
  }

  pathPrefs(): string {
    return this.baseDir + '/' + AppConstants.FILE_PREFS;
  }
}
