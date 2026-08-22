/**
 * WorkSchedulerExtAbility.ets — 后台定时任务扩展
 *
 * 当 WorkScheduler 注册的条件满足时（如循环间隔到达），系统在后台拉起此 Ability。
 * onWorkStart 中：
 *   1. 写触发信号到 filesDir/work_trigger.json（主进程前台时可检测）
 *   2. 发 reminder 通知提醒用户打开应用执行任务
 */
import WorkSchedulerExtensionAbility from '@ohos.WorkSchedulerExtensionAbility';
import workScheduler from '@ohos.resourceschedule.workScheduler';
import reminderAgentManager from '@ohos.reminderAgentManager';
import fs from '@ohos.file.fs';

const TAG = '[WorkSched]';

export default class WorkSchedulerExtAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    console.info(TAG, 'work started: id=' + work.workId);
    const taskDesc = work.parameters?.['task'] as string ?? 'scheduled task';
    const ctx = this.context;

    // 1. 写触发信号（主进程在前台时轮询检测）
    try {
      const triggerPath = ctx.filesDir + '/work_trigger.json';
      const trigger: Record<string, Object> = {};
      trigger['workId'] = work.workId;
      trigger['task'] = taskDesc;
      trigger['timestamp'] = Date.now();
      trigger['executed'] = false;
      writeTextFile(triggerPath, JSON.stringify(trigger));
      console.info(TAG, 'trigger signal written for work ' + work.workId);
    } catch (e) {
      console.error(TAG, 'write trigger failed: ' + (e as Error).message);
    }

    // 2. 发通知提醒用户
    try {
      const reminderReq: reminderAgentManager.ReminderRequestTimer = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
        triggerTimeInSeconds: 1,
        title: 'Harness 定时任务',
        content: taskDesc,
        wantAgent: {
          pkgName: ctx.applicationInfo.name,
          abilityName: 'EntryAbility',
        },
      };
      reminderAgentManager.publishReminder(reminderReq).then(() => {
        console.info(TAG, 'reminder published for work ' + work.workId);
      }).catch((e: Error) => {
        console.error(TAG, 'publish reminder failed: ' + e.message);
      });
    } catch (e) {
      console.error(TAG, 'reminder error: ' + (e as Error).message);
    }
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    console.info(TAG, 'work stopped: id=' + work.workId);
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
