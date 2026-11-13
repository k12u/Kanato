#!/usr/bin/env -S python3 -I
"""開発用: 起動中の推論サーバーでかな漢字変換を評価する（標準ライブラリのみ）。

    python3 -I scripts/eval-conversion.py \\
        --target zenz=zenz:http://127.0.0.1:8801/v1 \\
        --target qwen3-1.7b=chat:http://127.0.0.1:8802/v1 \\
        [--cases scripts/eval-cases.json] [--few-shot] [--json results.json] [--show all|errors|none]

--target は 名前=形式:API Base URL。形式は Kanato の「API形式」に対応する。
  chat: /chat/completions に Kanato の ConversionPrompt.literal を system として送る
  zenz: /completions に U+EE00 + カタカナ [+ U+EE02 + 左文脈] + U+EE01 を送る
        （行ごと・英字を含む ASCII は素通し。Kanato の ZenzBackend と同じ手順。長い行の分割は省略）
  zenz3: zenz v3 系の形式 [U+EE02 + 左文脈] + U+EE00 + カタカナ + U+EE01（それ以外は zenz と同じ）
Kanato の出力検証（ConversionValidator）は再現しないため、Kanato では拒否される出力も表示される。
"""
import argparse
import json
import re
import statistics
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROMPT_SWIFT = REPO_ROOT / "Kanato/Conversion/ConversionPrompt.swift"

# --few-shot 用の例（テストセットと重複しないこと）
FEW_SHOTS = [
    ("わたしのなまえはやまだです", "私の名前は山田です"),
    ("あたらしいぱそこんをかいました", "新しいパソコンを買いました"),
    ("かいぎしつをよやくしてください。\nよろしくおねがいします。", "会議室を予約してください。\nよろしくお願いします。"),
]


def system_prompt():
    """Swift ソースから ConversionPrompt.literal の本文を取り出す"""
    source = PROMPT_SWIFT.read_text(encoding="utf-8")
    match = re.search(r'return """\n(.*?)\n\s*"""', source, re.S)
    if not match:
        raise SystemExit(f"システムプロンプトを読み取れません: {PROMPT_SWIFT}")
    lines = match.group(1).split("\n")
    indent = min(len(l) - len(l.lstrip(" ")) for l in lines if l.strip())
    return "\n".join(l[indent:] for l in lines)


def post(url, body, timeout):
    request = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def to_katakana(text):
    return "".join(chr(ord(c) + 0x60) if "ぁ" <= c <= "ゖ" or c in "ゝゞ" else c for c in text)


def zenz_segments(text):
    """ZenzBackend.segments と同じ規則で (そのまま残すか, 文字列) に分ける"""
    runs = []
    for c in text:
        is_ascii = 0x20 <= ord(c) <= 0x7E
        if runs and runs[-1][0] == is_ascii:
            runs[-1][1] += c
        else:
            runs.append([is_ascii, c])
    segments, pending = [], ""

    def flush():
        nonlocal pending
        if pending:
            has_hiragana = any(0x3041 <= ord(c) <= 0x309F for c in pending)
            segments.append((not has_hiragana, pending))
            pending = ""

    for is_ascii, run in runs:
        if is_ascii and any(c.isascii() and c.isalpha() for c in run):
            flush()
            segments.append((True, run))
        else:
            pending += run
    flush()
    return segments


def zenz_v2_prompt(input_katakana, context):
    return "\uee00" + input_katakana + ("\uee02" + context if context else "") + "\uee01"


def zenz_v3_prompt(input_katakana, context):
    return ("\uee02" + context if context else "") + "\uee00" + input_katakana + "\uee01"


def make_zenz(base_url, timeout, build_prompt=zenz_v2_prompt, **_):
    def convert(text):
        lines = []
        for line in text.split("\n"):
            core = line.strip()
            if not core:
                lines.append(line)
                continue
            converted = ""
            for passthrough, segment in zenz_segments(core):
                if passthrough:
                    converted += segment
                    continue
                context = converted[-40:]
                prompt = build_prompt(to_katakana(segment.strip()), context)
                result = post(f"{base_url}/completions", {
                    "prompt": prompt, "max_tokens": len(segment) * 2 + 16, "temperature": 0, "stream": False,
                }, timeout)
                lead = segment[: len(segment) - len(segment.lstrip())]
                trail = segment[len(segment.rstrip()):]
                converted += lead + (result["choices"][0]["text"] or "").strip() + trail
            lines.append(line[: len(line) - len(line.lstrip())] + converted + line[len(line.rstrip()):])
        return "\n".join(lines)
    return convert


def make_chat(base_url, timeout, system, few_shot):
    def convert(text):
        messages = [{"role": "system", "content": system}]
        if few_shot:
            for user, assistant in FEW_SHOTS:
                messages += [{"role": "user", "content": user}, {"role": "assistant", "content": assistant}]
        messages.append({"role": "user", "content": text})
        result = post(f"{base_url}/chat/completions", {
            "model": "eval", "messages": messages, "temperature": 0, "stream": False,
            "max_tokens": len(text) * 2 + 32,
        }, timeout)
        content = result["choices"][0]["message"]["content"] or ""
        return re.sub(r"^\s*<think>.*?</think>", "", content, flags=re.S).strip()
    return convert


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", action="append", required=True, help="名前=形式:API Base URL（複数指定可）")
    parser.add_argument("--cases", default=str(REPO_ROOT / "scripts/eval-cases.json"))
    parser.add_argument("--few-shot", action="store_true", help="chat 形式に変換例を付ける")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--json", help="結果を JSON で保存するパス")
    parser.add_argument("--show", choices=["all", "errors", "none"], default="errors")
    args = parser.parse_args()

    cases = json.loads(Path(args.cases).read_text(encoding="utf-8"))
    system = system_prompt()
    makers = {
        "zenz": make_zenz,
        "zenz3": lambda *a, **k: make_zenz(*a, build_prompt=zenz_v3_prompt, **k),
        "chat": make_chat,
    }

    results = {}
    for spec in args.target:
        try:
            name, rest = spec.split("=", 1)
            kind, base_url = rest.split(":", 1)
            maker = makers[kind]
        except (ValueError, KeyError):
            raise SystemExit(f"--target の形式が不正です: {spec}（例: zenz=zenz:http://127.0.0.1:8801/v1）")
        convert = maker(base_url.rstrip("/"), timeout=args.timeout, system=system, few_shot=args.few_shot)
        convert("てすと")  # ウォームアップ
        rows = []
        for case in cases:
            start = time.perf_counter()
            try:
                output, error = convert(case["input"]), None
            except Exception as exc:  # 評価を止めずに記録する
                output, error = None, str(exc)
            rows.append({**case, "output": output, "error": error,
                         "ms": (time.perf_counter() - start) * 1000, "exact": output == case["expected"]})
        results[name] = rows

    print(f"| モデル | 完全一致 | 中央値 | 最大 |\n|---|---|---|---|")
    for name, rows in results.items():
        times = [r["ms"] for r in rows]
        exact = sum(r["exact"] for r in rows)
        print(f"| {name} | {exact}/{len(rows)} | {statistics.median(times):.0f} ms | {max(times):.0f} ms |")
    if args.show != "none":
        for name, rows in results.items():
            for r in rows:
                if args.show == "all" or not r["exact"]:
                    mark = "OK" if r["exact"] else "NG"
                    shown = r["error"] and f"ERROR: {r['error']}" or json.dumps(r["output"], ensure_ascii=False)
                    print(f"{mark}\t{name}\t{shown}\t(期待: {json.dumps(r['expected'], ensure_ascii=False)})")
    if args.json:
        Path(args.json).write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
