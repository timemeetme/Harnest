/**
 * capability-manual.ts — 设备能力手册（P0 版）
 *
 * 设计决策（已拍板）：P0 先行 / 仅随包内置 / 索引+按需查询 / Top 20 人工维护。
 * 本模块随 harness.js 一同打进三端（Android/HarmonyOS/iOS），无网络依赖。
 *
 * 章节分两类：
 *  - 系统能力：harness 设备工具（device_*）能直接完成的事，含参数与示例；
 *  - 三方应用（Top 20 人工维护）：安装后经「拉起 + 深链 + GUI 自动化」组合可完成的任务。
 *
 * 检索：searchSections 按关键词命中计分（keywords/title/summary/entries 全文，中英文皆可）。
 */

export interface ManualEntry {
  /** 能力名（人类可读） */
  name: string
  /** 精确调用方式：工具名 + 参数 */
  how: string
  /** 自然语言任务示例 */
  example?: string
  /** 限制/权限说明 */
  limits?: string
}

export interface ManualSection {
  /** 唯一 id，供 drill-down 查询（如 "camera", "apps.wechat"） */
  id: string
  /** 适用平台；'all' 表示三端行为一致（差异写在 entries.limits 里） */
  platform: 'all' | 'android' | 'harmony' | 'ios'
  /** 分类：system / media / communication / automation / apps */
  category: 'system' | 'media' | 'communication' | 'automation' | 'apps'
  title: string
  summary: string
  /** 系统版本范围（可选） */
  osRange?: string
  /** 三方应用标识（apps 类章节用）：包名/bundleId，供 device_probe 匹配已装应用 */
  appId?: { android?: string; harmony?: string; ios?: string }
  entries: ManualEntry[]
  /** 检索关键词（含中文） */
  keywords: string[]
}

// ── 系统能力章节 ─────────────────────────────────────────────

const CAMERA: ManualSection = {
  id: 'camera',
  platform: 'all',
  category: 'media',
  title: '相机拍摄（前置/后置切换、静默连拍、手动取景）',
  summary: 'device_camera 可直接指定前后摄像头拍照，无需打开相机 App；拍完的照片自动作为视觉输入附给模型（下一轮即可识别内容）。',
  entries: [
    {
      name: '后置摄像头自动拍照',
      how: 'device_camera(op:"capture")（facing 默认 back）',
      example: '"帮我拍一下桌上的文件"',
    },
    {
      name: '前置摄像头自拍',
      how: "device_camera(op:\"capture\", facing:\"front\")",
      example: '"切换到前置摄像头拍张照并识别一下我手里拿的是什么"',
      limits: '无需 GUI 操作相机 App，直接调用即可；这是处理"自拍/前置"类任务的首选方式。',
    },
    {
      name: '手动取景拍摄',
      how: 'device_camera(op:"manual")',
      example: '"打开相机，我自己按快门"',
      limits: '会拉起系统相机界面等待用户按快门（最长 120s）；仅在用户明确要自己拍摄时使用。',
    },
    {
      name: '照片内容识别',
      how: '拍照（capture/manual）成功后直接回答即可——照片已自动附给模型；不需要额外下载/读文件步骤。',
      example: '"拍张照看看这是什么植物"',
    },
  ],
  keywords: ['camera', 'photo', '拍照', '照相', '自拍', '前置', '后置', '摄像头', '切换摄像头', 'photo', 'selfie', 'front', '识别', 'vision', '看'],
}

const GUI_AUTOMATION: ManualSection = {
  id: 'gui-automation',
  platform: 'android',
  category: 'automation',
  title: 'GUI 自动化（读屏/点击/滑动/输入）',
  summary: 'Android 无障碍服务可读取屏幕控件树、按文本找元素、点击/滑动/输入。三方 App 没有开放接口时，用 GUI 自动化是通用兜底。',
  osRange: 'Android 7.0+（需在系统设置 > 无障碍中启用本应用服务）',
  entries: [
    {
      name: '读取当前屏幕',
      how: 'device_gui(op:"tree") 或 op:"find" + text',
      example: '"看看现在屏幕上有什么按钮"',
    },
    {
      name: '点击文本元素',
      how: 'device_gui(op:"click", text:"登录")；无文本时用 tree 拿 bounds 后按坐标 op:"tap"',
    },
    {
      name: '输入文字',
      how: 'device_gui(op:"type", text:"...")（先点击输入框获得焦点）',
    },
    {
      name: '全局动作',
      how: 'device_gui(op:"back" | "home")',
      limits: 'HarmonyOS/iOS 不支持 GUI 自动化：只能拉起 App + 深链，无法代用户点击。',
    },
  ],
  keywords: ['gui', 'automation', '点击', '自动操作', '无障碍', 'accessibility', '屏幕', '控件', '界面', 'tap', 'swipe', 'type'],
}

const APP_LAUNCH: ManualSection = {
  id: 'app-launch',
  platform: 'all',
  category: 'apps',
  title: '应用拉起与深链（打开 App / 应用内直达页面）',
  summary: 'device_app 可列出已装应用、按包名/深链 URI 拉起；配合各 App 章节的 scheme 可直达搜索、详情等页面。',
  entries: [
    {
      name: '列出可拉起的应用',
      how: 'device_app(op:"list") → 返回 {package,name} 列表',
      example: '"看看我手机上都装了什么应用"',
    },
    {
      name: '打开应用',
      how: 'device_app(op:"open", bundleName:"com.tencent.mm")；也可用深链 device_app(op:"open", uri:"weixin://")',
    },
    {
      name: '应用内搜索直达',
      how: '先用该 App 深链（见 apps.* 章节）直达搜索页，失败则 open 后用 gui 输入搜索词',
      limits: 'iOS 无 GUI 自动化，只能靠深链或 open。',
    },
  ],
  keywords: ['app', '应用', '打开', '拉起', '启动', 'launch', 'open', '深链', 'deeplink', 'scheme', 'uri'],
}

const CONTACTS: ManualSection = {
  id: 'contacts',
  platform: 'all',
  category: 'communication',
  title: '通讯录（查询/创建/更新）',
  summary: 'device_contacts 支持 query/list/create/update；Android 真实读写系统通讯录，HarmonyOS 第三方仅受限定访问。',
  entries: [
    { name: '查联系人', how: 'device_contacts(op:"query", query:"张三")', example: '"找一下张三的电话"' },
    { name: '新建联系人', how: 'device_contacts(op:"create", name:"...", phone:"...")', limits: '需要通讯录权限（device_permissions 可查/申请）。' },
  ],
  keywords: ['contacts', '通讯录', '联系人', '电话号码', 'address book'],
}

const CALENDAR: ManualSection = {
  id: 'calendar',
  platform: 'all',
  category: 'system',
  title: '日历日程（查询/创建/更新/删除）',
  summary: 'device_calendar 读写系统日历事件（title/from/to/notes/location）。',
  entries: [
    { name: '查近期日程', how: 'device_calendar(op:"list")', example: '"我这周有什么安排"' },
    { name: '创建日程', how: 'device_calendar(op:"create", title:"周会", from:<ms>, to:<ms>)', limits: '时间为 epoch 毫秒。' },
  ],
  keywords: ['calendar', '日历', '日程', '会议', '安排', 'schedule', 'event'],
}

const CLIPBOARD: ManualSection = {
  id: 'clipboard',
  platform: 'all',
  category: 'system',
  title: '剪贴板（读/写）',
  summary: 'device_clipboard op:"read"/"write"。',
  entries: [
    { name: '读剪贴板', how: 'device_clipboard(op:"read")', example: '"帮我看看复制的内容"对内容做处理' },
    { name: '写剪贴板', how: 'device_clipboard(op:"write", text:"...")', example: '"把这段翻译写到剪贴板"' },
  ],
  keywords: ['clipboard', '剪贴板', '复制', '粘贴', 'copy', 'paste'],
}

const MESSAGING: ManualSection = {
  id: 'messaging',
  platform: 'all',
  category: 'communication',
  title: '邮件 / 电话 / 短信',
  summary: 'device_mail 打开邮件编写器（用户发送）；device_call 拨号/直拨与通话记录；device_sms 读短信/打开发送器。',
  entries: [
    { name: '写邮件', how: 'device_mail(op:"compose", to:"a@b.c", subject:"...", body:"...")', limits: '打开编写器后由用户点发送。' },
    { name: '拨号', how: 'device_call(op:"dial", number:"10086")（dial 只打开拨号盘；call 直接拨出）' },
    { name: '查通话记录', how: 'device_call(op:"calllog")', limits: '需要 callLog 权限。' },
    { name: '读/发短信', how: 'device_sms(op:"read" | op:"compose")' },
  ],
  keywords: ['mail', 'email', '邮件', 'phone', 'call', '拨号', '打电话', '电话', 'sms', '短信', '通话记录'],
}

const MEDIA_PHOTOS: ManualSection = {
  id: 'photos',
  platform: 'all',
  category: 'media',
  title: '相册（查询/保存/删除）',
  summary: 'device_photos 查询系统相册（按时间/数量）、保存文件到相册、删除项目；查询结果带路径可供视觉识别。',
  entries: [
    { name: '查最近照片', how: 'device_photos(op:"query", limit:10)', example: '"看看我最近拍的照片"' },
    { name: '保存到相册', how: 'device_photos(op:"save", path:"...")' },
    { name: '删除照片', how: 'device_photos(op:"delete", id:"...")', limits: '删除有交互确认（安全设计）。' },
  ],
  keywords: ['photos', '相册', '照片', '图库', 'gallery', '图片', 'picture', '删除照片'],
}

const FILES: ManualSection = {
  id: 'files',
  platform: 'all',
  category: 'system',
  title: '文件（列表/读/写/删除）',
  summary: 'device_files 在应用沙盒目录内 list/read/write/delete，路径以 /data 开头。',
  entries: [
    { name: '列文件', how: 'device_files(op:"list", path:"/")' },
    { name: '读写文本', how: 'device_files(op:"read"|"write", path:"...", text:"...")' },
  ],
  keywords: ['files', '文件', '读写', 'file', '保存文件'],
}

const AUDIO: ManualSection = {
  id: 'audio',
  platform: 'all',
  category: 'media',
  title: '录音与语音',
  summary: 'device_recorder op:"start"(maxSeconds)/"stop" 录音返回 m4a 路径；录音文件可作为语音输入自动转写。',
  entries: [
    { name: '录一段话', how: 'device_recorder(op:"start", maxSeconds:30) → op:"stop")', example: '"录 30 秒环境音"', limits: '需要麦克风权限。' },
  ],
  keywords: ['recorder', '录音', 'audio', '语音', 'record', '麦克风', 'microphone'],
}

const REMINDERS: ManualSection = {
  id: 'reminders',
  platform: 'all',
  category: 'system',
  title: '提醒与定时任务',
  summary: 'device_reminder 建提醒（timer 倒计时 / calendar 指定时刻，list/remove 管理）；device_scheduler 建后台周期任务（间隔/网络/充电约束）。',
  entries: [
    { name: '倒计时提醒', how: 'device_reminder(op:"timer", message:"喝水", delayMinutes:30)', example: '"半小时后提醒我喝水"' },
    { name: '定点提醒', how: 'device_reminder(op:"calendar", message:"开会", hour:9, minute:30)' },
    { name: '周期后台任务', how: 'device_scheduler(op:"start", task:"...", intervalMinutes:60)' },
  ],
  keywords: ['reminder', '提醒', '闹钟', 'alarm', '定时', 'scheduler', '周期任务', 'timer'],
}

const DEVICE_STATUS: ManualSection = {
  id: 'device-status',
  platform: 'all',
  category: 'system',
  title: '设备状态与系统设置（信息/电量/网络/振动/定位/设置页）',
  summary: 'device_deviceinfo（型号/系统/电量）、device_network（联网状态）、device_vibrate（震动）、device_location（GPS 定位）、device_settings（打开设置页）。',
  entries: [
    { name: '设备信息', how: 'device_deviceinfo() → {brand,model,os,apiLevel,batteryLevel,charging}' },
    { name: '网络状态', how: 'device_network() → {type:wifi|cellular|none,online,...}' },
    { name: '定位', how: 'device_location()（需定位权限）' },
    { name: '震动反馈', how: 'device_vibrate(duration:300)' },
    { name: '打开系统设置', how: 'device_settings(page:"wifi"|"bluetooth"|"location"|"notification"|"app-manager"|省略=主页)' },
  ],
  keywords: ['device', '设备', '电量', 'battery', '网络', 'wifi', '定位', '位置', 'GPS', 'location', '震动', 'vibrate', '设置', 'settings'],
}

const SHARE: ManualSection = {
  id: 'share',
  platform: 'all',
  category: 'system',
  title: '系统分享（把文本/文件交给用户选择的应用）',
  summary: 'device_share 调起系统分享面板（text 或 file），由用户选择目标应用。',
  entries: [
    { name: '分享文本/文件', how: 'device_share(text:"...") 或 device_share(path:"...")', example: '"把这个文件分享出去"' },
  ],
  keywords: ['share', '分享', '转发', '发送给'],
}

// ── 三方应用章节（Top 20，人工维护）────────────────────────
// 通用模式：①深链直达（若有）→ ②device_app open 拉起 → ③GUI 自动化（仅 Android）。
// iOS/HarmonyOS 无 GUI 自动化时只能 ①②。

const APP_SECTIONS: ManualSection[] = [
  {
    id: 'apps.wechat',
    platform: 'all',
    category: 'apps',
    title: '微信（聊天/朋友圈/扫一扫/收款码）',
    summary: '拉起微信并经 GUI 自动化完成发消息、发朋友圈、扫码等高频任务。',
    appId: { android: 'com.tencent.mm', harmony: 'com.tencent.mm', ios: 'com.tencent.xin' },
    entries: [
      { name: '打开微信', how: 'device_app(op:"open", uri:"weixin://") 或 bundleName:"com.tencent.mm"' },
      { name: '给某人发消息', how: 'open 微信 → device_gui 点击通讯录/搜索 → 输入名字 → 点击联系人 → 点击输入框 → type 内容 → 点击发送', limits: '仅 Android（需无障碍服务）；iOS 只能打开微信。' },
      { name: '扫一扫', how: 'open 微信 → gui 点击右上角"+" → 点击"扫一扫"', limits: '仅 Android。' },
      { name: '发朋友圈', how: 'open 微信 → gui 点击"发现" → "朋友圈" → 右上角相机 → 输入 → 发表', limits: '仅 Android。' },
    ],
    keywords: ['微信', 'wechat', 'weixin', '聊天', '发消息', '朋友圈', '扫码', '扫一扫'],
  },
  {
    id: 'apps.alipay',
    platform: 'all',
    category: 'apps',
    title: '支付宝（扫一扫/付款码/乘车码）',
    summary: '拉起支付宝，GUI 到达扫码/付款码页面。',
    appId: { android: 'com.eg.android.AlipayGphone', harmony: 'com.alipay.mobile.client', ios: 'com.alipay.iphoneclient' },
    entries: [
      { name: '打开支付宝', how: 'device_app(op:"open", uri:"alipays://") 或 bundleName' },
      { name: '出示付款码', how: 'open 支付宝 → gui 点击"付款"/"收付款"', limits: '仅 Android GUI。' },
    ],
    keywords: ['支付宝', 'alipay', '付款码', '收款码', '扫码支付'],
  },
  {
    id: 'apps.amap',
    platform: 'all',
    category: 'apps',
    title: '高德地图（导航到目的地）',
    summary: '用 geo:/amapuri 深链直接发起导航，无需 GUI。',
    appId: { android: 'com.autonavi.minimap', ios: 'com.autonavi.Navipad' },
    entries: [
      { name: '导航到地点', how: 'device_app(op:"open", uri:"geo:0,0?q=<地名>")（系统选择器选高德）；或 device_location 拿当前位置后让高德 uri:"amapuri://route/plan?dname=<地名>"', example: '"导航去北京西站"' },
      { name: '打开高德', how: 'device_app(op:"open", bundleName:"com.autonavi.minimap")' },
    ],
    keywords: ['高德', '高德地图', 'amap', '导航', '地图', '路线', 'navigation', 'map'],
  },
  {
    id: 'apps.baidu-map',
    platform: 'all',
    category: 'apps',
    title: '百度地图（导航）',
    summary: 'geo: 深链或拉起后 GUI。',
    appId: { android: 'com.baidu.BaiduMap' },
    entries: [
      { name: '导航', how: 'device_app(op:"open", uri:"geo:0,0?q=<地名>") 选择百度地图；或 open 后 gui', limits: '仅 Android GUI。' },
    ],
    keywords: ['百度地图', 'baidu map', '导航', '地图'],
  },
  {
    id: 'apps.taobao',
    platform: 'all',
    category: 'apps',
    title: '淘宝（搜索商品/打开链接）',
    summary: '深链 taobao:// 可直达搜索；无则 open + gui。',
    appId: { android: 'com.taobao.taobao', ios: 'com.taobao.taobao4iphone' },
    entries: [
      { name: '搜索商品', how: 'device_app(op:"open", uri:"taobao://s.taobao.com/search?q=<关键词>")；失败则 open 后 gui 点搜索框输入', limits: '仅 Android GUI。' },
    ],
    keywords: ['淘宝', 'taobao', '购物', '买东西', '搜索商品'],
  },
  {
    id: 'apps.jd',
    platform: 'all',
    category: 'apps',
    title: '京东（搜索商品）',
    summary: 'openapp.jdmobile:// 深链或 open + gui。',
    appId: { android: 'com.jingdong.app.mall', ios: 'com.360buy.jdmobile' },
    entries: [
      { name: '搜索商品', how: 'device_app(op:"open", uri:"openapp.jdmobile://virtual?params=<urlencoded>") 或 open 后 gui', limits: '仅 Android GUI。' },
    ],
    keywords: ['京东', 'jd', '购物', '买东西'],
  },
  {
    id: 'apps.pdd',
    platform: 'all',
    category: 'apps',
    title: '拼多多（搜索商品）',
    summary: 'open + gui 搜索。',
    appId: { android: 'com.xunmeng.pinduoduo' },
    entries: [
      { name: '搜索商品', how: 'device_app(op:"open", bundleName:"com.xunmeng.pinduoduo") → gui 点搜索 → 输入 → 搜索', limits: '仅 Android GUI。' },
    ],
    keywords: ['拼多多', 'pdd', 'pinduoduo', '购物'],
  },
  {
    id: 'apps.douyin',
    platform: 'all',
    category: 'apps',
    title: '抖音（观看/搜索视频）',
    summary: 'snssdk1128:// 深链或 open + gui 搜索。',
    appId: { android: 'com.ss.android.ugc.aweme', ios: 'com.ss.iphone.ugc.Aweme' },
    entries: [
      { name: '搜索视频', how: 'device_app(op:"open", uri:"snssdk1128://search?keyword=<词>")；失败则 open 后 gui', limits: '仅 Android GUI。' },
      { name: '打开抖音', how: 'device_app(op:"open", bundleName:"com.ss.android.ugc.aweme")' },
    ],
    keywords: ['抖音', 'douyin', 'tiktok', '短视频', '视频'],
  },
  {
    id: 'apps.kuaishou',
    platform: 'all',
    category: 'apps',
    title: '快手（短视频）',
    summary: 'open + gui。',
    appId: { android: 'com.smile.gifmaker' },
    entries: [
      { name: '打开/搜索', how: 'device_app(op:"open", bundleName:"com.smile.gifmaker") → gui 搜索', limits: '仅 Android GUI。' },
    ],
    keywords: ['快手', 'kuaishou', '短视频'],
  },
  {
    id: 'apps.bilibili',
    platform: 'all',
    category: 'apps',
    title: '哔哩哔哩（打开视频/搜索）',
    summary: 'bilibili:// 深链直达搜索或视频。',
    appId: { android: 'tv.danmaku.bili', ios: 'bilibili' },
    entries: [
      { name: '搜索视频', how: 'device_app(op:"open", uri:"bilibili://search?keyword=<词>")', example: '"在B站搜一下科普视频"' },
      { name: '打开视频', how: 'uri:"bilibili://video/<avid或bvid>"' },
    ],
    keywords: ['b站', '哔哩哔哩', 'bilibili', 'bili', '视频', '番剧'],
  },
  {
    id: 'apps.weibo',
    platform: 'all',
    category: 'apps',
    title: '微博（看热搜/发微博）',
    summary: 'sinaweibo:// 深链或 open + gui。',
    appId: { android: 'com.sina.weibo', ios: 'com.sina.weibo' },
    entries: [
      { name: '打开微博', how: 'device_app(op:"open", uri:"sinaweibo://") 或 bundleName' },
      { name: '发微博', how: 'open → gui 点"+" → 输入 → 发送', limits: '仅 Android GUI。' },
    ],
    keywords: ['微博', 'weibo', '热搜', '发微博'],
  },
  {
    id: 'apps.xiaohongshu',
    platform: 'all',
    category: 'apps',
    title: '小红书（搜索笔记）',
    summary: 'open + gui 搜索。',
    appId: { android: 'com.xingin.xhs', ios: 'com.xingin.discover' },
    entries: [
      { name: '搜索笔记', how: 'device_app(op:"open", bundleName:"com.xingin.xhs") → gui 点搜索 → 输入', limits: '仅 Android GUI。' },
    ],
    keywords: ['小红书', 'rednote', 'xhs', '笔记', '种草'],
  },
  {
    id: 'apps.netease-music',
    platform: 'all',
    category: 'apps',
    title: '网易云音乐（播放歌曲）',
    summary: 'orpheus:// 深链播放，或 open + gui 搜索播放。',
    appId: { android: 'com.netease.cloudmusic', ios: 'com.netease.cloudmusic' },
    entries: [
      { name: '播放歌曲', how: 'device_app(op:"open", uri:"orpheus://song/<id>")；不确定 id 时 open 后 gui 搜索歌名点播放', example: '"放一首周杰伦的歌"', limits: '仅 Android GUI。' },
    ],
    keywords: ['网易云音乐', '云音乐', 'netease', '音乐', '放歌', '播放', 'music'],
  },
  {
    id: 'apps.qqmusic',
    platform: 'all',
    category: 'apps',
    title: 'QQ 音乐（播放歌曲）',
    summary: 'qqmusic:// 深链或 open + gui。',
    appId: { android: 'com.tencent.qqmusic', ios: 'com.tencent.qqmusic' },
    entries: [
      { name: '播放歌曲', how: 'device_app(op:"open", uri:"qqmusic://") → gui 搜索播放', limits: '仅 Android GUI。' },
    ],
    keywords: ['qq音乐', 'qqmusic', '音乐', '播放', '放歌'],
  },
  {
    id: 'apps.qq',
    platform: 'all',
    category: 'apps',
    title: 'QQ（聊天）',
    summary: 'mqq:// 深链或 open + gui。',
    appId: { android: 'com.tencent.mobileqq', ios: 'com.tencent.mqq' },
    entries: [
      { name: '打开QQ', how: 'device_app(op:"open", uri:"mqq://") 或 bundleName' },
      { name: '发消息', how: 'open → gui 选联系人 → 输入 → 发送', limits: '仅 Android GUI。' },
    ],
    keywords: ['qq', '腾讯qq', '聊天', '发消息'],
  },
  {
    id: 'apps.dingtalk',
    platform: 'all',
    category: 'apps',
    title: '钉钉（考勤/消息/会议）',
    summary: 'dingtalk:// 深链或 open + gui。',
    appId: { android: 'com.alibaba.android.rimet', ios: 'com.laiwang.DingTalk' },
    entries: [
      { name: '打开钉钉', how: 'device_app(op:"open", uri:"dingtalk://") 或 bundleName' },
      { name: '打卡/发消息', how: 'open → gui 按目标页面操作', limits: '仅 Android GUI。' },
    ],
    keywords: ['钉钉', 'dingtalk', '考勤', '打卡', '上班'],
  },
  {
    id: 'apps.feishu',
    platform: 'all',
    category: 'apps',
    title: '飞书（消息/文档/会议）',
    summary: 'feishu:// / lark:// 深链或 open + gui。',
    appId: { android: 'com.ss.android.lark', ios: 'com.ss.tencent.lark' },
    entries: [
      { name: '打开飞书', how: 'device_app(op:"open", uri:"feishu://") 或 bundleName' },
      { name: '发消息', how: 'open → gui 选会话 → 输入 → 发送', limits: '仅 Android GUI。' },
    ],
    keywords: ['飞书', 'lark', 'feishu', '消息', '文档'],
  },
  {
    id: 'apps.wemeet',
    platform: 'all',
    category: 'apps',
    title: '腾讯会议（入会）',
    summary: 'wwauth:// 或会议号深链入会。',
    appId: { android: 'com.tencent.wemeet.app', ios: 'com.tencent.meeting' },
    entries: [
      { name: '加入会议', how: 'device_app(op:"open", bundleName:"com.tencent.wemeet.app") → gui 输入会议号加入', limits: '仅 Android GUI。' },
    ],
    keywords: ['腾讯会议', 'wemeet', '会议', '视频会议', '开会'],
  },
  {
    id: 'apps.meituan',
    platform: 'all',
    category: 'apps',
    title: '美团（外卖/团购）',
    summary: 'imeituan:// 深链或 open + gui。',
    appId: { android: 'com.sankuai.meituan', ios: 'com.meituan.iphonewm' },
    entries: [
      { name: '点外卖', how: 'device_app(op:"open", bundleName:"com.sankuai.meituan") → gui 选商家加购下单', limits: '仅 Android GUI；支付环节留给用户确认。' },
    ],
    keywords: ['美团', 'meituan', '外卖', '点餐', '团购'],
  },
  {
    id: 'apps.dianping',
    platform: 'all',
    category: 'apps',
    title: '大众点评（找店/团购）',
    summary: 'open + gui。',
    appId: { android: 'com.dianping.v1', ios: 'com.dianping.dpscope' },
    entries: [
      { name: '搜店铺', how: 'device_app(op:"open", bundleName:"com.dianping.v1") → gui 搜索店名', limits: '仅 Android GUI。' },
    ],
    keywords: ['大众点评', 'dianping', '餐厅', '美食', '找店'],
  },
]

export const MANUAL_SECTIONS: ManualSection[] = [
  CAMERA,
  GUI_AUTOMATION,
  APP_LAUNCH,
  CONTACTS,
  CALENDAR,
  CLIPBOARD,
  MESSAGING,
  MEDIA_PHOTOS,
  FILES,
  AUDIO,
  REMINDERS,
  DEVICE_STATUS,
  SHARE,
  ...APP_SECTIONS,
]

export const MANUAL_APP_IDS: Array<{ id: string; title: string; appId: NonNullable<ManualSection['appId']> }> =
  MANUAL_SECTIONS.filter(s => s.appId).map(s => ({ id: s.id, title: s.title, appId: s.appId! }))

// ── 检索 ────────────────────────────────────────────────────

function sectionHaystack(s: ManualSection): string {
  return [
    s.id, s.title, s.summary, s.category,
    ...s.keywords,
    ...s.entries.flatMap(e => [e.name, e.how, e.example ?? '', e.limits ?? '']),
  ].join('\n').toLowerCase()
}

export interface SearchHit {
  section: ManualSection
  score: number
}

/** 关键词检索：按 query 分词在章节全文计分（中英文皆可，大小写不敏感） */
/** CJK 二元组：中文 query（如"前置自拍"）整词无法精确命中关键词（"自拍"），按滑窗二元组降级匹配 */
function cjkBigrams(term: string): string[] {
  if (!/[\u4e00-\u9fff]/.test(term)) return []
  const out: string[] = []
  for (let i = 0; i + 2 <= term.length; i++) out.push(term.slice(i, i + 2))
  return out
}

export function searchSections(query: string, opts: { platform?: string; category?: string; limit?: number } = {}): SearchHit[] {
  const terms = query.toLowerCase().split(/[\s,，、;；/|]+/).map(t => t.trim()).filter(t => t.length > 0)
  if (terms.length === 0) return []
  const hits: SearchHit[] = []
  for (const s of MANUAL_SECTIONS) {
    if (opts.platform && s.platform !== 'all' && s.platform !== opts.platform) continue
    if (opts.category && s.category !== opts.category) continue
    const hay = sectionHaystack(s)
    const kws = s.keywords.map(k => k.toLowerCase())
    let score = 0
    for (const t of terms) {
      const bis = cjkBigrams(t)
      if (kws.includes(t)) score += 5
      else if (bis.some(b => kws.includes(b))) score += 3
      else if (s.id.toLowerCase().includes(t) || s.title.toLowerCase().includes(t)) score += 3
      else if (hay.includes(t)) score += 1
      else if (bis.some(b => hay.includes(b))) score += 1
    }
    if (score > 0) hits.push({ section: s, score })
  }
  hits.sort((a, b) => b.score - a.score)
  return hits.slice(0, opts.limit ?? 5)
}

export function sectionById(id: string): ManualSection | undefined {
  return MANUAL_SECTIONS.find(s => s.id === id)
}

/** 渲染单章节为模型可读文本 */
export function renderSection(s: ManualSection): string {
  const lines = [`## ${s.title}`, `id: ${s.id} · platform: ${s.platform}${s.osRange ? ` · os: ${s.osRange}` : ''}`, s.summary]
  for (const e of s.entries) {
    lines.push(`- ${e.name}: ${e.how}`)
    if (e.example) lines.push(`  示例: ${e.example}`)
    if (e.limits) lines.push(`  限制: ${e.limits}`)
  }
  return lines.join('\n')
}

// ── 系统提示索引（c4：只注入目录，正文按需查）────────────────

/** 生成紧凑目录文本（注入系统提示，控制在 ~25 行内） */
export function buildCapabilityIndexText(platform?: string): string {
  const sys = MANUAL_SECTIONS.filter(s => s.category !== 'apps')
  const apps = MANUAL_SECTIONS.filter(s => s.category === 'apps')
  const sysLines = sys.map(s => `- ${s.id}: ${s.title.split('（')[0]}`).join('\n')
  const appLines = apps
    .filter(s => !platform || s.platform === 'all' || s.platform === platform)
    .map(s => `- ${s.id}: ${s.title.split('（')[0]}`)
    .join('\n')
  return [
    '## 本机能力手册（device capabilities manual）',
    '本设备运行的 harness 内置离线能力手册。遇到「不确定本机怎么做」的任务（如切换前置摄像头、控制三方 App、深链直达），先查手册再动手：',
    '- device_capabilities_query(query:"关键词") — 检索手册章节（中英文均可，如 "前置自拍"、"微信 发消息"、"导航"）',
    '- device_probe() — 探测系统版本 + 已装应用，返回与手册匹配的建议章节',
    '速查（高频误区）：前置自拍 → device_camera(op:"capture", facing:"front")，拍完照片自动附给模型可直接识别；三方 App 任务 → apps.* 章节有深链与 GUI 步骤。',
    '系统能力章节：',
    sysLines,
    '三方应用章节（Top 20，已装才可用；device_probe 可确认）：',
    appLines,
  ].join('\n')
}
