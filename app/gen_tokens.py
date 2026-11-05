#!/usr/bin/env python3
"""把 Mono Sharp 的 tokens.json 轉成 Swift。

    python3 gen_tokens.py            # 讀 design/mono-sharp.tokens.json，寫 MonoSharpTokens.swift

為什麼要產生而不是手抄：token 的顏色是 oklch，AppKit 不認得，要換算成 sRGB。
手抄換算結果最容易抄錯，而且抄錯的顏色看起來只是「有點怪」，不會報錯。
產生出來的檔案頭會記下來源檔的 sha256，所以看得出它是從哪一版 tokens 產生的。
"""
import hashlib, json, math, pathlib, re, sys

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE / "design" / "mono-sharp.tokens.json"
OUT = HERE / "MonoSharpTokens.swift"

raw = SRC.read_bytes()
digest = hashlib.sha256(raw).hexdigest()
tokens = json.loads(raw)

def camel(name):
    head, *rest = name.split("-")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)

OKLCH = re.compile(r"oklch\(\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*(?:/\s*([\d.]+)(%?))?\s*\)")

def oklch_to_color(text):
    """oklch → (色彩空間, r, g, b, a)。

    sRGB 裝得下就用 sRGB；裝不下就改用 Display P3（Mac 螢幕的原生色域），
    而不是把超出的部分硬裁掉 —— 那會讓狀態色的色相偏掉。
    P3 也裝不下才裁切，並且大聲回報。"""
    m = OKLCH.fullmatch(text.strip())
    if not m:
        sys.exit(f"看不懂的顏色值：{text!r}")
    L, C, H = float(m[1]), float(m[2]), float(m[3])
    alpha = 1.0
    if m[4] is not None:
        alpha = float(m[4]) / (100 if m[5] == "%" else 1)
    a, b = C * math.cos(math.radians(H)), C * math.sin(math.radians(H))
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, mm, s = l_ ** 3, m_ ** 3, s_ ** 3
    lin = (
        +4.0767416621 * l - 3.3077115913 * mm + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * mm - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * mm + 1.7076147010 * s,
    )
    def inside(rgb):
        return all(-1e-4 <= c <= 1 + 1e-4 for c in rgb)
    def encode(c):
        c = min(max(c, 0.0), 1.0)
        return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
    if inside(lin):
        space, chosen = "srgb", lin
    else:
        # 線性 sRGB → 線性 Display P3（同一個 D65 白點）
        r, g, bb = lin
        p3 = (
            0.8224621 * r + 0.1775380 * g + 0.0000000 * bb,
            0.0331941 * r + 0.9668058 * g + 0.0000000 * bb,
            0.0170827 * r + 0.0723974 * g + 0.9105199 * bb,
        )
        space, chosen = ("p3", p3) if inside(p3) else ("p3-clipped", p3)
    r, g, bb = (encode(c) for c in chosen)
    return space, r, g, bb, alpha

def hexof(r, g, b):
    return "#" + "".join(f"{round(c * 255):02x}" for c in (r, g, b))

# 顏色：先建名稱表，{foreground} 這種參照要解開
color_tokens = {t["name"]: t for t in tokens["color"]["tokens"]}
def resolve(name, theme, depth=0):
    value = color_tokens[name]["value"][theme]
    ref = re.fullmatch(r"\{([\w-]+)\}", value)
    if ref:
        if depth > 5:
            sys.exit(f"{name} 的參照繞圈了")
        return resolve(ref[1], theme, depth + 1)
    return value

lines = [
    "// 這個檔案是產生出來的，不要手改。",
    f"// 來源：design/mono-sharp.tokens.json  sha256:{digest[:16]}",
    "// 改 tokens.json 之後重跑：python3 gen_tokens.py",
    "",
    "import AppKit",
    "",
    "/// 一個顏色在深色／淺色主題下各自的值，跟著視窗的外觀自動切換。",
    "private func themed(_ name: String, dark: NSColor, light: NSColor) -> NSColor {",
    "    NSColor(name: NSColor.Name(\"MonoSharp.\" + name)) { appearance in",
    "        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light",
    "    }",
    "}",
    "",
    "private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {",
    "    NSColor(srgbRed: r, green: g, blue: b, alpha: a)",
    "}",
    "",
    "/// sRGB 裝不下的顏色（幾個狀態色）用 Display P3，不裁切。",
    "private func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {",
    "    NSColor(displayP3Red: r, green: g, blue: b, alpha: a)",
    "}",
    "",
    "struct MSTypeStyle {",
    "    let size: CGFloat",
    "    let weight: NSFont.Weight",
    "    let lineHeight: CGFloat?   // 倍數；tokens 裡寫成 px 的已換算成倍數",
    "}",
    "",
    "enum MonoSharp {",
]

report = []
lines.append("    // MARK: 顏色")
for t in tokens["color"]["tokens"]:
    name = t["name"]
    parts = {}
    for theme in ("dark", "light"):
        src = resolve(name, theme)
        space, r, g, b, a = oklch_to_color(src)
        parts[theme] = (space, r, g, b, a, src)
        if space == "p3":
            report.append(f"  改用 Display P3：{name} ({theme}) {src}")
        elif space == "p3-clipped":
            report.append(f"  連 P3 都裝不下，已裁切：{name} ({theme}) {src}")
    usage = t.get("usage", "").replace("\n", " ")
    lines.append(f"    /// {usage}")
    for theme in ("dark", "light"):
        space, r, g, b, a, src = parts[theme]
        tag = "" if space == "srgb" else f" ({space})"
        lines.append(f"    ///   {theme}: {src} ≈ {hexof(r, g, b)}{tag}" + (f" @{a:g}" if a < 1 else ""))
    def lit(p):
        space, r, g, b, a, _ = p
        fn = "srgb" if space == "srgb" else "p3"
        return f"{fn}({r:.4f}, {g:.4f}, {b:.4f}, {a:g})"
    lines.append(f"    static let {camel(name)} = themed(\"{name}\", dark: {lit(parts['dark'])}, light: {lit(parts['light'])})")

def px(v):
    m = re.fullmatch(r"([\d.]+)px", str(v))
    if not m:
        sys.exit(f"看不懂的尺寸：{v!r}")
    return float(m[1])

lines += ["", "    // MARK: 間距與尺寸（px）"]
for group in ("spacing", "layout", "radius"):
    for t in tokens[group]["tokens"]:
        lines.append(f"    /// {t.get('usage', '')}")
        lines.append(f"    static let {camel(t['name'])}: CGFloat = {px(t['value']):g}")

lines += ["", "    // MARK: 透明度"]
for t in tokens["opacity"]["tokens"]:
    lines.append(f"    /// {t.get('usage', '')}")
    lines.append(f"    static let {camel(t['name'])}: CGFloat = {float(t['value']):g}")

WEIGHTS = {400: ".regular", 500: ".medium", 600: ".semibold", 700: ".bold"}
lines += ["", "    // MARK: 字級"]
for groupdef in tokens["type"]["groups"]:
    for st in groupdef["styles"]:
        size = px(st["fontSize"])
        lh = st.get("lineHeight")
        if isinstance(lh, str):
            lh = px(lh) / size
        lines.append(f"    /// {st.get('usage', '')}")
        lh_lit = "nil" if lh is None else f"{lh:.4g}"
        lines.append(f"    static let {camel(st['name'])} = MSTypeStyle(size: {size:g}, "
                     f"weight: {WEIGHTS[st['fontWeight']]}, lineHeight: {lh_lit})")

families = [f.strip().strip('"') for f in tokens["type"]["families"]["sans"].split(",")]
lines += ["", "    // MARK: 字體", "    /// 依序嘗試；裝了的第一個就用。ui-sans-serif／system-ui 都對應到系統字。",
          f"    static let sansFamilies: [String] = {json.dumps(families, ensure_ascii=False)}"]
lines.append("}")
lines.append("")

OUT.write_text("\n".join(lines))
n_colors = len(tokens["color"]["tokens"])
n_sizes = sum(len(tokens[g]["tokens"]) for g in ("spacing", "layout", "radius"))
n_type = sum(len(g["styles"]) for g in tokens["type"]["groups"])
print(f"Generator: gen_tokens.py  source sha256:{digest[:16]}")
print(f"寫出 {OUT.name}：顏色 {n_colors} 個、尺寸 {n_sizes} 個、透明度 {len(tokens['opacity']['tokens'])} 個、字級 {n_type} 個")
srgb_count = n_colors * 2 - len(report)
print(f"色域：{n_colors * 2} 個顏色值中，sRGB {srgb_count} 個、其餘 {len(report)} 個如下" if report else f"色域：{n_colors * 2} 個顏色值全部在 sRGB 內")
for line in report:
    print(line)
