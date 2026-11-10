/* 作者只需修改本文件，填写方法见 site/home/README.md。
   所有内容会公开显示，请不要填写密钥或私人信息。图片放在 assets/author/。
   头像和二维码只能用本站的 assets/ 路径：页面的 CSP 只允许加载本站图片，外链图片显示不出来。
   空链接不会跳转；贡献者留空不会生成虚构姓名。保存后刷新网页生效。 */
window.DSH_GO_CONFIG = {
  // 分享元信息：填写后执行 npm run prepare:publish，写入静态 HTML。
  // 不更换品牌时保留标题、描述；siteUrl 填最终完整网址，目录网址以 / 结尾。
  metadata: {
    title: "DSH Go · 万物皆插件，随身而行",
    description: "DSH Go，由 DSH-TUI 作者 ccchimneyyy 精心打造的非官方 DeepSeek Harness 移动应用。万物皆插件，现在随身而行。",
    siteUrl: "https://go.dshtui.com/",
    shareImage: "", // 可选：assets/author/share.png 或完整 HTTPS 图片地址，推荐 1200×630 PNG/JPEG
    shareImageAlt: "DSH Go，万物皆插件，现在随身而行"
  },
  author: {
    avatar: "assets/dsh-go.svg", // 换成 assets/author/avatar.png
    id: "ccch1mneyyy",
    message: "DSH Go 是由 DSH-TUI 作者 ccchimneyyy 精心打造的非官方 DeepSeek Harness 手机客户端。我们希望把「万物皆插件」的体验带到手机上，让灵感不受地点限制。"
  },
  download: {
    label: "下载 DSH Go",
    platform: "Android 8.0+ · arm64（多数手机）/ x86_64",
    title: "获取 DSH Go",
    description: "DSH Go 1.0 已发布，支持 Android 8.0 及以上。安装包在 GitHub Releases 发布：大多数手机下载 arm64 版，模拟器和 x86 设备下载 x64 版。",
    qrImage: "assets/author/download-qr.png", // 内容是下面的 url；改 url 时要重新生成
    qrNote: "扫码打开 GitHub 下载页",
    url: "https://github.com/ccch1mneyyy/dsh-go/releases/latest", // 下载入口：GitHub Releases 最新版本
    urlLabel: "从 GitHub 下载",
    altUrl: "", // 可选：第二个下载入口，空值隐藏
    altLabel: ""
  },
  // 代码框和 Star 气泡都链接到这里；气泡上的 Star 数由本站的 /api/github/stars
  // 提供（services/share-worker/src/github.ts，固定查 ccch1mneyyy/dsh-go）。
  repository: {
    label: "github / ccch1mneyyy / dsh-go", // 整行文字均可修改
    url: "https://github.com/ccch1mneyyy/dsh-go"
  },
  // 三行从右向左滚动。每项可指定 row: 1、2 或 3；省略则轮流分配。
  // name 只用于无平台链接的姓名。平台对象的 label 是对应平台显示名。
  // 示例：{ name: "贡献者ID", row: 1 }
  // 示例：{ github: { label: "GitHub ID", url: "https://github.com/用户名" }, row: 2 }
  // 示例：{ bilibili: { label: "B站昵称", url: "https://space.bilibili.com/数字ID" } }
  // 同一项同时写 github、bilibili 即可得到「GitHub ID / B站昵称」。
  contributors: [
    { github: { label: "HuanLinOTO", url: "https://github.com/HuanLinOTO" }, row: 1 },
    { github: { label: "liguobao", url: "https://github.com/liguobao" }, row: 2 },
    { github: { label: "CikeSeven", url: "https://github.com/CikeSeven" }, row: 3 },
    {
      github: { label: "ClayGao233", url: "https://github.com/ClayGao233" },
      bilibili: { label: "采云师烧饼", url: "https://space.bilibili.com/28879571" },
      row: 1
    }
  ]
};
