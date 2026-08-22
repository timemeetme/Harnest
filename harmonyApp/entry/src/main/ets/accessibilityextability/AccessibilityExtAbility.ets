/**
 * AccessibilityExtAbility.ets — GUI 自动化无障碍扩展
 *
 * 用户在系统设置中开启本应用的无障碍服务后，此 Ability 在独立进程常驻。
 * 与主进程通信：命令文件轮询（filesDir/gui_cmd.json → filesDir/gui_result.json）
 *
 * 支持的命令（cmd）：
 *   tree   — 读取当前屏幕 UI 树（窗口列表 + 元素属性，深度限制）
 *   find   — 按文本查找元素 { text }
 *   click  — 点击 { x, y } 坐标，或 { text } 查找后点击
 *   swipe  — 滑动 { startX, startY, endX, endY, duration }
 *   input  — 向焦点输入框注入文本 { text }（通过剪贴板 + performAction paste）
 *   back   — 全局返回键
 *   home   — 全局 Home 键
 */
import AccessibilityExtensionAbility, {
  AccessibilityElement,
  AccessibilityEvent,
  AccessibilityExtensionContext,
  Rect
} from '@ohos.application.AccessibilityExtensionAbility';
import { GesturePath } from '@ohos.accessibility.GesturePath';
import { GesturePoint } from '@ohos.accessibility.GesturePoint';
import fs from '@ohos.file.fs';

const TAG = '[GuiExt]';
const CMD_FILE = '/gui_cmd.json';
const RESULT_FILE = '/gui_result.json';
const POLL_MS = 500;
const TREE_MAX_DEPTH = 8;
const TREE_MAX_ELEMENTS = 200;

interface GuiCommand {
  id: number;
  cmd: string;
  args: Record<string, string | number | boolean>;
}

interface GuiResult {
  id: number;
  ok: boolean;
  data?: string;
  error?: string;
}

interface SerializedElement {
  element: Record<string, Object>;
  count: number;
}

export default class AccessibilityExtAbility extends AccessibilityExtensionAbility {
  private pollTimer: number = -1;
  private lastCmdId: number = -1;

  onConnect(): void {
    console.info(TAG, 'accessibility service connected');
    this.startPolling();
  }

  onDisconnect(): void {
    console.info(TAG, 'accessibility service disconnected');
    this.stopPolling();
  }

  onAccessibilityEvent(event: AccessibilityEvent): void {
    // 事件流可用于响应式自动化（如监听到特定页面后自动操作），当前仅记录
    const _ = event.eventType;
  }

  onKeyEvent(): boolean {
    return false; // 不拦截物理按键
  }

  // ── 命令轮询 ──────────────────────────────────────────────

  private startPolling(): void {
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval(() => {
      this.checkCommand();
    }, POLL_MS);
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private checkCommand(): void {
    try {
      const cmdPath = this.context.filesDir + CMD_FILE;
      if (!fs.accessSync(cmdPath)) {
        return;
      }
      const raw = fs.readTextSync(cmdPath);
      const cmd = JSON.parse(raw) as GuiCommand;
      if (cmd.id <= this.lastCmdId) {
        return; // 已执行过
      }
      console.info(TAG, 'executing cmd #' + cmd.id + ': ' + cmd.cmd);
      this.lastCmdId = cmd.id;
      fs.unlinkSync(cmdPath); // 删除命令文件防重入

      this.executeCommand(cmd).then((result) => {
        this.writeResult(result);
      }).catch((e: Error) => {
        const r: GuiResult = { id: cmd.id, ok: false, error: e.message };
        this.writeResult(r);
      });
    } catch (e) {
      // 文件读取/解析失败静默忽略，等下一轮
    }
  }

  private writeResult(result: GuiResult): void {
    try {
      const resPath = this.context.filesDir + RESULT_FILE;
      writeTextFile(resPath, JSON.stringify(result));
    } catch (e) {
      console.error(TAG, 'write result failed: ' + (e as Error).message);
    }
  }

  // ── 命令执行 ──────────────────────────────────────────────

  private async executeCommand(cmd: GuiCommand): Promise<GuiResult> {
    const ctx = this.context as AccessibilityExtensionContext;
    switch (cmd.cmd) {
      case 'tree':
        return { id: cmd.id, ok: true, data: JSON.stringify(await this.getUiTree(ctx)) };
      case 'find':
        return this.cmdFind(ctx, cmd);
      case 'click':
        return this.cmdClick(ctx, cmd);
      case 'swipe':
        return this.cmdSwipe(ctx, cmd);
      case 'back':
        return this.cmdGlobalAction(ctx, cmd, 'back');
      case 'home':
        return this.cmdGlobalAction(ctx, cmd, 'home');
      case 'recent':
        return this.cmdGlobalAction(ctx, cmd, 'recent');
      case 'notifications':
        return this.cmdGlobalAction(ctx, cmd, 'notifications');
      case 'input':
        return this.cmdInput(ctx, cmd);
      default:
        return { id: cmd.id, ok: false, error: 'unknown cmd: ' + cmd.cmd };
    }
  }

  // ── UI 树读取 ────────────────────────────────────────────

  private async getUiTree(ctx: AccessibilityExtensionContext): Promise<Record<string, Object>> {
    const windows = await ctx.getWindows();
    const tree: Array<Record<string, Object>> = [];
    let count = 0;
    for (const win of windows) {
      if (count >= TREE_MAX_ELEMENTS) {
        break;
      }
      const node = await this.serializeElement(win, 0);
      count = node.count;
      tree.push(node.element);
    }
    const out: Record<string, Object> = {};
    out['windows'] = tree;
    out['windowCount'] = windows.length;
    out['elementCount'] = count;
    return out;
  }

  private async serializeElement(
    el: AccessibilityElement, depth: number
  ): Promise<SerializedElement> {
    let count = 1;
    const node: Record<string, Object> = {};
    try {
      node['type'] = await el.attributeValue('componentType').catch(() => '');
      node['text'] = await el.attributeValue('text').catch(() => '');
      node['desc'] = await el.attributeValue('description').catch(() => '');
      node['bundle'] = await el.attributeValue('bundleName').catch(() => '');
      node['clickable'] = await el.attributeValue('clickable').catch(() => false);
      node['editable'] = await el.attributeValue('editable').catch(() => false);
      node['scrollable'] = await el.attributeValue('scrollable').catch(() => false);
      const rect = await el.attributeValue('screenRect').catch(() => null) as Rect | null;
      if (rect !== null) {
        node['rect'] = makeRectObj(rect);
      }
      if (depth < TREE_MAX_DEPTH && count < TREE_MAX_ELEMENTS) {
        const children = await el.attributeValue('children').catch(() => [] as AccessibilityElement[]);
        if (children && children.length > 0) {
          const childNodes: Array<Record<string, Object>> = [];
          for (const child of children) {
            if (count >= TREE_MAX_ELEMENTS) {
              break;
            }
            const sub = await this.serializeElement(child, depth + 1);
            count += sub.count;
            childNodes.push(sub.element);
          }
          if (childNodes.length > 0) {
            node['children'] = childNodes;
          }
        }
      }
    } catch (e) {
      node['error'] = (e as Error).message;
    }
    const result: SerializedElement = { element: node, count: count };
    return result;
  }

  // ── find / click / swipe / input / 全局动作 ───────────────

  private async cmdFind(
    ctx: AccessibilityExtensionContext, cmd: GuiCommand
  ): Promise<GuiResult> {
    const text = String(cmd.args['text'] ?? '');
    if (!text) {
      return { id: cmd.id, ok: false, error: 'find requires text' };
    }
    const windows = await ctx.getWindows();
    const matches: Array<Record<string, Object>> = [];
    for (const win of windows) {
      const found = await this.findByText(win, text, 0);
      matches.push(...found);
      if (matches.length >= 20) {
        break;
      }
    }
    const out: Record<string, Object> = {};
    out['matches'] = matches;
    out['count'] = matches.length;
    return { id: cmd.id, ok: true, data: JSON.stringify(out) };
  }

  private async findByText(
    el: AccessibilityElement, text: string, depth: number
  ): Promise<Array<Record<string, Object>>> {
    const results: Array<Record<string, Object>> = [];
    if (depth > TREE_MAX_DEPTH) {
      return results;
    }
    try {
      const elText = String(await el.attributeValue('text').catch(() => ''));
      const elDesc = String(await el.attributeValue('description').catch(() => ''));
      if (elText.includes(text) || elDesc.includes(text)) {
        const node: Record<string, Object> = {};
        node['type'] = await el.attributeValue('componentType').catch(() => '');
        node['text'] = elText;
        node['desc'] = elDesc;
        node['clickable'] = await el.attributeValue('clickable').catch(() => false);
        const rect = await el.attributeValue('screenRect').catch(() => null) as Rect | null;
        if (rect !== null) {
          node['rect'] = makeRectObj(rect);
          node['centerX'] = rect.left + rect.width / 2;
          node['centerY'] = rect.top + rect.height / 2;
        }
        results.push(node);
      }
      const children = await el.attributeValue('children').catch(() => [] as AccessibilityElement[]);
      if (children) {
        for (const child of children) {
          const sub = await this.findByText(child, text, depth + 1);
          results.push(...sub);
        }
      }
    } catch (e) {
      // skip
    }
    return results;
  }

  private async cmdClick(
    ctx: AccessibilityExtensionContext, cmd: GuiCommand
  ): Promise<GuiResult> {
    const text = String(cmd.args['text'] ?? '');
    let x = Number(cmd.args['x'] ?? -1);
    let y = Number(cmd.args['y'] ?? -1);

    // 如果给了 text 而非坐标，先查找元素
    if (text && (x < 0 || y < 0)) {
      const windows = await ctx.getWindows();
      for (const win of windows) {
        const found = await this.findByText(win, text, 0);
        if (found.length > 0) {
          const first = found[0] as Record<string, Object>;
          x = Number(first['centerX'] ?? -1);
          y = Number(first['centerY'] ?? -1);
          break;
        }
      }
      if (x < 0) {
        return { id: cmd.id, ok: false, error: 'element not found: ' + text };
      }
    }
    if (x < 0 || y < 0) {
      return { id: cmd.id, ok: false, error: 'click requires x,y or text' };
    }

    try {
      const path = new GesturePath(200);
      const point = new GesturePoint(x, y);
      path.points = [point];
      ctx.injectGestureSync(path);
      const out: Record<string, Object> = {};
      out['clicked'] = true;
      out['x'] = x;
      out['y'] = y;
      return { id: cmd.id, ok: true, data: JSON.stringify(out) };
    } catch (e) {
      return { id: cmd.id, ok: false, error: 'injectGesture failed: ' + (e as Error).message };
    }
  }

  private async cmdSwipe(
    ctx: AccessibilityExtensionContext, cmd: GuiCommand
  ): Promise<GuiResult> {
    const startX = Number(cmd.args['startX'] ?? -1);
    const startY = Number(cmd.args['startY'] ?? -1);
    const endX = Number(cmd.args['endX'] ?? -1);
    const endY = Number(cmd.args['endY'] ?? -1);
    const duration = Number(cmd.args['duration'] ?? 300);
    if (startX < 0 || startY < 0 || endX < 0 || endY < 0) {
      return { id: cmd.id, ok: false, error: 'swipe requires startX,startY,endX,endY' };
    }
    try {
      const steps = 10;
      const points: GesturePoint[] = [];
      for (let i = 0; i <= steps; i++) {
        const t = i / steps;
        points.push(new GesturePoint(
          startX + (endX - startX) * t,
          startY + (endY - startY) * t
        ));
      }
      const path = new GesturePath(duration);
      path.points = points;
      ctx.injectGestureSync(path);
      const out: Record<string, Object> = {};
      out['swiped'] = true;
      return { id: cmd.id, ok: true, data: JSON.stringify(out) };
    } catch (e) {
      return { id: cmd.id, ok: false, error: 'swipe failed: ' + (e as Error).message };
    }
  }

  private async cmdGlobalAction(
    ctx: AccessibilityExtensionContext, cmd: GuiCommand, action: string
  ): Promise<GuiResult> {
    // 全局动作通过 focus element 的 performAction 或直接模拟手势实现
    // HarmonyOS API 12 无 executeGlobalAction，用返回键手势模拟 back
    if (action === 'back') {
      // 从屏幕右缘向左滑（返回手势）
      try {
        const path = new GesturePath(150);
        path.points = [
          new GesturePoint(1080, 500),
          new GesturePoint(900, 500),
          new GesturePoint(800, 500)
        ];
        ctx.injectGestureSync(path);
        return { id: cmd.id, ok: true, data: '{"action":"back"}' };
      } catch (e) {
        return { id: cmd.id, ok: false, error: 'back failed: ' + (e as Error).message };
      }
    }
    if (action === 'home') {
      // 从底部上滑（Home 手势）
      try {
        const path = new GesturePath(200);
        path.points = [
          new GesturePoint(540, 2200),
          new GesturePoint(540, 1500),
          new GesturePoint(540, 800)
        ];
        ctx.injectGestureSync(path);
        return { id: cmd.id, ok: true, data: '{"action":"home"}' };
      } catch (e) {
        return { id: cmd.id, ok: false, error: 'home failed: ' + (e as Error).message };
      }
    }
    return { id: cmd.id, ok: false, error: 'global action not supported: ' + action };
  }

  private async cmdInput(
    ctx: AccessibilityExtensionContext, cmd: GuiCommand
  ): Promise<GuiResult> {
    const text = String(cmd.args['text'] ?? '');
    if (!text) {
      return { id: cmd.id, ok: false, error: 'input requires text' };
    }
    // 通过查找可编辑元素并 performAction 输入
    try {
      const windows = await ctx.getWindows();
      for (const win of windows) {
        const editable = await this.findEditable(win, 0);
        if (editable) {
          await editable.performAction('setText', { 'text': text });
          const out: Record<string, Object> = {};
          out['input'] = true;
          out['text'] = text;
          return { id: cmd.id, ok: true, data: JSON.stringify(out) };
        }
      }
      return { id: cmd.id, ok: false, error: 'no editable element found on screen' };
    } catch (e) {
      return { id: cmd.id, ok: false, error: 'input failed: ' + (e as Error).message };
    }
  }

  private async findEditable(
    el: AccessibilityElement, depth: number
  ): Promise<AccessibilityElement | null> {
    if (depth > TREE_MAX_DEPTH) {
      return null;
    }
    try {
      const editable = await el.attributeValue('editable').catch(() => false);
      if (editable) {
        return el;
      }
      const children = await el.attributeValue('children').catch(() => [] as AccessibilityElement[]);
      if (children) {
        for (const child of children) {
          const found = await this.findEditable(child, depth + 1);
          if (found) {
            return found;
          }
        }
      }
    } catch (e) {
      // skip
    }
    return null;
  }
}

function writeTextFile(path: string, content: string): void {
  const fd = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
  try {
    fs.writeSync(fd.fd, content);
  } finally {
    fs.closeSync(fd);
  }
}

function makeRectObj(r: Rect): Record<string, number> {
  const obj: Record<string, number> = {};
  obj['left'] = r.left;
  obj['top'] = r.top;
  obj['width'] = r.width;
  obj['height'] = r.height;
  return obj;
}
