"""提示音範本產生器：只用標準函式庫合成，不取樣任何既有音效。"""
import math, random, wave, array, sys, hashlib, pathlib
SR = 44100
OUT = pathlib.Path(sys.argv[1])
random.seed(7)

def hz(m): return 440.0 * 2 ** ((m - 69) / 12)

def env_exp(n, tau, attack=0.002):
    a = max(1, int(attack * SR))
    return [ (i / a if i < a else 1.0) * math.exp(-(i / SR) / tau) for i in range(n) ]

# ---- 柔和版的四種音色：低音域、慢起音、高泛音很少 ----
def partials(f, n, spec, attack):
    out = [0.0] * n
    for ratio, amp, tau in spec:
        if f * ratio > 8000: continue          # 8kHz 以上一律不要 —— 那就是「刺」的來源
        w = 2 * math.pi * f * ratio / SR
        e = env_exp(n, tau, attack)
        for i in range(n): out[i] += amp * e[i] * math.sin(w * i)
    return out

def felt(f, dur=1.3, vel=1.0):
    """毛氈鋼琴：琴槌包了毛氈，敲下去沒有「叮」，只有圓圓的一聲。"""
    return [vel * x for x in partials(f, int(dur * SR), ((1, 1, .55), (2, .22, .25), (3, .06, .12)), 0.008)]

def softbell(f, dur=1.8, vel=1.0):
    """柔鐘：幾乎是純正弦，只留一點點鐘的不協和泛音，起音 15ms，尾音長。"""
    return [vel * x for x in partials(f, int(dur * SR), ((1, 1, .8), (2.76, .05, .2)), 0.015)]

def woodlow(f, dur=1.0, vel=1.0):
    """低木琴：木琴的音色移到低音域，拿掉槌子的雜訊、壓低第二泛音。"""
    return [vel * x for x in partials(f, int(dur * SR), ((1, 1, .38), (3.93, .07, .06)), 0.005)]

def hum(f, dur=1.1, vel=1.0):
    """氣音：兩個微微走音的正弦慢慢浮起、慢慢退下，完全沒有敲擊感。最不打擾。"""
    n = int(dur * SR); out = []
    w1 = 2 * math.pi * f / SR; w2 = 2 * math.pi * f * 1.004 / SR; w3 = 2 * math.pi * f * 2 / SR
    for i in range(n):
        t = i / SR
        amp = min(1, t / 0.06) * math.exp(-max(0, t - 0.06) / 0.28)
        out.append(vel * amp * (0.5 * math.sin(w1 * i) + 0.5 * math.sin(w2 * i) + 0.08 * math.sin(w3 * i)))
    return out

VOICES = {"felt": felt, "softbell": softbell, "woodlow": woodlow, "hum": hum}

# 旋律只留一、兩個音：卡住了＝同一個音敲兩下、需要你＝往上一個大三度、跑完了＝一個低音
MOTIFS = {
    "felt":     {"urgent": [(67, 0, 1), (67, .17, .9)], "attention": [(60, 0, .9), (64, .15, 1)], "done": [(55, 0, .9)]},
    "softbell": {"urgent": [(69, 0, 1), (69, .2, .9)],  "attention": [(62, 0, .9), (66, .18, 1)], "done": [(57, 0, .9)]},
    "woodlow":  {"urgent": [(64, 0, 1), (64, .15, .9)], "attention": [(57, 0, .9), (61, .13, 1)], "done": [(52, 0, .9)]},
    "hum":      {"urgent": [(65, 0, 1), (65, .22, .9)], "attention": [(58, 0, .9), (62, .2, 1)],  "done": [(53, 0, .9)]},
}
# 戴耳機用：整體比上一版小 7–9 dB
PEAK_DB = {"urgent": -13.0, "attention": -15.0, "done": -19.0}

def reverb(x, wet=0.14):
    """Schroeder 殘響：4 個 comb ＋ 2 個 allpass，只加一點點空間感。"""
    combs = [(1557, .80), (1617, .79), (1491, .81), (1422, .78)]
    y = [0.0] * len(x)
    for d, g in combs:
        buf = [0.0] * d; k = 0
        for i, s in enumerate(x):
            o = buf[k]; buf[k] = s + o * g; k = (k + 1) % d; y[i] += o / 4
    for d, g in ((225, .5), (556, .5)):
        buf = [0.0] * d; k = 0; z = []
        for s in y:
            b = buf[k]; o = -s + b; buf[k] = s + b * g; k = (k + 1) % d; z.append(o)
        y = z
    return [x[i] + wet * y[i] for i in range(len(x))]

def render(voice, role):
    notes = MOTIFS[voice][role]
    parts = [(int(t * SR), VOICES[voice](hz(m), vel=v)) for m, t, v in notes]
    n = max(s + len(p) for s, p in parts) + int(0.4 * SR)
    mix = [0.0] * n
    for s, p in parts:
        for i, v in enumerate(p): mix[s + i] += v
    mix = reverb(mix, wet=0.10)
    fade_in = int(0.003 * SR)                  # 開頭 3ms 淡入：第一個取樣就滿音量會「啪」一聲
    for i in range(fade_in): mix[i] *= i / fade_in
    # 尾巴淡出到 0（不然停掉的那一刻會「啪」一聲），再修剪掉安靜的尾巴
    peak = max(abs(v) for v in mix) or 1
    last = max(i for i, v in enumerate(mix) if abs(v) > peak * 0.001)
    mix = mix[:last + 1]
    fade = int(0.08 * SR)
    for i in range(fade): mix[-fade + i] *= 1 - i / fade
    gain = 10 ** (PEAK_DB[role] / 20) / peak
    return [v * gain for v in mix]

OUT.mkdir(parents=True, exist_ok=True)
made = 0
for voice in VOICES:
    for role in ("urgent", "attention", "done"):
        data = render(voice, role)
        pcm = array.array("h", (max(-32767, min(32767, int(v * 32767))) for v in data))
        path = OUT / f"{voice}-{role}.wav"
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
        made += 1
print(f"產生 {made} 個（應為 {len(VOICES) * 3}）")
print(f"Generator: {pathlib.Path(__file__).name} sha256:" + hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()[:16])
