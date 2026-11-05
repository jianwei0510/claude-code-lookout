// 這個檔案是產生出來的，不要手改。
// 來源：design/mono-sharp.tokens.json  sha256:ddff2cb46050db54
// 改 tokens.json 之後重跑：python3 gen_tokens.py

import AppKit

/// 一個顏色在深色／淺色主題下各自的值，跟著視窗的外觀自動切換。
private func themed(_ name: String, dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: NSColor.Name("MonoSharp." + name)) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// sRGB 裝不下的顏色（幾個狀態色）用 Display P3，不裁切。
private func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
    NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
}

struct MSTypeStyle {
    let size: CGFloat
    let weight: NSFont.Weight
    let lineHeight: CGFloat?   // 倍數；tokens 裡寫成 px 的已換算成倍數
}

enum MonoSharp {
    // MARK: 顏色
    /// Page ground (≈#09090b dark / #ffffff light). Dark is the default theme.
    ///   dark: oklch(0.141 0.005 285.823) ≈ #09090b
    ///   light: oklch(1 0 0) ≈ #ffffff
    static let background = themed("background", dark: srgb(0.0354, 0.0354, 0.0443, 1), light: srgb(1.0000, 1.0000, 1.0000, 1))
    /// Primary text and the only emphasis colour, on background, card and muted (≥14:1 in both themes). Also the brand mark square and the main data series.
    ///   dark: oklch(0.985 0 0) ≈ #fafafa
    ///   light: oklch(0.141 0.005 285.823) ≈ #09090b
    static let foreground = themed("foreground", dark: srgb(0.9803, 0.9803, 0.9803, 1), light: srgb(0.0354, 0.0354, 0.0443, 1))
    /// Section/Card surface (≈#18181b dark, one step above background). In light it equals background; cards separate by a 1px foreground/10 ring.
    ///   dark: oklch(0.21 0.006 285.885) ≈ #18181b
    ///   light: oklch(1 0 0) ≈ #ffffff
    static let card = themed("card", dark: srgb(0.0938, 0.0938, 0.1058, 1), light: srgb(1.0000, 1.0000, 1.0000, 1))
    /// Text on card.
    ///   dark: oklch(0.985 0 0) ≈ #fafafa
    ///   light: oklch(0.141 0.005 285.823) ≈ #09090b
    static let cardForeground = themed("card-foreground", dark: srgb(0.9803, 0.9803, 0.9803, 1), light: srgb(0.0354, 0.0354, 0.0443, 1))
    /// Dropdown, select and popover surfaces; pair with shadow-popover and ring-card.
    ///   dark: oklch(0.21 0.006 285.885) ≈ #18181b
    ///   light: oklch(1 0 0) ≈ #ffffff
    static let popover = themed("popover", dark: srgb(0.0938, 0.0938, 0.1058, 1), light: srgb(1.0000, 1.0000, 1.0000, 1))
    /// Text on popover.
    ///   dark: oklch(0.985 0 0) ≈ #fafafa
    ///   light: oklch(0.141 0.005 285.823) ≈ #09090b
    static let popoverForeground = themed("popover-foreground", dark: srgb(0.9803, 0.9803, 0.9803, 1), light: srgb(0.0354, 0.0354, 0.0443, 1))
    /// Primary button fill: near-white in dark, near-black in light. One per page. Hover: 80% opacity.
    ///   dark: oklch(0.92 0.004 286.32) ≈ #e4e4e7
    ///   light: oklch(0.21 0.006 285.885) ≈ #18181b
    static let primary = themed("primary", dark: srgb(0.8945, 0.8945, 0.9062, 1), light: srgb(0.0938, 0.0938, 0.1058, 1))
    /// Text on primary (13.9:1 dark).
    ///   dark: oklch(0.21 0.006 285.885) ≈ #18181b
    ///   light: oklch(0.985 0 0) ≈ #fafafa
    static let primaryForeground = themed("primary-foreground", dark: srgb(0.0938, 0.0938, 0.1058, 1), light: srgb(0.9803, 0.9803, 0.9803, 1))
    /// Secondary button fill.
    ///   dark: oklch(0.274 0.006 286.033) ≈ #27272a
    ///   light: oklch(0.967 0.001 286.375) ≈ #f4f4f5
    static let secondary = themed("secondary", dark: srgb(0.1529, 0.1529, 0.1658, 1), light: srgb(0.9564, 0.9564, 0.9593, 1))
    /// Text on secondary.
    ///   dark: oklch(0.985 0 0) ≈ #fafafa
    ///   light: oklch(0.21 0.006 285.885) ≈ #18181b
    static let secondaryForeground = themed("secondary-foreground", dark: srgb(0.9803, 0.9803, 0.9803, 1), light: srgb(0.0938, 0.0938, 0.1058, 1))
    /// Quiet fills: TabsList and FilterToggle track, progress track, skeleton, ghost-button hover (dark uses muted/50).
    ///   dark: oklch(0.274 0.006 286.033) ≈ #27272a
    ///   light: oklch(0.967 0.001 286.375) ≈ #f4f4f5
    static let muted = themed("muted", dark: srgb(0.1529, 0.1529, 0.1658, 1), light: srgb(0.9564, 0.9564, 0.9593, 1))
    /// Secondary text, labels, meta lines, hints. On background: 7.6:1 dark, 4.8:1 light. On muted in light it is 4.39:1 — below AA for small text; keep muted-foreground off muted fills in light (source value kept exact).
    ///   dark: oklch(0.705 0.015 286.067) ≈ #9f9fa9
    ///   light: oklch(0.552 0.016 285.938) ≈ #71717b
    static let mutedForeground = themed("muted-foreground", dark: srgb(0.6226, 0.6226, 0.6634, 1), light: srgb(0.4430, 0.4429, 0.4838, 1))
    /// Focused menu/select item background.
    ///   dark: oklch(0.274 0.006 286.033) ≈ #27272a
    ///   light: oklch(0.967 0.001 286.375) ≈ #f4f4f5
    static let accent = themed("accent", dark: srgb(0.1529, 0.1529, 0.1658, 1), light: srgb(0.9564, 0.9564, 0.9593, 1))
    /// Text on accent.
    ///   dark: oklch(0.985 0 0) ≈ #fafafa
    ///   light: oklch(0.21 0.006 285.885) ≈ #18181b
    static let accentForeground = themed("accent-foreground", dark: srgb(0.9803, 0.9803, 0.9803, 1), light: srgb(0.0938, 0.0938, 0.1058, 1))
    /// Errors, delete actions, invalid field borders. Used as text on a 10% (light) / 20% (dark) tint of itself, never as a solid fill. On background 6.9:1 dark / 4.8:1 light; on its own 10% tint in light 4.0:1 — below AA for 12px text (source value kept exact; prefer the dark tint or 14px text).
    ///   dark: oklch(0.704 0.191 22.216) ≈ #ee6e6c (p3)
    ///   light: oklch(0.577 0.245 27.325) ≈ #d42422 (p3)
    static let destructive = themed("destructive", dark: p3(0.9335, 0.4317, 0.4235, 1), light: p3(0.8303, 0.1404, 0.1332, 1))
    /// Done/passed/live status. Text + 10% fill + 40% border, never solid. On its tint: 9.8:1 dark, 4.9:1 light. Always paired with a word or icon.
    ///   dark: oklch(0.8 0.15 160) ≈ #52db9c
    ///   light: oklch(0.5 0.13 155) ≈ #2f7646 (p3)
    static let success = themed("success", dark: srgb(0.3202, 0.8580, 0.6115, 1), light: p3(0.1837, 0.4625, 0.2733, 1))
    /// Needs-attention status. Text + 10% fill + 40% border. On its tint: 10.3:1 dark, 5.0:1 light.
    ///   dark: oklch(0.84 0.14 85) ≈ #f4c352
    ///   light: oklch(0.52 0.13 62) ≈ #93570f (p3)
    static let warning = themed("warning", dark: srgb(0.9577, 0.7636, 0.3199, 1), light: p3(0.5745, 0.3429, 0.0580, 1))
    /// Every divider and outline: header bottom, divide-y rows, section rules, outline buttons (light). Decorative contrast only (~1.3–1.5:1).
    ///   dark: oklch(1 0 0 / 10%) ≈ #ffffff @0.1
    ///   light: oklch(0.92 0.004 286.32) ≈ #e4e4e7
    static let border = themed("border", dark: srgb(1.0000, 1.0000, 1.0000, 0.1), light: srgb(0.8945, 0.8945, 0.9062, 1))
    /// Input, select, checkbox and outline-button borders; dark controls also fill with input at 30%. Below the 3:1 control-boundary guideline in both themes (shadcn default kept exact) — the label and placeholder carry the affordance.
    ///   dark: oklch(1 0 0 / 15%) ≈ #ffffff @0.15
    ///   light: oklch(0.92 0.004 286.32) ≈ #e4e4e7
    static let input = themed("input", dark: srgb(1.0000, 1.0000, 1.0000, 0.15), light: srgb(0.8945, 0.8945, 0.9062, 1))
    /// Focus: border turns ring and a 1px ring at 50% appears. Weak in light (≈2.6:1 at full strength) — source kept exact; see README Focus.
    ///   dark: oklch(0.552 0.016 285.938) ≈ #71717b
    ///   light: oklch(0.705 0.015 286.067) ≈ #9f9fa9
    static let ring = themed("ring", dark: srgb(0.4430, 0.4429, 0.4838, 1), light: srgb(0.6226, 0.6226, 0.6634, 1))
    /// Lightest chart step. Charts stay grayscale; emphasise the series that matters with foreground.
    ///   dark: oklch(0.871 0.006 286.286) ≈ #d4d4d8
    ///   light: oklch(0.871 0.006 286.286) ≈ #d4d4d8
    static let chart1 = themed("chart-1", dark: srgb(0.8311, 0.8311, 0.8483, 1), light: srgb(0.8311, 0.8311, 0.8483, 1))
    /// Chart step 2.
    ///   dark: oklch(0.552 0.016 285.938) ≈ #71717b
    ///   light: oklch(0.552 0.016 285.938) ≈ #71717b
    static let chart2 = themed("chart-2", dark: srgb(0.4430, 0.4429, 0.4838, 1), light: srgb(0.4430, 0.4429, 0.4838, 1))
    /// Chart step 3.
    ///   dark: oklch(0.442 0.017 285.786) ≈ #52525c
    ///   light: oklch(0.442 0.017 285.786) ≈ #52525c
    static let chart3 = themed("chart-3", dark: srgb(0.3212, 0.3211, 0.3621, 1), light: srgb(0.3212, 0.3211, 0.3621, 1))
    /// Chart step 4.
    ///   dark: oklch(0.37 0.013 285.805) ≈ #3f3f46
    ///   light: oklch(0.37 0.013 285.805) ≈ #3f3f46
    static let chart4 = themed("chart-4", dark: srgb(0.2465, 0.2464, 0.2765, 1), light: srgb(0.2465, 0.2464, 0.2765, 1))
    /// Darkest chart step.
    ///   dark: oklch(0.274 0.006 286.033) ≈ #27272a
    ///   light: oklch(0.274 0.006 286.033) ≈ #27272a
    static let chart5 = themed("chart-5", dark: srgb(0.1529, 0.1529, 0.1658, 1), light: srgb(0.1529, 0.1529, 0.1658, 1))
    /// Sidebar surface, when an app has one.
    ///   dark: oklch(0.21 0.006 285.885) ≈ #18181b
    ///   light: oklch(0.985 0 0) ≈ #fafafa
    static let sidebar = themed("sidebar", dark: srgb(0.0938, 0.0938, 0.1058, 1), light: srgb(0.9803, 0.9803, 0.9803, 1))
    /// Text on sidebar.
    ///   dark: oklch(0.985 0 0) ≈ #fafafa
    ///   light: oklch(0.141 0.005 285.823) ≈ #09090b
    static let sidebarForeground = themed("sidebar-foreground", dark: srgb(0.9803, 0.9803, 0.9803, 1), light: srgb(0.0354, 0.0354, 0.0443, 1))
    /// Active sidebar item fill (neutral, not shadcn's default blue).
    ///   dark: oklch(0.92 0.004 286.32) ≈ #e4e4e7
    ///   light: oklch(0.21 0.006 285.885) ≈ #18181b
    static let sidebarPrimary = themed("sidebar-primary", dark: srgb(0.8945, 0.8945, 0.9062, 1), light: srgb(0.0938, 0.0938, 0.1058, 1))
    /// Text on sidebar-primary.
    ///   dark: oklch(0.21 0.006 285.885) ≈ #18181b
    ///   light: oklch(0.985 0 0) ≈ #fafafa
    static let sidebarPrimaryForeground = themed("sidebar-primary-foreground", dark: srgb(0.0938, 0.0938, 0.1058, 1), light: srgb(0.9803, 0.9803, 0.9803, 1))
    /// Sidebar item hover.
    ///   dark: oklch(0.274 0.006 286.033) ≈ #27272a
    ///   light: oklch(0.967 0.001 286.375) ≈ #f4f4f5
    static let sidebarAccent = themed("sidebar-accent", dark: srgb(0.1529, 0.1529, 0.1658, 1), light: srgb(0.9564, 0.9564, 0.9593, 1))
    /// Text on sidebar-accent.
    ///   dark: oklch(0.985 0 0) ≈ #fafafa
    ///   light: oklch(0.21 0.006 285.885) ≈ #18181b
    static let sidebarAccentForeground = themed("sidebar-accent-foreground", dark: srgb(0.9803, 0.9803, 0.9803, 1), light: srgb(0.0938, 0.0938, 0.1058, 1))
    /// Sidebar dividers.
    ///   dark: oklch(1 0 0 / 10%) ≈ #ffffff @0.1
    ///   light: oklch(0.92 0.004 286.32) ≈ #e4e4e7
    static let sidebarBorder = themed("sidebar-border", dark: srgb(1.0000, 1.0000, 1.0000, 0.1), light: srgb(0.8945, 0.8945, 0.9062, 1))
    /// Sidebar focus ring.
    ///   dark: oklch(0.552 0.016 285.938) ≈ #71717b
    ///   light: oklch(0.705 0.015 286.067) ≈ #9f9fa9
    static let sidebarRing = themed("sidebar-ring", dark: srgb(0.4430, 0.4429, 0.4838, 1), light: srgb(0.6226, 0.6226, 0.6634, 1))

    // MARK: 間距與尺寸（px）
    /// Button/xs and icon-xs height.
    static let controlXs: CGFloat = 24
    /// Button/sm, Toggle/sm and FilterToggle item height.
    static let controlSm: CGFloat = 28
    /// Default height of Button, Input, Select trigger, TabsList, Toggle.
    static let controlMd: CGFloat = 32
    /// Button/lg (hero calls to action).
    static let controlLg: CGFloat = 36
    /// Horizontal padding of buttons, inputs, select triggers (px-2.5).
    static let padControlX: CGFloat = 10
    /// Default Card padding (--card-spacing). Card/sm uses 12px.
    static let padCard: CGFloat = 16
    /// Section padding and list-row horizontal padding.
    static let padSection: CGFloat = 20
    /// Vertical padding of list rows and setting rows (py-3.5).
    static let padRowY: CGFloat = 14
    /// Page side gutter on phones (px-4).
    static let gutter: CGFloat = 16
    /// Page side gutter from sm up (px-6); also gap between PageHeader title and actions.
    static let gutterSm: CGFloat = 24
    /// Page top/bottom padding on phones (py-8); PageHeader bottom margin.
    static let pagePadY: CGFloat = 32
    /// Page top/bottom padding from sm up (py-10).
    static let pagePadYSm: CGFloat = 40
    /// Sticky app header height (h-12).
    static let headerHeight: CGFloat = 48
    /// Login and single-form pages (max-w-md).
    static let containerSm: CGFloat = 448
    /// Default page column (max-w-3xl).
    static let containerMd: CGFloat = 768
    /// Wider content pages (max-w-4xl).
    static let containerLg: CGFloat = 896
    /// Two-column pages (max-w-5xl).
    static let containerXl: CGFloat = 1024
    /// Landing page and the header row (max-w-6xl).
    static let containerWide: CGFloat = 1152
    /// Label column of SettingRow from sm up (8.5rem).
    static let settingLabel: CGFloat = 136
    /// Every component: buttons, inputs, cards, badges, menus, tooltips. The system is square.
    static let radius: CGFloat = 0
    /// Avatars only.
    static let radiusFull: CGFloat = 9999

    // MARK: 透明度
    /// Status tint behind success/warning/destructive text (bg-tone/10).
    static let toneFill: CGFloat = 0.1
    /// Status border (border-tone/40).
    static let toneBorder: CGFloat = 0.4
    /// Primary button hover (bg-primary/80).
    static let primaryHover: CGFloat = 0.8
    /// Disabled controls.
    static let disabled: CGFloat = 0.5
    /// Sticky header background (bg-background/85 with backdrop-blur-sm).
    static let headerGlass: CGFloat = 0.85

    // MARK: 字級
    /// Landing hero (text-5xl). 36px below sm.
    static let hero = MSTypeStyle(size: 48, weight: .semibold, lineHeight: 1.15)
    /// Hero on phones (text-4xl).
    static let heroSm = MSTypeStyle(size: 36, weight: .semibold, lineHeight: 1.15)
    /// PageHeader h1 from sm up (text-3xl).
    static let pageTitle = MSTypeStyle(size: 30, weight: .semibold, lineHeight: 1.2)
    /// PageHeader h1 on phones (text-2xl).
    static let pageTitleSm = MSTypeStyle(size: 24, weight: .semibold, lineHeight: 1.333)
    /// Page-level section h2 (text-xl).
    static let sectionTitle = MSTypeStyle(size: 20, weight: .semibold, lineHeight: 1.4)
    /// Section/Card title (text-base font-medium).
    static let cardTitle = MSTypeStyle(size: 16, weight: .medium, lineHeight: 1.5)
    /// Intro paragraph under a hero, in muted-foreground (text-base/relaxed).
    static let lead = MSTypeStyle(size: 16, weight: .regular, lineHeight: 1.625)
    /// Body copy, Section content, Notice text (text-sm/relaxed). Minimum for user-facing paragraphs in Chinese.
    static let body = MSTypeStyle(size: 14, weight: .regular, lineHeight: 1.625)
    /// List-row titles and emphasised body (text-sm font-medium).
    static let bodyMedium = MSTypeStyle(size: 14, weight: .medium, lineHeight: 1.429)
    /// Buttons, tabs, toggles, badges, menu items (text-xs font-medium).
    static let control = MSTypeStyle(size: 12, weight: .medium, lineHeight: 1.333)
    /// Inputs, hints, meta lines, captions, card text (text-xs/relaxed), usually muted-foreground.
    static let meta = MSTypeStyle(size: 12, weight: .regular, lineHeight: 1.625)

    // MARK: 字體
    /// 依序嘗試；裝了的第一個就用。ui-sans-serif／system-ui 都對應到系統字。
    static let sansFamilies: [String] = ["Inter", "ui-sans-serif", "system-ui", "PingFang TC", "Noto Sans TC", "Microsoft JhengHei", "sans-serif"]
}
