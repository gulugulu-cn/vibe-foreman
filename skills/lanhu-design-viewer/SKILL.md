---
name: lanhu-design-viewer
description: Use when viewing Demo design specs on Lanhu (蓝湖), extracting design parameters like dimensions, fonts, colors, and spacing from the design files.
---

# 蓝湖设计稿查看 Skill

## 触发条件
当需要查看 Demo 首页设计稿、提取设计参数时调用。

## 设计稿链接

> 下面是模板。把 `YOUR_*` 换成你自己蓝湖项目的 id ——
> 在蓝湖里打开设计稿，地址栏的 `pid` / `image_id` 就是。

### Mobile 设计稿 (iPhone)
```
https://lanhuapp.com/web/#/item/project/detailDetach?pid=YOUR_PROJECT_ID&project_id=YOUR_PROJECT_ID&image_id=YOUR_MOBILE_IMAGE_ID&fromEditor=true
```

### PC 设计稿 (Desktop)
```
https://lanhuapp.com/web/#/item/project/detailDetach?pid=YOUR_PROJECT_ID&project_id=YOUR_PROJECT_ID&image_id=YOUR_DESKTOP_IMAGE_ID&fromEditor=true
```

## 使用规则
- **依赖 `/browser-auto` skill 的双引擎协同机制**
- 蓝湖图层交互：优先用 Claude in Chrome（视觉精准点击）
- 蓝湖可能需要登录，如遇到登录页面告知用户手动登录

## 执行流程

### 1. 启动浏览器（按 browser-auto skill 流程）
先检测两个引擎连接状态，Claude in Chrome 连不上时自动修复

### 2. 打开设计稿
```
[Claude in Chrome] tabs_create_mcp → 创建新标签
[Claude in Chrome] navigate → 导航到设计稿 URL
```

### 3. 等待页面加载
使用 `computer` screenshot 截图确认加载完成

### 4. 查看设计稿
- `[Claude in Chrome] computer screenshot` → 截图查看整体布局
- `[Claude in Chrome] computer left_click` → 点击图层，右侧显示标注
- 蓝湖支持点击元素后在右侧面板显示 CSS 属性（尺寸/字体/颜色/间距）

### 5. 提取设计参数
对每个模块提取以下信息：
- **布局**: 列数、对齐方式、排列顺序
- **间距**: padding、margin、gap（px 值）
- **字体**: font-size、font-weight、line-height、color
- **图片**: 宽高比、圆角、尺寸
- **颜色**: 背景色、文字色、边框色（hex 值）
- **交互**: hover 效果、动画、滑动方式

### 6. 记录参数
将提取的参数保存到 memory 文件：
`/Users/dev/.claude/projects/-Users-dev-Documents-code-shopify-demo-release/memory/design-specs.md`

## 注意事项
- 蓝湖设计稿分 PC 和 Mobile 两版，**两版都要看**
- 如果设计稿页面较长，需要滚动查看，使用 `computer` 工具的滚动操作
- 提取颜色值时注意区分：设计稿颜色 vs 主题 CSS 变量中已有的颜色
- 设计稿中的间距值需要对照全局 `--section-vertical-spacing` 系统，尽量复用
